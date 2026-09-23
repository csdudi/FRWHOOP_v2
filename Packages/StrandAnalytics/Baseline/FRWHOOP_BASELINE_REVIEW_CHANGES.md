# Review of v1 baseline — request, change, proof

**Overall testing.** These eight requests are now folded into `FRWHOOP_BASELINE_CONDENSED_PLAN.md` and `FRWHOOP_BASELINE_FINAL_PLAN.md` (`param_set = v1.review`). Prime / gauntlet overall baseline testing must use those two files as the contract — not this file alone.

**What this file is.** The full response to the review of the first personal baseline. There are **eight** requests. They have the **same weight**. Each one is: the request, what is wrong in v1, how we add it, what the dashboard does, and the proof that the request is met.

**What this file is not.** Implemented code. A claim that a drug caused a change. A rewrite of Charge. A short list plus four “real” expansions — items 1, 3, 5, and 8 are not leftovers.

**Gate.** None of the eight is “done” until its proof in the acceptance pack passes. The design is not finalized against the review if any row is missing.

---

## 1. Calibrate normal ranges — how often is a stable person still called abnormal?

**Request.** Median and MAD are a good starting point, but we need to know how often someone who is actually stable would still get flagged as abnormal. Test and calibrate those ranges on real data.

**What is wrong today.** `k_band = 2` and the MAD floors are labeled starting values. Tests are synthetic. There is no report of false-positive rate (FPR) on stable stretches, and no per-series table. A later pass cannot “calibrate” if we never defined the counter.

**How we add it.** Keep median / MAD / `center ± k × spread`. Add a **calibration protocol** that runs on every series using **that series’** `k` and gates (item 2):

1. **Stable stretch** (all must hold): longer usual established, slow slope either flat or residuals in-band, `p_change` below threshold, no treatment, no patient-entered confounders, not stale, TRUST ≥ 35.
2. On those days, count per series (never one pooled number): `|z| ≥ k` vs longer path, vs this week, `two_of_three`, and (if a freeze exists) `above_mdc`.
3. **Synthetic first** so the harness exists: constructed stable RHR ~60, stable HRV, stable resp, stable steps.
4. **Real WHOOP 5.0** fills the same table later. Until that row is filled, we do **not** invent a new `k` from intuition. Item 2’s starting `k` values stay placeholders; this protocol is what replaces them.

Pulse ±1.65 and Cadence |z| ≥ 1.5 are **not** adopted until this table exists.

**Dashboard.** Release Baseline does not show “FPR %.” Test Centre / DEBUG may print the table. Calibration is how we set `k`; it is not a patient-facing score.

**Proof.**
- Artifact: **stable false-positive rate** table, one row per series.
- Fixture `stable_rhr_60`: low OFF rate at RHR `k`.
- Fixture `stable_hrv`: not forced through RHR’s `k`.
- Fixture `stable_resp`: tighter `k` does not explode FPR because resp jitter is smaller — if it does, that `k` is wrong, which is the point of the harness.
- Empty row **real WHOOP 5.0 — not run yet** is required honesty.

If we only “plan to look at real data” with no counter, this request is not met.

---

## 2. Each biometric has its own way of being “off usual”

**Request.** Not every metric should use the same baseline rules. HRV moves around a lot more naturally than respiratory rate. The same windows and thresholds will make some metrics too sensitive and others not sensitive enough. Each unique biometric needs its own differentiation.

**What is wrong today.** Every series shares `span_7 = 7`, `lookback = 60`, `k_band = 2`, CUSUM constants, and 7-day washout. Only the MAD **floor**, HRV **ln**, SpO₂ **slot gate**, and motion **21 nights** differ. Sleep RHR and respiratory rate can both trip OFF on a wiggle that is noise for one and real for the other.

**How we add it.** Same skeleton for everyone (this week vs gapped longer usual, no 0-fill, Student-t vs the *detrended* longer path from item 3). Then **`params(for: series)`** — not one global `Params`. Differentiation is all of these, not only `k`:

