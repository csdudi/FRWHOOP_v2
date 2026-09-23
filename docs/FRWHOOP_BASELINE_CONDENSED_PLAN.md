Longitudinal baseline (WHOOP 5.0)

Plan home (next to on-device analytics): Packages/StrandAnalytics/Baseline/. Same files are also under docs/. How to build on git HEAD: FRWHOOP_BASELINE_IMPLEMENTATION.md.

The strap records the samples. The paired phone or computer stores them and runs this math. Nothing here runs in strap firmware, and nothing here requires a server.

Charge and Recovery stay on the existing Winsorized EWMA. This work sits beside that path. It does not replace it, and it does not produce one blended recovery number. The 7-day baseline below is a different EWMA: a finite 7-day window, renormalized over quality-OK days only, not Charge’s production path.

Each metric, source, and context has its own history. Sleep RMSSD from WHOOP is never mixed with Apple SDNN. Sleep resting heart rate is never mixed with still waking heart rate, moving waking heart rate, or the continuous all-hours mean. Sleep SpO₂ mean is never mixed with sleep SpO₂ nadir. Daily steps are never mixed with daily active minutes. The five contexts (sleep, awake_rest, awake_active, continuous, waking_load) never share a key.

The primary baseline, for this version, is the last 7 days (EWMA). A second, slower copy looks back 60 days but skips those same 7 days (median). The two copies are never averaged together. That pair is still the engine skeleton. The **shipped contract** is `param_set = v1.review`: per-series knobs (1.7), slow slope on the longer path (1.2.1), TRUST / HOW OFF on the card (1.7), and a frozen **no-treatment model** after t0 (1.8.1). It is not the final engine: the intended successor is a robust state-space model of level, trend, and uncertainty (section 1.9).

Two modes share that math. Before a recorded start, one adaptive track answers what is usual now. After a qualifying start, freeze **Expected without treatment** (`L0`, `G0`) from days strictly before that clock time, and open a **new adaptive epoch** so **On {name} usual** only sees post-start nights. Patient and caregiver see the same named list (section 1.8). The two long copies are never averaged. The gap is not proof a drug caused the change (1.8.1 item 5).

Layer 1 is one series at a time. Each snapshot also stores the fast–slow gap, TRUST, HOW OFF, persistence counts, slope, and a regime flag so a later watchdog can read them. This pass does not fire alerts and does not mix metrics into one score.

**Overall testing (Prime / gauntlet).** This file **is** the overall baseline spec, including the eight equal-weight review requests folded into the numbered sections. Do not test only `FRWHOOP_BASELINE_REVIEW_CHANGES.md` in isolation. That file is the item-by-item source; the sections below are what must pass together. Unchanged product rules: Charge / Recovery stay on Winsorized EWMA; on-device math; missing ≠ 0; never infer t0 from HR; never average the two usuals; never average primary z into “it worked.”


1. Time

T is the last completed civil day on the device calendar. That is the day being scored. Both snapshots are built from days strictly before T, then T is compared to those snapshots. Samples with a timestamp after the as-of cutoff for T are ignored.

1.1 The 7-day baseline (primary) — EWMA

Calendar days [T−7, T−1], inclusive. Length = 7 days.

This is this week’s usual. T itself is not in the list; last night is T−1. Build the longer snapshot first (section 1.2, 1.2.1, and 1.6). Then score this week against that slower **path** (section 1.4) and form the 7-day EWMA. The center is an exponentially weighted moving average of the days this week that are allowed to train, not the median. Last night counts more than a night six days back, in a fixed, documented way, instead of a sorted-list cliff (the 4th of 7 values) that jumps when one extra night crosses the middle.

Smoothing constant (standard conversion). Default `span_7 = 7` (sleep RHR and most series):

α = 2 / (span_7 + 1) = 2 / 8 = 0.25

Sleep / rest HRV uses `span_7 = 10` so α = 2/11 (section 1.7 table). Worked weights in this section assume span 7.

Half-life: (1 − α)^h = 1/2 ⇒ h = ln(2) / ln(4/3) ≈ 2.41 days. About half of the 7-day center’s mass sits in the most recent two to three quality-OK nights.

Age of a day d in the window: age(d) = (T−1) − d. So T−1 has age 0, T−7 has age 6.

Raw exponential weight (only if that day is quality-OK):

w_raw(d) = α × (1 − α)^age(d) = 0.25 × 0.75^age(d)

If the day is missing, failed quality, or (awake rest / awake-rest SpO₂) under 30 still minutes: w_raw(d) = 0. The day is not entered as zero. For steps and active minutes, a true zero (wore the strap, recorded no steps) is a real value with w_raw > 0; a missing stream is w_raw = 0.

Learn weight (section 1.4). After the longer usual is established, a quality-OK day that is off that slower usual is downweighted with a smooth curve (Student-t / Huber), not dropped to 0:

w_learn(d) = w_raw(d) × λ(d)

λ(d) ∈ (0, 1]. Moderate |z_long| still trains a little; extreme |z_long| trains almost nothing. Center_7 uses w_learn. Always also store center_7_raw from w_raw so the absorbed week is visible.

Let W = sum of w_learn over the 7 slots. Need at least 4 quality-OK days (n_7 ≥ 4) to show a provisional 7-day snapshot. Need n_learn = sum λ(d) ≥ 4 and W > 0 to update center_7; otherwise hold the last published center_7. Four valid days are enough to show a number. They are not enough to treat spread or a later alert as strong (section 1.5, 1.7).

Normalized weight:

w(d) = w_learn(d) / W

Then:

center_7 = sum w(d) × x(d)
center_7_raw = sum (w_raw / sum w_raw) × x(d)   if sum w_raw > 0

If every slot is filled and λ = 1, sum of w_raw = 1 − 0.75^7 ≈ 0.867 (the infinite tail beyond 7 days is dropped on purpose). The normalized weights, oldest to newest, are:

T−7  T−6  T−5  T−4  T−3  T−2  T−1
0.051  0.069  0.091  0.122  0.162  0.216  0.289

T−1 is about 29% of the 7-day center. T−7 is about 5%. Newest / oldest ≈ 5.6. They still all contribute; last night does not get 100%.

If some days are missing, drop those raw weights and divide by the new W so the remaining weights still sum to 1. The surviving nights keep their relative recency. Example: T−5 missing does not dump its mass onto T−1 only; every remaining night’s share scales up by the same factor 1 / (1 − w_raw(T−5)/W_full).

Spread on the days that trained center_7 (section 1.5 if n_learn is small):

MAD_7 = median of |x(d) − center_7| over quality-OK days with λ(d) ≥ 0.5 (if fewer than 3 such days, use all quality-OK days)
spread_7_raw = max(1.4826 × MAD_7, floor)
spread_7 = borrowed mix of spread_7_raw and spread_long (section 1.5)

Band, delta, and z use center_7 and spread_7 as in section 2. Always also store z vs the longer copy, and gap = center_7_raw − center_long.

Worked week (sleep resting HR, bpm)

Day     age    value     w_raw      w after drop T−5
T−7     6      58        0.0445
T−6     5      60        0.0593
T−5     4      —         0
T−4     3      61        0.1055
T−3     2      59        0.1406
T−2     1      72        0.1875
T−1     0      72        0.2500

n_7 = 6. Sum of w_raw ≈ 0.787. Normalized weights on the six nights, oldest to newest: 0.057, 0.075, 0.134, 0.179, 0.238, 0.318.
center_7_raw = 66.5 bpm.

A median of the same six numbers is 60.5 bpm (middle of 58, 59, 60, 61, 72, 72). The raw EWMA is higher because T−2 and T−1 are 72 and they carry 0.238 + 0.318 ≈ 56% of the mass. That is the point of the descriptive EWMA: this week’s look follows the recent nights without waiting for 4 of 7 sorted values to jump.

If the longer usual is established near 60, those two 72s have |z_long| = 4.2 and Student-t λ ≈ 0.23 (section 1.4). They still contribute a little. n_learn = 4 + 2×0.23 = 4.46, so center_7 updates from the mix; center_7_raw stays 66.5 so gap stays visible.

If all 7 slots are 72 and the longer usual is also 72, center_7 = 72 exactly.
If all 7 slots are 72 and the longer usual is near 60 and established, each day has |z_long| = 4.2 and Student-t λ ≈ 0.23. n_learn ≈ 1.6 < 4, so hold the last well EWMA. center_7_raw = 72. z vs the longer copy stays large. The training center does not become 72.
If the three oldest are 60 and the four newest are 72, a median is 72 (4th of 7) and an equal-weight mean is 66.9. The raw EWMA is 69.5. After Student-t downweight vs a long usual near 60, n_learn ≈ 3.9 < 4, so hold rather than walking to 69.5. The 72s still have λ ≈ 0.23; they are not zeroed.

