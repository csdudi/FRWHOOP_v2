#!/usr/bin/env python3
"""Attempt official Harvard UniTS → Core ML (does not ship; convert fails).

Writes a probe artifact under .official-ckpts only. Never overwrites
UniTS_AD.mlpackage / TimesFM3_Student. TimesFM 3.0 weights are not converted.

    Tools/units-watchdog/.venv/bin/python Tools/units-watchdog/export_official_coreml.py

Never train on the phone.
"""
from __future__ import annotations

import shutil
import sys
import types
import urllib.request
from pathlib import Path

SEQ = 30
CH = 6
UNITS_CKPT = (
    "https://github.com/mims-harvard/UniTS/releases/download/ckpt/"
    "units_x32_pretrain_checkpoint.pth"
)

HERE = Path(__file__).resolve().parent
CACHE = HERE / ".official-ckpts"
VENDOR = HERE / "vendor"

FLOORS = [5.0, 5.0, 8.0, 0.35, 3.0, 2.0]
LO = [35.0, 35.0, 8.0, 28.0, 6.0, 88.0]
HI = [190.0, 120.0, 250.0, 38.0, 30.0, 100.0]


def download(url: str, dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 1_000_000:
        return dest
    print("download", url)
    urllib.request.urlretrieve(url, dest)
    return dest


def prompt_shapes(state: dict) -> dict[str, int]:
    out: dict[str, int] = {}
    for key, tensor in state.items():
        # module.prompt_tokens.ETTh1
        parts = key.split(".")
        if len(parts) >= 3 and parts[-2] == "prompt_tokens" or (
            len(parts) >= 3 and "prompt_tokens" in parts
        ):
            if parts[-2] == "prompt_tokens":
                name = parts[-1]
                if hasattr(tensor, "shape") and len(tensor.shape) == 4:
                    out[name] = int(tensor.shape[1])
    return out


def load_official_units(ckpt_path: Path):
    import torch

    sys.path.insert(0, str(VENDOR))
    from UniTS import Model  # type: ignore

    ckpt = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    args = ckpt["args"]
    raw = ckpt["student"]
    state = {k.replace("module.", "", 1): v for k, v in raw.items()}
    shapes = prompt_shapes(raw)
    configs = []
    for name, enc_in in sorted(shapes.items()):
        configs.append(
            (
                f"AD_{name}",
                {
                    "dataset": name,
                    "task_name": "anomaly_detection",
                    "enc_in": enc_in,
                    "seq_len": 32,
                    "pred_len": 0,
                    "num_class": 0,
                },
            )
        )
    configs.append(
        (
            "AD_Watchdog",
            {
                "dataset": "Watchdog",
                "task_name": "anomaly_detection",
                "enc_in": CH,
                "seq_len": 32,
                "pred_len": 0,
                "num_class": 0,
            },
        )
    )
    model = Model(args, configs, pretrain=False)
    missing, unexpected = model.load_state_dict(state, strict=False)
    print("loaded official UniTS missing", len(missing), "unexpected", len(unexpected))
    # Zero-shot 6-channel prompt: first 6 official ETTh1 tokens (7-variate).
    with torch.no_grad():
        src = model.prompt_tokens["ETTh1"][:, :CH].clone()
        model.prompt_tokens["Watchdog"].copy_(src)
        if "ETTh1" in model.mask_tokens:
            model.mask_tokens["Watchdog"].copy_(model.mask_tokens["ETTh1"][:, :CH])
    model.eval()
    return model, args


def _interp_linear(dl, in_f: int, out_f: int):
    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    fixed_in = dl.fixed_in
    fixed_weights = dl.weights[:, :fixed_in]
    dynamic_weights = dl.weights[:, fixed_in:]
    this_bias = dl.bias
    if in_f != dl.weights.size(1) or out_f != dl.weights.size(0):
        dynamic_weights = F.interpolate(
            dynamic_weights.unsqueeze(0).unsqueeze(0),
            size=(out_f, in_f - fixed_in),
            mode="bilinear",
            align_corners=False,
        ).squeeze(0).squeeze(0)
        if fixed_in != 0:
            fixed_weights = F.interpolate(
                fixed_weights.unsqueeze(0).unsqueeze(0),
                size=(out_f, fixed_in),
                mode="bilinear",
                align_corners=False,
            ).squeeze(0).squeeze(0)
    if out_f != dl.weights.size(0):
        this_bias = F.interpolate(
            this_bias.unsqueeze(0).unsqueeze(0).unsqueeze(0),
            size=(1, out_f),
            mode="bilinear",
            align_corners=False,
        ).squeeze(0).squeeze(0).squeeze(0)
    weight = torch.cat((fixed_weights, dynamic_weights), dim=1)
    lin = nn.Linear(in_f, out_f, bias=True)
    with torch.no_grad():
        lin.weight.copy_(weight)
        lin.bias.copy_(this_bias)

    class _Fixed(nn.Module):
        def __init__(self, inner: nn.Linear):
            super().__init__()
            self.inner = inner

        def forward(self, x, out_features=None):
            return self.inner(x)

    return _Fixed(lin)


def bake_dynamic_linears(units, wrapper_inputs) -> None:
    """Replace DynamicLinear with fixed Linear for the Watchdog 30→32 AD shapes."""
    import torch
    import torch.nn as nn
    from UniTS import DynamicLinear  # type: ignore

    seen: dict[nn.Module, tuple[int, int]] = {}

    def hook(mod, args, _out=None):
        x = args[0]
        out_f = args[1]
        if torch.is_tensor(out_f):
            out_f = int(out_f.detach().reshape(-1)[0].item())
        seen[mod] = (int(x.shape[-1]), int(out_f))

    handles = []
    for mod in units.modules():
        if isinstance(mod, DynamicLinear):
            handles.append(mod.register_forward_hook(hook))
    with torch.no_grad():
        wrapper_inputs()
    for h in handles:
        h.remove()
    print("baked DynamicLinear count", len(seen), seen and list(seen.values())[:8])

    def replace(parent: nn.Module) -> None:
        for name, child in list(parent.named_children()):
            if isinstance(child, DynamicLinear) and child in seen:
                in_f, out_f = seen[child]
                setattr(parent, name, _interp_linear(child, in_f, out_f))
            else:
                replace(child)

    replace(units)


def patch_units_for_coreml(units) -> None:
    """Hard-code Watchdog 32-step / 2-patch AD so coremltools sees no aten::Int."""
    import torch
    import torch.nn.functional as F
    import types

    prompt_len = 10
    token_len = 2
    prefix_seq = prompt_len + token_len
    seq_in = 32

    def tokenize(self, x, mask=None):
        means = x.mean(1, keepdim=True)
        x = x - means
        stdev = torch.sqrt(torch.var(x, dim=1, keepdim=True, unbiased=False) + 1e-5)
        x = x / stdev
        x = x.permute(0, 2, 1)
        n_vars = CH
        x = x.reshape(-1, token_len, 16)
        x = self.patch_embeddings.value_embedding(x)
        return x, means, stdev, n_vars, 0

    def pe_forward(self, x, offset=0):
        return self.pe[:, :, :token_len]

    def forecast_head(self, x_full, pred_len, tok_len):
        x_full = self.proj_in(x_full)
        x_pred = x_full[:, :, -token_len:]
        x = x_full.transpose(-1, -2)
        x = self.pos_proj(x, token_len)
        x = x.transpose(-1, -2)
        x = x + x_pred
        x = self.mlp(x)
        x = self.proj_out(x)
        bs, n_vars = x.shape[0], x.shape[1]
        x = x.reshape(bs, n_vars, token_len * self.patch_len)
        x = x.permute(0, 2, 1)
        return x

    def dynamic_linear(self, x, prefix_seq_len):
        x_func = x[:, :, prefix_seq:]
        x_seq = x[:, :, :prefix_seq]
        x_seq_out = self.seq_fc(x_seq, token_len)
        x_prompt = self.prompt_fc(x_seq, prompt_len)
        return torch.cat((x_prompt, x_seq_out, x_func), dim=-1)

    def backbone(self, x, prefix_len, seq_len):
        for block in self.blocks:
            x = block(x, prefix_seq_len=prefix_seq, attn_mask=None)
        return x

    def anomaly_detection(self, x, x_mark, task_id):
        prefix_prompt = self.prompt_tokens["Watchdog"]
        x, means, stdev, n_vars, padding = self.tokenize(x)
        x = self.prepare_prompt(
            x, n_vars, prefix_prompt, None, None, task_name="anomaly_detection"
        )
        x = self.backbone(x, prompt_len, token_len)
        x = self.forecast_head(x, seq_in, token_len)
        x = x[:, :seq_in]
        x = x * stdev[:, 0, :].unsqueeze(1)
        x = x + means[:, 0, :].unsqueeze(1)
        return x

    units.tokenize = types.MethodType(tokenize, units)
    units.backbone = types.MethodType(backbone, units)
    units.anomaly_detection = types.MethodType(anomaly_detection, units)
    units.position_embedding.forward = types.MethodType(pe_forward, units.position_embedding)
    units.forecast_head.forward = types.MethodType(forecast_head, units.forecast_head)
    from UniTS import DynamicLinearMlp  # type: ignore

    for mod in units.modules():
        if isinstance(mod, DynamicLinearMlp):
            mod.dynamic_linear = types.MethodType(dynamic_linear, mod)


def build_wrapper(units):
    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    class WatchdogOfficialUniTS(nn.Module):
        """Official Harvard reconstruct → Watchdog hat/sigma."""

        def __init__(self, units_model: nn.Module):
            super().__init__()
            self.units = units_model
            self.register_buffer("floors", torch.tensor(FLOORS).view(1, CH, 1))
            self.register_buffer("lo", torch.tensor(LO).view(1, CH, 1))
            self.register_buffer("hi", torch.tensor(HI).view(1, CH, 1))
            self.task_id = next(
                i
                for i, cfg in enumerate(units_model.configs_list)
                if cfg[1]["dataset"] == "Watchdog"
            )

        def forward(self, occupancy, prompt, personal_scale, observed):
            # observed: (1, 6, 30) → UniTS (1, 32, 6) with prompt fill + pad.
            personal = personal_scale.view(-1, CH, 1).clamp(min=0.05)
            prompt_t = prompt.view(-1, CH, 1)
            fill = torch.where(observed == 0, prompt_t.expand_as(observed), observed)
            x = fill.transpose(1, 2)
            pad = 2
            x = F.pad(x, (0, 0, 0, pad))
            recon = self.units.anomaly_detection(x, None, self.task_id)
            hat = recon[:, :SEQ, :].transpose(1, 2)
            hat = torch.minimum(self.hi, torch.maximum(self.lo, hat))
            sigma = torch.maximum(self.floors, personal)
            _ = occupancy
            return hat, sigma

    return WatchdogOfficialUniTS(units)


def convert(wrapper, dest: Path) -> None:
    import coremltools as ct
    import torch

    occupancy = torch.zeros(1, SEQ)
    prompt = torch.tensor([[60.0, 58.0, 48.0, 33.1, 14.0, 97.0]])
    personal = torch.tensor([[5.0, 5.0, 8.0, 0.35, 3.0, 2.0]])
    observed = prompt.unsqueeze(-1).expand(1, CH, SEQ).contiguous()
    traced = torch.jit.trace(
        wrapper,
        (occupancy, prompt, personal, observed),
        strict=False,
    )
    ml = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="occupancy", shape=(1, SEQ)),
            ct.TensorType(name="prompt", shape=(1, CH)),
            ct.TensorType(name="personal_scale", shape=(1, CH)),
            ct.TensorType(name="observed", shape=(1, CH, SEQ)),
        ],
        outputs=[
            ct.TensorType(name="hat"),
            ct.TensorType(name="sigma"),
        ],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS16,
    )
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        shutil.rmtree(dest)
    ml.save(str(dest))
    print("wrote", dest)


