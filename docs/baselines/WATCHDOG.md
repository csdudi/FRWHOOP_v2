# Watchdog — last 30 minutes

Did the last half-hour look like this person, given live motion and a reconstruction of this strip?

That is a **short-term** engine. It is not the 7-day / 60-day Layer 1 usual. Charge / Recovery are not rewritten. Watchdog **never writes** Layer 1 usuals. It never infers a treatment start from HR. It never names a drug. **No on-device training** (Core ML stays frozen). Wrist-off is **unavailable**, not recovered.

## Separate from Layer 1

| | Watchdog | Layer 1 |
|---|---|---|
| Question | Did *this* half-hour match the reconstruction? | What is usual across *days*? |
| Range on the card | Predicted \(\hat{x} \pm \sigma\) (model) | Center ± \(k \times\) MAD on each copy |
| Can speak without nights | Yes, once there is a hat on a covered window | No — establish N first |
| Writes the other | Never | Never |

Layer 1 is optional **input**. A shown usual (and a mature still sidecar) may tighten the prompt. They do not become the green corridor.

## Must stay true

These are the live-engine rules from leftover close-out 1–10. Charge is not rewritten.

| # | Rule |
|---|---|
| 1 | Day-tape HRV is **native RMSSD ms**. Layer 1 `toMath` is the only ln. Leftover ln buckets migrate once (`daytape.v2`). |
| 2 | Counts use the **measurement civil minute** of that channel. Re-reading a window, or holding one sparse temp while the wall clock moves, does not raise tape / band / sidecar `n`. A new measurement in the same wall minute still counts; `sessionAbs` and tape `activeMinutes` ignore held / tick-only minutes. |
| 3 | Sleep minutes never train `awakeRest*`. Band, sidecar, tape, and IMU learn only when `shouldTrainUsual` is true (quality ok, not confounded, not candidate/active/severe). Yesterday’s confounder applies only while last night’s sleep is still open. Detection still runs. |
| 4 | Each vital has its own seed, `nPresent`, ready (≥ 14 **that** channel), and first-day sidecar. Missing temp is not 0 and does not inherit HR ready. |
| 5 | Layer 1 last-OK / last-update use **clean, habit-matched** nights. Illness does not refresh freshness. |
| 6 | Personal-off is last fresh **native** HR / HRV vs the **logged felt-ill snapshot or 60-day** usual — never the walking 7-day, never the UniTS hat. Sustained personal-off is **candidate** even if the hat is quiet. Adaptation holds while Off or an episode is open. |
| 7 | Safety is last still-rest **extrema** (HR max/min, not the minute mean). An out-of-band RMSSD is kept; a 3-tap median must not erase it. Duration is held across thin / UniTS-fail ticks. Wrist-off stays unavailable. |
| 8 | First severe of an episode pages once. Persist and recovery advance on a **new valid observation minute**, not 20 s ticks or a held pair in a new wall minute. Missing data pauses recovery and does not resolve. Escalate needs a larger jump **and** 30 quiet minutes. |
| 9 | Live **Off** = `severity ≥ candidate` or safety or personal-off. It is not Layer 1 HOW OFF and not “last point outside the painted band.” Sparse C is fresh minutes / 30, never 1.0 from one pair. Thresholds stay `prior-untuned`. |
| 10 | Bundled graphs are **students** (`units-ad-coreml-v3` / `timesfm3-student-v3`). Not labelled official. Official Harvard UniTS / TimesFM 2.5 cannot ship today (Core ML convert fails; TimesFM 3.0 is license-banned). Wearer Early is shadow for student / hold. `present_mask` is a required Core ML input (1 = measured). A held forecast cube keeps emit clocks `now+60…now+300`; backcast scores those minutes. |

## Loop (on the phone)

`WatchdogService.tick` (foreground ~20 s, or a background refresh) → **active strap only** (HR, RR, temp, resp, SpO₂, steps, events, **IMU**) → 30×60 s window → `Watchdog.evaluate`. Sleep-open uses that strap’s sessions, not the dashboard WHOOP union. Switching `deviceId` clears live rings and loads that strap’s carry (v1 carry is not copied onto every new id). The UniTS prompt is last completed night, not the Baseline calendar swipe.

