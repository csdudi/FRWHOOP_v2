# Layer 1 Baseline — how it actually works

Short map for colleagues. Code: `LongitudinalBaseline.swift` (`param_set = v1.review`). This is the **days-and-nights** usual, not the 30-minute Watchdog card.

Charge and Recovery are separate engines. This path does not rewrite them. All scoring is on-device.

## The question

**What is usual for this person over days?** After they **log** a treatment start, how does tonight sit versus a **frozen** pre-start path?

It does **not** infer start time (`t0`) from heart rate. It does **not** name a drug. The two usuals below are **never averaged**.

## Two copies, never mixed

Every night, each biometric series is scored twice:

| Copy | Window | Estimator | What it is for |
|---|---|---|---|
| **7-day** | Last 7 **completed** days, not tonight | Finite EWMA (span 7, α = 0.25), MAD around that center | Recent level |
| **60-day** | Days T−60 … T−8 (53 slots; **7-day gap**) | Median + MAD, extremes trimmed | Longer core |

Tonight is **not** in either window. That is how “last night” cannot rewrite the usual it is compared to.

A series only **shows** after enough days (4 on the 7-day copy; 14 long for sleep/still-rest; 21 for waking / active / continuous). Until then the card stays quiet.

## What a “series” is

Contexts are separate rows. Sleep RHR is never mixed with awake-rest HR or with steps.

- Sleep: RHR, ln(RMSSD), wrist temp, breathing, SpO₂ mean / nadir
- Awake still: rest HR, HRV, SpO₂
- Awake moving: active HR, HRV, SpO₂
- Continuous: all-day HR / HRV / SpO₂ (needs enough minutes)
- Waking load: steps, active minutes

HRV math is on **ln(RMSSD)**; everything else stays in native units. Each series has a **floor** so a tiny MAD cannot make a 1 bpm wiggle look huge.

## One night

1. Build a daily observation (or skip if the day is too thin / confounded).
2. Compare tonight to each copy: \(z\) vs center ± \(k \times\) spread (\(k = 2\)).
3. **Hold vs learn:** a large residual can flag “off usual” without immediately moving the center (Huber / n-learn hold).
4. **CUSUM** tracks a slow shift across nights. Missing days skip the accumulator; they do not reset it.
5. If the wearer logged a treatment start, Phase B **freezes** the pre-`t0` path and scores wash-in / washout. Watchdog cannot invent that `t0`.

Daily log flags that already drop a Layer 1 night (felt ill, travel, extra med, alcohol, off-typical sleep/diet) keep that night out of the usual.

## What Watchdog may use

Watchdog **reads** shown Layer 1 usuals as a prompt (awake HR vs sleep RHR stay on separate copies). It **never writes** Layer 1 snapshots.

## Where to look

| Piece | Path |
|---|---|
| Engine | `Packages/StrandAnalytics/Sources/StrandAnalytics/LongitudinalBaseline.swift` |
| Trial / freeze | `LongitudinalBaselineTrial.swift` |
| App store / UI | `Strand/Data/BaselineStore.swift`, `BaselineMonitorView.swift` |
| Longer math | `docs/FRWHOOP_BASELINE_CONDENSED_PLAN.md` |
