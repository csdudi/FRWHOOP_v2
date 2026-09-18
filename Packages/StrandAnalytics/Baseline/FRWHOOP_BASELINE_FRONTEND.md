# Baseline + treatment — frontend outline (NARA)

This is the **frontend plan** for two features that ship together in phase C:

1. A **Baseline** tab (personal usuals, graphs, confidence, tracking calendar).
2. **Treatment marking** (exact start / dose / stop, which turns the Baseline screens into the trial shape).

It is not the math spec. Math and API: `FRWHOOP_BASELINE_CONDENSED_PLAN.md`, `FRWHOOP_BASELINE_IMPLEMENTATION.md`. Plain-language card names: `FRWHOOP_BASELINE_ONE_CALCULATION.md`.

**How to draw the main Baseline, and what you may conclude from it:** [How we display a baseline](#how-we-display-a-baseline-the-main-view). Do not build these screens until backend phases A and B are green.

Charge on Today stays the existing 0–100. This work does not replace it.

---

## Why we said “when-well,” and what people should see instead

**When-well** was an engineering nickname for the *slower* copy: nights in `[T−60, T−8]`, so **this week cannot vote**. The idea was “what was usual before this rough week,” not “the person is medically well.” It is easy to hear as a diagnosis. Do **not** put “when-well” on the cards.

| Situation | What that copy actually is | Label on screen |
|---|---|---|
| No treatment marked | Slow usual from earlier nights (this week excluded) | **Longer usual** |
| Treatment marked; frozen copy (does **not** take on-treatment nights) | Control from before the start clock | **Non-treatment usual** |
| Treatment marked; live slow copy (new epoch, only nights after start) | Slow usual *during* this treatment | **On-treatment usual** (use the treatment’s short name: “On lisinopril usual”) |

This week’s usual always stays **This week’s usual** (last 7 training nights). Off-lines follow the same words: **Off this week**, **Off longer usual**, or **Off non-treatment usual**.

The freeze is exactly “the baseline is not recording treatment nights into the control.” That copy is **Non-treatment usual**, named after the treatment the form saved (see entry form below).

Engine fields can still say `center_long` / `z_long` in tests. Card titles follow the table above and **change when a treatment starts**.

---

## What we already promised the UI (from today)

- Patient and caregiver see the **same** metrics. Captions may shorten; nothing is caregiver-only.
- Engine names (`z_long`, `p_change`, …) stay in the log. Cards use **Today**, **This week’s usual**, **Longer usual** (or **Non-treatment usual** / **On-treatment usual** after a start), **Off this week**, **Confidence**, **Why missing**, and the trial names below.
- **Confidence this week** and **Confidence (longer / non-treatment / on-treatment)** are always on the series card (two bars, not Charge).
- A **61-slot tracking calendar** shows how the tape works (longer usual → this week → today). Missing is a hole with a reason, never 0 bpm.
- Two graphs **equal weight**: this week and the slow copy. Left rail = IN RANGE / OFF / BUILDING. Right rail = that copy’s usual + confidence. Hatch band = usual range (`TypicalRangeBar` language). Slow-copy **title is dynamic** (Longer vs Non-treatment vs On-treatment).
- Layout **changes shape**: building → monitoring → trial → washing out → ended. Trial grows the page; it does not shrink the two plots. After End, the trial block collapses; **Log treatment** comes back for a new course.
- **Log treatment** and **End treatment** are one tap from Baseline (toolbar, banner, Treatment sticky footer). End is not under “…”.
- Theme: `StrandPalette`, UPPERCASE labels, big white numbers, no gold, green / amber / red status.
- **No sample-patient or testing mode** on these screens. Fixtures only in unit tests, DEBUG previews, and Test Centre (`#if DEBUG`).

---

## How we display a baseline (the main view)

This is the **method** for the main Baseline UI. Screen 1 / Screen 2 below are layout. This section is what those screens are *for*, and what a person is allowed to conclude from them.

One card = **one person, one biometric, one context** (example: sleep resting HR). Never mix RHR and HRV on one plot. Never average this week with longer usual. Charge is not on this tab.

### The picture we draw every scored day `T`

`T` is the last completed civil day. Tonight is not in the usual yet.

```
oldest                                                                 newest
|← longer usual (up to 53 nights, this week excluded) →|← this week (7) →|T|
T−60                                               T−8  T−7         T−1  T
                                                   gap     trains           scored, not folded in
```

| Band on screen | What it is | What it is not |
|---|---|---|
| **Today** (big number, larger plot dot **after** the 7-day window) | Last completed night’s value | Not yet part of either usual |
| **This week’s usual** (row 1 hatch) | Recency-weighted usual of `[T−7, T−1]` | Not “the truth”; a fever week is downweighted so the hatch must not sprint to 72 |
| **Longer usual** (row 2 hatch, no treatment) | Median of older nights `[T−60, T−8]` | Not a medical “when well”; not this week |
| **On {name} usual** (row 2 after a start) | Same slow math, **only nights after start** (once they are old enough) | Not the control |
| **Non-treatment usual** (trial block + optional tertiary hatch) | Frozen slow usual from **before** the start clock | Must not record on-treatment nights |

**Display recipe (series detail — this is the main Baseline):**

1. Header: metric UPPERCASE, **Today** + unit, two confidence bars (**THIS WEEK** and **LONGER** / **NON-TREATMENT** / **ON {NAME}**).
2. 61-slot calendar: tape, not a meds diary. Hole = missing, never 0.
3. Two plots, **equal size**. Left rail = IN RANGE / OFF / BUILDING / WEAK SIGNAL + which copy + delta in units. Right rail = that copy’s usual number + small confidence. Hatch = `center ± 2 × spread`.
4. Footer: “Not a diagnosis.”
5. If a treatment froze: page **grows** with Non-treatment usual vs On-treatment usual, Change since start in units, Bigger than sensor noise? The two plots do not shrink.

**Monitor list** is the same facts in miniature: Today, two verdict dots (this week / slow copy). Groups: sleep, then awake rest / active / all-day / load. Default **sleep resting HR**. Switching series must not rebuild the tab — see [Less clutter, easy biometric switching](#less-clutter-easy-biometric-switching).

### How a verdict is chosen (simple, same for patient and caregiver)

Use native units and the band. Do **not** show `z` on the card.

| Left rail | When | What the person should read |
|---|---|---|
| **BUILDING** | Not enough nights to show that copy (`n_7 < 4` or long not showable) | No usual yet. Wear the strap. No hatch. |
| **WEAK SIGNAL** | Stale, or confidence too low to shout | Do not treat last week’s green as live. |
| **IN RANGE** | Today inside that copy’s hatch, and confidence high enough | Today looks like **that** usual. |
| **OFF** | Today outside the hatch, confidence high enough | Today does **not** look like **that** usual. Delta in units (“+12 bpm”). If 2+ nights in a row on the slow row, say so. |
| **Not enough nights** (demoted OFF) | Would be OFF but confidence is low | Show the chart; do not alarm. |

IN RANGE on this week and OFF longer usual at the same time is allowed. That is the point of two copies: this week may have moved; the slower usual has not.

### Simple analysis we can conclude (and must not)

These are the only conclusions the UI should teach. Same sentences for patient and caregiver.

**No treatment marked**

| What you see | You may conclude | You must not conclude |
|---|---|---|
| Both rails **IN RANGE**, confidence decent | Today is like this week **and** like longer usual | That they are “healthy” or that Charge is fine |
| OFF this week, **IN RANGE** longer usual | This week’s usual does not match today; today still looks like the slower usual (classic: a rough week that must not become the new normal) | That they are ill; that this week’s hatch should sprint to today |
| **IN RANGE** this week, **OFF** longer usual | This week has settled near today; today is still unlike the slower usual | That the slower usual “should” update (it must not this week) |
| Both **OFF**, 2+ nights in a row on the slow copy | Today is persistently unlike longer usual. Optional out-of-bounds sheet: something else going on? | A disease name, an alert page, or that they must label every night |
| BUILDING | Not enough quality nights | Inventing a band or a 0 bpm |
| Calendar hole | Missing; tap Why missing (usually automatic `unknown`) | Filling 0; asking the caregiver to code the hole |
| This week hatch stays near 60 while the week looks like 72s | Usual is **held**; faint raw line (optional) is “how the week looked” | Relabeling 72 as this week’s usual |
| Steps OFF, sleep RHR IN RANGE | Activity load is unlike its own usual; rest is not | A global “activity mode” that restyles RHR |

**Treatment marked (freeze OK)**

| What you see | You may conclude | You must not conclude |
|---|---|---|
| Non-treatment usual still ~68, On lisinopril usual moving toward 61, today 61 | Control did not eat treatment nights. Live slow usual is learning the on-treatment period | That 61 is “the old usual” |
| **Change since start** large, Bigger than sensor noise? **yes**, no device/math banner | Physiology vs the **frozen path** (including pre-start slope) moved more than test-retest noise | That the drug caused it; that it is good or bad |
| Same change, Bigger than sensor noise? **no** | The move is small compared with measurement scatter | A treatment effect |
| Device or math changed | The step may be a device/firmware/definition change | Painting Change since start as physiology |
| One series froze, SpO₂ says not enough nights | Only the series that qualified has a control | Inventing a SpO₂ control |
| Settling in / On treatment / Washing out | Clock labels from the form; wash-in is 7 days, not instant | Instant effect at the first pill |
| After End: **After {name} usual** | Live slow copy is post-course; freeze stays in history | Mixing those nights back into Non-treatment usual |

**Worked reads (what the first screenshots should teach)**

1. **Quiet RHR ~60, both IN RANGE.** “Today looks like usual this week and longer usual.”
2. **Fever week, hold.** Today 72, longer usual ~60 OFF, this week’s hatch still near 60 (held) maybe IN RANGE or less off than a chasing EWMA. Caption: this week is not allowed to become the fever. Not an alert by itself.
3. **Building.** Calendar mostly empty, BUILDING, no hatch. “Wear the strap overnight.”
4. **Lisinopril freeze 68 → today 61.** Two plots still compare today to **this week** and **on lisinopril usual**. Trial block: Non-treatment usual 68, Change since start in bpm, Bigger than sensor noise? That is “moved vs the frozen path,” not “the pill worked.”
5. **Hospital / missing.** Empty slot, no 0, no Change since start that day. No out-of-bounds sheet (no today value).
6. **Off longer usual 2 of 3 nights.** Optional sheet: travel / illness / hospital / exercise? Dismiss is allowed. Scoring already happened.

Every conclusion is **this series only**. A rough RHR week with normal steps is two cards, not one story.

---

## Less clutter, easy biometric switching

The main Baseline is **one series at a time**. Clutter comes from repeating the tape, stacking 17 dashboard rows, and making people pop in and out of a list to compare RHR vs HRV. Switching series should feel like changing a filter, not opening a new app.

### What stays on screen (chrome, once)

Pin this at the top of the Baseline tab. It does **not** change when the biometric changes:

| Chrome | Why it is shared |
|---|---|
| Date `‹ DAY ›` | One scored day `T` for every series |
| Treatment banner (or Log treatment) | One course, not per metric |
| **61-slot calendar** | Same civil-day tape; only the fill (value vs hole) is series-specific |
| Context + metric switcher | How you move between biometrics |

Do **not** draw a second calendar on series detail. Do not put Log/End on both the banner and a second toolbar on the same scroll view.

### How you switch series (two taps max)

**1. Context strip (always visible on Monitor).** Five choices, one selected:

`SLEEP` · `REST` · `ACTIVE` · `ALL DAY` · `LOAD`

Short captions in `textTertiary` if needed: sleep night / still / moving / 24h / steps. This stops sleep RHR and awake-rest HR from looking like the same row.

**2. Metric chips inside that context** (only wired series, hide stubs):

| Context | Chips (when a column exists) |
|---|---|
| Sleep | RHR, HRV, Temp, Resp, SpO₂, Nadir |
| Rest | HR, HRV, SpO₂ |
| Active | HR, HRV, SpO₂ |
| All day | HR, HRV, SpO₂ |
| Load | Steps, Active min |

Selected chip is accent. One tap replaces **Today, dots, two plots, trial extras** for that series. Date, calendar, and treatment banner stay.

**3. Optional: horizontal pager inside the context.** Swipe from sleep RHR to HRV to temp. Swiping must **not** fight the calendar (calendar owns drags that start on the strip; pager owns the plot card). Context strip is not a swipe-through of all 17.

**Back** from a pushed detail (if we keep a push at all) returns to the same context + chip, not to Today. Prefer **no push**: Monitor *is* the plots for the selected chip, with a compact chip row instead of a 17-row dashboard. The old “list then detail” is the fallback for very small phones if the plot card cannot fit; even then the chip row stays on detail so you do not climb the stack to change metric.

### What we cut from the first screen

- No 17 equal My-Dashboard rows before you see a graph. At most a **one-line** strip of the other contexts’ OFF dots (optional later), not a second list.
- Trial block stays **below** the two plots and can start **collapsed** to one line: `{name} · Change since start +12 bpm · noise yes/no`. Expand for Non-treatment vs On-treatment numbers. Switching series keeps collapsed/expanded state? **No** — collapse by default each series so HRV does not inherit a huge RHR trial panel.
- Confidence: two thin bars in the series header only. Do not repeat them on both rails and the list.
- Engine fields (`z`, σ_bio, r1, missingness counts) stay in the `›` sheet, not on the switcher.

### Why this is easier to go back and forth

- Same `T` and same freeze/treatment while you flip RHR → HRV → steps (steps may still be Building; that is honest, not a navigation error).
- Sleep vs load is a context tap, not a long scroll.
- Caregiver and patient use the same switcher; nothing extra on one side.
- Deep link “Baseline › sleep HRV” sets context Sleep + chip HRV; calendar still on `T`.

```
Baseline tab
├── Chrome: date, treatment, calendar, context strip
└── Selected series (default sleep RHR)
    ├── Metric chips for that context
    ├── Today + two confidence bars
    ├── Two equal plots
    └── Trial one-liner (expand if freeze OK)
```

---

## How this sits in the current app

NARA is already a tab + More shell. Screens live in `Strand/Screens/` and are reused on iOS (`StrandiOS/App/RootTabView.swift`). macOS uses the sidebar (`Strand/App/RootView.swift` `NavItem`). Android twins the same destinations.

**iOS tab bar today (5 slots):** Today · Trends · Sleep · **Meds** · More.

`MedicationsView` is that Meds tab. It is a session-only dose list (“nothing is persisted yet”) plus a vital-response sketch from `Repository` dailies. It must **not** remain a second, throwaway treatment UI beside Baseline.

**Seamless rule:** one event store, two surfaces.

| Surface | Job |
|---|---|
| **Baseline tab** | Read `lb_v1_*` snapshots. Graphs, calendar, confidence, IN RANGE / OFF. When a qualifying start exists, the trial block appears. |
| **Treatment marking** | Write start / dose_change / interruption / restart / stop with **clock timestamps**. This is what flips Baseline into trial shape. Daily “I took the 8am pill” can stay here as a child of the same events. |

**Tab bar recommendation (keep 5 tabs):**

Today · Trends · Sleep · **Baseline** · More

- Tab 3 **becomes Baseline** (main feature). Icon: something already in the set (e.g. `waveform.path.ecg` is Live; prefer a chart-in-range glyph such as `chart.xyaxis.line` / Android equivalent). Do not add a sixth tab.
- **Meds** moves under Baseline as the **Treatment** screen (toolbar or a second top-level segment on the tab: Monitor | Treatment). Also keep a More row “Treatment” so it is findable.
- macOS: new `NavItem.baseline` in the Body sidebar group, next to Health. `NavItem` for Meds, if any, points at the same Treatment screen.
- Android: same five destinations; same Monitor | Treatment split.

Today, Trends, Sleep, Health, Insights, Charge rings: **unchanged**, except optional tiny dual dots on Health/Dashboard rows later (not required for v1 of this tab).

`tabPaths` is currently `count: 5`. Replacing Meds with Baseline keeps that count. If both Monitor and Treatment are **one tab** with an in-tab segment, do not add a sixth `NavigationPath`.

---

## Information architecture

```
Baseline tab
├── Chrome (shared, does not reset on series change)
│   ├── Date stepper, treatment banner / Log
│   ├── Tracking calendar (61 slots, fill follows selected series)
│   └── Context strip: Sleep | Rest | Active | All day | Load
└── Selected series (default Sleep · RHR)
    ├── Metric chips for that context
    ├── Today + two confidence bars + two equal plots
    └── Trial one-liner (expand if freeze OK)
Treatment (in-tab segment, not a sixth tab)
    ├── Timeline
    └── Mark event / start / end forms
```

Date stepper on Monitor matches Today (`‹ DAY ›`), default = last completed civil day `T`. Horizontal swipe on this tab must not fight the calendar strip (same pattern as Today vs HR chart: the strip owns drags that start on it).

Deep links: Health row “Baseline ›”, Treatment “Log treatment ›” / “End treatment ›”, More → Baseline / Treatment.

**The log form must be obvious.** It is not only inside a buried sheet. See “Where to find Log treatment and End treatment.”

---

## Screen 1 — Monitor (list + selected series)

`ScreenScaffold` title **Baseline**, subtitle one line: “Your usual this week, and your longer usual.”

If a treatment is active, subtitle becomes: **“{Treatment name} · {phase}”** (example: “Lisinopril 10 mg · On treatment”).

**Do not make Monitor a 17-row dashboard.** Chrome (date, treatment, calendar, context strip) is once. The body is the **selected series** (plots). Metric chips switch series in place. See [Less clutter, easy biometric switching](#less-clutter-easy-biometric-switching).

1. **Tracking calendar** (once, in chrome). Oldest left, Today right. Caption with no treatment: “Today is scored against this week and against longer usual. It is not folded in yet.” With a treatment: “Non-treatment usual is frozen. Nights after {start} do not change it.” Tap slot → value or Why missing for the **selected** series.
2. **Context strip + metric chips.** Default Sleep / RHR. Today value and two verdict dots live in the series header, not in a long list.
3. Hide series with no daily column (stubs). Order inside a context: RHR/HR, HRV, temp, resp, SpO₂, then extras.
4. Empty / building: still show calendar + “Wear the strap overnight. Usuals appear after a few quality nights.” No fake bands.

If a qualifying trial is active, a slim banner at the top uses **the treatment’s display name** (not a generic “trial”): **Lisinopril 10 mg · On treatment · started 12 Mar 7:00**. Trailing actions on that banner: **Log** (dose) and **End**. The whole banner also taps through to Treatment.

When there is **no** treatment, Monitor’s trailing toolbar is a persistent accent button **Log treatment** (same weight as Today’s primary actions). Do not hide start behind More-only.

---

## Screen 2 — Series detail (the graphs)

One biometric per page. Chrome: `surfaceRaised` card, `StrandPalette`, no gold.

**Header:** metric name UPPERCASE, **Today** in units, two confidence bars labeled **THIS WEEK** and either **LONGER**, **NON-TREATMENT**, or **ON {SHORT NAME}** depending on mode. Low confidence → verdict says **Not enough nights**, not OFF. Metric chips for the current context sit under this header (same as Monitor) so changing biometric does not require Back.

**Calendar is not repeated here** if Monitor already shows it in chrome. If detail is a push on a small phone, keep **one** calendar in the shared chrome, not a second strip.

**Two plots, equal height and weight** (implementation doc Phase C). Row 2’s titles **swap** when a treatment is marked:

| | Left rail | Center | Right rail |
|---|---|---|---|
| Row 1 | IN RANGE / OFF / BUILDING **this week** + delta in units | 7-day dots + hatch band | This week’s usual + % |
| Row 2 (no treatment) | IN RANGE / OFF **longer usual** + delta | Slow plot, this week excluded | Longer usual + % |
| Row 2 (treatment on) | IN RANGE / OFF **on {name}** + delta vs live on-treatment usual | Slow plot, **post-start nights only** | On-treatment usual + % |

Hatch = that copy’s `center ± 2 × spread`. Gaps for missing/low quality. Today is a larger dot **after** the training window. No `z` on axes. Footer `textTertiary`: “Not a diagnosis.”

**Trial block** (only if freeze OK): page **grows** below the two plots. Non-treatment usual is the copy that **does not record** on-treatment nights.

- Banner repeats **{Treatment name} · {dose} · {phase}** with **End treatment** on the trailing edge while the trial is active (hidden once a stop is already logged).
- Equal columns: **Non-treatment usual** | **On-treatment usual** (or Building).
- Change since start + Bigger than sensor noise?
- Device or math changed banner if set (do not paint Change since start as physiology).
- Other things going on as grey chips **only after** an optional out-of-bounds answer (or a one-off log). Do not show an empty “label this night” row every day.

**Out of bounds (in-app, not a push).** When `alert_eligible` and Days in a row off agree (`two_of_three`) and today is still OFF longer usual (or Change since start is above MDC), show a sheet using `contextPrompt.headline` / `body`: optional chips for travel, illness, hospital, exercise change. Dismiss is allowed. Patient and caregiver see the same sheet. A missing night does **not** open this sheet.

Detail sheet (`›` on the right rail): Has usual changed?, Week vs longer / non-treatment usual, Why this reading is weak.

---

## Where to find Log treatment and End treatment

Patient and caregiver use the same places. Prefer **one tap from Baseline**, not a hunt through Settings.

| Place | No treatment | Treatment active | After End (washing out / ended) |
|---|---|---|---|
| Tab **Monitor \| Treatment** | Always visible on the Baseline tab | Same | Same |
| Monitor toolbar | Accent **Log treatment** | **Log** (dose) + **End** | **Log treatment** for a *new* course; ended name in history |
| Monitor banner | — | Name · phase · **Log** · **End** | **Washing out** or **Ended {name}** · date; End is gone |
| Series detail | Same toolbar as Monitor | Same **End** on the trial block | Compact ended chip |
| Treatment screen (empty) | Full-width **Log treatment** + short why | Timeline; sticky footer **Log dose** and **End treatment** | **Start another treatment** |
| More list | Row **Treatment** → same screen | Same | Same |
| Today | No second meds UI. Optional later: one line “On lisinopril ›” into Baseline. Not required for v1. | | |

**End is as easy as start.** Do not nest End under “…” or “More actions.” Sticky footer on Treatment: left **Log dose**, right **End treatment** (`statusWarning` text, not a destructive red trap). Confirm sheet, then done.

### End treatment form (seamless stop)

Same chrome as the start form. Opens from every **End** listed above.

| Field | Required | Notes |
|---|---|---|
| Entered by | yes | Patient / caregiver (optional name) |
| End date | yes | Device calendar |
| End time | yes | Clock time; default now; never inferred from HR |
| Why it ended | yes | Completed course / doctor stopped / side effects / missed supply / other |
| Last dose (if known) | no | Amount + time |
| Notes | no | |

Confirm copy: “We will mark {display name} as ended at this time. Non-treatment usual stays frozen. The next week is **Washing out** — effect is not assumed to stop instantly.”

After save: phase → Washing out; **End** controls hide (already ended); banner shows ended time; Monitor stays on the same tab (no bounce to More). A **Restart** action remains on the timeline if they begin again without a new trial id (backend: restart keeps the original freeze). **Start another treatment** opens a new trial id and a fresh start form.

---

## Screen 3 — Treatment marking and start form

This **replaces** the throwaway `MedicationsView` persistence gap. It does not infer start from HR. Patient and caregiver use the **same form**; a field records who entered it.

### Start form — basic information (required vs optional)

Primary action: **Mark treatment start** (accent). Confirm copy: “Non-treatment usual will freeze from days **before** this time. Nights after this time do not change it.”

| Field | Required | Notes |
|---|---|---|
| Entered by | yes | Patient / caregiver (and optional name of the person entering) |
| Treatment name | yes | What shows on every Baseline banner (“Lisinopril”, “IV iron”, …) |
| Kind | yes | Medication / supplement / procedure / other |
| Reason / indication | yes | Why this was started, in plain language |
| Start date | yes | Civil day on the device calendar |
| Start time | yes | Clock time; default now; never inferred from HR |
| Dose | if medication | Amount + unit (10 mg, 500 mg, …) |
| Route | if medication | Oral, injection, IV, other |
| How often | if medication | Once daily, twice daily, weekly, as needed, other |
| Prescriber / clinic | no | Free text |
| Notes | no | Anything else both people should see |

Saving creates `trial_id`, display name `{name}` plus dose when present (“Lisinopril 10 mg”), and runs qualify-before-freeze per series. If a series fails, show **Not enough nights to freeze non-treatment usual** for that series only.

### Later events (same treatment name in the header)

Timeline, newest last. Header always **{display name} · {phase}**. Sticky footer while active: **Log dose** | **End treatment**. Other timeline actions: Dose change, Interruption, Restart. Each has date+time. Dose change relabels phase only; it does not reset non-treatment usual.

**Other things going on** / hospital / **activity or exercise change**: **not a nightly caregiver task.** Strap holes label themselves (`none` / `unknown` / weak signal). Human chips are **optional** and appear only on the Baseline **out-of-bounds** prompt (`contextPrompt.shouldAsk`) when Off longer usual (or Change since start) **persists** (alert-eligible + 2 of 3). The prompt is never required to score. If they already logged a reason that day, do not ask again. Do not infer from steps or HR.

Do not duplicate series charts on this screen. Link “See sleep RHR on Baseline ›”.

---

## How the UI stays dynamic

The same Monitor screen **reflows**. There is no “testing layout” and no second app. Shape comes from snapshots + the active treatment record.

### Activity and coverage (every day)

| What changed | What the UI does |
|---|---|
| High or low steps / active minutes vs longer usual | That series card: IN RANGE vs OFF on **this week** and **longer usual**, same rails as RHR. Other series do not steal this. |
| Flag **exercise / activity change** (Other things going on) | Grey chip **if they answered the out-of-bounds prompt** (or logged it once). Not a daily form. Primary Change since start still skips that day. |
| Charging, strap off, poor signal | Calendar hole; Why missing **automatic**; confidence bars drop; verdict **WEAK SIGNAL** / **Not enough nights**, not a fake 0. Do not ask the caregiver to code the hole. |
| Travel, illness, hospital | Same optional chip, offered on the **out-of-bounds** sheet when Off persists — not inferred from HR. Hospital is missing + reason, not 0 bpm. |
| A rough week of RHR while steps look normal | RHR may be OFF longer usual while steps stay IN RANGE. Cards stay separate. |
| Confidence this week falls (only 4 nights) | This-week bar amber; do not shout OFF. |

Steps and active minutes are **waking_load** series. They use the same two-plot card. “Adjustment” means the usual and the hatch **move with that series’ own nights**, not a global “activity mode” that restyles RHR.

### When a treatment starts (same tab, new labels)

| Moment | What changes |
|---|---|
| Form saved | Banner: **{Lisinopril 10 mg} · Settling in · started {date time}**. **Log** and **End** appear. Treatment timeline fills. |
| First evaluate after t0 | Slow-copy titles become **On lisinopril usual**. Frozen number labeled **Non-treatment usual**. Calendar tick at start. Second hatch (tertiary) = frozen control on the slow plot. |
| Settling in → On treatment → Washing out | Phase word on banner, Treatment header, and trial block updates. Plots stay; they do not reset. |
| Dose change | Banner dose text updates (“Lisinopril 20 mg”). Phase may return to Settling in. Non-treatment usual **unchanged**. |
| **End treatment** saved | Phase **Washing out**. Banner: **{name} · Washing out · ended {date time}**. **End** hides. Non-treatment usual still frozen. Patient stays on Baseline. |
| Washout clock finished | Trial block **collapses** to a compact **Ended {name}** chip (opens history). Live slow copy labeled **After {name} usual** (not an active treatment, not mixed back into non-treatment). **Log treatment** returns for a new course. |
| Interruption (not a full end) | Phase washing out / paused chip; **Resume** / Restart without a new trial id; freeze kept. |
| New trial id | New display name; previous freeze stays in history, not on the live banner. |

List, detail, and Treatment **all show the same display name**. If the caregiver entered the form, a quiet `textTertiary` line: “Entered by caregiver.”

```mermaid
flowchart LR
  none[No treatment: Longer usual]
  start[Log treatment]
  live[On-treatment + Non-treatment]
  end[End treatment: Washing out]
  after[After name usual + history]
  none --> start --> live --> end --> after
```

### Dynamic changes required by the baseline math (do these in the UI)

These are not extra “modes.” They are how Monitor must follow `evaluate` or the freeze will look wrong.

| Baseline fact | Frontend must do |
|---|---|
| `T` is not in either training window | Today’s dot sits **after** the 7-day plot (last train night is T−1). Do not draw today inside the hatch as if it already voted. |
| This week is only 7 slots; longer is 53 | Two plots stay equal *size*; they must **not** share an x-axis of 61 days or the week plot looks empty. |
| A night waits ~8 days before it can enter the slow copy | Calendar caption / tooltip: “In this week” vs “Aging into longer usual” vs “In longer usual.” |
| Student-t **hold**: fever week does not become this week’s usual | 7-day hatch stays near the held center. Optional faint line for `center_7_raw` (this week’s look) so Week vs longer usual is visible without walking the band up to 72. |
| `n_7 < 4` or long `n < 4` | **BUILDING**; no fake hatch; confidence tertiary. |
| Motion needs 21 nights to establish; rest 14 | Steps / active minutes stay Building longer. Do not copy RHR’s established badge onto steps. |
| Some series freeze, some fail qualify | Per-card: RHR may show Non-treatment usual while SpO₂ says **Not enough nights to freeze**. Never invent a control. |
| `quality_status` missing / low_quality | Gap or hatch on the plot; calendar empty/warning; never a zero point. |
| `confidence_pct_*` | Always two bars; low % demotes OFF to **Not enough nights**. |
| `regime_shift` / Has usual changed? | Detail + optional caption on the slow plot; do not relabel Non-treatment usual. |
| `provenance_break` | Critical banner; Change since start not painted as physiology. |
| Confounder **exercise / activity change** | Chip; that day excluded from primary Change since start. Steps series still plots the day. |
| Stale (>14 days no quality night) | Both confidences 0; **WEAK SIGNAL**; do not keep last week’s IN RANGE as if live. |
| After **End** + washout | Labels leave “On {name}”; freeze remains in history as Non-treatment usual; live slow copy **After {name} usual** until a new start. |
| Date stepper on an incomplete “today” | Score last **completed** civil day. Grey hint: “Tonight is not in the usual yet.” |
| Charge | Not on this tab. No 0–100 mix of Off this week. |

---

## Visual system (match the app)

- Tokens: `StrandPalette.surfaceRaised`, `textPrimary` / `textSecondary` / `textTertiary`, `accent` links, `statusPositive` / `statusWarning` / `statusCritical`, `track` for empty calendar slots.
- Cards: ~16–20px radius, fill only, no extra border.
- Labels UPPERCASE tracked; numbers big, white, tabular, unit suffix smaller.
- Typical range: solid = you, hatch = usual (`TypicalRangeBar`).
- Motion: tab crossfade already ~240ms; segment Monitor | Treatment uses the same curve. Trial block appears as inserted content (layout grow), not a modal “trial mode.”
- Liquid Today sky: optional behind Baseline `ScreenScaffold` via the same `topBackground` helper as other tabs — do not invent a new scene.

---

## Wiring (after A/B, not before)

| Read | Source |
|---|---|
| Series snapshots | `metricSeries` `lb_v1_{series}_*` for scored day `T` |
| Daily dots on plots | `DailyMetric` + quality reasons on observations |
| Calendar slots | same observations for `[T−60, T]` |
| Trial freeze / phase | event store + frozen bundle |

| Write | Destination |
|---|---|
| Treatment events | new local table / store (phase B). `IntelligenceEngine` does not guess them |
| Other things going on | flags on that civil day |

View layer: one observable `BaselineStore` (or repository methods) shared by Monitor and Treatment. Views do not call EWMA math.

SwiftUI views in `Strand/Screens/` (`BaselineMonitorView`, `BaselineSeriesView`, `TreatmentMarkingView`) so macOS sidebar and iOS tab share them. Android twins in `com.noop.ui`.

---

## Frontend build order (phase C only)

1. Shell: rename tab 3 to Baseline; Monitor root + Treatment push; macOS `NavItem`; Android bar. Meds tab content becomes Treatment.
2. List + calendar + confidence bars, reading real snapshots (or empty/building).
3. Series detail: two equal plots + side rails.
4. Treatment start **and end** forms (easy to find); Monitor grows/collapses trial block; washout labels.
5. `#if DEBUG` Test Centre inject fixture — **not** on the Baseline tab.
6. Snapshot tests for building / monitoring / trial. Release build has no fixture toggle.

---

## Phase C notes — display and architecture (before the first UI PR)

These are **suggestions for the upcoming frontend**, not math changes and not code yet. They exist so Monitor shows the right usuals clearly, and so views do not re-implement `evaluate`.

### What this tab is for (do not lose this)

Baseline answers **“how does today compare to this person’s usual?”** on one series at a time. It is not Charge, not a diagnosis, and not a drug-efficacy claim.

People should always be able to see, in words:

| Question | On screen | Engine |
|---|---|---|
| What is tonight/today’s number? | **Today** + unit | `todayNative` |
| What has this week been like? | **This week’s usual**, hatch, IN RANGE / OFF / BUILDING | `copy7`, `z7` hidden |
| What was usual before this week could vote? | **Longer usual** until a treatment starts | `copyLong` |
| After a start: what must not include treatment nights? | **Non-treatment usual** | freeze bundle |
| What is usual *on* this course? | **On {short name} usual** | live long after new epoch |
| Is the reading even usable? | Two **confidence** bars; Why missing; WEAK SIGNAL | `confidencePct_*`, quality |
| If they marked a start: did physiology move vs the frozen path? | **Change since start** in units + Bigger than sensor noise? | `z_trial_traj` / `above_mdc` (no z on the card) |

Patient and caregiver get this **same** list. Captions may shorten. Nothing is caregiver-only.

### Display: make the metrics readable

1. **Bind titles to `LBEvaluation.trial.card` (`LBCardCopy`).** Do not hardcode “when-well,” “Usual before treatment,” or engine keys on rails. The store already emits **This week's usual**, **Longer usual**, **Non-treatment usual**, **On {name} usual**, **After {name} usual**, and matching Off-lines. If a series failed freeze, that card keeps Longer usual plus `qualifyMessage`.

2. **Group the list by context, do not dump 17 equal rows.** Sleep first (RHR, HRV, temp, resp, SpO₂ mean). Then **Awake rest**, **Awake active**, **All day**, **Waking load**. One-line captions: sleep vs still vs moving vs 24h vs steps. Hide stub series until `DailyMetric` has a column. Default push from a list row: **sleep resting HR**.

3. **List rows stay thin.** UPPERCASE name, Today + unit, two verdict dots (this week / slow copy), chevron. Confidence bars and Change since start live on **detail**, not on every list row. A treatment banner on Monitor is enough for the name/phase.

4. **Native units only on cards.** HRV in **ms**, not ln. RHR bpm, temp °C, SpO₂ %, steps, minutes. Deltas signed in those units (“+12 bpm”, “−17 ms”). Never print `z_7`, `z_long`, `p_change`, `α` on rails.

5. **Two plots stay equal; they must not share a 61-day x-axis.** Week plot = 7 training slots + today after the window. Slow plot = 53 gapped slots (or post-start nights only after freeze). Same y-scale. Today is never drawn as if it already trained.

6. **Hatch language stays TypicalRangeBar.** Solid = this person, hatch = that copy’s usual (`center ± 2 × spread`). After freeze: live on-treatment hatch stays the slow plot’s primary hatch; frozen Non-treatment usual is a **second, tertiary** hatch + vertical start tick. Do not replace the live hatch with the freeze or people will think on-treatment usual is the control.

7. **Per-series honesty.** RHR may freeze while SpO₂ shows **Not enough nights to freeze non-treatment usual**. Steps/active minutes stay BUILDING until 21 nights. Low confidence demotes OFF to **Not enough nights**. Stale → WEAK SIGNAL, not last week’s green IN RANGE.

8. **Trial extras are secondary, but must be findable.** On the trial block: two equal numbers (Non-treatment | On-treatment), Change since start in **units**, Bigger than sensor noise? yes/no. Put σ_bio, r1 / n_eff, frozen `center_7` deltas, missingness counts, and `phaseBStatisticLedger` on the **detail sheet / trial log**, not on the two rails. Out-of-bounds sheet uses `contextPrompt` only when `shouldAsk`; dismissible; never a nightly form.

9. **Calendar is the tape, not a meds diary.** 61 slots, oldest left. Caption switches with mode (frozen vs not). Tap = value or automatic Why missing. Aging: “In this week” / “Aging into longer usual” / “In longer usual.” Start day = accent tick. Phase is a chip, not a second calendar.

10. **Charge, Trends, Sleep, Today stay as they are.** Dual dots on Health later are optional. No 0–100 blend of Off this week.

### Architecture: keep math out of the views

1. **`BaselineStore` (Swift) / same repository on Android is the only UI API.** Monitor, series detail, Treatment, and the out-of-bounds sheet read one observable: scored day `T`, `[LBEvaluation]` per visible series, `LBCardCopy`, `contextPrompt`, treatment events, persisted freeze. Views **must not** call `LongitudinalBaseline.evaluate` or EWMA.

2. **Score once per completed civil day in `IntelligenceEngine` (or a dedicated scorer it already owns), not in `onAppear`.** Replay over a 60-day tape × 17 series on the main thread will hitch. Write `lb_v1_*` shadow keys **and** a persisted freeze blob / treatment event table. Late-arriving nights write a **new** snapshot for a new `T`; they do not edit yesterday.

3. **Persist freeze outside `evaluate`.** The engine will re-qualify and freeze if `LBTrialRequest.freeze` is nil. The store must save `LBFreezeBundle` the first time `trialFreezeOk` and pass it back every later day. Dose change, interruption, and restart **must** reuse that blob. A new `trial_id` is the only new freeze.

4. **Treatment events are a real local store**, replacing session-only `MedicationsView`. Same events feed Monitor banners and the Treatment timeline. Clock time is required. Do not infer start from RHR. `enteredBy` is a quiet line, not a second layout.

5. **`T` is the last completed civil day** unless the date stepper is on an older day. Grey hint: “Tonight is not in the usual yet.” Date stepper matches Today (`‹ DAY ›`). Calendar strip owns horizontal drags.

6. **Read path for v1 of the tab:** store calls `evaluate` from dailies + events (source of card titles and trial). Shadow `metricSeries` is for later Health rows and debug, not the only place card copy lives (keys do not include “On lisinopril usual”).

7. **Shared screens in `Strand/Screens/`** (`BaselineMonitorView`, `BaselineSeriesView`, `TreatmentMarkingView`) so iOS tab 3 and macOS `NavItem.baseline` stay twins. Android: same five destinations, same Monitor | Treatment split, same field names. Keep `tabPaths` count at 5; Monitor | Treatment is an in-tab segment, not a sixth tab.

8. **Out-of-bounds is not a new notification system.** If `contextPrompt.shouldAsk`, present the in-app sheet on Monitor or detail. Writing a chip updates confounders for that civil day and rescoring skips primary Change since start. Missing nights never open the sheet.

9. **UI tests (product, not Test Centre on the tab).** Snapshots for `naraShape`: building, monitoring (in range + off), trial, washing_out, ended. Both plots equal height. Freeze-fail copy on one series. Release has no fixture toggle. DEBUG Test Centre may inject a snapshot; never on the Baseline tab in Release.

10. **Do not block the first UI PR on stub series, Kotlin twin, or Health dual-dots.** First vertical slice: tab shell + sleep RHR (list, calendar, two plots, confidence) + Log treatment / End + freeze titles from `LBCardCopy`. Then the rest of the wired DailyMetric columns. Then awake/continuous when columns exist.

### Hypothetical follow-ups (still not this PR’s code)

- Optional faint `center_7_raw` line on the 7-day plot so a held fever week is visible without walking the hatch up to 72.
- Quiet “Entered by caregiver” only; never hide numbers.
- More row **Treatment** + Health **Baseline ›** so the tab rename does not hide Log treatment.
- If both a freeze hatch and a live hatch confuse the first screenshot, keep freeze numbers in the trial block and the extra hatch behind a `›` “Show non-treatment range” until snapshots look readable.
- Persist charging / device-off onto the civil day later so Why missing can upgrade from `unknown` without caregiver coding.

---

## Explicit non-goals

- Sixth tab, or a “caregiver app” with different metrics.
- Showing `z_7` / `p_change` as card titles.
- Replacing Charge.
- Inferring treatment start from a jump in RHR.
- Requiring the caregiver (or patient) to label Why missing / Other things going on every night.
- A user-visible “load sample patient” switch.
- Re-implementing `MedicationsView`’s in-memory list as a third meds feature.

When in doubt, the implementation map Phase C is the visual contract; this file is how that contract mounts on NARA’s existing tabs and the Meds slot.
