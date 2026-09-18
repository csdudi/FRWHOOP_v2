# Personal baseline — change summary (16 Sep 2026)

This is a full account of what was implemented against the eight-item review of the first personal baseline, plus follow-up product changes on the same day. Charge / Recovery on Today was not rewritten. Math stays on-device. Start time is never inferred from heart rate. A gap vs a frozen path is never titled as proof that a drug caused the change.

Where to look in the Mac app: **Baseline** and **Treatment** (NOOP Staging). iPhone uses the **NOOPiOS** scheme; that was not the delivery path for this pass.

---

## 1. Calibrate how often a stable person is still called OFF

**Ask.** Median / MAD is a starting point. We need a false-positive counter per biometric on stable stretches, including (later) real WHOOP, so `k` is not guessed.

**Shipped.** A calibration harness scores only “stable” days (established longer usual, no treatment, no confounders, TRUST ≥ 35, etc.) and counts OFF vs the long path, vs this week, two-of-three, and MDC if frozen. Synthetic tapes exist for RHR ~60, HRV, and respiratory rate. The real-WHOOP row prints as **not run yet**. Starting `k` values stay placeholders until that row is filled. Pulse ±1.65 / Cadence |z| ≥ 1.5 were not adopted.

**Dashboard.** No “FPR %” on Baseline. This is an engine / test artifact.

---

## 2. Each biometric has its own “off usual” rules

**Ask.** HRV naturally wiggles more than respiratory rate. One global `k = 2` and `span = 7` over-flags some series and under-flags others.

**Shipped.** `params(for: series)` — not one global parameter blob. Examples: sleep RHR `k = 2.0`, span 7; HRV `k = 2.6`, span 10; respiratory rate `k = 1.6`; SpO₂ mean `k = 1.5`; steps / active minutes `k = 2.4` and 21 nights to establish. Hatch and IN RANGE / OFF use **that** series’ `k`. Changing a row bumps `param_set` to `v1.review`.

---

## 3. Slow change over weeks vs a short spike

**Ask.** A two-night fever should stay OFF the longer usual. A three-week drift should become the usual, not “stuck abnormal forever.”

**Shipped.** Every scored night: Theil–Sen slow slope on the long window. If the slope is usable, `z`, Student-t downweight, and CUSUM run on **residuals vs the path**, not vs a flat 60. If not usable, keep the flat median. Two ugly nights still do not pull this week’s *training* usual to the fever. Slope is capped at 30 days.

**Dashboard.** When slope is usable: “Longer usual may drift slowly. A short spike is not.”

---

## 4. Replace dashboard CONFIDENCE %

**Ask.** The old percent was data reliability, barely moved, and sounded like “we are sure they are sick.” Split “can this usual judge tonight?” from “how unusual is tonight?”

**Shipped.** Each usual box shows **TRUST** (`usual_trust_pct`: coverage, freshness, quality, effective nights, slope gate, failed freeze ×0.4, confounder ×0.5, tonight’s quality) and, on **this week**, **HOW OFF** (Student-t two-tail of |z|). TRUST &lt; 35 → **NOT ENOUGH NIGHTS**, HOW OFF hidden.

**Follow-up the same day.** HOW OFF on the **longer** box was removed. That percent is “how unusual vs the 60-day / no-treatment path.” It is a real statistic, but on the long card it read like a second diagnosis. TRUST and IN RANGE / OFF stay on the long box.

---

## 5. A freeze is not proof the medication caused the change

**Ask.** Pre-existing recovery, illness, diet, extra meds, device/math changes must not be sold as “the drug did this.”

**Shipped.** Primary gap is vs the **no-treatment path**, not a souvenir 68. Day events: illness, hospitalization, travel, sleep disruption, exercise change, diet change, concomitant medication. A labeled day is ineligible for the response summary (the gap can still be drawn). Provenance breaks after t0 are not scored as physiology. Settling-in cannot declare a response. Disclaimer is always on the trial block.