| Knobs that may differ | What it changes |
|---|---|
| Math space | HRV on ln(RMSSD); everyone else native units |
| `k` (band width) | How far from usual is OFF |
| `span_7` / α | How fast this week’s usual follows last night |
| Nights to establish | When we may show a longer usual / freeze |
| Floor on spread | Stops a flat week from making tiny noise look huge |
| Quality gate | What counts as a real day (still minutes, SpO₂ slots, true-zero steps) |
| Direction of “worse” | RHR/resp/temp up vs HRV/SpO₂ down vs steps either way |
| Primary OFF copy | Rest: longer path. Motion: this week first (behavior jumps) |

**v1 starting table** (placeholders until item 1’s FPR report). Changing a row bumps `param_set`; it does not edit old snapshots.

| Biometric | Math | `k` | This-week span | Establish | Floor | A day is usable when | OFF means |
|---|---|---|---|---|---|---|---|
| Sleep RHR | bpm | 2.0 | 7 (α=0.25) | 14 | 2 bpm | Sleep engine night, 30–120 bpm | Higher than expected path |
| Awake-rest HR | bpm | 2.0 | 7 | 14 | 3 bpm | ≥30 still minutes | Higher |
| Awake-active HR | bpm | 2.2 | 7 | 14 | 4 bpm | ≥30 moving minutes | Higher (context is motion) |
| Continuous HR | bpm | 2.2 | 7 | 14 | 5 bpm | ≥240 valid minutes | Higher |
| Sleep / rest HRV | ln(RMSSD) | **2.6** | **10** (α=2/11) | 14 | 0.08 ln | Clean RMSSD > 0 | **Lower** ms than expected |
| Sleep respiratory rate | /min | **1.6** | 7 | 14 | 0.5 | 4–40 /min | Higher |
| Sleep temperature | °C | 2.0 | 7 | 14 | 0.3 | In 20–42 | Higher or lower (both OFF) |
| Sleep SpO₂ mean | % | **1.5** | 7 | 14 + 10 nights with ≥8 slots | 0.5 pp | ≥8 slots, 70–100% | Lower |
| Sleep SpO₂ nadir | % | **1.7** | 7 | same slots | 0.5 pp | same | Lower (own series) |
| Awake-rest SpO₂ | % | 1.5 | 7 | 14 + slots | 0.5 pp | ≥8 still slots | Lower |
| Steps | count | **2.4** | 7 | **21** | 500 | Stream present; **0 is real** | Either way vs that person’s path |
| Active minutes | min | **2.4** | 7 | **21** | 10 | Stream present | Either way |

HRV is allowed to move more before OFF. Respiratory rate and SpO₂ are not. Motion needs a longer tape before we call a “usual.” Continuous / active HR are wider than sleep RHR because the day is messier.

**Dashboard.** Each series card uses **that row**. Sleep RHR’s IN RANGE / OFF / hatch is never copied onto HRV or steps.

**Proof.** `params(for: .sleepRHR).k ≠ params(for: .sleepHRVLn).k` and span differs. Same ±2% native wiggle: respiratory rate IN RANGE, HRV not auto-OFF from RHR’s `k`. If one global `Params` remains, this request failed.

---

## 3. Slow change over weeks vs a short spike

**Request.** We need a way to handle slow changes over time. If a patient is gradually getting better or worse over a few weeks, we do not want the baseline to keep treating that as a temporary anomaly. Separate short-term spikes from a real shift in their normal physiology.

**What is wrong today.** Student-t downweight + hold is correct for a two-night fever (this week’s usual must not sprint to 72). If the climb lasts, CUSUM sets `regime_shift` and **holds the old longer median**, so a real three-week improvement stays OFF forever. Slope exists at treatment freeze (`G0`) but is **not** used to score “off usual” on ordinary nights. Section 1.9’s state-space model is not this pass.

**How we add it.** Every scored day `T`, for each series:

1. Theil–Sen **slow slope** on the long kept nights (same estimator as freeze). Store `slope_long` on the adaptive snapshot.
2. **Usable slope gate:** enough established nights, slope distinguishable from 0 vs MAD, residual scatter not exploding. If the gate fails → flat center (today’s v1).
3. **Detrend:** `expected_long(d) = center_long + slope_long × (d − t_center)`. Residual = `x − expected_long`. `z_long`, Student-t λ, and CUSUM run on residuals, not on distance to a flat median.
4. **Spike:** slope ~ 0 or gate fails, two ugly nights → OFF longer usual; this week’s *training* usual still downweights so it does not become the fever.
5. **Shift:** slope gate passes, residuals in-band for weeks → that path **is** the usual. `p_change` on detrended residuals. Do not hold them as permanently abnormal.
6. **Cap:** do not project a 30-day slope 90 days past the last long night. Beyond the cap, TRUST on that copy drops (item 4).