Coverage: n_7 / 7. Need n_7 ≥ 4 (4/7 ≈ 57%) to show a provisional 7-day copy. Last update on this copy can be T−1. Do not set alert_eligible on four days (section 1.7).

This EWMA is not Charge’s Winsorized EWMA. Charge stays untouched. It is also not an infinite-history smoother: days older than T−7 have weight 0 on this copy.

1.2 The longer baseline (secondary; 60-day lookback) — median

Calendar days [T−60, T−8], inclusive.
Length = (T−8) − (T−60) + 1 = 53 days.

“60-day” is the lookback start (60 days before T). It is not 60 included days. Implement inclusive date math or the window will be off by one.

This copy is usual when well. The same 7 days that make the primary EWMA have membership weight 0 here. They are the gap (Gadaleta). T is also weight 0.

Membership when scoring T, for this copy only:

Each day in [T−60, T−8]: candidate if quality-OK, else 0 (equal rank in a sorted list; not EWMA).
Each day in [T−7, T−1]: weight 0 (those days belong to the 7-day EWMA, not this one).
Day T and anything older than T−60: weight 0.

Then trim (section 1.6) so a long abnormal run cannot become the median:

S = candidate days
m0, MAD0 from S
S1 = days in S with |x − m0| / max(1.4826 × MAD0, floor) < k_learn
If |S1| / |S| ≥ 1 − p_regime (default p_regime = 0.35) and |S1| ≥ 4: use S1
Else: do not absorb S yet; apply p_change (section 1.6). If p_change ≥ p_thr, hold the last established center_long and spread_long.

center_long = median of the kept long days (or the held value)
MAD_long = median of |x − center_long| on those same kept days
spread_long = max(1.4826 × MAD_long, floor)

Show numbers if n_long ≥ 4 (4/53 ≈ 7.5% of the long slots). Call it established if n_long ≥ 14 (14/53 ≈ 26%). Last update cannot be newer than T−8. alert_eligible requires established (section 1.7).

The median’s breakdown point is 50%. Trim plus hold is stricter: fever days aging into [T−60, T−8] stay out of the well median until p_change says the well state itself moved. Seven fever days are 7/53 ≈ 13% of a full long window; they are trimmed and p_change stays below p_thr. If the CUSUM probability crosses p_thr, do not quietly relabel that as normal — hold.

There is no half-life on the longer center. Recency for “this week” is the 7-day EWMA. A later bounded EWMA on the gapped 53-day list, if added, is not the returned longer center.

1.2.1 Slow slope vs a short spike (Theil–Sen on the long copy)

A two-night fever must stay OFF the longer usual, and this week’s *training* usual must not sprint to 72 (section 1.4). A **weeks-long** climb or drop is not a temporary anomaly: if the slope gate passes, residuals in-band mean that path **is** the usual.

Every scored day T, for each series:

1. Theil–Sen slow slope on the kept long nights (same estimator as freeze G0). Store `slope_long` on the adaptive snapshot.
2. Usable slope gate: longer copy established, enough nights (n ≥ 8), slope distinguishable from 0 vs MAD, residual scatter not exploding (`residualSpread < 3 × spread`). If the gate fails → score vs the **flat** median (classic v1).
3. Detrend when usable: `expected_long(d) = center_long + slope_long × (d − t_center)` with `t_center` the midpoint of the long kept window. Residual = `x − expected_long`. `z_long`, Student-t λ (1.4), and CUSUM (1.6) run on residuals, not on distance to a flat median.
4. Spike: slope ~ 0 or gate fails, two ugly nights → OFF longer usual; this week’s training usual still downweights.
5. Shift: slope gate passes, residuals in-band for weeks → not stuck OFF vs a flat old median. `p_change` on detrended residuals (a true jump still holds; a slow path does not).
6. Cap: do not project a 30-day slope far past the last long night (`slopeHorizonDays = 30`). Beyond the cap, expected holds last projected value and TRUST on that copy drops (1.7).

Dashboard: when slope is usable, the longer hatch follows the path (or the rail shows **expected today**). Caption: “Longer usual may drift slowly. A short spike is not.” When the gate fails, the flat median.

Proof fixtures (must both pass): `spike_rhr_two_nights` (long 60 then two 72s → OFF; training usual not 72) vs `slow_shift_rhr_three_weeks` (~0.3 bpm/day for ~21 days → **not** stuck OFF vs flat 60). A Kalman filter is not required for this proof.

1.3 Life cycle of one night D

T = D: D is “today.” Weight 0 on both copies.
T = D+1 through D+7: D is in the 7-day EWMA only. Its EWMA weight is largest the next morning (age 0) and shrinks each day until it leaves (age 6).
T = D+8 through D+60: D is in the longer median only (equal rank among up to 53 points).
T = D+61 onward: D has aged out.

When T advances by one civil day: the previous T becomes T−1 (age 0 in the EWMA); every other 7-day age increases by 1; the day that was T−7 leaves the EWMA and enters the longer median; the day that was T−60 drops off.

Clock from oldest longer slot through T is 61 calendar days. Seven of those feed the primary EWMA, 53 feed the secondary median, one (T) is scored and not folded in yet.

Device-wide stale: no quality-OK day on that series for more than 14 consecutive calendar days.

1.4 Downweight on the 7-day center (Student-t / Huber)

The 7-day EWMA will learn an abnormal week if every quality-OK day trains at full weight. That shrinks 7-day z while the person is still off their slower usual. Do not wait for the watchdog. Do not use a binary freeze (train vs λ = 0).

When the longer copy is established (n_long ≥ that series’ establish count) and spread_long exists:

expected_long(d) = center_long                         if slope gate fails (1.2.1)
                 = center_long + slope_long × (d − t_center)   if slope usable

z_long(d) = (x(d) − expected_long(d)) / spread_long    for each quality-OK d in [T−7, T−1]

Student-t weight (ν = 4):

λ(d) = min( 1, (ν + 1) / (ν + z_long(d)²) )

Huber alternative (same k_learn = 2): λ = 1 if |z_long| ≤ k_learn, else k_learn / |z_long|.

|z_long| = 0 → λ = 1. |z_long| = 2 → Student-t λ = 0.63. |z_long| = 4.2 → λ = 0.23. |z_long| = 10 → λ = 0.05. Moderate days still contribute; extremes contribute almost nothing.

If the longer copy is not yet established, λ(d) = 1 for every quality-OK day.

n_learn = sum of λ(d) over the 7-day slots (not a headcount of λ = 1).
If n_learn ≥ 4: recompute center_7 from w_learn.
If n_learn < 4: hold the last published center_7 and spread_7. Still write center_7_raw from all quality-OK days.

Always store:

gap = center_7_raw − center_long
gap_z = gap / spread_long   (omit if spread_long missing)

gap is the explicit fast–slow difference. A later watchdog reads gap and z_long first. It does not treat a small 7-day z as “back to normal” when gap_z is large.

1.5 Borrowed 7-day spread

MAD on 4–7 points is jumpy even when it is a MAD. Until this week has a full train set, mix in the longer spread:

λ_s = n_learn / n_borrow    (n_borrow default 7; cap λ_s at 1)

If the longer copy is established:
spread_7 = max( λ_s × spread_7_raw + (1 − λ_s) × spread_long, floor )
Else:
spread_7 = spread_7_raw

When n_learn = 7, λ_s = 1 and there is no borrow. When n_learn = 4, 4/7 of the band is this week’s MAD and 3/7 is the slower scale. conf_spread is low unless λ_s = 1 or the mix used an established long copy.

1.6 Online change-point on the longer copy

Trim (section 1.2) still stops a minority of fever days from walking the median. Calling a genuine new physiological state is an online probability, not a fixed 14-day block or a 35% drop rule.

For each new candidate long day d, residual e(d) = x(d) − expected_long(d) (section 1.2.1; flat center when the slope gate fails), scaled by spread_long. Robust one-sided CUSUM (both directions, take the max):

S_t = max( 0, S_{t−1} + |e(d)| / spread_long − k_cusum )

k_cusum = 0.5 (shared). Missing days do not increment S and do not reset it.

p_change = 1 − exp( −S_t / h_cusum )    h_cusum = 20

Store S_t and p_change every day. regime_shift = 1 if p_change ≥ p_thr (p_thr = 0.90). Then:

- **Jump** (residuals leave the path, like fourteen nights at 72 after a flat 60): hold the last established center_long and spread_long. Do not quietly relabel 72 as the new usual.
- **Slow shift** (slope usable, residuals in-band): do **not** hold the person OFF a flat old median. The path is the usual.

The two-block median shift (last 14 vs earlier, only if |S| ≥ 28) stays in the log as a diagnostic. It is not the decision. p_regime = 0.35 is likewise diagnostic for how much trim removed, not the new-state call.

A new epoch is allowed when the person (or a later rule) accepts the new state; this pass only stores p_change and holds a jump. A recorded start also opens trial mode and a new adaptive epoch for On {name} usual (section 1.8). Do not use Has usual changed? as a substitute for an explicit start timestamp.

