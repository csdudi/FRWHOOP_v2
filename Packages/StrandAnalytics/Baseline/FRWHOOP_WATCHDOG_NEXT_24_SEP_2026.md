# Watchdog — six review items, plan + implementation (24 Sep 2026)

**This is the most dynamic Watchdog / live Baseline we have shipped.** `config_version = watchdog-v2.5`, event geometry `geometry-v2-selflabel`.

**Humans do not label events.** No accept / reject / ±60 s cut nudge. UniTS teaches **what** (does reconstruction explain the vitals?). TimesFM helps **when**. `WatchdogEventMemory` keeps EMA prototypes of those residual signatures and names the next similar stretch. Wrist-off / gap / artifact / safety stay **device rules**. A personal WHOOP night is **not** a clinical label source (`real_whoop5: not_run`).

**In the app now (24 Sep night).** Equal-weight `WatchdogDirection`; forecast **Early**; session σ ±5%; 30×20 activity; self-label geometry + memory; `WatchdogBand` medium EMA (≤2% / tick, 0.75–1.40 of first typical width). Core ML may still load v2 occupancy. Thresholds remain **`prior-untuned`**.

Gate: `cd Packages/StrandAnalytics && swift test --filter Watchdog`. Green band is **`band-v2-medium`**. Log at the bottom.

Keep copies in sync: `docs/FRWHOOP_WATCHDOG_NEXT_24_SEP_2026.md` and `Packages/StrandAnalytics/Baseline/FRWHOOP_WATCHDOG_NEXT_24_SEP_2026.md`.

Hard rules do not change: Charge / Recovery are not rewritten; Watchdog never writes Layer 1 usuals; never infer `t0` from HR; never name a drug or a disease; on-device scoring; wrist-off is **unavailable**; **no on-device training**.

---

## What is wrong in v2.2 (shared diagnosis)

| Request | What the code does today | Why that is not the request |
|---|---|---|
| 1 Joint / direction | `WatchdogScores.joint = max(L2, max_i e_i)`. Residual energy is unsigned. | Loudest vital **is** the joint score. Direction of the other five is unused. |
| 2 Thresholds | `tNote=1.0`, `tActive=1.6`, `tSevere=2.4`, `rearmTicks=15`, `escalateDelta=0.5` | Engineering priors. No labeled events, no rule for where one event ends and the next starts. |
| 3 Green band | Model σ + quiet-EMA floor + artifact ×1.7. `sigma_scale = 1.0` | No coverage target. Later widening does not reuse the same caution as the first band. |
| 4 Activity | 8-way class, then `effortOccupancy` walk→0.32, run→0.85 into `(1,30)` | The model never sees motion richness. A lookup decides physiology. |
| 5 Forecast | Forecast **zeroed** unless `reconJ ≥ tNote`. Severity on `fused = max(recon, 0.5·forecast)` | Cannot raise Early while recon is quiet. Forecast can still push severe. |
| 6 Personal | Quiet EMA `α=0.08` after 8 ticks floors σ; `quietJointEma` subtracts up to 0.4 from *J* | Minutes redefine the decision surface. No per-phase / per-activity core. |

---

## Channel order (frozen)

Every vector below is this order. Weights are **exactly equal** whenever a channel is present.

| Index | Channel | Card name | Residual sign meaning |
|---|---|---|---|
| 0 | `hr` | Heart rate | \(r>0\) live above hat |
| 1 | `rhr` | Resting HR | \(r>0\) live above hat; **absent** on walk/run/cycle/resistance/artifact minutes |
| 2 | `hrv` | HRV (5-min RMSSD) | \(r>0\) live above hat |
| 3 | `temp` | Wrist temp | \(r>0\) live above hat |
| 4 | `resp` | Breathing | \(r>0\) live above hat |
| 5 | `spo2` | SpO₂ % | \(r>0\) live above hat |

There is **no privileged autonomic subset**. Temp and SpO₂ are not “extra.” If RHR is masked, the other present channels **renormalize** so each still has weight \(1/n_{\mathrm{present}}\).

---

## 1. Dynamic equal-weight direction of all six biometrics

### Request (updated)

Track the **direction** of **all** biometrics, **every tick**, dynamically. They all have **equal weight** in the direction calculation. Coordinated moderate motion across several vitals must matter; one extreme vital must not own the joint score.

### Why v2.2 and the first 24 Sep draft both fail this

`max(L2, max)` ignores direction and hands the score to one channel. The first draft’s concordance \(C\) only counted HR / HRV / resp and treated temp / SpO₂ as breadth-only. That is **unequal** weight. This revision deletes the privileged packet.

### What “direction” is

On every 20 s tick, after quality pass + reconstruct + σ:

1. Last **paired** minute per present channel: \(r_k = (x_k - \hat{x}_k) / \sigma_k\).
2. Also a **robust 30-min median** \(\tilde{r}_k\) of paired \(r_k\) in the window (ignore nils). The live direction uses a **3-tick EMA of \(r_k\)** so a single PPG glitch does not flip a sign: \( \bar{r}_k \leftarrow 0.5\,\bar{r}_k + 0.5\,r_k \) (carry fields `dirEma[6]`).
3. Bound so magnitude cannot steal the direction vote:
   \[
   d_k = \tanh(\bar{r}_k)
   \]
   Each \(d_k \in (-1,1)\). A +4σ HR and a +0.8σ HRV both sit on the same bounded scale before they are averaged.
4. **Presence mask** \(m_k \in \{0,1\}\): 0 if that minute has no pair, or channel is RHR and the activity family is not still/stand/sleep. \(n = \sum m_k\). If \(n=0\), direction is undefined; joint is 0; card does not invent a packet.
5. **Equal weight**
   \[
   w_k = \frac{m_k}{n}
   \]
   Always \(w_k = 1/n\) for every present channel. Never 2× on HR. Never 0× on temp because “it is not autonomic.”

### Direction summary (what we track)

