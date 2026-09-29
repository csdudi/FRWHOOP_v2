# Layer 1 — days and nights

What is usual for this person over days? After they **log** a treatment start, how does tonight sit versus a **frozen** pre-start path?

Code: `LongitudinalBaseline.swift` (`param_set = v1.review`). This is the **long-term** usual. It is not the 30-minute Watchdog card, and Watchdog’s green corridor is not this band. Charge and Recovery stay on their own engines. All scoring is on-device.

It does **not** infer start time from heart rate. It does **not** name a drug. The two usuals below are **never averaged**. Missing stays missing: no overnight → daytime formulas, no invented SpO₂ nadir, no step-count of zero trained as a good day.

## Two copies, never mixed

Every night, each biometric series is scored twice:

| Copy | Window | Estimator | Role |
|---|---|---|---|
| **7-day** | Last 7 **completed** days, not tonight | Finite EWMA (span 7; HRV week can use span 10), MAD around that center | Recent level |
| **60-day** | Days T−60 … T−8 (53 slots; **7-day gap**) | Median + MAD, extremes trimmed | Longer core |

Tonight is scored, not trained. A series only **shows** after enough days (4 on the week copy; 14 long for most vitals; 21 for steps / active minutes / IMU / other waking-load and all-day rows). Until then the card stays quiet. **TRUST** is how much that usual may judge tonight; **HOW OFF** on the week box is hidden when TRUST is under 35.

HRV week span 10 trims T−10…T−8 from the long copy (`n_long` 50 instead of 53). That is *k_learn*, not a mix of the two usuals.

A skip-and-hold of the **center** (thin or missing night) does not present that held center as “tonight’s usual.” The card stays quiet or shows that the copy did not update.

## Series stay in their own context

Sleep RHR is never mixed with awake-rest HR or with steps. Catalog is **18** series. Sleep + steps still come from `DailyMetric`. IMU energy and the daytime / nadir / active-minute stubs come from **measured unique minutes** (`LBDayTape`, same rest / effort / sleep / freshness / 20 min recovery gates as live Watchdog). No rest+6 / ×0.88 twins. A series with no minutes that day stays empty.

| Context | What trains today | What stays empty until measured minutes exist |
|---|---|---|
| Sleep | RHR, ln(RMSSD), wrist temp, breathing, SpO₂ mean (`DailyMetric`) | SpO₂ nadir until ≥ 3 unique fresh sleep percents |
| Awake still / moving / all-day | Unique rest / effort / all-day minutes from the Watchdog window (HR, ln(RMSSD), SpO₂). Rest tape skips the 20 min post-workout window. | Any stub that has not met its minute floor (HR/HRV ≥ 8; SpO₂ ≥ 4) |
| Waking load | Steps (recorded). Movement energy when the strap has IMU. Active minutes when occupancy or locomotion is high. | Active minutes until at least one unique minute |

HRV math is on ln(RMSSD); the card shows ms. Each series has a floor so a tiny spread cannot turn a 1 bpm wiggle into a huge off call. IMU floor is 0.02 (family `imu`). Coverage with a **nil** coverage field is low-quality, not a free pass.

Zero or nil steps do not train as `.ok`.

## Movement energy (IMU sidecar)

Own series `wakingImuEnergy` — never mixed with HR or step count. Not a `DailyMetric` column. `BaselineStore` keeps a per-day accumulator (`lastTs`, unique unix minutes, sample-weighted mean). Re-ingesting the same 30-minute window does not double-count. Persist at most once per minute.

Establish N = 21. Coverage ≥ 60 unique minutes. Same 7-day / 60-day copies as every other series.

## One night

1. Build a daily observation from a **recorded** column, the IMU sidecar, or a published `LBDayTape` mean, or skip if the day is thin or confounded (felt ill, travel, extra med, alcohol, off-typical sleep/diet). An unmarked night is still clean — the log does not invent illness. Watchdog’s live confounder bit uses **calendar today** (and yesterday only if a sleep session is still open). Layer 1 `asOf` is still the night being scored.
2. Compare tonight to each copy (\(z\) vs center ± \(k \times\) spread, \(k = 2\)).
3. A large residual can flag “off usual” without immediately moving the center.
4. CUSUM tracks a slow shift across nights. Missing days skip the accumulator; they do not reset it.
5. If the wearer logged a treatment start, the trial layer **freezes** the pre-start path. Watchdog cannot invent that start.

### Medication labels

The daily log can mark **took scheduled**, **missed scheduled**, or **another medication**.

| Label | Drops the night from usuals? |
|---|---|
| Took scheduled | No |
| Missed scheduled | No (not a confounder by itself) |
| Another / extra medication | Yes |
| Illness, travel, alcohol, off-typical sleep or diet | Yes |

The card never names a drug as the cause of a change.

## What Watchdog may use (read only)

Watchdog **reads** a *shown* Layer 1 copy as an optional prompt (awake HR vs sleep RHR stay on separate copies; two copies are never averaged). A shown usual can raise live TRUST and supply a MAD floor for reconstruction σ. It does **not** gate the half-hour call: nights are not required before Watchdog can leave learning.

Watchdog **never writes** Layer 1 7-day / 60-day snapshots. After a live tick it may append unique-minute **observations** to `LBDayTape`. The live predicted range is UniTS / prior \(\hat{x} \pm \sigma\), not Layer 1 \(k \times\) MAD. See [WATCHDOG.md](WATCHDOG.md).

| Piece | Path |
|---|---|
| Engine | `Packages/StrandAnalytics/Sources/StrandAnalytics/LongitudinalBaseline.swift` |
| IMU sidecar | `LongitudinalImuBaseline.swift`, `BaselineStore` |
| Day tapes (stubs) | `LBDayTape.swift`, `BaselineStore.ingestWatchdogTape` |
| Trial / freeze | `LongitudinalBaselineTrial.swift` |
| App | `Strand/Data/BaselineStore.swift`, `BaselineMonitorView.swift`, `TreatmentMarkingView.swift` |
| Pins | `LongitudinalBaselineBiometricLogicTests`, `LongitudinalBaselinePass27Tests`, catalog / audit suites |
