# NARA Baseline V1 — work completed 17 Sep 2026

First ship of NARA Baseline on iPhone: engine plus shell. This is **V1**, not a finished contract.

Constraints that did not change: Charge / Recovery on Today was not rewritten. Math stays on-device. Start time is never inferred from heart rate. A gap versus a frozen path is never titled as proof that a drug caused the change. The two copies of usual are never averaged.

---

## 1. Band width (`k`) and unconfounded range

- Table `k` is still the prior (e.g. sleep RHR 2.0, sleep HRV 2.6, respiratory rate 1.6) and the **clamp**.
- The test remains **center ± k × spread**. IN RANGE / OFF still uses that band.
- A night is **confounded** if the Daily log has felt ill, travel, another medication, alcohol, sleep not typical, or diet not typical. No log that day still trains (the rails are not emptied before people start logging). Workout is **not** a confounder; it still splits rest vs trained.
- The **longer usual and this week’s usual** (center and spread) are built only on **unconfounded** nights, then rest vs trained if ≥7 nights of that class remain. Confounded nights can stay visible (grey). They do not pull the rails. Illness still does not rewrite L0/G0.
- Live **`k_used` is one number**: the 95th percentile of `|residual| / spread` on those **same clean nights**, once ≥14 clean nights exist. Under 14, table `k`. Clamp to 0.75–1.40× table so one remaining wild week cannot explode the band. Snapshot: `k_band_table`, `k_band_used`, `n_clean`.
- Among **real** `DailyMetric` columns in the same biometric family, the column with the **smallest** clean `k_used` is the quietest (`quietestRealColumn`). Fake Rest / Active / All day stand-ins are ignored, so sleep HRV is never calibrated from a pretend all-day mean.
- There is no 24-hour clock search; WHOOP still/moving/hour tapes are not on device yet. Least confounding is the **Daily log filter** plus the **quietest real column**.

**Summary.** The range and `k` are now the unconfounded usual: center and spread from nights without logged confounders, and a single live `k` from those nights (clamped to the table). Quietest real column wins when more than one real series exists in the family. Clock-hour scanning is still waiting on real rest/active windows.

---

## 2. Daily log V1 (first version the wearer will fill)

- Product name is **Daily log** (not “day log”).
- The log is **not** opened because a night went OFF. Filling only after a red reading would bias answers.
- Entry is on **Today** under the greeting: **Daily log** / **Daily log saved**. The Baseline tab does not carry a log button.
- Sheet title **Daily log**; save **Save daily log**.
- 21:00 local repeating notification titled **Daily log** opens Today and the sheet.
- Stored per civil day in `UserDefaults` (`noop.baseline.daylog.v1`). Older saved JSON still loads; new fields default safely.
- Eight questions, same every day:
  1. Mood — low / okay / good
  2. When most active — morning / afternoon / evening / spread / mostly rest
  3. Activity load — no workout / easy / moderate / hard
  4. Energy — faded / steady / wired
  5. Demand besides workout — light / usual / heavy day
  6. Eating typical — typical / not typical
  7. Stood out — alcohol, travel, felt ill, another medication
  8. Last night’s sleep typical — typical / not typical
- After save, Today shows a **day label** (`summaryLine`): mood · Rest or Trained · demand, then flags that apply (alcohol, travel, felt ill, sleep/diet off-typical, extra med). Example: `Good · Trained · Usual day · Alcohol · Travel · Felt ill`.
- This questionnaire is a **first version**. It is not frozen science. **Suggestions are needed** on which questions to keep, drop, or add (especially mood, energy, demand, and active window, which are still label-only).

**Summary.** V1 gives every civil day a structured log and a readable label, filled whether the usual was green or not. It is the first form a user will see; the item list should be reviewed before treating it as the long-term instrument.

---

## 3. How the daily log is recorded and factored into the usual

