#!/usr/bin/env python3
"""Train and export Watchdog Core ML students.

UniTS-AD: time–channel mixer. Learns joint reconstruction from occupancy +
prompt + observed window. Target is expected physiology (spike-robust), not
a copy of the live trace. Physics equations are the training teacher, not
the shipped 1×1 identity.

TimesFM-style student: patched causal decoder, 30-min context → 5-min
multivariate forecast. Same job as TimesFM 3.0 on this strip. Google 330M
weights are not bundled (non-commercial). Never train on the phone.
"""
from __future__ import annotations

import hashlib
import math
import shutil
from pathlib import Path

import coremltools as ct
import torch
import torch.nn as nn
import torch.nn.functional as F

SEQ = 30
CH = 6
HORIZON = 5
PATCH = 5
D_UNITS = 32
D_FM = 32
SEED = 21

HR_EFFORT = 0.50
HR_TRACK = 0.40
HRV_DROP = 4.96
HRV_REF = 50.0
HRV_TRACK = 0.28
HRV_SMOOTH = 2
TEMP_GAIN = -0.15
TEMP_LAG = 6
TEMP_TRACK = 0.18
RESP_EFFORT = 0.60
RESP_TRACK = 0.32
SPO2_TRACK = 0.12
FLOORS = torch.tensor([5.0, 5.0, 8.0, 0.35, 3.0, 2.0])
RHO = torch.tensor([0.12, 0.07, 0.22, 0.0, 0.10, 0.0])
HR_UNCERT = 0.15
HRV_UNCERT = 3.04
TEMP_UNCERT = 0.10
RESP_UNCERT = 0.20
LO = torch.tensor([35.0, 35.0, 8.0, 28.0, 6.0, 88.0])
HI = torch.tensor([190.0, 120.0, 250.0, 38.0, 30.0, 100.0])


def causal_mean(x: torch.Tensor, taps: int) -> torch.Tensor:
    parts = []
    for t in range(x.shape[-1]):
        lo = max(0, t - taps + 1)
        parts.append(x[..., lo : t + 1].mean(dim=-1, keepdim=True))
    return torch.cat(parts, dim=-1)


def causal_mean_seq(x: torch.Tensor, taps: int) -> torch.Tensor:
    parts = []
    for t in range(SEQ):
        lo = max(0, t - taps + 1)
        parts.append(x[:, lo : t + 1].mean(dim=1, keepdim=True))
    return torch.cat(parts, dim=1)


def ema(x: torch.Tensor, alpha: float) -> torch.Tensor:
    y = x[..., 0:1]
    parts = [y]
    keep = 1.0 - alpha
    for t in range(1, x.shape[-1]):
        y = keep * y + alpha * x[..., t : t + 1]
        parts.append(y)
    return torch.cat(parts, dim=-1)


def ema_seq(x: torch.Tensor, alpha: float) -> torch.Tensor:
    y = x[:, 0:1]
    parts = [y]
    keep = 1.0 - alpha
    for t in range(1, SEQ):
        y = keep * y + alpha * x[:, t : t + 1]
        parts.append(y)
    return torch.cat(parts, dim=1)


def physics_hat(occupancy: torch.Tensor, prompt: torch.Tensor) -> torch.Tensor:
    occ = occupancy.clamp(0, 1)
    tlen = occ.shape[-1]
    hr_s = occ
    hrv_s = causal_mean(occ, HRV_SMOOTH)
    temp_s = causal_mean(occ, TEMP_LAG)
    hr_base = prompt[:, 0:1]
    rhr_base = prompt[:, 1:2]
    hrv_base = prompt[:, 2:3]
    temp_base = prompt[:, 3:4]
    resp_base = prompt[:, 4:5]
    spo2_base = prompt[:, 5:6]
    hr = ema((hr_base + HR_EFFORT * hr_base * hr_s).clamp(35, 190), HR_TRACK)
    rhr = rhr_base.expand(-1, tlen).clamp(35, 120)
    hrv = ema((hrv_base - HRV_DROP * hrv_s * (hrv_base / HRV_REF)).clamp(8, 250), HRV_TRACK)
    temp = ema((temp_base + TEMP_GAIN * temp_s).clamp(28, 38), TEMP_TRACK)
    resp = ema((resp_base + RESP_EFFORT * resp_base * occ).clamp(6, 30), RESP_TRACK)
    spo2 = ema(spo2_base.expand(-1, tlen).clamp(88, 100), SPO2_TRACK)
    return torch.stack([hr, rhr, hrv, temp, resp, spo2], dim=1)