**Follow-up the same day.** Those events are no longer a permanent chip row at the bottom of Baseline. If last completed night is outside usual, the **next open** shows a sheet with the same list. Saving a reason greys that night on the plots, halves TRUST, and keeps it out of a treatment-response sentence. “Not now” / “Nothing going on” dismisses for that night. After a label, a one-line **Marked for …** with **Change** is the only leftover on the dashboard.

---

## 6. Freeze a *model* of expected physiology without treatment

**Ask.** If they were already trending, compare tonight to that trajectory. Lead with expected, not “non-treatment usual = 68.” Keep comparing every night.

**Shipped.** At t0: freeze **L0** (level) and **G0** (slope). Later nights: `expected_untreated = L0 + G0 × Δt` (30-day cap). Thin pre-start slope → flat model plus “Not enough pre-start trend to project.” After start, this week and **On {name}** still move.

**Dashboard.** Right box: **Expected without treatment**. Three columns: expected | On {name} | Today. Ghost line vs the old flat usual. Summary in units vs the path and MDC (“bigger than sensor noise”), not a causal claim.

---

## 7. Wash-in / washout from what they typed — clocks only

**Ask.** A universal 7-day washout is wrong. Use the form to **label** phases. Typing “14 days” must not change expected or z.

**Shipped.** Start: when they expect it to start working; if they stop, how long until it is out; optional clinic notes (shown, not sent into z). End: last dose (clock starts there if later), washout override, “I already feel it’s out,” “still feeling effects.” Phase machine reads those fields. Same physiology, washout 3 vs 14: phases differ, expected and z stay the same. No PK lookup from a drug name.

---

## 8. Which metrics matter — and what to do when nobody knows

**Ask (review).** Do not scan 15 series after the fact and call whichever moved a “response.” Decide 1–3 primaries before judging.

**Problem in the product.** A patient or caregiver generally **does not know** which biometric will be the most vital. Forcing checkboxes at start either defaults everyone to resting HR, or invites them to wait and pin whichever series jumped — which is fishing. Ranking **after** the start by “who moved the most” is the same fishing problem with a nicer UI.

**Method that shipped (dynamic without fishing).** Dynamic means **which usuals are solid enough to watch**, not **which numbers moved after the drug**.

1. Score every series that has a real column.
2. Rank by **established longer usual**, then **TRUST**, then night count — data quality of the baseline at freeze, not post-start delta.
3. Start form: watch list is **optional**. If left blank, pin the **top three**. They can still tick series they already care about.
4. Open course on Treatment: **Watch list** with pin/unpin (max three). Unpinned series still plot on Baseline as **exploratory** and cannot write the response sentence.
5. The sentence “today vs the no-treatment path” still only fires for a pinned series, on an eligible day, after settling in. We do not average primary z’s into one “it worked” score.

The list **moves** when the tape is thin vs rich (a weak HRV usual loses to a solid RHR usual). It does **not** move because HRV happened to drop on night 12.

**Not doing (on purpose).** No in-app “this drug should raise HRV” lookup. No auto-summary from whichever exploratory series is farthest from expected. Later disease templates (e.g. sleep drug → suggest RHR and HRV) would still be suggestions from a clinic note, confirmed as a watch list, not inferred from who moved.

---

## What was left unchanged on purpose

- Charge / Recovery on Today.
- Two copies of usual, never averaged into one 0–100.
- On-device math; no Node scoring API.
- Missing nights stay missing (never 0 bpm).
- Expected drug direction is not an input to expected-without-treatment or z.
- Full state-space successor to the slow slope is not this pass.
- Real WHOOP `k` table is not faked to close item 1.

---

## Tests and remaining limits

Engine: longitudinal baseline suites including the review pack. App: `BaselineStoreTests` (usuals, freeze, outlier prompt, auto watch list).

Still true: Baseline/Treatment use a **demonstration tape** so usuals can be read without a long live WHOOP history. Rest / active / all-day windows are stand-ins until those columns exist. Android twin of this UI was not this pass. Real-WHOOP FPR (item 1) is harness-only until a tape is run.