Seven consecutive fever days at |z| ≈ 4.2 vs a **flat** usual give S ≈ 26 and p_change ≈ 0.73 (< 0.90): trim them, do not declare a new usual. Fourteen such days give S ≈ 52 and p_change ≈ 0.93: hold. A three-week 0.3 bpm/day crawl with in-band residuals is the other fixture (1.2.1) and must not look like those fourteen fever days.

1.7 TRUST, HOW OFF, quality reasons, parameters, persistence, FPR (no alerts)

Do **not** put `confidence_pct = valid × coverage × quality × stability` on the dashboard. That number is data completeness. It does not move when the person is off usual, and the word “confidence” reads like a diagnosis. Keep it in the log if tests pin old snapshots; the card uses **TRUST** and **HOW OFF**.

Boolean gates still exist so tests can pin show / established. Compute TRUST even when show is false.

quality_frac = n_ok / max(n_ok + n_low_quality, 1)
  n_ok = quality-OK days in that copy’s window
  n_low_quality = days in that window that produced a number (or an attempted read) but failed the quality gate
  Missing days with no strap-on attempt are Why missing, not low quality; they already lower coverage.

**TRUST** (`usual_trust_pct`) — how much this usual is allowed to judge tonight, for **this biometric**. Not Charge. Not “percent chance the drug worked.” Factors in 0…1; the series uses its own establish count, stale days, and `k` from `params(for:)`:

coverage     = n_ok / n_window          # this week = span_7 slots; long = 53
freshness    = max(0, 1 − age_last_ok / stale_days)
quality_win  = n_ok / (n_ok + n_low_quality)
n_eff_frac   = min(n_eff / n_establish, 1)
slope_ok     = 1 if 1.2.1 slope usable, else 0.75
freeze_ok    = 1 if this copy is live or a qualified freeze; 0.4 if freeze failed
confound     = 0.5 if today has patient-entered Other things going on, else 1
tonight_q    = 1 if today quality-OK, 0.25 if low_quality, 0 if missing

data_q       = coverage × freshness × quality_win × n_eff_frac × slope_ok × freeze_ok × confound
usual_trust_pct = round(100 × data_q × (0.5 + 0.5 × tonight_q))

Hide HOW OFF and say **Not enough nights** when TRUST < 35.

**HOW OFF** (`how_unusual_pct`) — Student-t two-tail on |z| vs that copy’s expected (this week’s EWMA, or longer **path**):

z        = (today − expected_for_that_copy) / spread
df       = max(n_eff − 1, 3)
how_unusual_pct = round(100 × student_t_two_tail(|z|, df))

High HOW OFF + high TRUST = we stand behind “off this usual.” High HOW OFF + low TRUST = Not enough nights, never a red 90% that looks like a diagnosis.

Dashboard layout (both copies show TRUST and HOW OFF):

THIS WEEK                    LONGER / ON {NAME} / EXPECTED WITHOUT TREATMENT
usual + hatch                usual or expected path + hatch
TRUST 72%                    TRUST 81%
IN RANGE · HOW OFF 8%        OFF · HOW OFF 86%     or  NOT ENOUGH NIGHTS

Proof: three nights at 72 vs usual 60 → TRUST low, HOW OFF not shown as a confident OFF. Full week in-band 60 → TRUST high, HOW OFF low. Full week 72 → TRUST high, HOW OFF high. HRV TRUST < RHR TRUST on the same calendar coverage because n_eff and k differ.

conf_spread (internal): high only if n_learn = 7, or n_learn ≥ 4 and established_long supplied the borrow.

show_7: n_7 ≥ 4
show_long: n_long ≥ 4
established_long: n_long ≥ that series’ establish count (1.7 table)
alert_eligible: established_long and not stale and not (regime_shift jump with no new epoch). Still not an alert.

Quality reason on every day that is not quality-OK. A low-quality reading is not the same as a missing day. Do not train either (w_raw = 0). Do not write 0 bpm. Always store a reason:

quality_status = ok | low_quality | missing

quality_reason (required unless status = ok):

poor_signal — noisy PPG / failed HRV intervals / failed optical
low_coverage — under 30 still minutes (awake rest); under 8 valid SpO₂ slots; too few clean RR intervals
out_of_range — native value outside the series min/max (example: 200 bpm “resting”, SpO₂ 50% or 101%)
sparse_sleep — night staged on sparse motion (existing sleep flag)
charging
device_off — strap off / removal
app_fail
hospital
unknown

missing_cause is the same vocabulary when status = missing (none only when a quality-OK value exists). Counts of each reason sit on the snapshot. In these patients, the reason itself is information.

A single-day z is never an alert. Store persistence on z_long (the when-well score), same sign:

run_length: consecutive quality-OK days ending at T with |z_long| ≥ k_band
worse: 1 if |z_long(T)| > |z_long(T−1)| on that series, else 0 (omit if T−1 missing)
hits_3: how many of the last 3 quality-OK days, including T, have |z_long| ≥ k_band
two_of_three: 1 if hits_3 ≥ 2

The later watchdog may require two_of_three, or run_length ≥ 2, before paging. This pass only writes the fields.

Layer 1 does not combine series. Layer 2 (later) may require several series at once (example: RHR up, HRV down, respiration up, wrist temperature up). Do not average those z-scores into one 0–100 number here. TRUST and HOW OFF are also per series. Rest series use the longer path as the primary OFF copy; steps and active minutes use this week first.

Parameters. Shared skeleton (stored on the snapshot). Changing a row or a global writes a new version string. It does not edit old snapshots. `param_set = v1.review`.

lookback_long = 60
gap_days = 7
k_learn = 2
ν = 4
k_cusum = 0.5
h_cusum = 20
p_thr = 0.90
n_7_show = 4
n_long_show = 4
n_borrow = 7
p_regime = 0.35
persist_window = 3
persist_hits = 2
stale_days = 14
slopeHorizonDays = 30
trustHideThreshold = 35
wash_in_days / washout_days defaults = 7 if the patient omits them (1.8.1); they are not a global clock that ignores the form

`params(for: series)` — not one global k / span / floor. Starting table until the FPR report replaces a row:

| Biometric | Math | k | This-week span | Establish | Floor | A day is usable when | OFF means |
|---|---|---|---|---|---|---|---|
| Sleep RHR | bpm | 2.0 | 7 (α=0.25) | 14 | 2 bpm | Sleep engine night, 30–120 bpm | Higher than expected path |
| Awake-rest HR | bpm | 2.0 | 7 | 14 | 3 bpm | ≥30 still minutes | Higher |
| Awake-active HR | bpm | 2.2 | 7 | 14 | 4 bpm | ≥30 moving minutes | Higher |
| Continuous HR | bpm | 2.2 | 7 | 14 | 5 bpm | ≥240 valid minutes | Higher |
| Sleep / rest HRV | ln(RMSSD) | 2.6 | 10 (α=2/11) | 14 | 0.08 ln | Clean RMSSD > 0 | Lower ms than expected |
| Sleep respiratory rate | /min | 1.6 | 7 | 14 | 0.5 | 4–40 /min | Higher |
| Sleep temperature | °C | 2.0 | 7 | 14 | 0.3 | In 20–42 | Higher or lower |
| Sleep SpO₂ mean | % | 1.5 | 7 | 14 + 10 nights with ≥8 slots | 0.5 pp | ≥8 slots, 70–100% | Lower |
| Sleep SpO₂ nadir | % | 1.7 | 7 | same slots | 0.5 pp | same | Lower (own series) |
| Awake-rest SpO₂ | % | 1.5 | 7 | 14 + slots | 0.5 pp | ≥8 still slots | Lower |
| Steps | count | 2.4 | 7 | 21 | 500 | Stream present; 0 is real | Either way vs that person’s path |
| Active minutes | min | 2.4 | 7 | 21 | 10 | Stream present | Either way |

Proof: `params(for: .sleepRHR).k ≠ params(for: .sleepHRVLn).k` and span differs. Same ±2% native wiggle: respiratory rate IN RANGE, HRV not auto-OFF from RHR’s k.

**k from the most stable reading time.** Table k is the prior. Live `k_used` is the 95th percentile of |residual|/spread on that series’ **stable window**, once n_long ≥ 14, clamped to [0.75, 1.40] × table k. Sleep HRV / RHR / resp / temp / SpO₂ use overnight sleep. Awake-rest uses still waking. Motion uses waking load. Do not calibrate HRV k from the all-day mean when a quieter night series exists. Store `k_band_table` and `k_band_used` on the snapshot.

