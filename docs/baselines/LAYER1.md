# Layer 1 — days and nights

What is usual for this person over days? After they **log** a treatment start, how does tonight sit versus a **frozen** pre-start path?

Code: `LongitudinalBaseline.swift` (`param_set = v1.review`). This is not the 30-minute Watchdog card. Charge and Recovery stay on their own engines. All scoring is on-device.

It does **not** infer start time from heart rate. It does **not** name a drug. The two usuals below are **never averaged**.

## Two copies, never mixed

Every night, each biometric series is scored twice:

| Copy | Window | Estimator | Role |
|---|---|---|---|
| **7-day** | Last 7 **completed** days, not tonight | Finite EWMA (span 7), MAD around that center | Recent level |
| **60-day** | Days T−60 … T−8 (53 slots; **7-day gap**) | Median + MAD, extremes trimmed | Longer core |

Tonight is not in either window. A series only **shows** after enough days (4 on the week copy; 14 long for sleep/still-rest; 21 for waking / active / continuous). Until then the card stays quiet. **TRUST** is how much that usual may judge tonight; **HOW OFF** is hidden when TRUST is under 35.

## Series stay in their own context

Sleep RHR is never mixed with awake-rest HR or with steps.

- Sleep: RHR, ln(RMSSD), wrist temp, breathing, SpO₂
- Awake still / moving / all-day: their own HR, HRV, SpO₂ rows
- Waking load: steps, active minutes

HRV math is on ln(RMSSD). Each series has a floor so a tiny spread cannot turn a 1 bpm wiggle into a huge off call.

## One night

1. Build a daily observation, or skip if the day is thin or confounded (felt ill, travel, extra med, alcohol, off-typical sleep/diet).
2. Compare tonight to each copy (\(z\) vs center ± \(k \times\) spread, \(k = 2\)).
3. A large residual can flag “off usual” without immediately moving the center.
4. CUSUM tracks a slow shift across nights. Missing days skip the accumulator; they do not reset it.
5. If the wearer logged a treatment start, the trial layer **freezes** the pre-start path. Watchdog cannot invent that start.

## What Watchdog may use

Watchdog **reads** shown Layer 1 usuals as a prompt (awake HR vs sleep RHR stay on separate copies). It **never writes** Layer 1 snapshots.

| Piece | Path |
|---|---|
| Engine | `Packages/StrandAnalytics/Sources/StrandAnalytics/LongitudinalBaseline.swift` |
| Trial / freeze | `LongitudinalBaselineTrial.swift` |
| App | `Strand/Data/BaselineStore.swift`, `BaselineMonitorView.swift` |