def main() -> int:
    print(
        "Official UniTS Core ML convert (probe only; students stay shipped):\n"
        "  UniTS  = mims-harvard units_x32_pretrain (MIT)\n"
        "  TimesFM 3.0 weights are not converted"
    )
    try:
        import coremltools as ct  # noqa: F401
        import torch
        import timm  # noqa: F401
    except ImportError as e:
        print("need torch + coremltools + timm:", e, file=sys.stderr)
        print("use Tools/units-watchdog/.venv/bin/python", file=sys.stderr)
        return 2

    units_path = download(UNITS_CKPT, CACHE / "units_x32_pretrain_checkpoint.pth")
    units, _ = load_official_units(units_path)
    wrapper = build_wrapper(units)
    wrapper.eval()
    occupancy = torch.zeros(1, SEQ)
    prompt = torch.tensor([[60.0, 58.0, 48.0, 33.1, 14.0, 97.0]])
    personal = torch.tensor([[5.0, 5.0, 8.0, 0.35, 3.0, 2.0]])
    observed = prompt.unsqueeze(-1).expand(1, CH, SEQ).contiguous()

    def _probe():
        return wrapper(occupancy, prompt, personal, observed)

    bake_dynamic_linears(units, _probe)
    patch_units_for_coreml(units)
    wrapper.eval()
    with torch.no_grad():
        hat, sigma = wrapper(occupancy, prompt, personal, observed)
    print("probe hat", tuple(hat.shape), "sigma", tuple(sigma.shape), "mean", float(hat.mean()))

    dest = CACHE / "UniTS_AD.official.mlpackage"
    convert(wrapper, dest)
    print("probe package only:", dest)
    print("shipped UniTS_AD / TimesFM3_Student not overwritten")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