**Stable FPR (calibrate k).** Keep median / MAD / center ± k × spread. Count, per series, how often a **stable** person is still called OFF. Stable stretch: longer usual established, slow slope flat or residuals in-band, p_change below threshold, no treatment, no **acute** day-log flags (illness / travel / extra med), not stale, TRUST ≥ 35. On those days count |z| ≥ k vs longer path, vs this week, two_of_three, and (if a freeze exists) above_mdc. Synthetic fixtures first (`stable_rhr_60`, `stable_hrv`, `stable_resp`). Real WHOOP 5.0 fills the same table later — until that row is filled, do not invent a new k from intuition. Pulse ±1.65 and Cadence |z| ≥ 1.5 are not adopted until this table exists. Release Baseline does not show “FPR %.” Test Centre / DEBUG may print the table. An empty **real WHOOP 5.0 — not run yet** row is required honesty.

1.8 Names on the screen (same list for patient and caregiver)

Engine fields stay in the log. What people see uses these names. Patient and caregiver get the same metrics on every series. Captions can be shorter for the patient; nothing is hidden.

today → Today
center_7 / band_7 → This week’s usual / this week’s range
z_7 → Off this week
center_long / expected_long / band_long → Longer usual / expected path / On {name} usual (after start)
z_long → Off longer usual / Off expected path / Off on-treatment usual (mode)
gap / gap_z → Week vs longer usual
L0 / G0 / expected_untreated → Expected without treatment (frozen model, not a souvenir number)
run_length, two_of_three, worse → Days in a row off
p_change / regime_shift → Has usual changed?
usual_trust_pct_7 / usual_trust_pct_long → TRUST this week / TRUST longer or on-treatment or expected-without (not Charge)
how_unusual_pct_7 / how_unusual_pct_long → HOW OFF this week / HOW OFF longer
adaptive long after t0 → On {name} usual
z_trial_traj → Change since start (gap vs no-treatment path; not a causal drug claim)
z_trial_level → Vs the old flat usual (detail / ghost only)
MDC_95 / above_mdc → Bigger than sensor noise?
σ_meas / σ_bio → Sensor noise / body variation
r1 / n_eff → Night-to-night hangover / effective nights
wash_in, steady_state, washout → Settling in / on treatment / washing out (patient clocks)
quality_reason / missing_cause → Why this reading is weak / Why missing
confounder flags → Other things going on (includes diet change)
provenance / provenance_break → What device and math / Device or math changed
primary / exploratory → (unlabeled) / EXPLORATORY

1.8.1 Trial/intervention mode

The formulas in 1.1–1.7 do not change. After an explicit start they run on two long copies. Never infer t0 from heart rate. Never title a card “{drug} lowered RHR.”

Expected without treatment (frozen **model**). At clock time t0, if that metric qualifies, copy L0 (level), G0 (usable slope from 1.2.1 at T_freeze, else flat), spread, r1, σ_meas, window, provenance — as-of strictly before t0. Days with timestamp ≥ t0 never enter it.

expected_untreated(T) = L0 + G0 × (T − T_freeze)   with a 30-day extrapolation cap; then expected holds and TRUST on that copy drops.

Thin slope gate → freeze a **flat** model and say: “Not enough pre-start trend to project; comparing to the usual level only.”

On {name} usual (new adaptive epoch at start). Same windows and formulas, but the long median in this epoch only sees nights on or after t0 once they are 8 days old. This week’s usual still uses [T−7, T−1] in the live epoch. Dose change, interruption, restart, and stop do not open a new epoch and do not rewrite the freeze. A hard series break still starts a new epoch.

Two questions after t0, never mixed:

Monitoring: today vs This week’s usual and vs On {name} usual (building until the post-start long copy is established).
Change since start: today vs expected_untreated(T). Not a causal drug claim. Gap vs flat L0 is detail only (“if we had frozen a number”).

Example: RHR 68 before treatment with G0 = +0.05, 61 weeks later. This week’s usual may move toward 61. Expected without treatment is the path, not a card that leads with “Non-treatment usual = 68.” On {name} usual grows from post-start nights only.

Always on screen under the trial block:

> This is the difference from what this series was doing before the start, including any slow trend. Sleep, activity, illness, diet, another medication, or the disease itself can move the same number. It is not proof the treatment caused the change.

Dashboard trial block every night: **Expected without treatment** | **On {name}** | **Today**. Line in units: “Today is 6 bpm below the no-treatment path (bigger than sensor noise).” Ghost: “Vs the old flat usual it would look like 8 bpm.”

Phase-aware comparison:

| Phase | Comparison behavior |
|---|---|
| Settling in | Show the three numbers. Summary: **Too early to judge a response**. TRUST can be high. |
| On treatment | Summary may fire on **primaries** if eligible, \|gap vs path\| ≥ MDC, TRUST ≥ 35, HOW OFF vs path high. |
| Washing out | Keep expected_untreated frozen. Add last on-treatment usual. Do not mix washout nights into L0. |
| Ended | History: path vs what happened; live slow copy **After {name}**. |

Six requirements:

1. Qualify before freeze. Do not freeze whatever is on the device at t0. Per series, all of these must hold on the as-of just before t0:

established_long (n_long ≥ that series’ establish count; steps/active 21; SpO₂ extra slot nights)
show_7 (n_7 ≥ 4)
not stale
regime_shift is false (or a new epoch was already accepted)
coverage and quality gates in section 3
conf_spread not collapsed (borrow from established long is allowed)
baseline period stored: first and last civil day that entered the freeze
SpO₂ series: ≥ 8 valid 30-minute slots on at least 10 of the long kept nights

If a metric fails, trial_freeze_ok = 0 for that metric. Adaptive still runs. Do not invent a control from 3 thin nights.

2. Separate sensor noise from body variation. MAD on the live series mixes both. At freeze, on consecutive quality-OK pairs:

δ(d) = x(d+1) − x(d)
σ_meas = 1.4826 × MAD(δ) / √2
σ_bio² = max(spread_long_frozen² − σ_meas², 0)
MDC_95 ≈ 2.77 × σ_meas

If |gap vs path| < MDC_95, above_mdc = 0.

3. Exact timing, dose, and **patient-labeled** phases. Store events with exact timestamps (never inferred from the HR series): start, dose, dose_change, interruption, restart, stop. Clocks and watch-list only. Expected side effects / “HRV should rise” never pull expected_untreated or hide a drop. No in-app PK lookup from a drug name.

On Log treatment: start date+time (required), name/dose (required), **When I expect it to start working (days)** (optional, default 7) → Settling in length, **If I stop, how long until I expect it out of my system (days)** (optional, default 7), primary series 1–3 (required to judge a response), clinic notes (shown, not sent into z).

On End treatment: end date+time, last dose (washout clock starts from last dose if later), why it ended, **I expect washout to take (days)** (overrides start-form washout), **I already feel it’s out of my system** → overlay Patient says clear; **ends the washing-out label now**; does **not** edit L0/G0 or z.

While washing out: Still feeling effects keeps Washing out even if the day count passed (math unchanged). Feels gone → Ended. Logged a dose/restart → Settling in, same trial id, freeze kept. Interruption → Washing out until restart, freeze kept.

Phase machine (reads the record, not a global 7 that ignores the form):

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

Proof: same physiology tape, washout 3 vs 14 → Ended on different days; expected_untreated and z identical. Patient says clear on day 2 of a 14-day washout: phase Ended, z unchanged.

4. Time-series structure and confounders. Consecutive nights are correlated. Store Night-to-night hangover r1 and effective nights n_eff ≈ n × (1−r1)/(1+r1). G0 is the last usable adaptive slope strictly before t0.

Other things going on on day T: none, illness, hospitalization, travel, sleep_disruption, exercise_change, **diet_change**, concomitant_med (one or more flags). Primary Change since start uses days with Other things going on = none and Why missing = none and provenance_break = 0. Chipped days stay **visible** (grey). Other days stay in the same log both people can open. Do not split weekday/weekend; weekend steps widen scatter.

Proof: `preexisting_recovery` — falling RHR before t0 continues after; path gap small, flat gap large; summary follows the path. `confounded_start` — illness or diet or extra med → primary contrast ineligible; chip visible. `provenance_break_after_start` — firmware change → not scored as change since start.

5. Preserve missingness and Why missing. A day with no usable value is missing, never zero. Store Why missing: none, poor_signal, charging, device_off, app_fail, hospital, unknown. Counts of Why missing are part of the trial log.

6. Freeze full provenance. Frozen with Expected without treatment, and stored on every live snapshot: device_model, firmware, decoder_version, metric_def_version, sensor_source, raw_ref. If any of those change after t0: Device or math changed = 1. Do not treat that step as Change since start. A firmware change after t0 must set provenance_break = 1 (Step 6).

1.8.2 Primary series before judging a response

Layer 1 still scores every series that has data. After a qualifying freeze, **do not** let every series write the summary. Fishing 15 signals will always find a wiggle.

