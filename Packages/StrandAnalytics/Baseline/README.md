# Personal longitudinal baseline

This folder is the home of the baseline **plan**, next to the on-device analytics that already scores Charge, HRV, sleep, and strain (`Packages/StrandAnalytics`).

FRWHOOP_v2 has **no Node backend**. Nightly math runs in this package. Hosted `supabase/` is push/durability only and does not score baselines.

| File | Role |
|---|---|
| [FRWHOOP_BASELINE_REVIEW_CHANGES.md](FRWHOOP_BASELINE_REVIEW_CHANGES.md) | Review of v1: **eight equal requests** (FPR, per-biometric, spike vs shift, TRUST/HOW OFF, causality, freeze model, patient washout, primaries) — each with how + proof |
| [FRWHOOP_BASELINE_FRONTEND.md](FRWHOOP_BASELINE_FRONTEND.md) | NARA Baseline tab + treatment marking (phase C) — original contract |
| [FRWHOOP_BASELINE_FRONTEND_PROGRESS.md](FRWHOOP_BASELINE_FRONTEND_PROGRESS.md) | Plan + 12 Sep 2026 update: Baseline and Treatment screens |
| [FRWHOOP_BASELINE_IMPLEMENTATION.md](FRWHOOP_BASELINE_IMPLEMENTATION.md) | How to build on git HEAD; API; phases A (both copies) → B (trial) → C (NARA UI) — original map |
| [FRWHOOP_BASELINE_IMPLEMENTATION_PROGRESS.md](FRWHOOP_BASELINE_IMPLEMENTATION_PROGRESS.md) | Plan + 12 Sep 2026 update: engine (two usuals, freeze, confidence) |
| [FRWHOOP_BASELINE_CONDENSED_PLAN.md](FRWHOOP_BASELINE_CONDENSED_PLAN.md) | Math contract |
| [FRWHOOP_BASELINE_ONE_CALCULATION.md](FRWHOOP_BASELINE_ONE_CALCULATION.md) | One-morning walkthrough |
| [FRWHOOP_BASELINE_FIELD_METHODS.md](FRWHOOP_BASELINE_FIELD_METHODS.md) | Methods appendix |
| [FRWHOOP_BASELINE_FINAL_PLAN.md](FRWHOOP_BASELINE_FINAL_PLAN.md) | Source evaluation |
| [FRWHOOP_BASELINE_CHANGE_SUMMARY_16_SEP.md](FRWHOOP_BASELINE_CHANGE_SUMMARY_16_SEP.md) | 16 Sep: eight review items + same-day follow-ups |
| [FRWHOOP_BASELINE_CHANGE_SUMMARY_17_SEP.md](FRWHOOP_BASELINE_CHANGE_SUMMARY_17_SEP.md) | 17 Sep: NARA Baseline V1 — daily log v1 (suggestions needed), habit stratum, iPhone tabs |
| [fixtures/](fixtures/) | Synthetic daily tapes for tests (added with phase A code) |

The same files are also kept under `docs/` so the repo docs tree still has them. Edit both, or copy this folder over `docs/FRWHOOP_BASELINE_*.md` after a change.

**Code:** `LongitudinalBaseline.swift` + `LongitudinalBaselineTrial.swift` (Phase A+B math). App: `BaselineStore`, `BaselineMonitorView`, `TreatmentMarkingView`. Do not put this engine inside `Baselines.swift` / `RecoveryScorer.swift`. Kotlin twin and `IntelligenceEngine` shadow persist still to add. What is done vs leftover: the two `*_PROGRESS.md` files.