1. **Quality** — coverage, HR gaps, wrist-off. `deviceOff` wins; a leftover 2A37 clock cannot clear WRIST_OFF. Wrist-off stays unavailable. A **thin** window or UniTS failure still runs **safety** (fresh still-rest **extrema**, not the minute mean) without the models. An out-of-band RMSSD is kept for that rule; a 3-tap median must not erase it. Safety first-seen unix is held across thin ticks. Other quality fails do not run the models.
2. **Clocks** — each vital has its own freshness (HR/RHR: WHOOP packet clock; HRV 5 min; temp 8 min; resp / SpO₂ 6 min). Stale series are wiped (`maskStaleChannels`) **before** UniTS / TimesFM. Missing is nil, not BPM 0. Residuals and learning skip absent channels. The same sparse minute is not a new sample.
3. **Activity** — the 20-col row drives occupancy every minute. Unknown stays unknown (not walk). First **exercise** family holds 120 s before a workout name. After effort, still-band and rest day-tape wait 20 min; models still infer.
4. **Prompt** — UniTS / the Swift prior reconstruct this half-hour first. A shown Layer 1 usual (HR ≠ RHR) and a mature phase×activity sidecar may *tighten* that prompt. They do not block the short-term call. `evaluate` never writes 7-day / 60-day snapshots.
5. **UniTS reconstruct** — dotted expected line and predicted range for HR, RHR, HRV, temp, breathing, SpO₂. That corridor **is** the short-term baseline (model σ, not Layer 1 MAD).
6. **Direction** — two scores. Tanh `joint` decides “UniTS explained this strip” (workout names). Clip-sum `severityJoint` (RHR out, each \|r\| capped at 1) decides severe. If severity is severe, the name cannot stay `normal_*`.
7. **TimesFM** — at most once a minute (`forecastSource`: **student** / hold / test inject). Bundled graphs are students — not labelled official. Wearer Early is **shadow**. Official Harvard UniTS / TimesFM 2.5 cannot ship today (Core ML convert fails; 2.5 is ~925 MB univariate). TimesFM **3.0** must not ship. Cannot severe-notify. Background ticks may skip TimesFM and still run UniTS + safety. A held cube keeps the **emit** target times (`now+60…now+300`); backcast scores those minutes, not the last five present samples. Missing minutes are a present-mask (and occupancy + prompt fill on the student graphs).
8. **Confounders** — felt-ill / extra med **today** (calendar day, not Layer 1 `asOf`) stops still-band and rest-tape learning. Models still draw. Open sleep may still use yesterday’s log. Live UniTS prompt `asOf` is **calendar yesterday** (newest scored night ≤ today), not the Baseline calendar swipe.
9. **Green band** — small σ updates on the current phase×activity key after 14 **present** minutes of that channel (still/sleep, or a held workout family). A walk key does not write the still key. Post-workout is not learnable. The same **civil minute** does not increment `n`. Band and sidecar **do not learn** while severity is candidate/active/severe or Layer 1 **personal-off**. Personal-off is last fresh HR / HRV vs the **logged felt-ill / treatment freeze or 60-day** matching usual — not the walking 7-day, not the UniTS hat. A quiet hat with a sustained personal-off is still **candidate**.
10. **Safety** — still-wrist extrema can page only if that channel is **fresh**, including when coverage is incomplete. Historical backfill and `liveAlerts: false` cannot `shouldNotify`.
11. **Day tape** — after the tick, unique gated minutes go to Layer 1 `LBDayTape` only when `shouldTrainUsual` is true. Sleep minutes (col-19 or open interval) never write `awakeRest*`. That is observations, not snapshot write. `trainUsual: false` is a no-op.
12. **Carry / notify** — UserDefaults carry is namespaced by **active `deviceId`**; switching straps clears live rings and does not clone a leftover v1 blob onto the new id. First severe of an episode pages once. Mismatch persist is per **civil minute**. Delivery is queued / sent / failed. BG expiration **cancels** the in-flight tick.

## How each vital’s short-term baseline is calculated

Every channel is reconstructed independently. The live line is **observed** (empty minutes stay empty). The dotted line is \(\hat{x}\). The corridor is \(\hat{x} \pm \sigma\), with

\[\sigma_t = \max(\text{floor},\ \text{optional Layer 1 MAD},\ |\hat{x}_t|\times\text{reconFraction},\ \text{motion uncertainty})\]

