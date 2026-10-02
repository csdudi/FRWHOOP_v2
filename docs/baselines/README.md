# Baselines

This fork’s product work is **personal baselines on the device**. Charge, Layer 1, and Watchdog are three separate engines. They share the strap’s raw samples. They do **not** share usuals, green ranges, or TRUST scores. They are never averaged.

Watchdog never writes Layer 1. Layer 1 never scores the last 30 minutes. Neither path infers a treatment start from heart rate or names a drug. Charge / Recovery stay on their own engines. Illness nights do not refresh Layer 1 “last OK.” Watchdog learning freezes while an episode or personal-off is open. Bundled forecast graphs are **students**; official TimesFM 2.5 convert is deferred.

| Engine | Question | Window | Usual / range | Code |
|---|---|---|---|---|
| **Charge / Effort / Rest** | How recovered / loaded is today? | Nights and sessions that already feed Today | Charge’s own fold | `Baselines.swift`, `RecoveryScorer.swift` — **not rewritten** |
| **Layer 1 usuals** | What is usual for this person over days? | 7-day EWMA and 60-day gapped median, never mixed. Sleep + steps from `DailyMetric`. IMU energy and daytime stubs from unique-minute tapes, never invented twins. | Night / day series after enough completed days | `LongitudinalBaseline.swift`, `LBDayTape.swift` |
| **Watchdog (live)** | Did the last half-hour look like this person? | 30 one-minute bins, tick ~20 s (BG refresh may skip TimesFM) | UniTS / Swift-prior reconstruction ± model σ | `Watchdog.swift` |

## They stay separate

| | Layer 1 (long-term) | Watchdog (short-term) |
|---|---|---|
| **Lives on** | Baseline tab usuals / HOW OFF / treatment freeze | First card on Baseline: last 30 minutes |
| **Builds from** | Completed civil days and nights | This half-hour’s observed minutes + frozen Core ML |
| **Green / predicted range** | \(z\) vs each copy’s center ± \(k \times\) MAD | \(\hat{x} \pm \sigma\) from UniTS or the Swift prior |
| **TRUST** | How much that usual may judge **tonight** | How much to believe this vital’s in-range / off call **now** |
| **When it can speak** | After enough nights (4 week / 14 long; 21 for steps, active minutes, IMU) | After a filled window with a model hat — nights are **not** required |
| **Writes the other?** | No | No. Watchdog may *read* a shown Layer 1 usual as an optional prompt |

The only allowed coupling: Watchdog **reads** a shown Layer 1 copy (awake HR ≠ sleep RHR) and a mature still-phase sidecar to *tighten* the reconstruction prompt. Day tapes Watchdog **feeds** after a tick are Layer 1 **observations**, not 7-day / 60-day snapshots — `evaluate` still does not write those. The live corridor is never the long band. If Layer 1 is still learning, Watchdog still reconstructs.

How they work:

1. [Layer 1 — days and nights](LAYER1.md)
2. [Watchdog — last 30 minutes](WATCHDOG.md)

App surfaces: **Baseline** tab (live card + long-term usuals), **Treatment** marking (Layer 1 freeze only after the wearer logs a start). Models stay frozen Core ML; there is no on-device training.

Pins and test tapes live next to the engine: `Packages/StrandAnalytics/Baseline/units/` and `fixtures/`.
