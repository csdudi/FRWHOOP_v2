# Personal baseline — 17 Sep 2026 (NARA Baseline V1)

This is the **end-of-day summary** for the first NARA Baseline ship: engine + iPhone shell on Chinmay’s phone. It is **V1**, not the finished contract. Charge / Recovery on Today was not rewritten. Math stays on-device. Start time is never inferred from heart rate. A gap vs a frozen path is never titled as proof that a drug caused the change. Two usuals are never averaged.

**Still open (do not bury).** Boss item 1 — live `k` from each biometric’s **quietest / least-confounded hours** — is **not** fulfilled as stated. Code uses a hardcoded window map plus a clamped residual width. See §1.

---

## The three things the boss asked for

These are the contract. They are not optional polish. Item 1 is **not** “explain MAD / EWMA / table k.” Those already exist. Item 1 is the **second step** below.

### 1. Dynamic k — quietest hours for that series (THIS IS THE BOSS ITEM)

> **The boss item is a second step on top of that table: after enough nights, live k is taken from the quietest hours for that series (overnight for sleep HRV), then clamped so it cannot run away from the table. The test is still “center ± k × spread.” Only the width of the band can move a little with your stable nights.**

Read that twice. That *is* the request.

| Already existed (not the ask) | The ask (item 1) |
|---|---|
| Table k per biometric (RHR 2.0, HRV 2.6, resp 1.6, …) | After enough nights, **pick the quietest hours** for *that* series — the stretch with the **least confounding** — and take **live k** from there |
| Center and spread; band = center ± k × spread | **Do not change the test.** Still center ± k × spread. k is only how wide |
| IN RANGE / OFF vs that band | Clamp live k so it cannot run away from the table |

Worked meaning: sleep HRV’s k must come from **overnight** (quiet, fewer confounders), not from an all-day mean that includes talking, motion, and meals. The same idea applies to every biometric: **scan for that series’ least-confounded period**, then set k from those hours — not from a global 2 and not from the noisiest part of the day.

**Status — not fulfilled as stated.** Code today hard-maps series → a named window (sleep → overnight, rest → still waking, …) and then rescales k from residuals **inside that pre-chosen column**. That is a proxy, not a scan of each biometric for the period with the fewest confounders. Rest / Active / All day on the phone are still demonstration stand-ins. Table k + clamp + “same test” are in place; **quietest-hours search is not.** Do not write this item up as “we shipped 95th-percentile MAD.”

Dashboard (when the window is known): caption can name it (e.g. most stable overnight). No FPR % on the card. Snapshot stores `k_band_table` and `k_band_used`.

### 2. Everyday **daily log** — not an OFF-triggered “what went wrong?” form

**Ask.** Opening a confounder sheet because a night went red trains people to fill it only when the number looks bad. That biases the log.

**Shipped (V1).** No auto sheet when a night is OFF. The wearer logs **the civil day** whether or not the rails are green. Product name is **Daily log**, not “day log.”

This is the **first version of the daily log the user will fill out.** It is a starting questionnaire so each civil day has a stored label. **Suggestions are needed** from the boss / clinical side: which questions stay, which should be dropped, which should become strata vs acute skips, and whether demand / diet / mood should move the usual the same way workout already does. Do not treat these eight items as frozen science.

### 3. Bake workouts and habits into the usual, not only into a footnote

**Ask.** A hard session should not be judged against rest-day RHR. Habits belong in the tracking, not only as a red-night excuse.

**Shipped (partial).** Rest vs trained stratum is live (see the pipeline below). Other daily-log fields are **recorded** and shown as the day’s label; only a subset **changes the number** in V1. That gap is intentional for V1 and is where suggestions are needed.

---

## Daily log V1 — what is asked, stored, and what actually moves the usual

This section is the connection between **Today’s Daily log** and **Baseline math**. If a sentence is not in “moves the usual,” it does **not** change center, spread, or IN RANGE / OFF in this version.

### Where it lives

- **Today** (liquid and classic): a **Daily log** row under the greeting. Empty: “Daily log.” Saved: **Daily log saved** plus the computed **day label** (`LBDayLog.summaryLine`).
- Sheet title **Daily log**; save **Save daily log**.
- Repeating **21:00 local** notification titled **Daily log** (opens Today + the sheet). Category `baseline-day-log`.
- **Not** on the Baseline tab (that made the usual look like a one-night score).
- Persistence: `UserDefaults` key `noop.baseline.daylog.v1`, map of civil day → `LBDayLog`. Survives relaunch. Old JSON without new fields still decodes (demand defaults to usual, diet typical defaults true).

### The eight questions (same every day)