That is **not** this window’s residual scatter and **not** Layer 1 \(k \times\) MAD. Gray until the phase×activity key is ready; then it may draw green.

| Vital | Observed tape | \(\hat{x}\) (Swift prior; UniTS replaces this when Core ML loads) | \(\sigma\) floor / recon frac |
|---|---|---|---|
| **Heart rate** | 1-minute mean of live / stored BPM | Rest prompt (Layer 1 awake HR, still sidecar, or population ~60) **plus** occupancy lift \(0.35 \times\) base \(\times\) occ | 5 bpm / 0.12 |
| **Resting HR** | Still / stand minutes only. Walk, run, lift, cycle, artifact never enter. Packed across the plot so a short rest tail is not a sliver at t=29. | Rest prompt only (not a second HR graph) | 5 bpm / 0.07 |
| **HRV** | 5-minute RMSSD on the minute grid (8 clean beats; 3-tap median). Jumpy one-minute tails are not a new usual. | **TimesFM is not this line** (forecast student only). UniTS-AD often reconstructs a flat prompt. Live hat = slow EMA of *this* window’s RMSSD (sleep/awake usual is only the seed), then occupancy drop. If UniTS hat span &lt; 4 ms, the card uses that short-term prior. | 8 ms / 0.22 |
| **Temp** | Wrist skin °C (family-aware decode). Sparse — WHOOP writes it periodically, not every second. | Rest prompt ± lagged occupancy (activity **lowers** expected wrist temp) | 0.35 °C / 0 |
| **Breathing** | 1. `respSample` as a **rate** (Oura milli-bpm). 2. Else WHOOP `respSample` **waveform** → 5-minute peak-detector (`respRateAndRRV`). 3. Else RSA from beat-accurate R–R in 5-minute blocks (often empty while awake). | Rest prompt + occupancy \(\times\) 60% of that rest | 3 /min / 0.10 |
| **SpO₂** | **Percent only** (50…110). Oura stores % in `red` (`ir = 0`). A percent-shaped `red` is kept even if IR is present. Raw WHOOP ADC pairs (thousands) are **not** converted with `red/ir` — that is not a percent. WHOOP 5 historical v18 has **no** `spo2_red` / `resp_rate_raw`; those graphs stay empty until a percent row exists. | Prompt or population, clamped 88…100. Motion is not a predicted desat. | 2 % / 0 |

UniTS, when loaded, emits \(\hat{x}\) and \(\sigma\) together from the same frozen package. The prior above is the load-fail fallback and the Core ML input prompt.

## TRUST (per vital)

\[50U + 35C + 15E\]

| Term | Meaning |
|---|---|
| **U** | Short-term first. A finite hat → \(U = 0.55\). A **shown** Layer 1 usual **replaces** that with that copy’s TRUST 0…1 (awake HR ≠ sleep RHR; copies never averaged). Caps 18 / 28 only when there is no hat and no shown usual. |
| **C** | **HR / RHR / HRV:** fill of the current period (LiveTail HR coverage after a rest cut, else the 30-minute HR window). **Temp / breathing / SpO₂:** fraction of **that** series’ tail minutes that are finite **and** fresh — not HR fill, and not 1.0 from a stale last pair. |
| **E** | Evidence vs reconstruction: \(1 - \text{energy}/\tau\) in range; persist × magnitude if off. |

**Sticky sparse TRUST.** Temp, breathing, and SpO₂ keep the last computed percent until **that vital’s last observation changes** (or it leaves the 30-minute window). Occupancy and HR fill must not walk the number between samples.

The page number (if shown) is the min of channels that have both an observation and a hat. Below 35% that row stays in **learning** and does not call a reading off. A filled 30-minute window with a model hat is enough to leave learning — Layer 1 nights are not required.

## Why breathing or SpO₂ can sit still

The strap can be sampling and the card can still be empty:

- **Breathing** — Watchdog now reads `respSample`. A WHOOP 4 waveform only becomes a rate after a usable 5-minute peak-detect. RSA-from-RR needs beat-accurate intervals and a plausible 8–25 /min median; daytime RR often fails that. WHOOP 5 v18 does not emit `resp_rate_raw`.
- **SpO₂** — only a **percent** row is scored. Two-channel ADC (e.g. red 18000 / IR 17000) is dropped on purpose. WHOOP 5 v18 does not emit `spo2_red` / `spo2_ir` (`spo2_candidate_82` is instrumentation, not a scored percent).