| Quantity | Formula | Role |
|---|---|---|
| Direction vector | \(\mathbf{d} = (d_0,\ldots,d_5)\) | Live signs + bounded strength |
| Equal-weight mean direction | \(\mu_d = \sum_k w_k d_k\) | Net signed drift (can be near 0 if half up / half down) |
| Equal-weight RMS direction | \(D = \sqrt{\sum_k w_k d_k^2}\) | How much the **group** has moved; one huge \(d_k\) cannot exceed 1 |
| Breadth | \(B = \sum_k w_k \mathbf{1}[|d_k| \ge d_{\mathrm{soft}}]\) | Share of **present** channels that actually turned; \(d_{\mathrm{soft}}=0.40\) until item 2 retunes |
| Alignment | \(A = 1 - \mathrm{Var}_w(\mathrm{sign}(d_k) \mid |d_k|\ge d_{\mathrm{soft}})\) mapped to \([0,1]\) | High when the channels that moved **agree in the sense that several moved**, not when one moved. Implementation: among present channels with \(|d_k|\ge d_{\mathrm{soft}}\), \(A = n_{\mathrm{soft}}/n\) (already equal-weight breadth). **Do not** score “HR up + HRV down” as extra. Alignment **is** breadth under equal weights. |

**Joint reconstruction** (no `max`, no privileged γ):

\[
J_{\mathrm{recon}} = D \times (1 + \beta B), \qquad \beta = 1.0 \text{ until item 2}
\]

- One channel at \(d=0.95\), others ~0: \(D \approx \sqrt{1/6}\cdot 0.95 \approx 0.39\), \(B\approx 1/6\), \(J\) stays small.
- Three channels at \(|d|\approx 0.65\), three ~0: \(D \approx \sqrt{0.5}\cdot 0.65 \approx 0.46\), \(B=0.5\), \(J\approx 0.69\).
- Six channels at \(|d|\approx 0.55\): \(D\approx 0.55\), \(B=1\), \(J\approx 1.10\).

That is the whole point: **the same per-channel move is worth more when more channels do it**, and **every channel’s direction vote costs the same**.

Artifact minutes: multiply \(J_{\mathrm{recon}}\) by 0.72 after the formula. Artifact must not manufacture presence (masked channels stay masked).

**Card / Test Centre (required so “we track direction” is visible):**

- Each vital strip already shows in/out. Add a **direction row** in Test Centre (DEBUG / Test Centre only, not a medical claim): six cells `HR ↑` `RHR ·` `HRV ↓` `T ↑` `R ↓` `O2 ·` from \(\mathrm{sign}(d_k)\) with `·` if \(m_k=0\) or \(|d_k|<d_{\mathrm{soft}}\).
- Wearer banner does **not** name a disease. If \(B\ge 0.5\) and \(J_{\mathrm{recon}}\) ≥ note: “Several readings moving together · not a diagnosis.”
- Single-channel extreme: that strip is out of sync; safety may fire; joint stays small.

**Files / API**

| Piece | Where |
|---|---|
| `WatchdogDirection.compute(residuals, mask, carry) -> (d, D, B, J)` | `WatchdogV2.swift` |
| `WatchdogCarry.dirEma: [Double]` length 6 | persist with carry |
| Delete `WatchdogScores.joint = max(l2, mx)` | replace callers |
| `WatchdogResult.direction: [Double]` + `directionMask` | Test Centre |

`UniTS` still does **not** emit `joint`. Swift owns direction.

### Proof

| Fixture | Required |
|---|---|
| `dir_equal_weight` | Same \(|r|\) on HR only vs temp only vs SpO₂ only → **identical** \(D\), \(B\), \(J\). |
| `dir_six_vs_one` | Six channels \(d=0.55\) → \(J\) **>** one channel \(d=0.95\). |
| `dir_dynamic` | Flip HR sign at tick 10; `dirEma` and Test Centre arrow update; no stale sign after 3 ticks. |
| `dir_rhr_mask` | Run minute: RHR \(m=0\); remaining five each weight 0.2; asserting `sum(w)==1`. |
| `dir_no_max` | Source test: no `max(l2, mx)` in `WatchdogScores`. |
| `dir_no_autonomic_bonus` | HR+HRV+resp packet vs temp+SpO₂+HR packet, same \(|d|\) on three channels → **same** \(J\). |

### Honesty / not doing

No Treatment “it worked” average. No disease name. No extra weight on HR because it is familiar.

---

## 2. Event labeling and how events are separated

### In the app now (most dynamic)

`WatchdogEventGeometry` (`geometry-v1-dynamic`) runs every tick **after** UniTS reconstruct and TimesFM forecast:

| Signal | Model | Job |
|---|---|---|
| \(J_{\mathrm{recon}}\) + direction breadth | **UniTS** | **What.** `explained` iff \(J_{\mathrm{recon}} < t_{\mathrm{note}}\). Walk logits + loud recon → **not** `workout_walk`. |
| \(J_{\mathrm{fc}}\) persist = 2 | **TimesFM** | **When.** Cut reason `timesfm-onset`; label can be `forecast_drift_only` if recon is still quiet. |
| Class family hold ≥ 2 min | IMU/steps | Cut reason `class-hold` (1-minute blips do not cut). |
| Recon crossing note for 2 ticks | **UniTS** | Cut reason `units-regime`. |
| Wrist-off / gap / artifact / safety | Rules | Never relabeled by a model. |

`WatchdogResult` now carries `eventLabel`, `cutReason`, `eventExplained`. Carry holds `eventMemory`. Test Centre prints the live name.

**Honesty.** There is no human catalog. `WatchdogTuneCatalog.json` is a pin (`human_review: forbidden`). Thresholds stay `prior-untuned` until a **self-labeled** synthetic replay exists. Memory is EMA of signatures — not on-device Core ML training.

### Request (updated)

Thresholds come from a test set. **Event labeling** must be explicit for every type, and it must be **obvious how events are cut apart** so a window is never two things at once.

### An event is not a 30-minute file