1. Start form (before save): pick **1–3 primary series** from the catalog that already has data. Optional second list = exploratory; default exploratory = all other series with data. Clinic notes may *suggest* which series to pick; they do not auto-select primaries and do not bias z.
2. Store that list on `trial_id` **at t0**. Editing primaries after the first post-start `evaluate` requires a **new trial id** (no fishing in the UI).
3. Monitor still shows other series, badge **Exploratory**. Same TRUST / HOW OFF / plots. They **cannot** write the summary sentence.
4. Meaningful response (trial block): only primaries that `trial_freeze_ok`, using gap vs path + TRUST + above_mdc + eligible day (1.8.1) + phase On treatment. Do **not** average primary z’s into one “it worked” score.
5. If they refuse to pick primaries: engine may still freeze what qualifies; summary = **No primary series chosen — not judging a treatment response.**

Proof: 12 series, 1 primary (sleep RHR). After start, several exploratory series move. Summary does not say there was a treatment response from those. Empty primaries → not judging.

1.8.3 Everyday day log (not an OFF questionnaire)

Do **not** open a “what went wrong last night?” sheet because TRUST/HOW OFF went red. That cues the answers from the number. Every scored civil day, the patient (or caregiver) logs **what the day was**, before or after they look at the rails:

- Workout: none / easy / moderate / hard
- Alcohol, travel, felt ill, sleep typical, diet typical, another medication

Workout is a **stratum**. Rest days compare to rest-day usuals; trained days compare to trained-day usuals when at least 7 nights of that class exist. Felt ill / travel / extra med remain **acute** and skip primary Change since start. They do not rewrite L0/G0.

Frozen bundle (immutable). For each metric that qualifies, store:

center_7, spread_7, center_7_raw, center_long, spread_long
gap, gap_z
L0, G0 / slope_long (pre-treatment trajectory; Theil–Sen; 1.2.1)
n_7, n_learn, n_long, coverage, quality flags, TRUST inputs
baseline period [d_first, d_last]
param_set = v1.review, both version strings, epoch id at freeze
provenance
σ_meas, MDC
lag-1 residual autocorrelation r1
primary_series list on the trial (1.8.2)

Post-treatment data must not update any field in that bundle.

delta_trial_level = today − L0
delta_trial_traj = today − expected_untreated(T)
z_trial_level = delta_trial_level / spread_long_frozen
z_trial_traj = delta_trial_traj / spread_long_frozen

Also store the same two deltas vs frozen center_7. Primary trial contrast is Change since start (z_trial_traj) vs the path. A progressive untreated slope makes expected_untreated move; a flat slope makes it = L0.

1.9 Intended engine: robust state-space

v1.review still returns the 7-day EWMA and the gapped 60-day median, plus Theil–Sen on the long copy (1.2.1). That pair is a strong first snapshot. It is not the last baseline engine. Item 3’s slope is not a Kalman filter.

The successor is a robust state-space model, one series at a time, estimated on the companion device:

state: underlying level L_t and trend G_t
observation: x_t = L_t + noise, noise Student-t or Huber (same spirit as section 1.4)
process: L_t = L_{t−1} + G_{t−1} + process noise; G_t wanders slowly
uncertainty: posterior variance of L_t (and of G_t), not only a MAD on 4–7 points
missing x_t: skip the update; do not insert 0

That handles gradual drift, irregular missingness, and a changing usual without a hard 7-day / 53-day split. v1 already stores the pieces that model maps onto: center ≈ L, slope_long ≈ G, spread and σ_meas ≈ observation scale, p_change ≈ probability the level jumped.

Until a state-space version string is fit on real WHOOP 5.0 days, keep returning v1.review. New snapshots from that model do not edit old EWMA/median rows.

Within a civil day

Awake-rest HR, HRV, and awake-rest SpO₂: still minutes are equal in that day’s mean. Under 30 still minutes, the whole civil day is w_raw = 0 for that series.

Sleep series use the overnight sleep engine, not this 30-minute still gate.

SpO₂ sampling: one reading every 30 minutes (48 slots per civil day). A slot with no sample, a non-finite value, or a value outside 70–100% is dropped (missing, not zero). Sleep SpO₂ mean = equal-weight mean of slots whose timestamp falls in detected sleep; need ≥ 8 valid slots (4 hours). Sleep SpO₂ nadir = minimum of those same valid overnight slots (own series; same ≥ 8 slot gate). Awake-rest SpO₂ mean = equal-weight mean of 30-minute slots that are waking and still; need ≥ 8 valid slots. Do not mix sleep slots and waking slots. Do not mix a 30-minute % with a different device’s SpO₂.

Steps and overall activity (waking_load, not sleep): daily steps = sum of steps in waking hours that civil day. Daily active minutes = count of waking minutes that are not still (step rate or motion above the still gate). Each step is equal in the daily sum; each active minute is equal in the daily count. Need a stored step/activity stream for that day or the day is missing. Steps and active minutes are two series; they are not averaged into one “motion score.”

The still/moving gate for rest series is the same step/activity stream: a minute with (approximately) zero steps and no activity is still. That gate is not a substitute for the steps and active-minute baselines.

No weekday/weekend split on this pass (weekend step counts will widen MAD). No hour-of-day bands. Civil days are local to the device calendar.


2. What we compute

For every series we keep two snapshots from the same daily numbers. They are not averaged together. Compute the longer median snapshot first (with trim and 1.2.1 slope), then the 7-day EWMA snapshot (with Student-t downweight vs the longer **path**). That pair is the adaptive track. After a qualifying start, Expected without treatment is the frozen L0/G0 model, and On {name} usual is the same pair on a new epoch that only sees post-start nights.

Each snapshot has: center, spread, expected band, signed delta, z-score, coverage, context, valid-day count, last update, version, plus gap, gap_z, n_learn, TRUST, HOW OFF, slope_long, expected_long, persistence fields, regime_shift, and param_set = v1.review.

7-day (primary):

α = 2 / (span_7 + 1)   (sleep RHR: 0.25; HRV span 10: 2/11)
w_raw(d) = α × (1 − α)^((T−1)−d)   if quality-OK, else 0
w_learn(d) = w_raw(d) × λ(d)
center_7 = sum(w_learn x) / sum(w_learn)    if n_learn ≥ 4, else hold
center_7_raw = sum(w_raw x) / sum(w_raw)
MAD_7 = median of |x − center_7| on days with λ ≥ 0.5
spread_7_raw = max(1.4826 × MAD_7, floor)
spread_7 = mix with spread_long (section 1.5)

Longer (secondary):

center_long = median of kept days in S1 (or held)
MAD_long = median of |x − center_long| on kept days
spread_long = max(1.4826 × MAD_long, floor)
slope_long = Theil–Sen on kept long days (1.2.1)
expected_long(T) = center_long + slope_long × (T − t_center)  if slope usable, else center_long

Both copies:

k = params(for: series).kBand
band = [expected − k × spread, expected + k × spread]   # this week: expected = center_7; long: expected_long
delta = today − expected
z = (today − expected) / spread

Also:

gap = center_7_raw − center_long
z_long(T) = (today − expected_long(T)) / spread_long

Trial track (only after a qualifying freeze at t0):

expected_untreated(T) = L0 + G0 × (T − T_freeze)   # 30-day cap; then hold
delta_trial_traj = today − expected_untreated(T)
z_trial_traj = delta_trial_traj / spread_long_frozen
delta_trial_level = today − L0
z_trial_level = delta_trial_level / spread_long_frozen

Measurement noise vs biological variation (computed once at freeze, on consecutive quality-OK pairs in the freeze window):

δ(d) = x(d+1) − x(d)
σ_meas = 1.4826 × MAD(δ) / √2
σ_bio² = max(spread_long_frozen² − σ_meas², 0)
MDC_95 = 1.96 × √2 × σ_meas ≈ 2.77 × σ_meas

If |delta_trial_traj| < MDC_95, above_mdc = 0. MAD on the live series still mixes both sources; σ_meas is the test-retest piece. v1 uses adjacent-day pairs; a later paired still-window estimate is a new param_set.

Time-series structure (stored at freeze and on each trial day; does not change center_7 or center_long):

r1 = lag-1 autocorrelation of (x − center_long) on kept freeze-window days
n_eff ≈ n_long × (1 − r1) / (1 + r1)    if |r1| < 1
confounder on day T: none, illness, hospitalization, travel, sleep_disruption, exercise_change, diet_change, concomitant_med (one or more flags)
Primary trial contrast uses days with confounder = none and missing_cause = none and provenance_break = 0. Other days stay in the log.

Missingness: a day with no usable value is missing, never zero. A day with a number that fails the gate is low_quality, never trained as if it were ok. Store quality_status and quality_reason (section 1.7). Counts of each reason are part of the snapshot and the trial log.

Provenance (frozen with the control; also stored on every adaptive snapshot):

device_model, firmware, decoder_version, metric_def_version, sensor_source, raw_ref
If any of those change after t0: provenance_break = 1. Do not treat that step as a physiological change since intervention.

A day with no usable data is missing. It is not written as zero.