Empty minutes stay empty. The card does not invent a line.

## Notifications

A real push is extreme only: safety extrema, or a severe reconstruction that persists and is an abnormal / safety family. The **first** severe of an episode pages once **after the banner is sent**. `queued` is in-flight (no second page). `denied` (notifications off) and `failed` stay on the card and retry after the 30-minute cooldown. Persist and recovery count **new valid measurement minutes**, not 20 s ticks; missing data pauses recovery and does not resolve. After 15 in-range minutes the episode rearms. Not a diagnosis. No push for looking ahead, workouts, normal still/sleep, or history backfill. A cancelled background tick must not finish a page. Thresholds stay `prior-untuned` engineering defaults (1.0 / 1.6 / 2.4, persist 2 **minutes**) until a measured catalog is promoted.

Live **Off** is Watchdog `severity ≥ candidate`, safety, or personal-off (`Watchdog.liveOff` / `result.liveOff`). It is **not** Layer 1 HOW OFF and **not** “last point outside the painted band” alone. A row may show Off only when that door is true and that channel is contributing. Quality line **HR fill** is the 30-minute HR window, not temp/breathing/SpO₂ C.

## What the wearer sees

First card on **Baseline**: each vital in its own block — live value, predicted hi/lo, **per-vital** TRUST. No page TRUST, no event / activity headline. Long-term usuals stay on the same tab from Layer 1. DEBUG Test Centre can play short tapes (quiet, walk, learning, off wrist).

## Models on the phone

| File | Job |
|---|---|
| `UniTS_AD.mlpackage` | Student reconstruct. Official Harvard UniTS cannot convert to this I/O yet (`aten::Int` / `unfold`). |
| `TimesFM3_Student.mlpackage` | Student 5-min forecast (not TimesFM 3.0 — production-banned; 2.5-200m not converted). |
| Swift prior | Fallback if Core ML cannot load |

TimesFM 3.0 official weights are licensed `timesfm-non-commercial-license-v1.0` and **cannot** go in a production app. Official TimesFM 2.5-200m is Apache-2.0 but has no 30×6 Core ML graph. Official UniTS PyTorch probe works; `coremltools` fails on `DynamicLinear` / `unfold` / `aten::Int`. The phone loads the bundled students (or the Swift prior). Version strings stay `units-ad-coreml-v3` / `timesfm3-student-v3`. Both students take `present_mask` (1 = measured). TimesFM student is trained on the next five minutes, not a copy of now.

Live Watchdog only uses **30 minutes in** and **5 minutes out**, plus σ floors and a clipped `J`. On that strip, 2.5 vs 3.0 is a small hat difference. The large jump is formula-student → official 2.5 / official UniTS. Early (“looking ahead”) needs a real forecast cube (`forecastSource` official; inject is tests only). A hold cube cannot Early.

| Piece | Path |
|---|---|
| Evaluate | `Packages/StrandAnalytics/Sources/StrandAnalytics/Watchdog.swift` |
| Window / optical / resp | `WatchdogWindow.swift` |
| Quality / notify | `WatchdogV2.swift` |
| Events / band | `WatchdogEventGeometry.swift`, `WatchdogEventLabeler.swift`, `WatchdogPhaseUsual.swift` |
| UI | `Strand/Screens/WatchdogView.swift` |
| Live load | `Strand/Watchdog/WatchdogService.swift` (active `deviceId` only; carry `v2.{deviceId}`) |
| Notify | `Strand/Watchdog/WatchdogNotifier.swift` (queued / sent / failed) |
| Background tick | `Strand/Watchdog/WatchdogBackgroundScheduler.swift` (cancel on expire) |
| Day-tape ingest | `LBDayTape.swift` via `BaselineStore` |
| Official convert attempt (fails; does not overwrite students) | `Tools/units-watchdog/export_official_coreml.py` |
| Pins | `Packages/StrandAnalytics/Baseline/units/`, `WatchdogV40CloseoutTests`, `WatchdogStatisticsContractTests` |
| Planned sidecars (not shipped) | [ADDONS.md](ADDONS.md) — F08 episode note after **sent**; F09 7-day clinician pack + ledger; F04 time-to-usual. No scoring change. |