A **raw event** is a half-open interval on the civil / unix timeline. A **tape** is one 30-minute `WatchdogWindow` that is **allowed to sit inside exactly one event**. If a 30-minute extract would cross a cut, it is **rejected** (`label = mixed_rejected`) and is not used for FPR, miss, or band coverage.

```
event_id        string   // "syn-walk-003"
label           enum     // exclusive, see table
t0              unix     // inclusive
t1              unix     // exclusive
family          whoop4 | whoop5
cut_reason      why t0/t1 were placed (see Cuts)
notes           string   // engineer, not wearer
expected        { notify, severity_floor, severity_ceil, quality }
```

Catalog: `Packages/StrandAnalytics/Baseline/units/WatchdogTuneCatalog.json`.
Builders: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/WatchdogTune/`.
Report: `Packages/StrandAnalytics/Baseline/units/WatchdogTuneReport.md` (generated).

### Exclusive label set (one minute, one label)

A minute is assigned **exactly one** label by walking this list **top to bottom**. First match wins. That is how types stay separated.

| Priority | `label` | When it applies | Expected Watchdog |
|---|---|---|---|
| 1 | `wrist_off` | Strap off, or quality would return `wristOff` | `dataUnavailable`. **Not** recovered. **Not** abnormal. |
| 2 | `gap` | Coverage / freshness / empty-minute gate (`coverage`, `stale`, `gap`) | Unavailable. Not a false alert if we stay silent. |
| 3 | `artifact_spike` | IMU artifact class or optical spike recipe (single-sample HR jump, motion CV high) | σ widen, \(J\) damped, **no severe notify** |
| 4 | `workout_walk` | Walk family ≥ 2 consecutive minutes, residuals **explained** by activity-conditioned hat | \(J_{\mathrm{recon}}\) quiet; **no Early** from forecast (item 5) |
| 5 | `workout_run` | Run family, explained | same |
| 6 | `workout_cycle` | Cycle-like, explained | same |
| 7 | `workout_lift` | Resistance / saw-tooth, explained | same |
| 8 | `post_workout` | Still/stand, and last workout `t1` was < 20 min ago | Own state (item 6). Not `normal_still`, not `abnormal_*` |
| 9 | `normal_sleep` | Sleep window, quality pass, no artifact, no workout overlap | Inside band; no notify |
| 10 | `normal_still_awake` | Still/stand, wake, explained | Inside band; no notify |
| 11 | `forecast_drift_only` | Synthetic: recon stays inside band; forecast path leaves | **Early** only; `shouldNotify=false` |
| 12 | `abnormal_still_tachycardia` | Still/stand, flat HR well above hat, other channels not required | HR strip hot; safety **may** severe; \(J_{\mathrm{recon}}\) **must not** be required to be huge (item 1) |
| 13 | `abnormal_multi_direction` | Still/stand; ≥3 present channels \(\|d_k\|\ge d_{\mathrm{soft}}\) | \(J_{\mathrm{recon}}\) ≥ note/candidate after tune |
| 14 | `abnormal_spo2_still` | Still; SpO₂ below hat by catalog; no disease copy | Strip + breadth; not named hypoxia on the wearer card |
| 15 | `safety_bound` | Still-wrist extrema that trip `WatchdogSafety` | Severe notify is a **hit** |
| 16 | `mixed_rejected` | Extract crosses a cut | Drop from all rates |

`workout_*` is **never** also `abnormal_*`. If a “run” has still-logits and a flat 96 bpm, priority 12/15 wins — that is **not** a workout event. Labeling uses the **activity tensor + hat**, not the wearer’s calendar title.

### How events are cut (separation rules)

Cuts are **hard**. An event ends at the first unix that satisfies any rule. The next event starts at that unix (or after a mandatory **guard**).

| Cut | Rule | Guard after cut |
|---|---|---|
| **C1 Quality** | Quality gate flips available → unavailable or the reverse | 60 s dropped (`mixed_rejected` if a window overlaps the flip) |
| **C2 Wrist** | Wrist-off starts or ends | Entire off period is one `wrist_off` event |
| **C3 Family change** | Activity **family** changes and the new family holds for **≥ 2 minutes** (walk→run, run→still, …). One-minute blips do **not** cut | 0 — new event starts at the first minute of the new family |
| **C4 Workout edge** | AutoWorkout / classifier workout start or end | 2 minutes at the edge are `mixed_rejected` so warm-up is not `normal_still` and not `abnormal_*` |
| **C5 Post-workout clock** | 20 minutes after workout `t1` | Then still-wake may become `normal_still_awake` |
| **C6 Sleep edge** | Sleep onset / wake from WHOOP sleep interval | 5 minutes either side `mixed_rejected` |
| **C7 Abnormal seed** | Synthetic abnormal is **injected** only inside a still event that already existed 5 minutes; injection start/end are cuts | 2 minutes after injection end `mixed_rejected` |
| **C8 Max length** | No event longer than **45 minutes** (split into sequential events of the **same** label with new `event_id`) | 0 — so a 3-hour sleep is several `normal_sleep` events, not one blob |
| **C9 Overlap forbid** | If two rules fire on the same second, **lower priority number** (table above) wins and the other event does not start | — |

**Windowing for the tuner**

- Slide 30-minute windows by 5 minutes, but **discard** any window whose `[now-30m, now)` intersects two `event_id`s or any `mixed_rejected` minute.
- WHOOP 4 and WHOOP 5/MG are **separate** tapes (`family` field). Same `event_id` stem, suffix `-w4` / `-w5`.
- Minimum counts (synthetic, first catalog):

| Label | Min events | Min accepted windows |
|---|---|---|
| `normal_sleep` | 8 | 8 |
| `normal_still_awake` | 8 | 8 |
| each `workout_*` | 3 | 3 |
| `post_workout` | 3 | 3 |
| `artifact_spike` / `gap` / `wrist_off` | 3 each | 3 each |
| `abnormal_still_tachycardia` | 4 | 4 |
| `abnormal_multi_direction` | 4 | 4 |
| `abnormal_spo2_still` | 2 | 2 |
| `forecast_drift_only` | 4 | 4 |
| `safety_bound` | 2 | 2 |

### How events are labeled (no human)

This replaces the old accept / `mixed_rejected` / ±60 s review. **Nobody clicks a label.**

1. Quality fail → `wrist_off` or `gap`. Stop. Models do not run.
2. UniTS reconstruct → \(J_{\mathrm{recon}}\). Quiet (\(J < t_{\mathrm{note}}\)) means the 30×20 hat **explains** the vitals.
3. TimesFM → \(J_{\mathrm{fc}}\). Persist 2 ticks can cut and, if recon is still quiet, name `forecast_drift_only`.
4. `WatchdogEventGeometry.what` is the **teacher** (workout only if explained; loud recon is never a workout).
5. `WatchdogEventMemory.observe` may rename **inside the same family**: explained ↔ explained (e.g. IMU `unknown` that matches a learned walk), or abnormal ↔ abnormal (tach vs SpO₂ vs multi). It **cannot** turn a loud recon into `workout_*`.
6. After the name is chosen, the signature (6 directions + tanh \(J\) + tanh \(J_{\mathrm{fc}}\) + activity slot + SpO₂ residual) **EMA-updates** that prototype. After 4 visits the centroid is mature and can name the next tick.
7. `mixed_rejected` is only a **window that crossed a cut**, produced by `WatchdogEventLabeler.windowAccepted`. It is not a reviewer action.
8. Synthetics: replay `Watchdog.evaluate` on generated minutes. The same teacher + memory names them. Do not ship a Python priority table as truth.
9. Real WHOOP: `real_whoop5: not_run`. Do not invent clinical events from a personal night.

Accuracy improves because repeats look like the stored residual, not because a person graded tapes.

### Scoring the catalog (false alert vs miss)

| Label | False if | Miss if |
|---|---|---|
| `normal_*`, `workout_*`, `post_workout` | `shouldNotify` or severity `severe` | — |
| `artifact_*`, `gap` | `shouldNotify` | Unavailable not used → miss of *quality*, counted separately |
| `wrist_off` | Any severity other than unavailable | Gate does not return `wristOff` |
| `forecast_drift_only` | `shouldNotify` or severity `severe` | No Early / note |
| `abnormal_multi_direction` | — | \(J_{\mathrm{recon}}\) < candidate (after tune) |
| `abnormal_still_tachycardia` | — | HR strip in-range **and** safety silent |
| `abnormal_spo2_still` | — | SpO₂ strip in-range |
| `safety_bound` | — | `shouldNotify==false` |

Sweep: `tNote`, `tActive`, `tSevere`, `persistTicks`, `rearmTicks`, `escalateDelta`, \(\beta\), \(d_{\mathrm{soft}}\), Early threshold. Constraints on the **synthetic** set: FPR(severe | normal∪workout∪post∪artifact) = 0; `forecast_drift_only` never severe; miss as in the table ≤ 1 window per abnormal family.

Until `WatchdogCalibration.json` has `calibration_source = tune-catalog-v1`, keep 1.0 / 1.6 / 2.4 and print **`prior-untuned`**. Do not silently pick new pretty numbers.

### Proof (self-label)

- Unexplained walk class is **not** `workout_walk`.
- After explained walks, memory names IMU-unknown as `workout_walk`.
- Memory refuses to name a loud recon as a workout.
- Memory refines abnormal family (SpO₂ vs multi) without a reviewer.
- Wrist-off / safety / artifact never write a prototype.
- Old carry JSON without `eventMemory` still decodes.

---

## 3. Green band: first construction and live updates use the same caution

### In the app now (medium — not frozen, not loose)

`WatchdogBand` version **`band-v2-medium`**. This is the contract on the green corridor:

- **Not frozen.** Every *eligible* still minute (normal sleep / still-awake, quiet \(J\), no safety, no HR-hot, \(|r|<2.5\)) adds a **small weight** to a running typical residual \(q_k\). The true width **accumulates**.
- **Not yanked.** Gain \(\alpha = 2/(n+1)\) shrinks as \(n\) grows (capped at ~two weeks of still minutes). A residual entering \(q\) is clipped at 1.2. The displayed scale may move at most **`stepMax = 0.02`** on one tick (2%). Session noise is a separate ±5% cap, not ±15%.
- **Not loose later.** After 14 eligible minutes, \(q\) becomes the **anchor** (first typical width). Later scale is \(q / \mathrm{anchor}\), clamped to **0.75–1.40**. Workout, abnormal, artifact, and ineligible minutes **do not** update \(q\). A still-tachycardia minute cannot widen the band.
- **Applied.** The scale multiplies the displayed half-width this tick. Joint \(J\) still uses the model σ first so a widening band cannot hide a miss.

Caption stays **Predicted range**. Never “calibrated.”

### Caution contract (identical for t = first night and t = week 6)

A minute may **enter the band estimator** only if **all** of these hold:

1. Quality gate passed (not wrist-off, coverage, stale, gap).
2. Event label is `normal_sleep` or `normal_still_awake` (not workout, not post_workout, not artifact, not abnormal, not mixed).
3. Activity family is still / stand / sleep.
4. No safety cap this tick.
5. \(J_{\mathrm{recon}} < t_{\mathrm{note}}\) (prior 1.0 until tuned) — a loud joint minute must **not** widen the band.
6. Per-vital \(|r_k| < 2.5\) — a single-channel spike must **not** widen that vital’s σ (this is how we refuse to swallow still tachycardia).
7. Daily log confounders that already drop Layer 1 nights (felt ill, travel, extra med, alcohol, sleep/diet off-typical) also **drop** this minute from the Watchdog band estimator. Watchdog still does not write Layer 1.

**Same numeric caution** as first build:

| Knob | First band | Later updates |
|---|---|---|
| Target cover HR/RHR/HRV/resp/temp | 0.90–0.95 | **same** |
| Target cover SpO₂ | ≥ 0.97 | **same** |
| Floors | HR 5 bpm, RHR 5, HRV 8 ms, temp 0.35 °C, resp 3 /min, SpO₂ 2 % | **same** |
| Clamp vs catalog / first scale | 0.75×–1.40× | **same** (cannot walk out to 3× because “lately noisy”) |
| This-window scatter | **never** sets σ | **never** |
| Update cadence | After ≥ 14 **eligible** minutes exist, set `sigma_scale` | Every eligible tick, **tiny** gain (below) |
| Gain | N/A (batch) | \(\alpha_{\sigma} = 2 / (N_{\mathrm{elig}}+1)\) with \(N_{\mathrm{elig}}\) capped at 14×24×3 (about two weeks of still minutes) so late ticks are **not** more aggressive than the first batch |

### Estimator (no gaps)

**Cold start (no eligible minutes yet).** σ = Core ML / prior σ × `sigma_scale=1` × floors × artifact gain if artifact (artifact minutes still do not *train* the scale). Caption: **Predicted range**.

**First batch.** When 14 eligible minutes exist (can be one sleep + next morning):

\[
q_k = \mathrm{quantile}_{0.90}\{|x-\hat{x}| \text{ on eligible minutes of channel } k\}
\]

\[
\mathrm{scale}_k \leftarrow \mathrm{clamp}\big(q_k / \mathrm{median}(\sigma_{k,\mathrm{model}}),\; 0.75,\; 1.40\big)
\]

This is the **anchor** `scale_anchor_k`. Store it. All later scales stay within 0.75–1.40 of **this anchor**, not of last week’s scale (so caution cannot compound).

**Continuous update (same caution).** On each new eligible minute:

\[
q_k \leftarrow (1-\alpha_{\sigma})\,q_k + \alpha_{\sigma}\,|x_k-\hat{x}_k|
\]

then recompute `scale_k` from \(q_k / \mathrm{median}\,\sigma_{\mathrm{model}}\) and clamp to **anchor**. Ineligible minutes: **no update**. Workout: **no update**. Abnormal: **no update**.

**Per-state scales.** Separate `scale_k` for `sleep` vs `still_wake` only (workout bands are the model’s activity-conditioned σ, not this estimator). Do not one-pool sleep and desk-still.

**UI.** Never “fully calibrated.” **Predicted range** until `tune-catalog-v1` **and** live cover on the last 7 eligible days sits in target. Then **Range from tune-catalog-v1**. Test Centre prints `cover`, `n_elig`, `scale`, `anchor`, `alpha`.

### Proof

| Fixture | Required |
|---|---|
| `band_first_caution` | 14 eligible sleep minutes → scale in 0.75–1.40; tachycardia minute excluded. |
| `band_later_same_clamp` | 200 noisy-but-ineligible minutes do **not** move scale. 200 eligible minutes cannot pass 1.40× **anchor**. |
| `band_no_swallow` | Inject 96 bpm still after a “calibrated” week → outside band. |
| `band_workout_ignored` | Run hour does not change sleep/still scales. |
| `band_copy` | No wearer “calibrated” string. |

---

## 4. Rich activity into the model; the model decides

### Request (updated)

Activity tracking must be **much more dynamic**. Give the model a **large** activity feature block and let **it** learn what physiology should do. No fixed effort lookup as the physiology.

### Why 8-way → 0.32 / 0.85 is still a half-fix

Even a one-hot (1,30,8) is a **hard class**. Walk vs “brisk walk on a hill” looks the same. The request is: ship **raw-ish activity time series** and train the mixer so hat/σ are functions of that series.

### Activity feature block (every minute, F = 20)

`WatchdogActivityFeatures.row(i) -> [Double]` length 20, all finite, documented ranges:

| Idx | Feature | Source | Range |
|---|---|---|---|
| 0–7 | Activity logits (8-way, sum 1) | `WatchdogActivityRuntime` | [0,1] |
| 8 | Motion magnitude (gravity residual 0–1) | IMU | [0,1] |
| 9 | dynAccel mean | IMU | [0, ~4] winsor 4 |
| 10 | dynAccel std | IMU | [0, ~4] |
| 11 | Gravity \|mag−1\| mean | IMU | [0, 1] |
| 12 | Step still fraction | type-63 | [0,1] |
| 13 | Step walk fraction | type-63 | [0,1] |
| 14 | Step run fraction | type-63 | [0,1] |
| 15 | AutoWorkout overlap | in-tree detector | {0,1} |
| 16 | Minutes since workout end / 60 | clock | [0, 2] cap |
| 17 | sin(2π hour / 24) | local hour | [−1,1] |
| 18 | cos(2π hour / 24) | local hour | [−1,1] |
| 19 | Sleep-interval bit | WHOOP sleep | {0,1} |

Missing IMU: logits → unknown; features 8–11 from occupancy mag if any, else 0; quality / TRUST already fail closed when the window is unscorable. **Do not invent a class.**

**Delete** `effortOccupancy` as the Core ML `occupancy` input. It may remain as a **debug print** only.

### Core ML I/O (`units-ad-coreml-v3`, `timesfm3-student-v3`)

| Tensor | Shape | Role |
|---|---|---|
| `activity` | (1, 30, 20) | Feature block above |
| `prompt` | (1, 6) | Layer 1 / phase usual (item 6), HR vs RHR split unchanged |
| `personal_scale` | (1, 6) | Layer 1 MAD / floors |
| `observed` | (1, 6, 30) | Live strip (gaps → last-hold + mask inside the net) |
| `hat` | (1, 6, 30) | Reconstruction |
| `sigma` | (1, 6, 30) | Corridor |

The **mixer learns** walk vs lift vs downhill vs sleep from columns 0–19. Training (`Tools/units-watchdog/train_export.py`):

- Sample synthetic **activity paths**, not one scalar: constant walk, walk↔stand, run, lift (high dyn CV + low step-run), cycle (motion + low steps), sleep (sleep bit + still logits), unknown (empty IMU).
- Teacher hat is **not** `0.50 R × occ`. Teacher is a function of the **feature row** (smooth HR rise on high step-walk; saw-tooth on high dyn CV + resistance logit; near-zero RHR teacher unless still+sleep/stand). The network must beat a control that only sees column-8 magnitude.
- Loss: robust recon on hat vs teacher, plus σ NLL on residual; **RHR loss masked** unless still/stand/sleep.
- Offline only. SHA256 pins. v2 package is fallback if v3 missing; `qualityLine` says `units-ad-coreml-v3` or `prior fallback`.

**Swift prior `units-ad-recon-v4`:** uses the **full 20-vector** with a small frozen table (nearest prototype of the 8 logits + dyn CV) — still not a single occupancy line. Fallback only.

**RHR:** minutes with resistance/run/walk/cycle/artifact logits winning → RHR observed treated as nil in the cube (model cannot “explain” RHR with effort).

**Banner:** `On · {display class}` from argmax of 0–7, but the **model** saw the other 12 columns.

### Proof

| Fixture | Required |
|---|---|
| `activity_shape_20` | Predict rejects (1,30) occupancy-only. |
| `model_uses_dyn` | Same logits walk, high vs low dynAccel → hats differ. |
| `model_uses_clock` | Same motion, sleep bit 0 vs 1 → HR hat differs. |
| `walk_vs_lift` | Same prompt/HR tape → different hats. |
| `effort_lookup_gone` | `UniTSRuntime.occupancy` not passed into Core ML. |
| `rhr_masked` | Run features → RHR hat/energy unmoved. |
| `still_tachycardia` | High HR + still features → not explained. |

---

## 5. Forecast Early vs reconstruction severe — and why we over-notified

### Request

Reconstruction = “wrong **now**.” TimesFM = “leaving the expected path.” Strong forecast may raise **Early** even if recon is not severe. Forecast **alone** must not **severe-notify**.

### What went wrong once daily event testing started

After Watchdog started cutting and naming events every day (item 2 + live ticks), it was **too easy to page**. Testing the event path made that obvious:

- Every new event (walk → still, TimesFM onset, UniTS regime, a Test Centre **Test notification** / **Severe** inject) *felt* like something the phone should announce.
- Early (“leaving the expected path”) sat next to the same Watchdog card as a real page, so a forecast drift looked like an alert.
- `episode-start` and `escalate` (+0.5 on recon \(J\)) could fire on a severe stretch that was not actually an extrema / not an abnormal family.
- The DEBUG **Test notification** button (`WatchdogNotifier.post(..., test: true)`) sends a local banner **even when `shouldNotify` is false**. That is for engineers. It is **not** the wearer policy.

That is over-sending. Event labels, cuts, and Early are for the card and Test Centre. They are **not** a notification stream.

### In the app now: notifications only for the most extreme predictions

A wearer push (`WatchdogNotifier.post` without `test:`) runs **only** when `WatchdogNotifyPolicy` says so. That policy is **extreme-only**:

| May page | May not page |
|---|---|
| Hard **safety** rising edge (still-wrist extrema) | TimesFM / Early / `forecast_drift_only` |
| **Severe reconstruction now**: \(J_{\mathrm{recon}} \ge t_{\mathrm{severe}}\) (2.4), persist 2 ticks, **and** event family is `safety_bound` or `abnormal_*` | `note` / `candidate` / `active` |
| Same episode **escalate** only if recon \(J\) jumps by ≥ 0.5 *and* the family is still extreme | `workout_*`, `post_workout`, `normal_*`, artifact, gap, wrist-off, mixed |
| | New event **cut** (`class-hold`, `units-regime`, `timesfm-onset`) |
| | Test Centre “Tick now” / quiet inject |
| | DEBUG “Test notification” (engineer-only; not `shouldNotify`) |

“Most extreme predictions” here means: the models (UniTS reconstruction, plus safety rules) agree this is a **severe, unexplained, abnormal or safety** stretch **right now**. A TimesFM path that is merely leaving the corridor is an **Early** banner — on-screen, **no sound, no push**. A correctly explained walk is an event name, **not** a page.

`WatchdogService.tick` still calls `WatchdogNotifier.post(result)` only when `result.shouldNotify` is true. Copy stays “Not a diagnosis.”

### Additions (forecast math; unchanged)

1. **\(J_{\mathrm{fc}}\) uses the same equal-weight direction formula** as item 1 on forecast residuals. Not `max` across channels.
2. **Early persist:** 2 ticks with \(J_{\mathrm{fc}} \ge t_{\mathrm{note}}\) before Early. One bad student call does not flicker.
3. **Early is forbidden** on `workout_*`, `post_workout`, `artifact_*`, or quality fail.
4. **TRUST:** if TRUST < 35, Early is Test Centre only.
5. **Student I/O** is `activity (1,30,20)`. ≤1 infer/min. Missing student → \(J_{\mathrm{fc}}=0\).
6. **No fused severity.** Forecast cannot raise `severe`. Delete `max(recon, 0.5·forecast)` as a notify input.

| Condition | Wearer card | Phone notify |
|---|---|---|
| Safety extrema | Severe | **Yes** (rising edge) |
| \(J_{\mathrm{recon}}\) ≥ tSevere + persist + extreme family | Severe | **Yes** (start / recon escalate only) |
| \(J_{\mathrm{recon}}\) active / candidate / note | Those levels | **No** |
| Early persist, recon not severe | **Early** · “Leaving the expected path · not a diagnosis” | **No** |
| New event cut, workout, forecast-only | Label / cut reason | **No** |
| Student down | Recon only | Unchanged (still extreme-only) |

### Proof

`forecast_cannot_severe`, `forecast_early_recon_quiet`, `testHardSafetyPagesDuringStableEpisode`, `test07` (stable severe does not re-page), notify deny on workout / forecast families, Test Centre test bell is DEBUG-only.

---

## 6. Short-term noise learning; long-term core per phase and activity

### Request (updated)

Learn **something** over a short period (local noise, this session). The **core** usual must be **long-term** and adapted to **each phase of the day and each activity**.

### Two stores, two jobs

**A. Short-term (this session) — may learn quickly**

- Key: `(phase, activity_family)` currently showing.
- State: per-channel Welford / EMA of **absolute residual** \(|x-\hat{x}|\) over the last **up to 90 minutes** of **eligible** minutes in that key (`WatchdogCarry.sessionAbs[phase][family][6]`, `sessionN`).
- Eligibility = item 3 caution list (no abnormal, no artifact, no safety, \(J_{\mathrm{recon}}<t_{\mathrm{note}}\), \(|r|<2.5\)).
- **May do:** multiply σ by `clamp(session_median / model_σ, 0.90, 1.15)` — a **narrow** local noise tweak (tighter than item 3’s 0.75–1.40). This is “it is a jittery afternoon; widen a little.”
- **Must not:** move `prompt` / hat **center**; subtract from \(J\); write Layer 1; write the long-term store; survive past **4 hours idle** or **civil-day rollover** (carry session block resets).

**B. Long-term core — slow, phase × activity**

`WatchdogPhaseUsual` sidecar (not Layer 1, not Charge):

```
key        phase × family
center[6]  slow center (units of the vital)
mad[6]
n_days
updated    last civil day we wrote
```

**Phases** (local clock + sleep bit; first match):

| `phase` | Rule |
|---|---|
| `sleep` | Sleep-interval bit = 1 |
| `late` | 00:00–04:59 and not sleep (wake in the night) |
| `morning` | 05:00–11:59 |
| `midday` | 12:00–16:59 |
| `evening` | 17:00–23:59 |

**Activity families** (argmax of logits 0–7, collapsed):

| Family | Classes |
|---|---|
| `still` | still, stand |
| `walk` | walk |
| `endurance` | run, cycleLike |
| `resistance` | resistance |
| `other` | unknown (core **does not** update; prompt stays Layer 1) |

`post_workout` overrides family for 20 minutes after workout `t1` (still/stand only).

**Daily write (once per civil day per key):** median of that day’s **eligible** minutes for that key, only if the key had ≥ 12 minutes. Then

\[
\mathrm{center} \leftarrow 0.85\,\mathrm{center} + 0.15\,\mathrm{day\_median}
\]

(first day: center = day median). MAD same, Winsorized. **Need `n_days ≥ 7`** before this center may replace Layer 1 in the prompt for that key. Two Layer 1 copies are never averaged; this sidecar does not mix them.

**Prompt resolution (per minute)**

1. Population prior if Layer 1 missing.
2. Layer 1: HR = awake-rest/continuous only; RHR = sleep usual only; never fill one from the other.
3. If `WatchdogPhaseUsual` for `(phase, family)` is mature **and** family is not `other`: **blend 70% sidecar center / 30% Layer 1** for channels that exist in both (documented, not a silent 50/50 of the two Layer 1 copies).
4. Activity tensor (item 4) still shapes the hat around that prompt.

**Remove** `quietJointEma` entirely.

**Watchdog never writes Layer 1.** `LongitudinalBaseline.evaluate` does not import Watchdog.

### Proof

| Fixture | Required |
|---|---|
| `short_learns_sigma` | 20 eligible still-morning minutes, residual 0.4σ → σ scale ∈ [0.90, 1.15]; **prompt unchanged**. |
| `short_resets` | Idle 4 h → session block zero. |
| `short_cannot_eat_tachycardia` | 20 minutes of 96 bpm still: ineligible; center and short σ **unchanged**. |
| `core_immature` | 3 days walk-morning: prompt still Layer 1. |
| `core_mature_phase` | 10 days morning-walk vs 10 days evening-walk → **different** centers. |
| `core_sleep_not_run` | Run minutes never update `sleep × still`. |
| `no_joint_offset` | `quietJointEma` unused. |
| `no_L1_write` | Layer 1 snapshot bytes unchanged after ticks + daily write. |

---

## Tick pipeline (v2.4, most dynamic)

`WatchdogService.tick` (20 s) → `WatchdogWindowBuilder.build` → `Watchdog.evaluate`:

1. `WatchdogQuality.gate` — fail → unavailable, **stop** (no models).
2. `WatchdogActivityFeatures.build` (30×20).
3. Blend `WatchdogPhaseUsual` into prompt if mature.
4. `UniTSRuntime.reconstruct`.
5. `WatchdogDirection` → \(J_{\mathrm{recon}}\).
6. `WatchdogForecastRuntime` → \(J_{\mathrm{fc}}\).
7. `WatchdogSafety`.
8. **`WatchdogEventGeometry.resolve`** — UniTS what + TimesFM when + **memory rename**.
9. Severity from recon + safety only. Early if forecast persist and label allows.
10. Notify: episode / safety / recon escalate. **Never** forecast-only severe.
11. Band + session σ if the **resolved** label is eligible.
12. UI: Live baseline, Early, Test Centre direction + `cutReason`.

---

## Implementation order

| Step | Work |
|---|---|
| A | Direction joint (item 1); forecast Early split (item 5); delete `quietJointEma` and fused severity; session σ cap (item 6 A) |
| B | Activity (1,30,20) Core ML v3 + prior v4 + pins; drop occupancy input |
| C | `WatchdogPhaseUsual` + daily write (item 6 B) |
| D | Self-label (geometry + memory). No human catalog. |
| E | Band estimator + live update with same caution (item 3) |

**Gate:** `cd Packages/StrandAnalytics && swift test --filter Watchdog` plus `WatchdogDirection`, `WatchdogEventLabeler`, `WatchdogTune`, `WatchdogPhaseUsual`, forecast-early, activity-shape tests.

---

## Wearer copy

- **On · {activity}**
- **Early** only for forecast (item 5); not a diagnosis; no notify
- Several channels moving: “Several readings moving together · not a diagnosis”
- Range: **Predicted range** until D–E
- No “calibrated,” no drug, no “we adapted to you this afternoon”

---

## Out of scope

Charge, Recovery, Layer 1 write path, inferring `t0`, cloud Watchdog, on-device gradient training, Google TimesFM 330M, Harvard UniTS public weights, Daily log rewrite, naming a disease on `abnormal_spo2_still`.

---

## Test log (24 Sep 2026, 22:43)

Command: `cd Packages/StrandAnalytics && swift test --filter Watchdog`  
Result: **118 passed, 0 failed** (24 Sep 22:48; includes extreme-notify deny).

### WatchdogV25SelfLabelTests (12) — self-label + medium band + extreme notify — all passed

| Test | What it locks |
|---|---|
| `testUnexplainedWalkClassIsNeverWorkoutFromPriorityTable` | Walk class without UniTS explain is not `workout_walk` |
| `testSpo2TeacherWithoutHR` | Loud SpO₂, quiet HR → `abnormal_spo2_still` |
| `testMemoryRenamesUnknownStillToLearnedWalk` | After 4+ explained walks, IMU-unknown gets `workout_walk` |
| `testMemoryCannotTurnLoudReconIntoWorkout` | UniTS veto: loud recon stays abnormal |
| `testMemoryRefinesAbnormalFamily` | Next similar miss named SpO₂, not multi |
| `testQualityNeverLearned` | Wrist-off writes zero prototypes |
| `testCarryDecodesWithoutEventMemory` | Old carry JSON still loads |
| `testLiveQuietDoesNotNeedAHumanLabel` | Live tape names itself; never `mixed_rejected` |
| `testConfigIsV25` | `watchdog-v2.5` + `geometry-v2-selflabel` + `band-v2-medium` |
| `testBandIsNotFrozenAndNotYanked` | Seed 14 min; 8 louder ticks each ≤2%; ineligible does not move; 500 ticks stay in 0.75–1.40 |
| `testBandAlphaShrinksSoLateTicksAreSmaller` | α(2) > α(80); late α is capped |
| `testNotifyDeniedOnForecastAndWorkout` | Severe + forecast/workout → no push; abnormal family → episode-start |

### WatchdogV24DynamicTests (15) — hybrid geometry — all passed

| Test | What it locks |
|---|---|
| `testUnitsExplainsQuietWorkout` | UniTS quiet + walk class → `workout_walk` |
| `testUnitsRejectsWalkThatDoesNotMatchHat` | UniTS loud + walk class → **not** a workout |
| `testTimesFMNamesForecastDriftWhenReconQuiet` | TimesFM high, recon quiet → `forecast_drift_only` |
| `testStillTachycardiaIsNotAWorkout` | Still + loud + HR-only → `abnormal_still_tachycardia` |
| `testSafetyAndArtifactStayRules` | Models cannot relabel safety/artifact |
| `testTimesFMOnsetNeedsPersist` | Cut only on 2nd tick at note |
| `testUnitsRegimeOnset` | UniTS crossing note for 2 ticks |
| `testClassHoldCutAfterTwoMinutesNewFamily` | `class-hold` after 2 min new family |
| `testOneMinuteFamilyBlipDoesNotCut` | 1 min walk in still does not cut |
| `testTimesFMCutReason` | `cutReason == timesfm-onset` |
| `testUnitsCutReason` | `cutReason == units-regime` |
| `testWristOffNeverUsesModels` | Wrist-off → quality, unavailable |
| `testQuietStillIsNormalAndExplained` | Live quiet tape explained, no notify |
| `testGeometryVersionIsDynamic` | `geometry-v2-selflabel` + `watchdog-v2.5` |
| `testCatalogLabelerStillExclusive` | Catalog priority: wrist-off wins |

### WatchdogV23Tests (15) — direction / band / phase / activity — all passed

`testDirEqualWeightSameAbsOnAnyChannel`, `testDirSixBeatsOne`, `testDirNoAutonomicBonus`, `testDirRHRMaskRenormalizes`, `testJointHasNoMaxEscape`, `testForecastCannotSevere`, `testFusedIsReconOnly`, `testEventPriorityWristBeatsAbnormal`, `testOneMinuteWalkDoesNotSplitWhenCuttingSameLabel`, `testWindowStraddleRejected`, `testActivityFeaturesWidth20`, `testEarlyForbiddenOnWorkoutLabel`, `testMinutesDoNotWritePhaseUsual`, `testBandIgnoresIneligibleAndClamps`, `testConfigIsV23` (asserts v2.5).

### WatchdogV2GauntletTests (28) — all passed

`test01`…`test14`, `testCarryJSONWithoutNewKeysStillDecodes`, `testHardCalibrationFileMatchesSwift`, `testHardColdStartWidensSigmaNotMedian`, `testHardCopyNeverNamesDrugOrCause`, `testHardForecastDoesNotReplaceDottedLine`, `testHardGapSixEmptyMinutesFailsClosed`, `testHardLastNotifiedAtDoesNotMute`, `testHardNeverInfersRestFromLiveHR`, `testHardSafetyPagesDuringStableEpisode`, `testHardStaleNewestFailsClosed`, `testHardTwoHRVUsualsAreNeverAveraged`, `testHardWristOffIsUnavailableNotRecovered`.

### WatchdogEpisodeTests (14) — all passed

Including `testFourteenQuietWindowsNeverSevere`, `testWatchdogDoesNotMoveUsualHashes` (isolation), safety / inject / walk-vs-run.

### WatchdogUniTSTests (20) — all passed

Reconstruction hats, predicted σ, one-channel shift does not severe-notify, Core ML vs prior.

### WatchdogWindowTests (13) — all passed

WHOOP 4/5 coverage, wrist-off, SpO₂ percent, RHR still minutes.

### WatchdogIsolationTests (1) — passed

`testWatchdogDoesNotMoveUsualHashes` — Watchdog does not write Layer 1.