Why EWMA on 7 days and median on the long copy. A 7-day median is a middle order statistic: it ignores how recent a night is and can jump when the 4th sorted value flips. A span-7 EWMA has a stated α, a 2.4-day half-life, and a smooth pull toward last night. That matches a “this week” look (center_7_raw). The training center (center_7) uses the same weights only on days that are not off the slower usual (section 1.4). The longer copy must not learn this week; a median with a 7-day gap, a trim, a 50% breakdown point, and a regime hold is the right tool there (Leys; NightSignal; Gadaleta). On a mixed longer list of 46 nights at 60 bpm and 7 nights at 72, the mean is 61.6 and the median is still 60.

MAD vs standard deviation. Standard deviation squares residuals, so one glitch inflates the scale. MAD takes the median of absolute residuals from that copy’s center (Leys). The 7-day MAD is around the EWMA center, so spread stays robust even though the center itself is recency-weighted.

1.4826. For a normal distribution, MAD converges to 0.6745 × σ, because Φ⁻¹(0.75) ≈ 0.6745. Then σ ≈ 1.4826 × MAD (NIST).

k = params(for: series).kBand. Band is expected ± k × spread. Pulse’s ±1.65 and Cadence’s |z| ≥ 1.5 are different cuts. Do not adopt them until the FPR table (1.7) exists. The 7-day band is this week’s range. The longer band is around the expected path when the slope is usable, else the median.

z-score. z = (today − expected) / spread. Primary z is versus the 7-day EWMA; secondary z is versus the longer **path** (1.2.1). For HRV, subtract and divide on ln(RMSSD); convert delta and band to ms with exp. SpO₂ delta is in percentage points. Steps and active minutes stay in steps and minutes.

ln(RMSSD). A multiplicative drop (50 ms → 25 ms) is −ln(2) ≈ −0.69 on the log scale, which is what we EWMA, MAD, and z. Never mix SDNN into this series.

Floors and k: the `params(for:)` table in section 1.7. Do not use one global k = 2.

7-day status: omit unless n_7 ≥ 4 (provisional show). Longer copy: n_long < 4 calibrating; 4–13 provisional; established at that series’ count (14 rest, 21 motion). TRUST / HOW OFF follow section 1.7. Stale if no quality-OK day for > 14 calendar days. A later watchdog may page only if alert_eligible and persistence fields agree; it still must not page on a lone z.


3. Daily numbers (one per series per civil day)

Sleep resting heart rate — nightly resting HR from the sleep engine, bpm.
Awake-rest heart rate — mean of waking HR while still; the day counts only with at least 30 still minutes.
Sleep HRV — ln(RMSSD) from clean overnight successive beat intervals. Display in milliseconds. Never SDNN.
Awake-rest HRV — same ln(RMSSD) on still waking beats, only if coverage is enough.
Sleep respiration — overnight rate only if it is a stored, validated breaths/min.
Sleep wrist temperature — overnight wrist mean, °C. Labeled wrist, not core.
Sleep SpO₂ mean — mean of 30-minute % samples inside detected sleep; ≥ 8 valid slots or the night is missing. Calibrated percent only.
Sleep SpO₂ nadir — minimum of those same overnight 30-minute samples. Own series (do not mix with the mean).
Awake-rest SpO₂ mean — mean of 30-minute % samples while waking and still; ≥ 8 valid slots or the day is missing.
Daily steps — waking step sum. Zero steps with a live stream is a real day; no stream is missing.
Daily active minutes — waking minutes that are not still, from the same step/activity stream.
Still/moving — gate only for rest series, derived from that stream. Not its own usual.

Every civil day also stores: missing_cause (none if a value exists), confounder flags (includes diet_change), treatment phase (none before t0), provenance pointer. Missingness is kept; it is not dropped without a cause code.

24-hour mean heart rate is not a rest series. Do not mix Apple SpO₂ with WHOOP SpO₂. High-rate research capture is not this daily history.


4. How to build it

Product phases (do not skip): A = this week + when-well API; B = trial freeze; C = NARA UI. Details and per-series fixtures: Packages/StrandAnalytics/Baseline/FRWHOOP_BASELINE_IMPLEMENTATION.md §8–9. The numbered steps below are the math/build sequence inside those phases, not a reason to ship UI first.

Step 1. Types
Series key: person, metric, WHOOP 5.0, derivation, context (sleep, awake_rest, awake_active, continuous, or waking_load), epoch. A qualifying start opens a new epoch for On {name} usual and keeps Expected without treatment frozen (L0, G0). Dose change does not.
Daily observation: calendar day, value, coverage minutes or 30-minute slot count, quality flag, Why missing, Other things going on (includes diet_change), treatment phase.
Snapshot: every field in section 2, twice (longer median first, then 7-day EWMA), plus Week vs when-well, Days in a row off, TRUST, HOW OFF, slope, Has usual changed?, param_set, What device and math. After a qualifying t0, Expected without treatment and On {name} sit beside each other (section 1.8).
Versions: ewma-span7-mad-k-series-7-t4 (primary; HRV span 10) and gap7-med-mad-k-series-60-cp1 (secondary), plus epoch id and param_set = v1.review. Trial bundle copies those strings at freeze and never changes them.
Intervention event: timestamp, type (start, dose_change, interruption, restart, stop), trial_id, dose fields, patient onset/washout days, primary series 1–3.
Context on the key: sleep, awake_rest, awake_active, continuous, or waking_load (steps and active minutes).

Step 2. Pull daily numbers from local WHOOP 5.0 storage
Sleep, awake-rest, awake-active, and continuous cannot share a key. RMSSD and SDNN cannot. SpO₂ mean and SpO₂ nadir cannot. Steps and active minutes cannot. Drop impossible values (example: 200 bpm “resting”; SpO₂ 50% or 101%; 500,000 steps). Cut history at as-of so a later sample cannot enter T’s usual.

Step 3. Cut the two windows (section 1)
longer list = quality-OK days in [T−60, T−8] (53 calendar slots)
7-day list = quality-OK days in [T−7, T−1] (7 calendar slots)
T is in neither list.

Step 4. Run the formulas (longer median first, then 7-day EWMA)
Longer: trim, median, MAD, floor, Theil–Sen slope (1.2.1), ±k band vs expected path, delta, z, CUSUM on residuals, regime check.
7-day: Student-t downweight vs established long **path**, α from that series’ span_7, renormalize over w_learn, MAD around that EWMA, borrow spread, floor, ±k band, delta, z, gap, TRUST, HOW OFF, persistence.
HRV stays on ln(RMSSD); convert center, band, and delta to ms for display. SpO₂ stays in percentage points. Steps stay in steps. Active minutes stay in minutes.

Step 5. Apply the day-count gates
Omit the 7-day copy below 4 of 7 days (show only). Do not set alert_eligible until the longer copy is established. Do not claim outside the longer range while that copy is calibrating. Late-arriving history writes a new snapshot version. It does not edit old ones.

Step 6. Tests that must pass
Three quality-OK nights in [T−7, T−1] → no 7-day snapshot.
Four nights around 60 bpm in the 7-day list → 7-day EWMA about 60; show_7 true; alert_eligible false unless the longer copy is already established.
Seven days at 72 in [T−7, T−1] after a longer usual near 60, established → λ ≈ 0.23 each, n_learn ≈ 1.6 < 4; center_7_raw = 72; center_7 held (not 72); z_long large; gap large.
Three oldest 60 and four newest 72, long usual 60 established → raw EWMA ≈ 69.5; Student-t n_learn ≈ 3.9 < 4 so hold; the 72s still have λ ≈ 0.23.
n_learn = 4, established long → spread_7 mixes 4/7 raw MAD with 3/7 spread_long.
Two of the last three days |z_long| ≥ k_band → two_of_three = 1; snapshot is not an alert.
Seven fever days aged into a 53-day well list → trim keeps the well median; p_change ≈ 0.73; regime_shift false.
Fourteen late days at 72 → p_change ≈ 0.93 ≥ p_thr → regime_shift true; center_long held.
200 bpm is not an observation.
SpO₂ 50% or 101% is not an observation. Seven nights of sleep SpO₂ means → 7-day EWMA; a single 30-minute slot is never the daily number.
Zero recorded steps with a live stream is a real day; a missing stream is not a zero.
ln(RMSSD) band converts back to milliseconds.
Sleep, awake-rest, awake-active, continuous, and waking_load keys stay distinct. SpO₂ mean and nadir stay distinct. Steps and active minutes stay distinct.
Layer 1 does not average RHR z with HRV z.
A start event with n_long = 8 → trial_freeze_ok = 0; adaptive still updates.
A start event that qualifies → frozen L0/G0 bundle written (Expected without treatment); a new adaptive epoch starts (On {name}); a later 61 bpm day may move This week’s usual and must not change L0 or G0.
expected_untreated(T) uses frozen G0; today vs frozen mean alone is not the only trial contrast; the card leads with the path.
|delta_trial_traj| < MDC_95 → above_mdc = 0.
A firmware change after t0 → provenance_break = 1.
missing_cause = hospital is stored; that day is not a zero RHR.
dose_change after t0 relabels phase; it does not rewrite the freeze.
Patient washout 3 vs 14 on the same tape → Ended on different days; z and expected_untreated identical.
Empty primaries → summary not judging a response; exploratory moves do not write the summary.
spike_rhr_two_nights → OFF longer usual; training usual not 72.
slow_shift_rhr_three_weeks → not stuck OFF vs a flat 60.
params(for: sleepRHR).k ≠ params(for: sleepHRVLn).k
TRUST / HOW OFF on the card; old CONFIDENCE formula is not the displayed percent.
Stable FPR table printed per series; real WHOOP row may be empty (“not run yet”).
Non-causal disclaimer present on the trial block.

