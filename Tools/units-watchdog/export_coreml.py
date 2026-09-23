#!/usr/bin/env python3
"""Physics-only UniTS export (untrained 1×1 residual). Live students:

    python3 Tools/units-watchdog/train_export.py

I/O: occupancy (1,30), prompt (1,6), personal_scale (1,6) → hat, sigma (1,6,30).
The trained package also takes observed (1,6,30). Never train on the phone.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import coremltools as ct
import torch
import torch.nn as nn
import torch.nn.functional as F

SEQ = 30
CH = 6  # hr, rhr, hrv, temp, resp, spo2

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
    for t in range(SEQ):
        lo = max(0, t - taps + 1)
        parts.append(x[:, lo : t + 1].mean(dim=1, keepdim=True))
    return torch.cat(parts, dim=1)


def ema(x: torch.Tensor, alpha: float) -> torch.Tensor:
    y = x[:, 0:1]
    parts = [y]
    keep = 1.0 - alpha
    for t in range(1, SEQ):
        y = keep * y + alpha * x[:, t : t + 1]
        parts.append(y)
    return torch.cat(parts, dim=1)


class UniTSAD(nn.Module):
    """Reconstruction AD head. Physics decoder + 1×1 residual slot (zero at export).

    A later checkpoint can replace this module's weights; Watchdog still reads
    `hat` and `sigma` from the same call.
    """

    def __init__(self) -> None:
        super().__init__()
        self.delta_hat = nn.Conv1d(CH, CH, kernel_size=1, bias=True)
        self.delta_sigma = nn.Conv1d(CH, CH, kernel_size=1, bias=True)
        nn.init.zeros_(self.delta_hat.weight)
        nn.init.zeros_(self.delta_hat.bias)
        nn.init.zeros_(self.delta_sigma.weight)
        nn.init.zeros_(self.delta_sigma.bias)
        self.register_buffer("floors", FLOORS.view(1, CH, 1))
        self.register_buffer("rho", RHO.view(1, CH, 1))
        self.register_buffer("lo", LO.view(1, CH, 1))
        self.register_buffer("hi", HI.view(1, CH, 1))

    def forward(self, occupancy: torch.Tensor, prompt: torch.Tensor, personal_scale: torch.Tensor):
        occ = occupancy.clamp(0, 1)
        hr_s = occ
        hrv_s = causal_mean(occ, HRV_SMOOTH)
        temp_s = causal_mean(occ, TEMP_LAG)
        resp_s = occ

        hr_base = prompt[:, 0:1]
        rhr_base = prompt[:, 1:2]
        hrv_base = prompt[:, 2:3]
        temp_base = prompt[:, 3:4]
        resp_base = prompt[:, 4:5]
        spo2_base = prompt[:, 5:6]

        hr = (hr_base + HR_EFFORT * hr_base * hr_s).clamp(35, 190)
        hr = ema(hr, HR_TRACK)
        rhr = rhr_base.expand(-1, SEQ).clamp(35, 120)
        hrv = (hrv_base - HRV_DROP * hrv_s * (hrv_base / HRV_REF)).clamp(8, 250)
        hrv = ema(hrv, HRV_TRACK)
        temp = (temp_base + TEMP_GAIN * temp_s).clamp(28, 38)
        temp = ema(temp, TEMP_TRACK)
        resp = (resp_base + RESP_EFFORT * resp_base * resp_s).clamp(6, 30)
        resp = ema(resp, RESP_TRACK)
        spo2 = spo2_base.expand(-1, SEQ).clamp(88, 100)
        spo2 = ema(spo2, SPO2_TRACK)

        physics = torch.stack([hr, rhr, hrv, temp, resp, spo2], dim=1)
        hat = physics + self.delta_hat(physics)

        personal = personal_scale.view(-1, CH, 1)
        coup = torch.stack(
            [
                HR_UNCERT * hr_base * hr_s,
                torch.zeros_like(occ),
                HRV_UNCERT * hrv_s * (hrv_base / HRV_REF),
                TEMP_UNCERT * temp_s,
                RESP_UNCERT * resp_base * resp_s,
                torch.zeros_like(occ),
            ],
            dim=1,
        )
        recon = self.rho * hat.abs()
        sigma_phys = torch.maximum(torch.maximum(self.floors, personal), torch.maximum(recon, coup))
        sigma = sigma_phys + self.delta_sigma(sigma_phys).abs()
        return hat, sigma


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    pkg_out = root / "Packages/StrandAnalytics/Sources/StrandAnalytics/Resources/UniTS_AD.mlpackage"
    app_out = root / "Strand/Resources/Watchdog/UniTS_AD.mlpackage"
    pin = root / "Packages/StrandAnalytics/Baseline/units"

    model = UniTSAD().eval()
    occupancy = torch.zeros(1, SEQ)
    prompt = torch.tensor([[58.0, 58.0, 48.0, 33.1, 14.0, 97.0]])
    personal = torch.tensor([[5.0, 5.0, 8.0, 0.35, 3.0, 2.0]])
    traced = torch.jit.trace(model, (occupancy, prompt, personal))

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="occupancy", shape=(1, SEQ)),
            ct.TensorType(name="prompt", shape=(1, CH)),
            ct.TensorType(name="personal_scale", shape=(1, CH)),
        ],
        outputs=[
            ct.TensorType(name="hat"),
            ct.TensorType(name="sigma"),
        ],
        minimum_deployment_target=ct.target.iOS16,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
    )
    mlmodel.short_description = "UniTS reconstruction AD: hat and sigma for 6 Watchdog vitals × 30 min."
    mlmodel.author = "FRWHOOP Watchdog"
    mlmodel.version = "units-ad-coreml-v1"

    for dest in (pkg_out, app_out):
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.exists():
            import shutil
            shutil.rmtree(dest)
        mlmodel.save(str(dest))

    weights = pkg_out / "Data" / "com.apple.CoreML" / "weights" / "weight.bin"
    digest_src = weights if weights.exists() else pkg_out / "Manifest.json"
    sha = hashlib.sha256(digest_src.read_bytes()).hexdigest()
    (pin / "UniTS_AD.sha256").write_text(sha + "  " + digest_src.name + "\n")
    print("wrote", pkg_out)
    print("wrote", app_out)
    print("sha256", sha)


if __name__ == "__main__":
    main()