This is also where freeze `G0` (item 6) comes from: the last usable adaptive slope strictly before t0.

**Dashboard.** When slope is usable, the longer hatch follows the path (or the right rail shows **expected today**). Caption: “Longer usual may drift slowly. A short spike is not.” When slope is not usable, the flat median as today.

**Proof.** Two fixtures, opposite outcomes:

| Fixture | Tape | Must show |
|---|---|---|
| `spike_rhr_two_nights` | Long stretch at 60, then two nights at 72 | OFF longer usual. This week’s training usual does **not** become 72. |
| `slow_shift_rhr_three_weeks` | RHR falls ~0.3 bpm/day for ~21 days | **Not** stuck OFF vs a flat 60. Off is vs the moving expected path. `p_change` is not a false “new disease jump.” |

If both tapes still call the slow patient OFF-for-weeks, this request is not met. A Kalman filter is **not** required for this proof.

---

## 4. Replace dashboard “CONFIDENCE %” — data quality is not “they are abnormal”

**Request.** The current confidence score is more like a data-reliability score (how much data, signal quality, stability). That is useful, and it is different from statistical confidence that a value is actually abnormal. Those should be separated. On the dashboard, replace the existing CONFIDENCE line with a **dynamic** score that actually moves, without mixing the two meanings into one number.

**What is wrong today.** `confidence_pct = round(100 × valid × coverage × quality × stability)`. A full quiet week and a full fever week can both read ~100. Three nights at 72 can still look like a “confidence” story. The label sounds like “we are sure they are sick.” The percent barely moves except when night count ticks.

**What replaces it on the dashboard.** Each usual box drops the word **Confidence**. It shows **`usual_trust_pct`** labeled **TRUST**, plus **HOW OFF** on the call (or **Not enough nights**). TRUST is “how much this usual is allowed to judge tonight” for **this biometric**. It is not Charge. It is not “percent chance the drug worked.”

**How TRUST is computed (every `T`, every series, every copy).** Factors in 0…1; the series uses its own establish count, stale days, and `k` from item 2.

```
coverage     = n_ok / n_window          # span_7 slots; long = 53
freshness    = max(0, 1 − age_last_ok / stale_days)   # not a cliff at day 14 only
quality_win  = n_ok / (n_ok + n_low_quality)
n_eff_frac   = min(n_eff / n_establish, 1)            # hangover; HRV usually lower n_eff
slope_ok     = 1 if item-3 slope usable, else 0.75
freeze_ok    = 1 if this copy is live or a qualified freeze; 0.4 if freeze failed
confound     = 0.5 if today has patient-entered “other things going on,” else 1
tonight_q    = 1 if today quality-OK, 0.25 if low_quality, 0 if missing

data_q       = coverage × freshness × quality_win × n_eff_frac × slope_ok × freeze_ok × confound
usual_trust_pct = round(100 × data_q × (0.5 + 0.5 × tonight_q))
```

This **moves** when last night was weak, the strap was off, nights are correlated, a freeze failed, or they tagged illness/diet — not only when `n` goes from 6 to 7.

**Unusualness (not TRUST).** Left rail IN RANGE / OFF. Under it, **`how_unusual_pct`** labeled **HOW OFF**. Hide and say **Not enough nights** when `usual_trust_pct < 35`.

```
z        = (today − expected_for_that_copy) / spread
df       = max(n_eff − 1, 3)
how_unusual_pct = round(100 × student_t_two_tail(|z|, df))
```

High HOW OFF + high TRUST = we stand behind “off this usual.” High HOW OFF + low TRUST = **Not enough nights**, never a red 90% that looks like a diagnosis.

**Dashboard layout.**

```
THIS WEEK                    LONGER / ON {NAME} / EXPECTED WITHOUT TREATMENT
usual + hatch                usual or expected path + hatch
TRUST 72%                    TRUST 81%
IN RANGE · HOW OFF 8%        OFF · HOW OFF 86%     or  NOT ENOUGH NIGHTS
```

After a treatment start, the right box is **Expected without treatment** (item 6).

