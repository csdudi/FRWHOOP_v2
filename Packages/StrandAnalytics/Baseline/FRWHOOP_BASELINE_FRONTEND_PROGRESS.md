# Baseline + treatment — plan and 12 Sep 2026 update (app)

This is a working summary of **what the Baseline and Treatment screens are for**, **the layout we are aiming at**, and **what landed on 12 Sep 2026**. Math lives in the engine summary ([`FRWHOOP_BASELINE_IMPLEMENTATION_PROGRESS.md`](FRWHOOP_BASELINE_IMPLEMENTATION_PROGRESS.md)). The full visual contract is [`FRWHOOP_BASELINE_FRONTEND.md`](FRWHOOP_BASELINE_FRONTEND.md).

How to open the current slice: scheme **Strand** → **NOOP Staging**. Quit a running copy first. iOS tab 3 is **Baseline**; **Treatment** is under Body (Mac sidebar / iOS More). Charge on Today is unchanged.

---

## Overall plan — what people should get

Two features that ship together:

1. **Baseline** — personal usuals, two graphs, confidence, a tracking calendar. One person, one biometric, one context at a time (example: sleep resting HR). Never mix RHR and HRV on one plot. Never average this week with longer usual.
2. **Treatment marking** — exact start / dose / stop with a **clock time**. That is what turns Baseline into the trial shape (non-treatment usual frozen; on-treatment usual can grow). Start is never inferred from a jump in HR.

Patient and caregiver see the **same** numbers. Captions may shorten. Nothing is caregiver-only. Engine names (`z`, `p_change`) stay in the log; cards use Today, This week’s usual, Longer usual (or Non-treatment / On {name} after a start), Off this week, Confidence, Why missing.

**What you may conclude:** today looks like this week, or like longer usual, or neither. After a marked start: the control did not eat treatment nights; change since start is in bpm/ms, and whether that move is larger than sensor noise. **What you must not conclude:** a diagnosis, that Charge is “the baseline,” or that the medication “worked.” Footer always: not a diagnosis.

### The picture every scored day `T`

Tonight is not in the usual yet.

| On screen | Meaning |
|---|---|
| **Today** | Last completed night |
| **This week’s usual** | Recency-weighted `[T−7, T−1]`. A fever week is held so the hatch must not chase 72. |
| **Longer usual** | Median of older nights `[T−60, T−8]`. Not “the person is well.” |
| After a freeze | **Non-treatment usual** (frozen control) vs **On {name} usual** (live slow copy after start) |

Layout **changes shape**: building (not enough nights, no fake band) → monitoring (two plots) → trial (page **grows**, plots stay) → washing out → ended. After End, Log treatment comes back for a new course.

### Target Monitor (not all of this is drawn yet)

- Header: metric, Today, **two confidence bars** (this week + longer / non-treatment / on {name}).
- **61-slot calendar** — how the tape works (longer → this week → today). Missing is a hole with a reason, never 0 bpm. This is not a meds diary.
- **Two equal plots.** Left: IN RANGE / OFF / BUILDING / WEAK SIGNAL + delta in units. Right: that copy’s usual + confidence. Hatch = usual range. Low confidence must not shout OFF.
- Context strip: Sleep · Rest · Active · All day · Load. Chips switch biometric in place (default sleep RHR). Hide series with no real column.
- Treatment banner on Baseline: Log / End one tap away. Trial block below the plots: change since start, bigger than sensor noise?

Theme: existing `StrandPalette`, uppercase labels, big numbers, no gold. No sample-patient toggle on the tab in Release.

### Target Treatment

One event store shared with Baseline. Start form: name, kind, dose, day, **time**. Later: dose, dose change, interruption, restart, end (with why). Timeline + calendar. Do not duplicate the biometric charts here — link back to Baseline.

**Build order we are following:** shell (tab + destinations) → plots + chips → treatment forms that actually freeze → calendar / verdicts / trial block → live WHOOP nights → Android.

---

## Where the screens stood before today

Already shipped as a vertical slice:

- Shared `BaselineStore` (views do not call EWMA).
- iOS tab 3 = Baseline; Mac Body items Baseline + Treatment; still five iOS tabs.
- Monitor: period pills, metric chips, scored value, two plots (7-day day-nav, 60-day week-nav).
- Treatment: start / dose / end / edit / delete; freeze persisted per series; a new course after one ends.
- Engine freeze and card copy existed; Monitor did not yet show a trial block or confidence.

Limits that were already true: demonstration tape instead of `Repository.days`; rest/active/all-day synthesized from sleep; no Load chips; no 61-slot calendar on Monitor.

---

## What got done today (app)

**Confidence on both ranges.** Each usual’s box shows `CONFIDENCE N%` (green ≥70, muted ≥40, warning below). The 7-day percent is for the scored night. The 60-day percent is for the week on the long chart. That is the first time the UI teaches “how much can I trust this band?”

**Longer usual follows the week stepper.** Stepping weeks rebuilds a new 60-day median for that week — the same idea as the short EWMA updating when you step days. The scored night stays put. This matches the plan that a night waits ~8 days before it can enter the slow copy: looking at last month should not reuse tonight’s median.

**Treatment layout.** Calendar is a **narrow column on the left** (~260pt). Start form and log sit **on the right** (they stack if the window is narrow). The log is tighter and on-theme: Start / Dose / Ended capsules, date · time, hairlines, Edit. Fit with the rest of NARA rather than a raw dump of event fields.

**No caregiver checkbox.** The form no longer asks who entered the event. Logging is one flow. An internal entered-by value is still stored; it is not a UI control.

**Tests:** 20 `BaselineStoreTests` (including confidence and weekly median rebuild).

---

## What the screens look like now

**Baseline** — hero (SCORED NIGHT / DAY / REST / ACTIVE + value), Sleep · All day · Rest · Active pills, chips, 7-day EWMA plot, 60-day median plot, “not a diagnosis.” Green band = that copy’s range. No left-rail IN RANGE/OFF yet. No tracking calendar yet. No trial block yet (freeze still runs in the store).

**Treatment** — month grid + always-visible start (name, kind, dose, day, time). Open course: log dose / end. Full log of past events; tap a row to select that day. Events on device (`UserDefaults`).

**Shell note:** the original IA was Monitor | Treatment as **one** tab with a segment. They ship as **two destinations** so Treatment is obvious. That is a findability choice, not a second event store.

---

## Limits to be aware of

- Plots still read a **demonstration tape**, not live WHOOP nights. Rest / Active / All day are stand-ins (sleep RHR offsets) so those pills can draw — not strap still/moving windows.
- Freeze numbers are not on Baseline yet (need the trial block). Log / End live on Treatment, not a Monitor banner.
- Load / steps chips are off the strip. Android UI not started.
- Release builds should not look like a sample patient; wiring live dailies (and parking demo data in Test Centre) is still required.

---

## What is still open (app), in order

1. **Real tape.** Prefer `Repository.days` when there are enough quality nights; demo / fixtures only in tests and DEBUG Test Centre.
2. **Honest periods.** Hide or mark rest / active / all-day until those windows exist; add Load (steps).
3. **Language and verdicts.** Bind titles to `LBCardCopy` (this week / longer / on {name} / after). Left rails IN RANGE / OFF / BUILDING / WEAK SIGNAL; low confidence → not enough nights, not OFF.
4. **Chrome from the plan.** 61-slot calendar (slots already computed), treatment banner on Baseline, trial block under the plots (non-treatment vs on-treatment, change since start, bigger than sensor noise?). Keep week-pan as history inspection; freeze belongs in the trial block.
5. **Two header confidence bars** in addition to the range-box percents, labeled THIS WEEK and LONGER / NON-TREATMENT / ON {NAME}.
6. **Treatment completeness** without bringing the caregiver checkbox back: indication / notes as needed, interruption / restart, confirm copy about freeze and washout.
7. **Out-of-bounds sheet** only when off usual persists — optional, never a nightly chore.
8. **Nightly persist** so the tab reads snapshots instead of scoring on every appear. Then Android twins.

Charge, Today, Sleep, and Trends stay as they are.