Step 7. Shadow log
Write the adaptive snapshot, including Week vs when-well, TRUST this week / longer, HOW OFF, Days in a row off, Has usual changed?, Why this reading is weak / Why missing, Other things going on (including diet), slope / expected path, and What device and math. If a qualifying freeze exists, write Expected without treatment, On {name}, Change since start (path), Bigger than sensor noise?, phase from the patient form, primaries vs Exploratory, the non-causal sentence, and Device or math changed beside it. Do not feed Charge. Do not add alerts or a weighted 0–100 mix. Do not let post-t0 days edit the frozen bundle. Same fields for patient and caregiver.

Step 8. After this ships
A later watchdog can read Off the longer path, Week vs when-well, Days in a row off, and alert_eligible on the live epoch, then (later still) combinations across series. Change since start is for physiological change since intervention, not for that watchdog’s “are they off usual now” page. An optional bounded EWMA on the gapped 53-day list is not the returned longer center. k values stay v1.review placeholders until the FPR table (including real WHOOP) replaces a row. Same named list for patient and caregiver. Prime overall testing uses **this file**, not only REVIEW_CHANGES.md.


5. Worked math

Lists are oldest → newest. Longer copy first (trim). 7-day center is the EWMA on learn days (α from that series’ span_7, renormalized). Spread is 1.4826 × MAD around that EWMA, borrowed from the longer spread when n_learn < 7, with the floor. param_set = v1.review. Sleep RHR worked numbers below still use k = 2.0 and span 7.

5.1 Sleep resting heart rate (floor 2 bpm)

7-day list [T−7, T−1] (bpm): 57, 58, 59, 60, 61, 62, 63
Normalized weights: 0.051, 0.069, 0.091, 0.122, 0.162, 0.216, 0.289
center_7 = 61.1 bpm
|x − center|: 4.1, 3.1, 2.1, 1.1, 0.1, 0.9, 1.9 → MAD = 1.92
1.4826 × 1.92 = 2.85 → spread = 2.85 (above the 2 bpm floor)
7-day band = 61.1 ± 5.70 = 55.4 to 66.8 bpm

Today T = 72 bpm
7-day delta = 10.9 bpm
7-day z = 10.9 / 2.85 = 3.8

If those seven days were all 72 and the longer usual were also 72, center_7 = 72 and today’s 7-day delta is ~0.
If those seven days were all 72 and the longer usual is 60 (established, spread_long = 2.85), each λ ≈ 0.23 so n_learn ≈ 1.6 < 4 and center_7 is held at 61.1; center_7_raw = 72; gap = 12 bpm; gap_z = 12 / 2.85 = 4.2; z_long(T) if today is also 72 is 4.2. The 7-day training center does not walk up. See 5.12–5.13.

5.2 Awake-rest heart rate (floor 3 bpm; need ≥30 still minutes that day)

7-day still-waking means (bpm): 64, 65, 66, 67, 68, 69, 70
center_7 = 68.1 bpm
MAD = 1.92 → 1.4826 × 1.92 = 2.85 → spread = 3.0 (floor wins)
7-day band = 68.1 ± 6.0 = 62.1 to 74.1 bpm

Today = 75 bpm
7-day delta = 6.9 bpm
7-day z = 6.9 / 3.0 = 2.3

5.3 Sleep HRV (RMSSD; math on ln; floor 0.08 on the log scale)

Five quality-OK nights in the 7-day window, treated as T−5 through T−1 (two oldest slots empty; weights renormalized).
RMSSD (ms): 40, 45, 48, 50, 55
ln values: 3.689, 3.807, 3.871, 3.912, 4.007
center_7 (ln) = 3.898, which is 49.3 ms
MAD (ln) = 0.091 → spread = 0.135 (above the 0.08 floor)
Band on ln = 3.898 ± 0.270 = 3.628 to 4.168
7-day band in ms = 37.6 to 64.6 ms

Today RMSSD = 32 ms, ln = 3.466
7-day delta = 32 − 49.3 = −17.3 ms
7-day z = (3.466 − 3.898) / 0.135 = −3.2

5.4 Awake-rest HRV (same recipe; only if still-waking coverage is enough)

RMSSD (ms), T−5 through T−1: 28, 30, 32, 31, 29
ln values: 3.332, 3.401, 3.466, 3.434, 3.367
center_7 (ln) = 3.403, which is 30.1 ms
MAD (ln) = 0.036 → 1.4826 × 0.036 = 0.053 → spread = 0.08 (floor wins)
Band on ln = 3.403 ± 0.16 = 3.243 to 3.563
7-day band in ms = 25.6 to 35.3 ms

Today RMSSD = 22 ms, ln = 3.091
7-day delta = 22 − 30.1 = −8.1 ms
7-day z = (3.091 − 3.403) / 0.08 = −3.9

5.5 Sleep respiration (floor 0.5 /min; only if the nightly rate is stored and validated)

T−5 through T−1 (breaths/min): 14.5, 14.6, 14.8, 15.0, 15.2
center_7 = 14.92 /min
MAD = 0.28 → 1.4826 × 0.28 = 0.41 → spread = 0.50 (floor wins)
7-day band = 14.92 ± 1.00 = 13.92 to 15.92 /min

Today = 17.5 /min
7-day delta = 2.58 /min
7-day z = 2.58 / 0.50 = 5.2

5.6 Sleep wrist temperature (floor 0.3 °C)

T−5 through T−1 (°C): 32.80, 32.85, 32.90, 33.00, 33.10
center_7 = 32.97 °C
MAD = 0.12 → 1.4826 × 0.12 = 0.18 → spread = 0.30 (floor wins)
7-day band = 32.97 ± 0.60 = 32.37 to 33.57 °C

Today = 33.80 °C
7-day delta = 0.83 °C
7-day z = 0.83 / 0.30 = 2.8

5.7 Sleep SpO₂ mean (floor 0.5 percentage points; 30-minute samples)

Within one night: 16 valid 30-minute slots in sleep (8 hours). Example slot %: 97, 96, 96, 95, 97, 96, 98, 96, 95, 96, 97, 96, 96, 95, 97, 96.
Daily number = equal-weight mean of those 16 = 96.19%. (If only 7 slots were valid, this night is missing, not a mean of 7.)

7-day list of those nightly means (%): 96.0, 96.2, 96.5, 96.8, 97.0, 96.4, 96.1
Normalized weights: 0.051, 0.069, 0.091, 0.122, 0.162, 0.216, 0.289
center_7 = 96.43%
MAD = 0.33 → 1.4826 × 0.33 = 0.50 → spread = 0.50 (floor ties)
7-day band = 96.43 ± 1.00 = 95.43 to 97.43%

Today = 94.0%
7-day delta = −2.43 percentage points
7-day z = −2.43 / 0.50 = −4.9

5.8 Sleep SpO₂ nadir (own series; floor 0.5 percentage points)

Same nights, daily number = min of the valid overnight 30-minute slots. Example 7-day nadirs (%): 95, 94, 95, 96, 95, 94, 95
center_7 = 94.84%
MAD = 0.16 → spread = 0.50 (floor wins)
7-day band = 94.84 ± 1.00 = 93.84 to 95.84%

Today nadir = 91%
7-day delta = −3.84 percentage points
7-day z = −3.84 / 0.50 = −7.7

Do not average mean-SpO₂ z with nadir z. They are different series.

5.9 Awake-rest SpO₂ mean

Same 30-minute math as 5.7, but only waking-and-still slots, ≥ 8 valid. Same EWMA / MAD / floor on those daily means. Do not fold sleep slots into this series.

5.10 Daily steps (floor 500 steps; waking_load)

7-day waking step sums: 8000, 9200, 7500, 11000, 8800, 6400, 9100
center_7 = 8503 steps
MAD = 697 → 1.4826 × 697 = 1034 → spread = 1034 (above the 500 floor)
7-day band = 8503 ± 2068 = 6435 to 10571 steps

Today = 4200 steps (stream present)
7-day delta = −4303 steps
7-day z = −4303 / 1034 = −4.2

5.11 Daily active minutes (floor 10 min; waking_load)