1. Mood — low / okay / good (`LBDayMood`)
2. When most active — morning / afternoon / evening / spread / mostly rest (`LBActiveWindow`)
3. How hard was activity — no workout / easy / moderate / hard (`LBWorkoutLoad`)
4. Energy through the day — faded / steady / wired (`LBDayEnergy`)
5. How demanding besides the workout — light / usual / heavy day (`LBDayDemand`) **new in V1**
6. Was eating typical — typical / not typical (`dietTypical`) **new in the sheet; field already existed**
7. Anything that stood out — alcohol, travel, felt ill, another medication
8. Last night’s sleep typical — typical / not typical

### Day label (what the user sees after save)

`summaryLine` is the **recorded label** for that civil day, shown on Today:

- Always: mood · Rest **or** Trained (from workout) · demand (Light / Usual / Heavy day)
- Then only if they apply: energy if not steady, Alcohol, Travel, Felt ill, Sleep off-typical, Diet off-typical, Another med

Example from the phone: `Good · Trained · Usual day · Alcohol · Travel · Felt ill · Sleep off-typical · Another med`.

That string is the V1 “informed label.” It is stored with the structured fields. It is **not** a 0–100 score and it is **not** mixed into Charge.

### How the log is factored into baseline calculation (V1)

Every scored night, `evaluate` / `scoreOneDay` reads `dayLogsByDay` for that civil day. Two paths can change math. Everything else is keep-for-later.

**A. Rest vs trained usual (workout → habit stratum) — this *does* change the longer usual.**

- `LBWorkoutLoad.none` → habit class **rest**. Easy / moderate / hard → **trained**.
- If today is rest or trained **and** the long window has **≥ 7 nights** of the **same** class, the longer copy (median, spread, Theil–Sen path, live `k` residuals) is built only from those matched nights. A hard day is judged against other trained days, not against rest-day RHR.
- If fewer than 7 matched nights, the engine keeps the mixed long list (does not invent a trained usual from three gym days).
- Workout is **not** an acute skip. A hard day still scores; it is compared to the trained rail when that rail exists.
- Snapshot fields: `habitClass`, `habitMatched`.

This is how **logged activity type** enters **center ± k × spread**. It is the only daily-log field that currently **rebuilds** the longer copy.

**B. Acute flags — this *does not* rewrite L0/G0; it *does* skip primary “Change since start.”**

From the same log, `acuteConfounders` / `acuteFlags(on:)`:

| Log toggle | Chip | Effect in V1 |
|---|---|---|
| Felt ill | illness | Acute |
| Travel | travel | Acute |
| Another medication | concomitant_med | Acute |

On an acute civil day: primary trial contrast is **ineligible** (the gap can still be drawn; it is not sold as a drug effect). TRUST can move. The frozen expected-without-treatment bundle (**L0 / G0**) is **not** rewritten. Illness does not become the new usual.

**C. Recorded, labeled, not yet used to rebuild the usual (V1 — suggestions needed).**

These are persisted and appear on the day label. They do **not** currently select a different long median, change `k`, or skip IN RANGE / OFF:

| Field | Why it is on the form | What V1 does **not** do yet |
|---|---|---|
| Mood | Labels the day | No mood-matched usual |
| Active window | When the load sat | No morning-vs-evening stratum |
| Energy | How the day felt | No energy-matched usual |
| Demand (light / usual / heavy) | Desk-heavy rest vs easy rest | No demand stratum (workout is the only load split) |
| Diet typical | Diet is a named confounder in the trial contract | `dietTypical = false` is **label only** in V1; it is **not** wired as `diet_change` skip |
| Alcohol | Common HRV / RHR confounder | Label only; not a stratum or skip |
| Sleep typical | Sleep disruption chip exists in the old list | Label only; not auto `sleep_disruption` |

**Suggestions needed (daily log V1):** which of C should become (1) another stratum like rest/trained, (2) an acute skip like illness, (3) a grey night that stays visible, or (4) stay as label-only. Especially: diet, alcohol, sleep typical, and demand. Do not add those into the usual without that call — averaging “heavy desk days” into rest RHR is the same class of mistake as averaging gym days into rest RHR.

**D. What the log never does**

- Never infers treatment start from a bad night.
- Never auto-opens because the band went red.
- Never edits Charge, Recovery, or a blended 0–100.
- Never averages the two usuals.
- Never claims a drug caused a change because the log was filled.

---

## Phone bring-up

NOOPiOS on Chinmay’s iPhone. Bundle prefix `com.chinmaydudi.frwhoop` via gitignored `Config/BundleIdSecrets.xcconfig`; App Group `group.com.chinmaydudi.frwhoop.noop.staging`. Signing Team must be set on **NOOPiOS**, **NOOPiOSWidgets**, **NOOPWatch**, **NOOPWatchComplications**. Baseline and Treatment use the **demonstration tape** so usuals can be read without a long live WHOOP history. `displayDays` still ignores live `Repository.days` for that reason.