**Proof.** Three nights, RHR 72 vs usual 60: TRUST low, HOW OFF not shown as a confident OFF. Full week in-band 60: TRUST high, HOW OFF low. Full week 72: TRUST high, HOW OFF high. HRV TRUST < RHR TRUST on the same calendar coverage because `n_eff` and `k` differ. If `confidence_pct_*` is still the only percent on the card, this request failed.

---

## 5. Frozen baseline after a medication is not proof the medication caused the change

**Request.** Comparing someone after starting a medication to a frozen number does not tell us the medication caused the change. They could already have been getting worse, then naturally improve. Sleep, activity, illness, diet, another medication, etc. could change at the same time. Account for those as much as we can.

**What is wrong today.** Copy in the spec already says “not a causal drug claim,” but the product can still lead with a frozen **number**. Confounder flags exist; diet is missing. Easy to read the trial block as “the med did this.” Start time must never be inferred from HR — that rule stays.

**How we add it.** This request is **not** absorbed into item 6. Item 6 is the control *model*. Item 5 is everything that stops us from calling the gap a drug effect:

1. **Pre-start trend** — primary gap is vs `expected_untreated` (item 6), not vs flat L0. If they were already improving, the path gap is small even when the flat gap is large.
2. **Other things going on** — patient/caregiver chips on that civil day: illness, hospitalization, travel, sleep disruption, exercise/activity change, **diet change**, **concomitant medication**. Primary “change since start” uses days with **no** chip and quality-OK. Chipped days stay **visible** (grey).
3. **Provenance** — device or math change after t0: **Device or math changed**. Do not paint that step as physiology.
4. **Phase** — Settling in (item 7) cannot declare a meaningful response even if the gap is large.
5. **Primaries** — item 8: we do not hunt 15 series and then tell a causal story about whichever moved.
6. **On-screen sentence, always:**

> This is the difference from what this series was doing before the start, including any slow trend. Sleep, activity, illness, diet, another medication, or the disease itself can move the same number. It is not proof the treatment caused the change.

7. Never infer t0 from heart rate. Never title a card “Lisinopril lowered RHR.”

**Dashboard.** Trial block disclaimer under the three columns. Grey chips on calendar and detail. Ineligible days: gap drawn, summary silent.

**Proof.**
- `preexisting_recovery`: falling RHR before t0 continues after; path gap small, flat gap large; summary follows the path.
- `confounded_start`: illness or diet or extra med on that day → primary contrast **ineligible**; chip visible.
- `provenance_break_after_start`: firmware change → not scored as change since start.
- Card copy contains the non-causal sentence.

If we only freeze a slope and skip chips/disclaimer/ineligibility, this request is not met.

---

## 6. Freeze a model of expected physiology without treatment — live vs on-treatment every night

**Request.** Instead of only freezing the baseline value, freeze a model of what we expected their physiology to do without treatment. If they were already trending up or down before starting, compare them against that expected trajectory rather than a flat number. After start, keep that comparison **updating** every night against medication-time usuals.

**What is wrong today.** The freeze bundle stores centers. The card can lead with **Non-treatment usual = 68**. `z_trial_traj` exists in the engine but is not what the dashboard tells. Settling in vs on-treatment vs washout do not change how the comparison is shown.

**What we freeze at t0** (days strictly before start; never edited later):

- `L0` level, `G0` slope (item 3 at T_freeze), spread, `r1`, `σ_meas`, window, provenance  
- `expected_untreated(T) = L0 + G0 × (T − T_freeze)` with a **30-day extrapolation cap** (then expected holds; TRUST on that copy drops)

Thin slope gate → freeze a **flat** model and say so: “Not enough pre-start trend to project; comparing to the usual level only.”

**What keeps moving after t0 (medication time):** this week’s usual; **On {name} usual** (post-start slow copy); today.

**Comparison that updates every scored day** (summary sentence: **primary series only**, item 8):

| Shown | Formula | Role |
|---|---|---|
| Expected without treatment | `expected_untreated(T)` | Frozen **model**, not a flat souvenir |
| On-treatment usual | live `center_long` in the post-start epoch | What this course looks like now |
| Today | last completed night | |
| Gap vs path | `today − expected_untreated(T)` | Primary “change since start” in **units** |
| Gap vs flat L0 | `today − L0` | Detail only — “if we had frozen a number” |
| Gap vs on-treatment usual | `today − center_on_rx` | Monitoring on the drug, not vs control |
| Bigger than sensor noise? | `|gap vs path| ≥ MDC_95` | Test-retest, not causality |
| Eligible today? | item 5 chips / quality / provenance; item 7 phase for the **summary** | |