Waking minutes that are not still, same 7 days: 42, 55, 38, 70, 50, 28, 48
center_7 = 45.9 min
MAD = 7.93 → 1.4826 × 7.93 = 11.8 → spread = 11.8
7-day band = 45.9 ± 23.6 = 22.3 to 69.5 min

Today = 18 min
7-day delta = −27.9 min
7-day z = −27.9 / 11.8 = −2.4

Steps and active minutes can disagree (many slow steps vs few high-motion minutes). That is why they stay two series. The still gate for HR / HRV / SpO₂ uses the same stream: minutes with ~0 steps and no activity are still.

5.12 Student-t downweight on the 7-day center (sleep RHR; long usual established)

Longer copy already established: center_long = 60 bpm, spread_long = 2.85 bpm. ν = 4.

7-day list (bpm): 58, 59, 60, 61, 62, 72, 72
z_long on the two 72s = (72 − 60) / 2.85 = 4.2 → λ = 5 / (4 + 4.2²) = 0.23.
The first five days have |z_long| ≤ 0.70 → λ = 1.
n_7 = 7. n_learn = 5 + 2×0.23 = 5.46.

center_7_raw = 66.3 bpm (all seven days at full EWMA weight).
center_7 = 62.7 bpm (72s still in the sum, but at 23% of their raw EWMA weight).
gap = 66.3 − 60 = 6.3 bpm
gap_z = 6.3 / 2.85 = 2.2

MAD on days with λ ≥ 0.5 = 2.73 → spread_7_raw = 4.05
λ_s = 5.46 / 7 = 0.78
spread_7 = 0.78 × 4.05 + 0.22 × 2.85 = 3.79

Today T = 72 bpm
z vs downweighted center_7 = (72 − 62.7) / 3.79 = 2.5
z_long = 4.2
A 7-day z vs the raw 66.3 would have been ~2.0. Binary freeze would have put center_7 at 60.6. Student-t sits between those. This is not an alert.

5.13 Hold when the whole week is off (sleep RHR)

Same long usual. 7-day list: 72, 72, 72, 72, 72, 72, 72
Each λ ≈ 0.23. n_learn ≈ 1.61 < 4 → hold last published center_7 = 61.1 bpm and its spread.
center_7_raw = 72
gap = 12 bpm
gap_z = 12 / 2.85 = 4.2
Today 72 → z_long = 4.2. The training center does not become 72. The 72s were not given λ = 0; their total mass was just too small to update.

5.14 Persistence fields (still not an alert)

z_long on T−2, T−1, T = 4.2, 4.2, 4.2 (same series).
run_length = 3
worse = 0 (not larger than yesterday)
hits_3 = 3
two_of_three = 1
alert_eligible = 1 if the long copy is established and not stale.
The snapshot stores those fields. It does not page.

5.15 Borrowed spread with four learn days

n_learn = 4, spread_7_raw = 2.0 (floor), spread_long = 2.85, established.
λ_s = 4/7
spread_7 = (4/7) × 2.0 + (3/7) × 2.85 = 2.36
conf_spread is not “full week,” but the band is not a 4-point MAD alone.
show_7 can be true. alert_eligible still follows the longer copy (n_long ≥ 14), not these four days.

5.16 Trim vs online change-point on the longer copy

46 well nights at 60 bpm and 7 fever nights at 72 in [T−60, T−8].
Median of all 53 is 60. The 72s have |z| ≥ 2 vs that median → trimmed. |S1|/|S| = 46/53 ≈ 0.87 ≥ 0.65. center_long stays 60.
CUSUM on seven days at |e|/spread ≈ 4.2: S ≈ 26, p_change ≈ 0.73 < 0.90. regime_shift = 0.

39 nights at 60 then 14 nights at 72.
Two-block shift = 12 / 2 = 6.0 (diagnostic only).
CUSUM on fourteen days: S ≈ 52, p_change ≈ 0.93 ≥ 0.90. regime_shift = 1. Hold the last established center_long. Do not call 72 the new usual.

5.16b Slow shift vs spike (same sleep RHR)

spike_rhr_two_nights: long stretch at 60, then two nights at 72. Slope gate fails or slope ~ 0. OFF longer usual. This week’s training usual does not become 72 (same hold as 5.1 fever week).

slow_shift_rhr_three_weeks: RHR falls ~0.3 bpm/day for ~21 days. Slope usable. Off is vs the moving expected path, not vs a flat 60. Must not stay OFF-for-weeks against the old median. p_change is not a false “new disease jump.”

5.17 Two tracks after treatment start (sleep RHR; same EWMA/MAD math)

Qualifying freeze at t0. Frozen bundle: L0 = 68 bpm, G0 = +0.05 bpm/day, spread_long = 2.85 bpm, n_long = 40, trial_freeze_ok = 1. Settling in length from the start form (default 7 if omitted).
T_freeze is the last completed day before t0.

28 days after T_freeze, today = 61 bpm, confounder = none, missing_cause = none, phase = on_treatment (past settling in), primary = sleep RHR.
Adaptive track has been allowed to learn: center_7 ≈ 61.2 bpm. Monitoring z vs that center is ~0.

expected_untreated(T) = 68 + 0.05 × 28 = 69.4 bpm   (within the 30-day cap)
delta_trial_level = 61 − 68 = −7.0 bpm
z_trial_level = −7.0 / 2.85 = −2.5   (ghost / detail only)
delta_trial_traj = 61 − 69.4 = −8.4 bpm
z_trial_traj = −8.4 / 2.85 = −2.9   (primary Change since start)

The card leads with Expected without treatment = 69.4 that day, not “Non-treatment usual = 68.” L0 stays 68. The 61s do not enter it. σ_meas = 1.0 bpm → MDC_95 = 2.77 bpm. |−8.4| > 2.77 → above_mdc = 1. Disclaimer on the block. Exploratory series that also moved do not write the summary.

5.18 Qualification miss

start event, sleep RHR n_long = 8. trial_freeze_ok = 0. No frozen bundle. Adaptive snapshots continue. Do not write a trial z.

5.19 Missingness and provenance

A post-t0 day with no RHR and missing_cause = hospital is missing, not 0 bpm. It does not train adaptive center_7 (w_raw = 0) and does not enter the trial contrast.
A decoder_version change on day 10 after t0 sets provenance_break = 1. A 3 bpm step that day is not a physiological change since intervention.


6. Sources

Cadence — 14-day honesty before an established usual on the longer copy; keep RMSSD and SDNN in separate series. Four 7-day points may show; they do not make alert_eligible.
https://github.com/rajanshxrma/cadence

Vela — median + MAD on the longer copy; ln(HRV) z; missing stays missing; as-of cutoff
https://github.com/SunWeizhou/Vela

Pulse — on-device personal band per metric (including SpO₂ and temperature in that app; we still use WHOOP 30-minute % and MAD, not their 30-day SD)
https://github.com/Luraxx/pulse

NightSignal — overnight / still-gated heart rate; longer usual = median of nightly averages. Successive-night counts are stored as persistence fields on this snapshot; they are not alerts yet.
https://github.com/StanfordBioinformatics/wearable-infection

HRV-Foundation-Forecasting — EWMA as a classical short-horizon tracker (used for the 7-day center, not as a foundation-model residual)
https://github.com/Luukas-P/HRV-Foundation-Forecasting

Gadaleta et al., npj Digital Medicine, 2021 — last 7 days left out of the longer usual (those 7 days are the primary EWMA instead)
https://www.nature.com/articles/s41746-021-00533-1

Alavi et al., Nature Medicine, 2022 — rest-gated overnight HR median
https://doi.org/10.1038/s41591-021-01593-2

Mason et al. (TemPredict), Scientific Reports, 2022 — person-specific nightly range
https://doi.org/10.1038/s41598-022-07314-0

Mishra, Li et al., Nature Biomedical Engineering, 2020 — resting HR versus personal baseline
https://doi.org/10.1038/s41551-020-00640-6

Leys et al., 2013 — median and MAD instead of mean and standard deviation (longer copy)
https://doi.org/10.1016/j.jesp.2013.03.013

NIST — 1.4826 scale on MAD
https://itl.nist.gov/div898/handbook/eda/section3/eda35h.htm

Plews et al., Sports Medicine — ln(RMSSD)
https://doi.org/10.1007/s40279-013-0071-8

Oura HRV Balance — short recent window versus a long window
https://ouraring.com/blog/hrv-balance/

Open Wearables — sleep-window filter for variability (not 7-day CV, not SDNN fallback)
https://github.com/the-momentum/open-wearables

Also reviewed, not used for this snapshot: River, Darts, AnomalyDetect, H-Watch, Sensori, OxWearables. Daily steps and active minutes come from the WHOOP step/activity stream on the companion device, not Sensori.

https://github.com/online-ml/river
https://github.com/unit8co/darts
https://github.com/gireeshkbogu/AnomalyDetect
https://github.com/ETH-PBL/H-Watch/
https://github.com/OxWearables/Sensori
https://github.com/OxWearables