---

## UI — iPhone shell (end of 17 Sep)

PR 15-style **five tabs**, NARA content in those slots:

**Today · Baseline · Sleep · Treatment · More**

### Today

- Under **Good evening**: **Daily log** / **Daily log saved** + day label (see above).
- **Either Synthesis or Baseline, never both.** While usuals are still building, Synthesis stays. Once short-term and/or long-term usual is ready: Baseline shortcut with **no biometric** (e.g. “Long-term baseline is fully calculated”). Tap → Baseline tab.
- Charge / Effort / Rest rings unchanged.

### Baseline tab (`BaselineMonitorView`)

- Header is the **series name** (plus EXPLORATORY). No moving SCORED NIGHT / single-night hero.
- Sleep / All day / Rest / Active + metric chips jump both plots to the **newest** scored night.
- Plot chrome: heading; method note; date chevrons + **fixed 152pt** summary box; chart height on the chart only.
- Out of range paint: orange → red by distance past the band. Stats (k, z, IN RANGE / OFF) unchanged.
- **Open Treatment** → Treatment tab. Reverse **Open Baseline** on Treatment.
- Under the **overall (longer) usual**, in order:
  1. **Watchdog** fold — same disclosure chrome as Trends; expand shows a Coming soon placeholder. **Not** a tab.
  2. **Trends** fold — Charge / effort / vitals over weeks (`TrendsView(embedded:)`).
- No Daily log button on this tab.

### Treatment tab (`TreatmentCaregiverView`)

- Tab label **Treatment** (not Meds). Same calendar / start / dose / end / freeze course as before.
- Page title remains Treatment. Open Baseline at the top of the form column.

### Sleep / More

Unchanged destinations. More still lists Baseline and Treatment for findability. Trends is not a primary tab; `.trends` deep link opens Baseline with the Trends fold expanded. Daily-log notification opens Today + the sheet.

### Tab bar performance / clipping

A first pass forced an **opaque** UITabBar and faded tab roots. On iOS 26 the glass **pill** still drew, but layout reserved a full-height strip — white band and **KEY METRICS clipped**. That chrome, toolbar-background, and page-fade opacity were **reverted**. Tabs still switch **without** animating the entire TabView (no 240ms implicit animation on the bar). Native Liquid Glass pill is back so scroll clearance matches the floating bar (`NoopMetrics.tabBarClearance`).

### Shell / text

`ScreenScaffold` titles wrap/scale; More pushes get extra top padding so the back chevron does not sit on the in-content title.

---

## Files (where to look)

| Area | Paths |
|---|---|
| Quietest-hours k (boss item 1 — **open**) | Contract above. Proxy: `kBandFromStableWindow` / `stableWindow` in `LongitudinalBaselineReview.swift` |
| Daily log V1 + stratum | `LongitudinalBaselineTrial.swift` (`LBDayLog`, `LBWorkoutLoad`, `LBDayDemand`, `summaryLine`, `acuteConfounders`); `scoreOneDay` habit-matched pairs in `LongitudinalBaseline.swift` |
| Store | `Strand/Data/BaselineStore.swift` |
| Baseline / Treatment / Today UI | `BaselineMonitorView.swift` (sheet + Daily log CTA + Watchdog/Trends folds), `TreatmentMarkingView.swift`, `LiquidTodayView.swift`, `TodayView.swift` |
| Evening reminder | `Strand/System/DayLogReminder.swift` |
| Watchdog placeholder | `Strand/Screens/WatchdogPlaceholderView.swift` (full-screen leftover; Baseline uses the fold) |
| iOS tabs | `StrandiOS/App/RootTabView.swift` — Today · Baseline · Sleep · Treatment · More |
| Tests | `LongitudinalBaselineReviewTests`, `LongitudinalBaselineTrialTests` (incl. daily-log label + diet/demand decode), `BaselineStoreTests` |

---

## Unchanged on purpose

- Charge on Today.
- Two copies of usual, never one 0–100.
- Demonstration tape until live WHOOP nights replace `displayDays`.
- Rest / Active / All day columns are still stand-ins until WHOOP still/moving/all-hours exist.
- Boss item 1 (k from quietest / least-confounded hours per biometric) is still open.
- Watchdog is a **placeholder fold**, not a researched detector.
- Android twin of this UI was not this pass.
- Real-WHOOP FPR table is still harness-only.

---

## Tests and remaining limits

Package test `testDailyLogLabelUsesDietAndDemand` covers the V1 label and old-JSON decode. Other longitudinal tests were green after habit-stratum work. Mac `StrandTests` host can still fail to boot from a zstd dylib team-id issue on this machine; that is not a Baseline logic failure.

Still true: Baseline math on device is demonstration-tape-backed in the app until the live WHOOP pipeline is wired to `displayDays`.