**Phase-aware:**

| Phase | Comparison behavior |
|---|---|
| Settling in | Show the three numbers. Summary: **Too early to judge a response** (onset days from item 7). TRUST can be high. |
| On treatment | Summary may fire on primaries if eligible, \|gap vs path\| ≥ MDC, TRUST ≥ 35, HOW OFF vs path high. Copy from item 5. |
| Washing out | Keep expected_untreated frozen. Add **last on-treatment usual**. Do not mix washout nights into L0. |
| Ended | History: path vs what happened; live slow copy **After {name}**. |

**Dashboard trial block.** Three equal columns every night: **Expected without treatment** | **On {name}** | **Today**. Line in units: “Today is 6 bpm below the no-treatment path (bigger than sensor noise).” Ghost: “Vs the old flat usual it would look like 8 bpm.”

**Proof.** Same `preexisting_recovery` tape: `expected_untreated ≠ L0` when `G0 ≠ 0`; primary z ≠ flat z; card leads with expected. If the big number is still only “Non-treatment usual = 68,” this request failed even if slope sits in the log.

---

## 7. Washout and settling in from what the patient enters — do not bias the model

**Request.** A fixed 7-day washout should not be universal; drugs differ. Logging the medication and researching onset, washout, and expected effects is one option. The other is: do not tell the model what we expect to see; use that information only to define what to look for and to interpret afterward. The app should use **what the patient (or caregiver) typed** to **label** phases.

**Decision.** Clocks and watch-list only. Expected side effects / “HRV should rise” never pull `expected_untreated` or hide a drop. No in-app PK lookup from a drug name in this version.

**What is wrong today.** `washInDays = 7` and `washoutDays = 7` sit on global `Params`. The end form in the frontend plan is not wired to the clock.

**Patient/caregiver fields that drive phases** (clock time required; never inferred from HR).

**On Log treatment (start):**

| Field | Required | What the app does with it |
|---|---|---|
| Start date + time | yes | t0 |
| Treatment name / dose | yes | Banner |
| **When I expect it to start working (days)** | no, default 7 | Length of **Settling in** |
| **If I stop, how long until I expect it out of my system (days)** | no, default 7 | Default **Washing out** length |
| Primary series (1–3) | yes to judge a response | Item 8 |
| Notes from clinic / label | no | Shown on Treatment; **not** sent into z |

**On End treatment:**

| Field | Required | What the app does with it |
|---|---|---|
| End date + time | yes | `t_stop` |
| Last dose date + time | no | Washout clock starts from **last dose** if later than End |
| Why it ended | yes | Timeline only |
| **I expect washout to take (days)** | no | Overrides start-form washout for this stop |
| **I already feel it’s out of my system** | no | Overlay **Patient says clear**; **ends the washing-out label now**. Does **not** edit L0/G0 or z |

**While washing out (optional, not a nightly chore):**

| Check-in | Effect on **label** | Effect on **math** |
|---|---|---|
| Still feeling effects | Stay **Washing out** even if the day count passed | None |
| Feels gone | **Ended** + “Patient says clear” | None |
| Logged a dose / restart | Back to **Settling in** (same trial id) | Freeze kept |
| Interruption (paused, will resume) | **Washing out** until restart | Freeze kept |

**Phase machine (reads the record, not global 7):**

```
wash_in    = start.onset_days ?? 7
washout    = stop.washout_days ?? start.washout_days ?? 7
t_clock    = last_dose_at ?? t_stop

if no start:           none
if stop/interrupt:
    if patient_says_clear:     ended
    if patient_still_feeling:  washing_out
    if T < t_clock + washout:  washing_out
    else:                      ended
else if T < t0 + wash_in:      settling_in
else:                          on_treatment
```

**Dashboard.** Banner **{name} · {phase}**. Caption: “Washing out — you entered 14 days after last dose {time}.” TRUST / expected path **do not** change when they type 14 instead of 3.