def physics_hat_seq(occupancy: torch.Tensor, prompt: torch.Tensor) -> torch.Tensor:
    """SEQ-only, Core ML friendly (loops over a Python constant)."""
    occ = occupancy.clamp(0, 1)
    hr_s = occ
    hrv_s = causal_mean_seq(occ, HRV_SMOOTH)
    temp_s = causal_mean_seq(occ, TEMP_LAG)
    hr_base = prompt[:, 0:1]
    rhr_base = prompt[:, 1:2]
    hrv_base = prompt[:, 2:3]
    temp_base = prompt[:, 3:4]
    resp_base = prompt[:, 4:5]
    spo2_base = prompt[:, 5:6]
    hr = ema_seq((hr_base + HR_EFFORT * hr_base * hr_s).clamp(35, 190), HR_TRACK)
    rhr = rhr_base.expand(-1, SEQ).clamp(35, 120)
    hrv = ema_seq((hrv_base - HRV_DROP * hrv_s * (hrv_base / HRV_REF)).clamp(8, 250), HRV_TRACK)
    temp = ema_seq((temp_base + TEMP_GAIN * temp_s).clamp(28, 38), TEMP_TRACK)
    resp = ema_seq((resp_base + RESP_EFFORT * resp_base * occ).clamp(6, 30), RESP_TRACK)
    spo2 = ema_seq(spo2_base.expand(-1, SEQ).clamp(88, 100), SPO2_TRACK)
    return torch.stack([hr, rhr, hrv, temp, resp, spo2], dim=1)


def physics_sigma(occupancy: torch.Tensor, prompt: torch.Tensor, personal: torch.Tensor, hat: torch.Tensor) -> torch.Tensor:
    occ = occupancy.clamp(0, 1)
    hr_s = occ
    hrv_s = causal_mean(occ, HRV_SMOOTH)
    temp_s = causal_mean(occ, TEMP_LAG)
    hr_base = prompt[:, 0:1]
    hrv_base = prompt[:, 2:3]
    resp_base = prompt[:, 4:5]
    coup = torch.stack(
        [
            HR_UNCERT * hr_base * hr_s,
            torch.zeros_like(occ),
            HRV_UNCERT * hrv_s * (hrv_base / HRV_REF),
            TEMP_UNCERT * temp_s,
            RESP_UNCERT * resp_base * occ,
            torch.zeros_like(occ),
        ],
        dim=1,
    )
    floors = FLOORS.to(hat.device).view(1, CH, 1)
    rho = RHO.to(hat.device).view(1, CH, 1)
    personal = personal.view(-1, CH, 1)
    recon = rho * hat.abs()
    return torch.maximum(torch.maximum(floors, personal), torch.maximum(recon, coup))


class MixerBlock(nn.Module):
    def __init__(self, seq: int, d: int):
        super().__init__()
        self.n1 = nn.LayerNorm(d)
        self.time = nn.Sequential(nn.Linear(seq, seq * 2), nn.GELU(), nn.Linear(seq * 2, seq))
        self.n2 = nn.LayerNorm(d)
        self.ff = nn.Sequential(nn.Linear(d, d * 2), nn.GELU(), nn.Linear(d * 2, d))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = self.time(self.n1(x).transpose(1, 2)).transpose(1, 2)
        x = x + y
        return x + self.ff(self.n2(x))


class UniTSAD(nn.Module):
    """UniTS-style reconstruction: mix time and channels, then hat + sigma."""

    def __init__(self):
        super().__init__()
        self.in_proj = nn.Linear(CH + 1 + CH, D_UNITS)
        self.blocks = nn.ModuleList([MixerBlock(SEQ, D_UNITS) for _ in range(3)])
        self.out_hat = nn.Linear(D_UNITS, CH)
        self.out_sig = nn.Linear(D_UNITS, CH)
        self.register_buffer("floors", FLOORS.view(1, CH, 1))
        self.register_buffer("lo", LO.view(1, CH, 1))
        self.register_buffer("hi", HI.view(1, CH, 1))

    def forward(self, occupancy, prompt, personal_scale, observed):
        personal = personal_scale.view(-1, CH, 1).clamp(min=0.05)
        prompt_t = prompt.view(-1, CH, 1)
        z = (observed - prompt_t) / personal
        occ = occupancy.clamp(0, 1).unsqueeze(1)
        phys = physics_hat_seq(occupancy, prompt)
        z_phys = (phys - prompt_t) / personal
        x = torch.cat([z, occ, z_phys], dim=1).transpose(1, 2)
        x = self.in_proj(x)
        for block in self.blocks:
            x = block(x)
        delta = torch.tanh(self.out_hat(x)).transpose(1, 2)
        hat = phys + 0.35 * personal * delta
        hat = torch.minimum(self.hi, torch.maximum(self.lo, hat))
        sig_raw = F.softplus(self.out_sig(x)).transpose(1, 2)
        sigma = torch.maximum(self.floors, personal) + sig_raw
        return hat, sigma


