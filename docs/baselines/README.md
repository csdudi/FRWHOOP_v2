# Baselines

This fork’s product work is **personal baselines on the device**. Charge, Layer 1, and Watchdog are three separate engines. They are never averaged. Watchdog never writes Layer 1. Neither path infers a treatment start from heart rate or names a drug.

| Baseline | Question | Window | Code |
|---|---|---|---|
| **Charge / Effort / Rest** | How recovered / loaded is today? | Nights and sessions that already feed Today | `Baselines.swift`, `RecoveryScorer.swift` — **not rewritten** by Layer 1 or Watchdog |
| **Layer 1 usuals** | What is usual for this person over days? | 7-day and 60-day copies, never mixed | `LongitudinalBaseline.swift` |
| **Watchdog (live)** | Did the last half-hour look like this person? | 30 one-minute bins, tick ~20 s | `Watchdog.swift` |

How they work:

1. [Layer 1 — days and nights](LAYER1.md)
2. [Watchdog — last 30 minutes](WATCHDOG.md)

App surfaces: **Baseline** tab (live card + long-term usuals), **Treatment** marking (Layer 1 freeze only after the wearer logs a start). Models stay frozen Core ML; there is no on-device training.

Pins and test tapes live next to the engine: `Packages/StrandAnalytics/Baseline/units/` and `fixtures/`.