**Proof.** Same physiology tape, washout 3 vs 14: **Ended** on different days; `expected_untreated` and z identical. Patient says clear on day 2 of a 14-day washout: phase **Ended**, z unchanged. “Expect RHR to fall” is not an engine input. If phase still uses only `Params.washoutDays`, this request failed.

---

## 8. Decide which metrics matter before judging a response

**Request.** We should decide ahead of time which metrics we actually care about for each medication/disease. If we look at 15–20 signals after starting a drug, something will almost always change by chance. The important metrics should be defined **before** we judge whether there was a meaningful physiological response.

**What is wrong today.** Layer 1 scores every series that has data. After a qualifying freeze, every such series can show Change since start. There is no primary vs exploratory. A noisy SpO₂ wiggle can look like a “response” next to a quiet RHR.

**How we add it.**

1. **Start form (before save):** pick **1–3 primary series** from the catalog that already has data. Optional second list = exploratory; default exploratory = all other series with data.
2. Store that list on `trial_id` **at t0**. Editing primaries after the first post-start `evaluate` requires a **new trial id** (no fishing in the UI).
3. Monitor still shows other series, badge **Exploratory**. Same TRUST / HOW OFF / plots. They **cannot** write the summary sentence.
4. **Meaningful response** (trial block): only primaries that `trial_freeze_ok`, using gap vs path (item 6) + TRUST (item 4) + `above_mdc` + eligible day (item 5) + phase On treatment (item 7). Do **not** average primary z’s into one “it worked” score.
5. If they refuse to pick primaries: engine may still freeze what qualifies; summary = **No primary series chosen — not judging a treatment response.**
6. Clinic/label notes (item 7) may *suggest* which series to pick (watch-list). They do not auto-select primaries and do not bias z.

**Dashboard.** Primary cards unlabeled (they are the default). Others: **EXPLORATORY**. Summary line names only primaries.

**Proof.** Fixture: 12 series, 1 primary (sleep RHR). After start, several exploratory series move. Summary does **not** say there was a treatment response from those. Empty primaries → not judging, even if others moved. If every frozen series can write the summary, this request failed.

---

## What we are not changing

- Charge / Recovery on Today.
- Two copies of usual, never averaged into one 0–100.
- On-device math. No Node scoring API.
- Patient and caregiver see the same metrics.
- Missing nights stay missing (never 0 bpm).
- Expected drug direction is never an input to `expected_untreated` or z.
- Full state-space (item 3’s successor) is not this pass.
- Real WHOOP `k` table (item 1) is not faked to close the review.

---

## Acceptance pack — all eight, equal gate

Each request has one proof. Missing any row means the review is not in the baseline.

| # | Request | Proof artifact | Passes when |
|---|---|---|---|
| 1 | Calibrate / stable FPR | `stable_rhr_60`, `stable_hrv`, `stable_resp` + empty real-data row | Per-series rates printed; HRV not scored with RHR `k` |
| 2 | Per-biometric rules | `params(for:)` + resp vs HRV wiggle | k/span/gates differ; outcomes differ |
| 3 | Spike vs weeks-long shift | `spike_rhr_two_nights` vs `slow_shift_rhr_three_weeks` | Spike OFF; slow shift not stuck OFF vs flat usual |
| 4 | TRUST ≠ HOW OFF | Three-case table + HRV vs RHR TRUST | No old CONFIDENCE formula on the card; numbers disagree when they should |
| 5 | Freeze ≠ the drug did it | `preexisting_recovery` + `confounded_start` + provenance + disclaimer | Path wins; chipped day ineligible; no causal title |
| 6 | Freeze a no-treatment **model** | Same tape: `expected(T)` vs L0; three-column block | `expected ≠ L0`; primary z ≠ flat z; card leads with expected |
| 7 | Patient-labeled washout; no model bias | 3 vs 14 days; “says clear” day 2 | Phases follow the form; z/expected identical |
| 8 | Pre-specify metrics | 12 series, 1 primary | Summary ignores exploratory moves |

**Build order (dependency, not priority).** The eight are equal in the product. Implementation may go 2 → 3 → 4 → 6 → 5 → 7 → 8 → 1 because later proofs reuse earlier fields. Item 1’s harness can be written as soon as item 2’s `k` exists. Do not ship a “final” baseline that only implements 2, 4, 6, and 7.

Until **all eight** proofs pass, this review is not in the baseline.
