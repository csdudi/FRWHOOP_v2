# Baseline work — 16 Sep 2026

This is a working note of what changed in Baseline and Treatment, including one design choice that is easy to get wrong: **how to watch biometrics when nobody knows which one “matters.”**

Scheme: **Strand** → **NOOP Staging**. Charge on Today is unchanged.

---

## What the two screens are for

**Baseline** is personal usuals: this week vs a longer path, TRUST (can this usual judge tonight?), IN RANGE / OFF, and — on this week only — HOW OFF. After a logged start, the right box is the **expected path without treatment**, not a souvenir number.

**Treatment** is the clock. Start / dose / end never come from a jump in HR. Phases (Settling in / On treatment / Washing out) use the days the person typed. Those clocks label the course; they do not pull expected physiology or hide a drop.

Nothing here is a diagnosis, and a gap vs the no-treatment path is not proof a drug caused the change.

---

## What landed today (in order)

**Review of the first personal baseline (eight equal items).** Per-series rules (`k`, span, floors). Slow Theil–Sen path vs a two-night spike. TRUST + HOW OFF instead of a dashboard CONFIDENCE %. Freeze L0/G0 as expected-without-treatment. Confounders including diet; ineligible days; non-causal disclaimer. Patient-entered wash-in / washout. Stable FPR harness with an empty real-WHOOP row.

**Outlier nights.** The chip row at the bottom of Baseline is gone. If last completed night sits outside usual, the next open shows a sheet (illness, hospital, travel, sleep, exercise, extra med, diet). A saved reason greys that night on the plots, halves TRUST, and keeps it out of a treatment-response sentence.

**HOW OFF on the longer usual is hidden.** That percent was “how unusual is tonight vs the 60-day / no-treatment path.” It is a real statistic, but on the long box it read like a second diagnosis. TRUST and IN RANGE / OFF stay there. This week can still show HOW OFF.

**Watch list instead of “pick the vital biometric.”** See the next section.

---

## How to watch series when the person does not know which biometric is vital

### The trap

A fixed “primary series (1–3)” checkbox at start sounds like good science: decide endpoints before you look. In clinic it fails. A patient or caregiver starting a blood-pressure pill or an SSRI usually **does not know** whether sleep RHR, HRV, or respiratory rate is the one that will move. Forcing a pick either (a) defaults everyone to resting HR, or (b) invites them to wait, then pin whichever series jumped — which is fishing, and will almost always find *something* among 12 signals.

Ranking **after** the start by “who moved the most” is the same fishing problem with a nicer UI.

### The method that is actually dynamic

Dynamic here means **which usuals are solid enough to watch**, not **which numbers moved after the drug**.

At start (or on the open course):

1. Score every series that has a real column.
2. Rank by **established longer usual**, then **TRUST**, then night count. That is data quality of the baseline, using nights **at the freeze**, not post-start delta.
3. If they left the form blank, **pin the top three** as the watch list. They can pin/unpin on Treatment (still max three).
4. Unpinned series still plot on Baseline with TRUST / IN RANGE; they are **exploratory** and cannot write the response sentence.
5. The sentence “today vs the no-treatment path” still only fires for a pinned series, on an eligible day, after settling in.

So the list **moves** when the tape is thin vs rich (HRV with a weak usual loses to RHR with a solid one). It does **not** move because HRV happened to drop on night 12.

### What we are not doing (on purpose)

- No in-app “this drug should raise HRV” lookup.
- No auto-summary from whichever exploratory series is farthest from expected.
- No single 0–100 “it worked” score averaged across primaries.

If a later pass wants disease templates (e.g. “sleep drug → watch RHR and HRV”), those are **suggestions from the clinic note**, still confirmed as a watch list, still not inferred from who moved.

---

## What to look at in the app

- Baseline: outlier sheet on a wild last night; longer box has no HOW OFF %; grey points after a labeled event.
- Treatment: start does not require checkboxes. After start, **Watch list** ranked by TRUST / established. Pin up to three.

Demonstration nights are still the tape on these tabs so usuals can be read without a long live WHOOP history.
