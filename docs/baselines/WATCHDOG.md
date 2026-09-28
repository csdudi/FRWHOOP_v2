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

## Loop (on the phone)

`WatchdogService.tick` → 30×60 s window → `Watchdog.evaluate`:

1. **Quality** — coverage, freshness, gaps. Wrist-off does not run the models.
2. **Activity** — motion / steps / class as a hint, not a calendar workout title.
3. **Prompt** — UniTS / the Swift prior reconstruct this half-hour first. A shown Layer 1 usual (HR ≠ RHR) and a mature phase×activity sidecar may *tighten* that prompt. They do not block the short-term call. Still no Layer 1 write.
4. **UniTS reconstruct** — dotted expected line and predicted range for HR, RHR, HRV, temp, breathing, SpO₂. That corridor **is** the short-term baseline.
5. **Direction** — all six channels, equal weight. \(J = \sum \min(\|r_k\|, 1)\). RHR is not a second HR addend.
6. **TimesFM student** — at most once a minute. Can show **Looking ahead**. Cannot severe-notify.
7. **Events** — exclusive name after a 120 s family hold. No human labels. Workout only if reconstruction is quiet.
8. **Green band** — small σ updates on the current phase×activity key after 14 **minutes** (still/sleep, or a held workout family). A walk key does not write the still key. Forecast-drift and spikes do not widen it. Session ±5% after ready + 8 min.
9. **Safety** — still-wrist extrema can page without the models.

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
| **C** | **HR / RHR / HRV:** fill of the current period (LiveTail HR coverage after a rest cut, else the 30-minute HR window). **Temp / breathing / SpO₂:** 1.0 while that vital still has a paired reading — **not** sliding HR coverage. |
| **E** | Evidence vs reconstruction: \(1 - \text{energy}/\tau\) in range; persist × magnitude if off. |

**Sticky sparse TRUST.** Temp, breathing, and SpO₂ keep the last computed percent until **that vital’s last observation changes** (or it leaves the 30-minute window). Occupancy and HR fill must not walk the number between samples.

The page number (if shown) is the min of channels that have both an observation and a hat. Below 35% that row stays in **learning** and does not call a reading off. A filled 30-minute window with a model hat is enough to leave learning — Layer 1 nights are not required.

## Why breathing or SpO₂ can sit still

The strap can be sampling and the card can still be empty:

- **Breathing** — Watchdog now reads `respSample`. A WHOOP 4 waveform only becomes a rate after a usable 5-minute peak-detect. RSA-from-RR needs beat-accurate intervals and a plausible 8–25 /min median; daytime RR often fails that. WHOOP 5 v18 does not emit `resp_rate_raw`.
- **SpO₂** — only a **percent** row is scored. Two-channel ADC (e.g. red 18000 / IR 17000) is dropped on purpose. WHOOP 5 v18 does not emit `spo2_red` / `spo2_ir` (`spo2_candidate_82` is instrumentation, not a scored percent).

Empty minutes stay empty. The card does not invent a line.

## Notifications

A real push is extreme only: safety extrema, or a severe reconstruction that persists and is an abnormal / safety family. Not a diagnosis. No push for looking ahead, workouts, or normal still/sleep. Thresholds stay `prior-untuned` (1.0 / 1.6 / 2.4, persist 2 ticks) until a measured catalog is promoted.

## What the wearer sees

First card on **Baseline**: each vital in its own block — live value, predicted hi/lo, **per-vital** TRUST. No page TRUST, no event / activity headline. Long-term usuals stay on the same tab from Layer 1. DEBUG Test Centre can play short tapes (quiet, walk, learning, off wrist).

## Models on the phone

| File | Job |
|---|---|
| `UniTS_AD.mlpackage` | Reconstruct this 30-minute strip |
| `TimesFM3_Student.mlpackage` | Short forecast student |
| Swift prior | Fallback if Core ML cannot load |

| Piece | Path |
|---|---|
| Evaluate | `Packages/StrandAnalytics/Sources/StrandAnalytics/Watchdog.swift` |
| Window / optical / resp | `WatchdogWindow.swift` |
| Quality / notify | `WatchdogV2.swift` |
| Events / band | `WatchdogEventGeometry.swift`, `WatchdogEventLabeler.swift`, `WatchdogPhaseUsual.swift` |
| UI | `Strand/Screens/WatchdogView.swift` |
| Live load | `Strand/Watchdog/WatchdogService.swift` |
| Pins | `Packages/StrandAnalytics/Baseline/units/` |
