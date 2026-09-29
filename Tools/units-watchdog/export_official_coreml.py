#!/usr/bin/env python3
"""Export official UniTS + TimesFM 2.5 into Watchdog Core ML I/O.

TimesFM 3.0 pretrained weights are non-commercial / non-production
(timesfm-non-commercial-license-v1.0). This pipeline uses official
google/timesfm-2.5-200m-pytorch (Apache-2.0) and mims-harvard UniTS
units_x32_pretrain_checkpoint.pth.

Never train on the phone. Run from a machine with torch + coremltools:

    python3 Tools/units-watchdog/export_official_coreml.py
"""
from __future__ import annotations

import hashlib
import shutil
import sys
import urllib.request
from pathlib import Path

SEQ = 30
CH = 6
HORIZON = 5
UNITS_CKPT = (
    "https://github.com/mims-harvard/UniTS/releases/download/ckpt/"
    "units_x32_pretrain_checkpoint.pth"
)

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "Tools" / "units-watchdog" / ".official-ckpts"
PKG = ROOT / "Packages/StrandAnalytics/Sources/StrandAnalytics/Resources"
APP = ROOT / "Strand/Resources/Watchdog"
PIN = ROOT / "Packages/StrandAnalytics/Baseline/units"


def pin_sha(pkg: Path, name: str) -> None:
    weights = pkg / "Data" / "com.apple.CoreML" / "weights" / "weight.bin"
    src = weights if weights.exists() else pkg / "Manifest.json"
    sha = hashlib.sha256(src.read_bytes()).hexdigest()
    PIN.mkdir(parents=True, exist_ok=True)
    (PIN / name).write_text(sha + "  " + src.name + "\n")
    print("sha256", name, sha)


def download(url: str, dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 1_000_000:
        return dest
    print("download", url)
    urllib.request.urlretrieve(url, dest)
    return dest


def main() -> int:
    print(
        "Official Watchdog export:\n"
        "  UniTS  = mims-harvard units_x32_pretrain (Apache-2.0 / paper ckpt)\n"
        "  TimesFM = google/timesfm-2.5-200m-pytorch (Apache-2.0)\n"
        "  Not using TimesFM 3.0 (non-commercial production ban)."
    )
    try:
        import coremltools as ct
        import torch
        import torch.nn as nn
    except ImportError as e:
        print("need torch + coremltools:", e, file=sys.stderr)
        return 2

    CACHE.mkdir(parents=True, exist_ok=True)
    units_path = download(UNITS_CKPT, CACHE / "units_x32_pretrain_checkpoint.pth")
    ckpt = torch.load(units_path, map_location="cpu", weights_only=False)
    keys = list(ckpt.keys()) if isinstance(ckpt, dict) else []
    print("UniTS checkpoint keys", keys[:12], "… n=", len(keys) if keys else "tensor-or-module")

    # Official UniTS / TimesFM graphs do not match occupancy+prompt+30×6 I/O.
    # A traced official wrapper is the next conversion step (coremltools + timesfm pip).
    # Until that convert succeeds, do not overwrite the on-device packages from here
    # with a fake student.
    print(
        "Checkpoint fetched. Full Core ML convert of UniTS x32 + TimesFM 2.5-200m "
        "is a standalone export (custom ops / 200M weights). "
        "Do not replace UniTS_AD.mlpackage until ct.convert of the official graph passes."
    )
    print("saved", units_path, "bytes", units_path.stat().st_size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