- Every scored night, `evaluate` / `scoreOneDay` reads that day’s `LBDayLog`. Missing log = still trains.
- **Workout → rest vs trained (after the clean filter).** No workout = rest; easy / moderate / hard = trained. If today is rest or trained and **≥ 7 remaining clean nights** of that class exist, the longer copy is those nights only. Workout is not a confounder and not an acute skip. Snapshot: `habitClass`, `habitMatched`.
- **`confoundsUsual` (rebuilds center, spread, and `k`; does not rewrite L0/G0).** Felt ill, travel, another medication, alcohol, sleep not typical, or diet not typical drop that night from both usuals and from live `k`. The same flags still grey the plot point. Felt ill / travel / extra med remain acute for trial eligibility (primary “Change since start” ineligible that day). Illness does not become the new freeze.
- **Label only:** mood, active window, energy, demand. They appear on the day label. They do not create a mood-matched usual, a morning-vs-evening split, or a demand stratum.
- The log never infers treatment start, never auto-opens on OFF, never edits Charge, never averages the two usuals, never claims a drug caused a change.

**Summary.** Unconfounded nights build the rails. Workout then splits rest vs trained on what is left. Acute chips still skip the treatment-response sentence without rewriting the freeze. Mood, energy, demand, and active window stay labels.

---

## 4. Device bring-up

- NOOPiOS ran on a physical iPhone.
- Bundle prefix `com.chinmaydudi.frwhoop` via gitignored `Config/BundleIdSecrets.xcconfig`; App Group `group.com.chinmaydudi.frwhoop.noop.staging`.
- Signing Team is required on NOOPiOS, NOOPiOSWidgets, NOOPWatch, NOOPWatchComplications.
- Baseline and Treatment still score a **demonstration tape** so usuals can be read without a long live WHOOP history (`displayDays` does not yet use live `Repository.days`).
- I need to understand how to run the **actual analysis off the device** (Mac / package tests / a later pipeline), so the phone is not constantly overheating from on-device scoring.

**Summary.** The shell is viewable on device. Live WHOOP nights are not yet the Baseline tape. How to keep heavy analysis off the phone — so it does not overheat — is an open question before Watchdog and live tape work.

---

## 5. iPhone tab bar

- Five tabs, matching the prior NARA slot count: **Today · Baseline · Sleep · Treatment · More**.
- Baseline occupies the former Trends slot. Treatment occupies the former Meds slot (label **Treatment**, not Meds).
- Watchdog is **not** a tab.
- Deep link `.baseline` → Baseline tab; `.treatment` → Treatment tab; `.trends` → Baseline with Trends expanded; daily-log notification → Today + sheet.

**Summary.** Navigation is the familiar five-item bar with Baseline and Treatment as primary tabs.

---

## 6. Baseline screen

- Header is the series name (plus EXPLORATORY) and a caption that the usual and `k` come from nights without logged confounders. No moving SCORED NIGHT / single-day hero.
- Sleep / All day / Rest / Active and metric chips jump both plots to the newest scored night. Chevrons still walk history.
- Plot layout: heading; reserved method note; date chevrons and a **fixed 152pt** summary box; chart height on the chart only.
- Out-of-range paint: orange → red by distance past the band. k, z, and IN RANGE / OFF are unchanged. In-range stays green.
- **Open Treatment** goes to the Treatment tab. **Open Baseline** on Treatment returns.
- Under the **longer usual**, in order: **Watchdog** disclosure (Coming soon placeholder), then **Trends** disclosure (Charge / effort / vitals).
- No Daily log control on this tab.

**Summary.** Baseline is the usuals (this week + longer), not a one-night score. Watchdog and Trends sit under the long copy as folds, not as extra tabs.

---

## 7. Treatment screen

- Tab and page use the existing course UI: calendar, start, dose, end, wash clocks, freeze of expected-without-treatment.
- Open Baseline at the top of the form column.
- Onset / washout are stacked steppers; course actions wrap on a narrow phone.

**Summary.** Treatment is the primary Meds-slot destination and still the only place a start time is entered by hand.

---

## 8. Today screen

- Daily log row under the greeting (see item 2).
- Either Synthesis **or** a Baseline shortcut, never both. While usuals are building, Synthesis stays. When short-term and/or long-term usual is ready, the shortcut has **no biometric** (e.g. “Long-term baseline is fully calculated”).
- Charge / Effort / Rest rings unchanged.

**Summary.** Today still owns Charge. Once usuals exist, it points at Baseline instead of duplicating a number.

---

## Next

Baseline V1 on the phone is the current ship. I am moving on to the **Watchdog** phase of the project now: nights that leave the usual, without asking the wearer to hunt for them. The Watchdog fold under the longer usual stays a placeholder until that phase.