class CausalAttn(nn.Module):
    def __init__(self, d: int, heads: int, patches: int):
        super().__init__()
        self.heads = heads
        self.d = d
        self.patches = patches
        self.scale = (d // heads) ** -0.5
        self.qkv = nn.Linear(d, 3 * d)
        self.proj = nn.Linear(d, d)
        mask = torch.triu(torch.ones(patches, patches) * -1e4, diagonal=1)
        self.register_buffer("mask", mask)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        h = self.heads
        qkv = self.qkv(x).view(-1, self.patches, 3, h, self.d // h).permute(2, 0, 3, 1, 4)
        q, k, v = qkv[0], qkv[1], qkv[2]
        att = (q @ k.transpose(-2, -1)) * self.scale + self.mask
        att = att.softmax(dim=-1)
        y = (att @ v).transpose(1, 2).contiguous().view(-1, self.patches, self.d)
        return self.proj(y)


class TimesFMStudent(nn.Module):
    """Patched causal decoder: TimesFM-style job on 30×6 Watchdog strips."""

    def __init__(self):
        super().__init__()
        self.patches = SEQ // PATCH
        self.embed = nn.Linear(PATCH * CH, D_FM)
        self.pos = nn.Parameter(torch.zeros(1, self.patches, D_FM))
        self.n1 = nn.LayerNorm(D_FM)
        self.attn = CausalAttn(D_FM, 4, self.patches)
        self.n2 = nn.LayerNorm(D_FM)
        self.ff = nn.Sequential(nn.Linear(D_FM, D_FM * 2), nn.GELU(), nn.Linear(D_FM * 2, D_FM))
        self.head = nn.Linear(D_FM, HORIZON * CH)
        self.register_buffer("lo", LO.view(1, CH, 1))
        self.register_buffer("hi", HI.view(1, CH, 1))

    def forward(self, history: torch.Tensor, prompt: torch.Tensor, occupancy: torch.Tensor) -> torch.Tensor:
        x = history.transpose(1, 2).contiguous().view(-1, self.patches, PATCH * CH)
        x = self.embed(x) + self.pos
        x = x + self.attn(self.n1(x))
        x = x + self.ff(self.n2(x))
        y = self.head(x[:, -1, :]).view(-1, CH, HORIZON)
        y = y + prompt.unsqueeze(-1) * 0 + occupancy.mean(dim=1, keepdim=True).unsqueeze(-1) * 0
        last = history[:, :, -1:]
        return torch.minimum(self.hi, torch.maximum(self.lo, last + y))


def sample_batch(n: int, extra_future: int = 0) -> dict[str, torch.Tensor]:
    tlen = SEQ + extra_future
    occupancy = torch.rand(n, tlen)
    occupancy = occupancy.cumprod(dim=1).clamp(0, 1)
    occupancy = occupancy / occupancy.max(dim=1, keepdim=True).values.clamp(min=0.2)
    flip = torch.rand(n, 1) > 0.45
    occupancy = torch.where(flip, occupancy, torch.zeros_like(occupancy))
    prompt = torch.stack(
        [
            torch.empty(n).uniform_(52, 72),
            torch.empty(n).uniform_(52, 72),
            torch.empty(n).uniform_(25, 70),
            torch.empty(n).uniform_(32.2, 34.2),
            torch.empty(n).uniform_(11, 17),
            torch.empty(n).uniform_(95, 99),
        ],
        dim=1,
    )
    personal = torch.tensor([5.0, 5.0, 8.0, 0.35, 3.0, 2.0]).view(1, CH) * torch.empty(n, 1).uniform_(0.8, 1.3)
    clean = physics_hat(occupancy, prompt)
    noise = torch.randn_like(clean) * personal.view(n, CH, 1) * 0.12
    observed = clean + noise
    spike = torch.rand(n, 1, tlen) < 0.04
    observed = torch.where(spike, observed + personal.view(n, CH, 1) * 4, observed)
    lo = LO.view(1, CH, 1)
    hi = HI.view(1, CH, 1)
    observed = observed.clamp(lo, hi)
    return {
        "occupancy": occupancy,
        "prompt": prompt,
        "personal": personal,
        "clean": clean,
        "observed": observed,
    }


def train_units(steps: int = 1400) -> UniTSAD:
    torch.manual_seed(SEED)
    model = UniTSAD()
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    model.train()
    for step in range(steps):
        b = sample_batch(64)
        hat, sigma = model(b["occupancy"][:, :SEQ], b["prompt"], b["personal"], b["observed"][:, :, :SEQ])
        target = b["clean"][:, :, :SEQ]
        scale = b["personal"].view(-1, CH, 1).clamp(min=0.05)
        loss_h = F.smooth_l1_loss((hat - target) / scale, torch.zeros_like(hat))
        sig_t = physics_sigma(b["occupancy"][:, :SEQ], b["prompt"], b["personal"], target)
        loss_s = F.smooth_l1_loss(sigma, sig_t)
        loss = loss_h + 0.15 * loss_s
        opt.zero_grad()
        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        if step % 150 == 0 or step == steps - 1:
            print(f"units step {step} loss {loss.item():.4f} hat {loss_h.item():.4f}")
    model.eval()
    return model


def train_forecast(steps: int = 1200) -> TimesFMStudent:
    torch.manual_seed(SEED + 1)
    model = TimesFMStudent()
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    model.train()
    for step in range(steps):
        b = sample_batch(64, extra_future=HORIZON)
        hist = b["clean"][:, :, :SEQ]
        fut = b["clean"][:, :, SEQ : SEQ + HORIZON]
        pred = model(hist, b["prompt"], b["occupancy"][:, :SEQ])
        scale = b["personal"].view(-1, CH, 1).clamp(min=0.05)
        loss = F.smooth_l1_loss((pred - fut) / scale, torch.zeros_like(pred))
        opt.zero_grad()
        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        if step % 140 == 0 or step == steps - 1:
            print(f"timesfm step {step} loss {loss.item():.4f}")
    model.eval()
    return model


def export_ml(traced, inputs, outputs, dests, version: str, description: str) -> None:
    mlmodel = ct.convert(
        traced,
        inputs=inputs,
        outputs=outputs,
        minimum_deployment_target=ct.target.iOS16,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
    )
    mlmodel.short_description = description
    mlmodel.author = "FRWHOOP Watchdog"
    mlmodel.version = version
    for dest in dests:
        dest = Path(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.exists():
            shutil.rmtree(dest)
        mlmodel.save(str(dest))
        print("wrote", dest)


def pin_sha(pkg: Path, pin: Path, name: str) -> None:
    weights = pkg / "Data" / "com.apple.CoreML" / "weights" / "weight.bin"
    digest_src = weights if weights.exists() else pkg / "Manifest.json"
    sha = hashlib.sha256(digest_src.read_bytes()).hexdigest()
    pin.mkdir(parents=True, exist_ok=True)
    (pin / name).write_text(sha + "  " + digest_src.name + "\n")
    print("sha256", name, sha)


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    pkg_dir = root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Resources"
    app_dir = root / "Strand/Resources/Watchdog"
    pin = root / "Packages/StrandAnalytics/Baseline/units"

    units = train_units()
    occ = torch.zeros(1, SEQ)
    prompt = torch.tensor([[58.0, 58.0, 48.0, 33.1, 14.0, 97.0]])
    personal = torch.tensor([[5.0, 5.0, 8.0, 0.35, 3.0, 2.0]])
    observed = physics_hat(occ, prompt)
    with torch.no_grad():
        traced_u = torch.jit.trace(units, (occ, prompt, personal, observed))
    export_ml(
        traced_u,
        [
            ct.TensorType(name="occupancy", shape=(1, SEQ)),
            ct.TensorType(name="prompt", shape=(1, CH)),
            ct.TensorType(name="personal_scale", shape=(1, CH)),
            ct.TensorType(name="observed", shape=(1, CH, SEQ)),
        ],
        [ct.TensorType(name="hat"), ct.TensorType(name="sigma")],
        [pkg_dir / "UniTS_AD.mlpackage", app_dir / "UniTS_AD.mlpackage"],
        "units-ad-coreml-v2",
        "Trained UniTS-style reconstruction AD: hat and sigma, 6 vitals × 30 min.",
    )
    pin_sha(pkg_dir / "UniTS_AD.mlpackage", pin, "UniTS_AD.sha256")

    fm = train_forecast()
    hist = observed
    with torch.no_grad():
        traced_f = torch.jit.trace(fm, (hist, prompt, occ))
    export_ml(
        traced_f,
        [
            ct.TensorType(name="history", shape=(1, CH, SEQ)),
            ct.TensorType(name="prompt", shape=(1, CH)),
            ct.TensorType(name="occupancy", shape=(1, SEQ)),
        ],
        [ct.TensorType(name="forecast")],
        [pkg_dir / "TimesFM3_Student.mlpackage", app_dir / "TimesFM3_Student.mlpackage"],
        "timesfm3-student-v2",
        "TimesFM-style patched student: 6 vitals × 5 min forecast.",
    )
    pin_sha(pkg_dir / "TimesFM3_Student.mlpackage", pin, "TimesFM3_Student.sha256")

    with torch.no_grad():
        hat, _ = units(occ, prompt, personal, observed)
        fut = fm(hist, prompt, occ)
        print("units rest HR hat", hat[0, 0, -1].item())
        print("forecast next HR", fut[0, 0].tolist())


if __name__ == "__main__":
    main()
