# FRWHOOP longitudinal baseline — audit and gauntlet report

**Date.** 2026-09-17 (machine clock). **Repo.** `/Users/chinmaydudi/Desktop/FRWHOOP/FRWHOOP_v2`, branch `main`,
HEAD `4e6e384` *Retire Node backend; ingest runs entirely on Supabase Edge.* Working tree dirty: the whole
longitudinal-baseline feature is uncommitted work. **Nothing in this audit was reset, stashed, deleted, or
overwritten.** No production code was changed in the audit pass. Thresholds were not relaxed to make any test pass.
**Machine.** macOS 26.6.2 (25G83), arm64, 14 cores, Swift 6.3.3 (swiftlang-6.3.3.1.3), Xcode 26.6 (17F113).

**Requirement source.** `Packages/StrandAnalytics/Baseline/FRWHOOP_BASELINE_REVIEW_CHANGES.md` (352 lines).
Its own gate: *"None of the eight is 'done' until its proof in the acceptance pack passes"* (line 7) and
*"Until all eight proofs pass, this review is not in the baseline"* (line 352). Eight items have equal weight.

**Verdict headline. The review is not in the baseline.** 3 of 8 items fail their proof outright (1, 3, 8),
4 are partial (the engine behaviour is present and verified, but a required counter, display, wiring path or clock
is missing: 2, 4, 5, 7), and 1 passes with two caveats (6). The real-WHOOP calibration row is **NOT RUN** (no real
data is available or used; nothing was fabricated).

| # | Requirement | Verdict | Risk |
|---|---|---|---|
| 1 | Stable-stretch false-positive calibration, per biometric | **FAIL** (real-WHOOP row **NOT RUN**) | HIGH |
| 2 | Per-biometric params, gates, transforms, k, spans, establish counts | **PARTIAL** (core PASS, 3 dormant knobs) | MEDIUM |
| 3 | Two-night spike vs multi-week shift (Theil–Sen, detrend, CUSUM, 30-day cap) | **FAIL** (required slow-shift fixture fails) | HIGH |
| 4 | TRUST vs HOW OFF semantics, thresholds, missing data, confounders | **PARTIAL** (math PASS, required layout FAIL) | MEDIUM-HIGH |
| 5 | No causal claims; confounders, provenance, quality gates, excluded days | **PARTIAL** (provenance dead at app layer) | HIGH |
| 6 | Treatment freeze of L0/G0, expected path, flat fallback, post-start comparison | **PASS** with 2 caveats | MEDIUM |
| 7 | Patient-entered settling/washout clocks label only | **PARTIAL** (engine PASS, UI paths missing) | MEDIUM |
| 8 | Predeclared primaries, no post-treatment fishing | **FAIL** (app re-pins under the same trial id) | HIGH |

---

## 1. What was run

| # | Command | Result | Artifact |
|---|---|---|---|
| A | `cd Packages/StrandAnalytics && swift test` (baseline, before the gauntlet file) | **1973 tests, 0 failures** (47.4 s) | `/tmp/frwhoop_audit/swift_test_full.log` |
| B | `cd Packages/StrandAnalytics && swift test` (after the gauntlet file) | **2020 tests, 6 failures** — all 6 are the new gap detectors | `/tmp/frwhoop_audit/swift_test_with_gauntlet.log` |
| C | `swift test --filter FRWhoopBaselineGauntletTests` | **47 tests, 6 failures** (28.8 s) | `/tmp/frwhoop_audit/gauntlet_run3.log` |
| D | `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests/BaselineStoreTests test` | **22 tests, 0 failures**, `** TEST SUCCEEDED **` | `/tmp/frwhoop_audit/xcode_baselinestore_test.log` |
| E | `xcodebuild … -only-testing:StrandTests test-without-building` (whole app test target) | **not completed twice**: after ~525 fast cases the run sits in `BugReportTemplateTests.testAttachZipCheckboxPresent`, which alone takes **1346 s (22.4 min)** on this host (isolated run below); both attempts were killed after ~7 min — see §14.5 | `/tmp/frwhoop_audit/xcode_full_strandtests.log`, `…2.log` |
| E2 | `xcodebuild … -only-testing:StrandTests/BugReportTemplateTests test` | **5 tests, 0 failures**, `** TEST SUCCEEDED **` — `testAttachZipCheckboxPresent` took 1346.123 s, the other four 0.002-0.004 s | `/tmp/frwhoop_audit/xcode_bugreport.log` |
| F | `xcodebuild … -only-testing:StrandTests/BaselineStoreTests -only-testing:StrandTests/MoreListParityTests test` | **29 tests, 0 failures**, `** TEST SUCCEEDED **` (22 + 7) | `/tmp/frwhoop_audit/xcode_targeted.log` |
| G | `xcodebuild … -only-testing:StrandTests test` (whole app test target, third attempt) | **1613 tests, 1 skipped, 1 failure** in 12.2 s, `** TEST FAILED **` — the single failure is `SkinTempAbsoluteDisplayTests.testTheSecondaryLeadsTheCaptionSoItSitsUnderTheValue`, unrelated to this baseline; all 22 `BaselineStoreTests` pass inside it | `/tmp/frwhoop_audit/xcode_full_strandtests3.log` |

New harness added by this audit (no production edits):
`Packages/StrandAnalytics/Tests/StrandAnalyticsTests/FRWhoopBaselineGauntletTests.swift` (1300 lines, 47 tests).
Six of its rows are deliberate **gap detectors**: they encode a required proof from the review doc and fail on the
current tree. The file header names them, and they turn green only when the gap is fixed. Everything else in the
file is a requirement check that passes today and must not regress.

Independent analysis used three read-only research passes (documentation map, app-side wiring audit, existing-test
inventory) whose notes are quoted where they add line-level evidence.

**Scope limits.** Not run: real WHOOP 5.0 data (item 1's row stays empty), iOS/Android device runs, SwiftUI
snapshot tests (none exist), CI (no workflow names this suite), and any behaviour reachable only through
`BaselineStore` from a package test (the app target is not importable from `StrandAnalyticsTests`; app-side
findings are code-reading plus the app test target).

---

## 2. Item 1 — stable-stretch false-positive calibration, per biometric: **FAIL**

**Required proof** (`FRWHOOP_BASELINE_REVIEW_CHANGES.md:29-33, 341`): a *per-series* stable false-positive-rate
table; fixtures `stable_rhr_60`, `stable_hrv`, `stable_resp` with low OFF rates at each series' own `k`; an empty
row *"real WHOOP 5.0 — not run yet"*; acceptance = **"Per-series rates printed; HRV not scored with RHR `k`."**

**What exists.** `stableFalsePositiveTable` (`LongitudinalBaselineReview.swift:240-269`), `printStableFPRTable`
(`:271-278`), `LBStableFPRRow` (`:42-54`), per-series `k` via `params(for:)` (`:245`), a real-data flag defaulting
false (`:242`) and the literal `"not run yet"` (`:275`).

**Passing evidence (gauntlet).**
`test_gauntlet_item1_stableFPRTableHasOneRowPerSeriesAndRealRowNotRun` (`FRWhoopBaselineGauntletTests.swift:131`)
— a 120-night synthetic tape per series (`sleepRHR` 60, `sleepHRVLn` 65 ms, `sleepResp` 15, `wakingSteps` 8 000)
produces one row per series, `realWhoopRun == false` for each, and the printed table contains `not run yet`:

```
ITEM1 FPR TABLE
series                  n    off_long  off_week  2of3  mdc  real
sleep_rhr              8  0  0  0  0  not run yet
```

**Failing evidence (three gap detectors).**
1. `test_gauntlet_item1_stableDayCountCoversTheWholeStableStretch` (`:152`) — a **150-night stable tape** yields
   `nStableDays = 8`. The counter only walks `for back in 0..<8` (`LongitudinalBaselineReview.swift:251`) and
   additionally requires the *last* day itself to pass the stable filter (`:248-250`). Failure text:
   *"FPR must be counted per series over the stable stretch (150 stable nights here). A count of 8 cannot calibrate k."*
   An 8-day denominator has no power: one flagged night is a 12.5 % "FPR".
2. `test_gauntlet_item1_printedTableCarriesPerSeriesRates` (`:165`) — the printed table shows counts only
   (`n off_long off_week 2of3 mdc real`). `LBStableFPRRow.rateLonger` (`:51-53`) is computed and **never read by
   production code or any test**. Acceptance row 1 (*per-series rates printed*) is not met.
3. `test_gauntlet_item1_stableGatePChangeIsNotVacuous` (`:178`) — the stable filter requires `p_change < p_thr`,
   but every stable day is re-scored with `replay: false` (`:253-254`), so `carry.cusumS` is always the empty
   carry and `pChange = 1 − exp(0) = 0` (`LongitudinalBaseline.swift:1189-1201`). Measured on a tape with a
   12-night fever plateau: `p_change online = 0.9454 (S = 58.17)` vs `p_change isolated = 0.0 (S = 0.0)`.
   The criterion is vacuous, so a shifting tape is counted as a stable false positive.

**Further static gaps.**
- The stable filter has **no confounder input** (`:248-256`), so item 1's *"no patient-entered confounders"*
  condition cannot be evaluated. `confoundersByDay` is read only in `attachTrial`
  (`LongitudinalBaselineTrial.swift:733`).
- Item 1's *"slow slope either flat or residuals in-band"* condition is not part of the filter.
- The `above_mdc` column is dead on this path: `ev.trial.aboveMdc` is non-nil only when a freeze exists
  (`LongitudinalBaselineTrial.swift:743, 771`), and the filter requires `ev.trial.phase == .none`, which implies
  no freeze. The column reads 0 always.
- The three required fixture names do not exist: `Baseline/fixtures/` holds only `quality_mix.csv`,
  `sleep_hrv_ln_ms.csv`, `sleep_rhr_week_ramp.csv`, `waking_steps_zero.csv`.
- The existing review test (`LongitudinalBaselineReviewTests.swift:205-222`) asserts row count, `realWhoopRun == false`
  and the "not run yet" substring on **constant** tapes, so a regression that always records `offLonger = 0` still passes.

**Real WHOOP 5.0 row: NOT RUN.** No real tape was supplied and none was invented. The harness emits a per-series
`real` column reading `not run yet` instead of the literal requested row label `real WHOOP 5.0 — not run yet`
(`:33`); honesty is preserved but the literal artifact is not produced.

**Risk: HIGH.** Item 1 is the counter that is supposed to set `k`; the doc freezes `k` as placeholders until this
table exists (`:22, 58`) and gates Pulse ±1.65 / Cadence |z| ≥ 1.5 on it (`:24`). With n ≤ 8 and a vacuous
p_change gate, the table cannot distinguish a tight `k` from a loose one, and item 2's `k` values remain unvalidated.

---

## 3. Item 2 — per-biometric params, gates, transforms, k, spans, establish counts: **PARTIAL**

**Required proof** (`:79, 342`): *"`params(for: .sleepRHR).k ≠ params(for: .sleepHRVLn).k` and span differs.
Same ±2 % native wiggle: respiratory rate IN RANGE, HRV not auto-OFF from RHR's `k`. If one global `Params`
remains, this request failed."* Acceptance: *"k/span/gates differ; outcomes differ."*

**What is implemented.** `LBSeriesParams` + `params(for:)` (`LongitudinalBaselineReview.swift:18-117`) with
per-series `kBand`, `span7`, `alpha = 2/(span7+1)`, `nLongEstablished`, `floor`, `worse`, `primaryOff`,
`spo2EstablishExtraNights`. The engine consumes `kBand` (`LongitudinalBaseline.swift:1326, 1336, 1387, 1392`),
`span7`/`alpha` in the this-week window and weights (`:1216, 1245`), `nLongEstablished` (`:1139, 900`), the floor
through `seriesSpec` (`:879-895`), `usesLog` for HRV (`:63-68, 905-918`), and per-context coverage gates
(`:1492-1521`).

**Passing evidence (gauntlet, all green).**

| Test | Proves | Measured |
|---|---|---|
| `test_gauntlet_item2_paramsTableMatchesTheReviewStartingTable` (`:201`) | the v1 table is implemented as written | RHR (2.0, 7, 14, 2, higher); HRV (2.6, 10, 14, 0.08, lower, α = 2/11); resp (1.6, 0.5); temp (2.0, either); SpO₂ mean 1.5 / nadir 1.7; steps (2.4, 21, 500); active-min (2.4, 21, 10) |
| `test_gauntlet_item2_respExcursionIsJudgedWithRespsOwnK` (`:228`) | resp uses its own `k` | z_long = 1.70 → OFF at 1.6, IN RANGE at RHR's 2.0 |
| `test_gauntlet_item2_hrvDropIsNotForcedThroughRHRsK` (`:245`) | HRV is judged in ln space with its own `k` | z_long = −2.33 → OFF at 2.0, IN RANGE at 2.6 |
| `test_gauntlet_item2_establishCountDiffersBySeriesAndIsUsed` (`:260`) | per-series establish is consumed | 17 long nights: RHR `established=true`, steps `established=false` |
| `test_gauntlet_item2_thisWeekWindowFollowsTheSeriesSpan` (`:274`) | per-series span is consumed | 11 present nights: HRV `n7=10`, RHR `n7=7` |
| `test_gauntlet_lowQualityOutOfRangeAndSlotGates` (`:1173`) | per-series gates | 5-slot SpO₂ night → missing, `nLong=0`; 20-slot → `nLong=53`; 200 bpm sleep RHR → not data; step `0` with a stream → real `0`; no stream → missing |

**Failing / partial evidence — three knobs are set but never read anywhere in the repo** (grep-verifiable):

| Knob | Where set | Consumers | Consequence |
|---|---|---|---|
| `worse` (`:24, 36`) | every row (`:81-115`) | **none** — the only `worse` output is `LBEvaluation.worse`, which is `abs(z) > abs(z_prev)` (`LongitudinalBaseline.swift:1325`) | Item 2's *"direction of worse"* knob does nothing: an HRV rise and an HRV drop of equal size are treated identically. |
| `primaryOff` (`:25, 37`) | `wakingSteps`, `wakingActiveMin` (`:112, 115`) | **none** in `Sources/` or `Strand/` | Item 2's *"primary OFF copy: rest → longer path, motion → this week first"* is not implemented. |
| `spo2EstablishExtraNights` (`:26, 38`) | SpO₂ rows (`:106, 109`) | **none** — the freeze gate hardcodes `okSlots < 10` (`LongitudinalBaselineTrial.swift:567-570`) | The *"14 + 10 nights with ≥ 8 slots"* establish rule is only half-implemented, and editing the param changes nothing. |

**Also partial.**
- The legacy global blob survives: `LongitudinalBaseline.Params.kBand = 2.0`, `span7 = 7` (`:485, 481`) are still
  exported in `v1ParameterLedger` (`:524-531`) and still drive the legacy `confidencePct7/Long` path
  (`:1064-1090`). Two existing tests pin the globals (`LongitudinalBaselineCatalogTests.swift:203`,
  `LongitudinalBaselineMethodsTests.swift:223`), so a future edit can silently re-globalise a rule.
- `copySnapshot` version strings are global (`Params.version7`/`versionLong`, `:1387, 1391`), not per-row, so
  `param_set` cannot record *which row* changed, contrary to item 2's *"Changing a row bumps `param_set`"*.

**Risk: MEDIUM.** The differentiation that changes verdicts (`k`, `span`, `establish`, `floor`, gates, ln space,
per-series quality gates) is real and verified. The dormant knobs are doc-vs-code drift with real behavioural
consequences for two of them (direction of worse, motion's primary copy).

---

## 4. Item 3 — two-night spike vs multi-week shift: **FAIL**

**Required proof** (`:106-109, 343`): `spike_rhr_two_nights` → *"OFF longer usual. This week's training usual does
**not** become 72."* `slow_shift_rhr_three_weeks` (`RHR` falls ~0.3 bpm/day for ~21 days) → *"**Not** stuck OFF vs
a flat 60… `p_change` is not a false 'new disease jump.'"* plus the 30-day projection cap.

**Passing evidence (gauntlet).**

| Test | Required behaviour | Measured |
|---|---|---|
| `test_gauntlet_item3_spikeTwoNightsIsOffLongerUsualAndDoesNotTrainTheWeekTo72` (`:289`) | spike OFF, week usual does not learn the fever | `zLong = 5.8` (OFF), training usual `center7 = 60.67`, raw 7-day center 63.50 (not 72), `twoOfThree = true`, `runLength = 2` |
| `test_gauntlet_item3_cusumRunsOnDetrendedResiduals` (`:391`) | CUSUM on residuals, not distance to a flat median | slow ramp: `S = 0.0`, `pChange = 0.0`, `regimeShift = false` while the flat median is 8 bpm away |
| `test_gauntlet_item3_thirtyDayProjectionCap` (`:357`) | 30-day cap | `expectedUntreated` at +10 = L0 + 10·G0 = 65.0; at +90 = L0 + 30·G0 = 75.0; unusable slope → L0 = 60.0 |
| `test_gauntlet_item3_horizonBeyondLastLongNightDropsTheProjection` (`:374`) | no projection when the newest long night is older than the horizon | `slopeUsable = false`, `expectedLong == copyLong.center` (flat) |
| `test_gauntlet_item3_slowShiftAcrossTheLongWindowIsNotStuckOff` (`:335`) | detrending works when the drift spans the window | slope = −0.3, `expected = 49.4` vs flat median 58.4, `zLong = −0.12`, `pChange = 0.0` |

**Failing evidence — the review's own slow-shift fixture is still OFF.**
`test_gauntlet_item3_slowShiftThreeWeeksIsNotStuckOff` (`:307`), tape: 60 nights at 66, then 21 nights falling
0.3 bpm/day to 60.4 at T.

```
ITEM3 shift slope=-0.024695121951219222 usable=true expected=64.85914634146341 flatMedian=65.6
      spread=2.0 zLong=-2.229573170731708 zVsFlat=-2.6 pChange=0.20546639749666507 regime=false
```

Failure text: *"a 21-day slow shift must not be stuck OFF vs the expected path"* — `zLong = −2.23` is past
`sleepRHR`'s `k = 2.0`, so the recovering patient is still called OFF after three weeks. The flat-number contrast
(`zVsFlat = −2.6`) shows the detrending changed almost nothing.

**Root cause (verified independently).** A Python re-implementation of the engine's own window gives
`Theil–Sen = −0.024695` — byte-identical to the engine's `slopeLong`, so the estimator is not buggy; the *window*
is. The long window is `[T−60, T−8]` (`LongitudinalBaseline.swift:1130`), so for a shift that starts ~21 days
before T, 40 of the 53 nights are the pre-shift plateau. Then:

- `origin` is the **window midpoint**, `(first + last long epoch) / 2` (`:1174-1175`), i.e. ~34 days before T.
- `expectedOnPath` clamps `dt = day − origin` to ±30 and returns `center + slope·dt`
  (`LongitudinalBaselineReview.swift:130-139`), so the shallow 0.025 slope is extrapolated 34 days forward from the
  old median 66 → `expected = 64.86` while the patient is at 60.4.
- The horizon guard uses a *different* anchor: `(tEpoch − lastLongNight) <= slopeHorizonDays` (`:1185`), and
  `lastLongNight` is at most T−8, so for any tape with a healthy week the guard is 8…53 while the projection is
  measured from the window midpoint. The cap therefore does not bound the extrapolation that actually happens.

Variant probe (same estimator, different window): a ramp that ends at T−8 gives `z = −1.73` (IN RANGE) and a ramp
that spans the window gives `z = +0.50` (IN RANGE). The machinery is real; the required fixture sits outside its
reachable regime.

**Secondary inconsistency.** The trial's flat-7 path computes its own cap as
`min(tEpoch − fEpoch, slopeHorizonDays)` with no lower clamp (`LongitudinalBaselineTrial.swift:773`), a different
rule from `expectedUntreated`.

**Risk: HIGH.** This is the exact failure mode the review names: *"If both tapes still call the slow patient
OFF-for-weeks, this request is not met"* (`:109`). A genuinely improving or deteriorating patient is reported OFF
the longer usual for the whole ramp, and the fix is structural (anchor the path at the newest usable nights, or add
the recent nights to the slope fit), not a constant tweak.

---

## 5. Item 4 — TRUST vs HOW OFF: **PARTIAL**

**Required proof** (`:160, 344`): *"Three nights, RHR 72 vs usual 60: TRUST low, HOW OFF not shown as a confident
OFF. Full week in-band 60: TRUST high, HOW OFF low. Full week 72: TRUST high, HOW OFF high. HRV TRUST < RHR TRUST
on the same calendar coverage because `n_eff` and `k` differ. If `confidence_pct_*` is still the only percent on the
card, this request failed."* The required layout shows HOW OFF on **both** boxes (`:152-155`).

**Implemented.** `LBTrustInputs` + `usualTrustPct` (`LongitudinalBaselineReview.swift:56-167`) implement the
formula term for term; `howUnusualPct = 100·(1 − twoTailStudentT(|z|, df = max(n_eff−1, 3)))` with a continued-fraction
regularised incomplete beta (`:169-232`); `trustHideThreshold = 35` (`:76`); the ×0.4 failed-freeze and ×0.5
confounder effects are applied in `evaluate` (`LongitudinalBaseline.swift:760-766`).

**Passing evidence (gauntlet, all green).**

| Test | Required case | Measured |
|---|---|---|
| `test_gauntlet_item4_howOffMatchesStudentTTable` (`:410`) | HOW OFF is the Student-t two-tail | t(2, df 3) = 86, t(3, 3) = 94, t(1, 3) = 61, t(2, df 29) = 95, df floor `n_eff=1 → 3`, `z=nil → nil` (all within 1 point of `scipy`) |
| `test_gauntlet_item4_fullWeekInBandHasHighTrustAndLowHowOff` (`:427`) | case 1 | `TRUST7 = 100`, `HOW OFF7 = 19` |
| `test_gauntlet_item4_fullWeekOffHasHighTrustAndHighHowOff` (`:438`) | case 2 | `TRUST long = 75`, `HOW OFF long = 100`, `zLong = 5.8` |
| `test_gauntlet_item4_threeNightsHasLowTrust` (`:456`) | case 3 | `TRUST7 = 25 < 35`, engine still returns `howOff7 = 98` for the UI to hide |
| `test_gauntlet_item4_hrvTrustIsLowerThanRhrTrustOnTheSameCoverage` (`:476`) | case 4 | same 18 nights: HRV `TRUST = 1 %` (`n_eff = 1.17`) < RHR `TRUST = 14 %` (`n_eff = 1990`) |
| `test_gauntlet_item4_trustMovesForTonightQualityStalenessFreezeAndConfounder` (`:497`) | TRUST moves | tonight ok/low-quality/missing = 75/47/38, stale = 0, failed freeze = 30 (= 75 × 0.4), chipped = 38 (= 75 × 0.5); through `evaluate`, a diet chip takes the long TRUST 33 → 17 |
| `test_gauntlet_item4_cardShowsTrustAndHowOffWithoutLegacyConfidence` (`:1292`) | no CONFIDENCE label | `Text("TRUST …%")` and `Text("HOW OFF …%")` at `BaselineMonitorView.swift:417, 423`; `NOT ENOUGH NIGHTS` verdict at `BaselineStore.swift:336`; no `Text(` literal contains "onfidence" — **but see the failing assertion below** |

**Failing evidence — the longer box has no HOW OFF.** The same test fails on:

```
item 4 required layout: the longer box shows TRUST and IN RANGE / OFF *and* HOW OFF
(OFF - HOW OFF 86% or NOT ENOUGH NIGHTS). Hard-nil removes a required display
```

`BaselineStore.swift:303-304` is `var longHowOff: Int? { nil }` (comment: *"HOW OFF vs a 60-day path is not shown on
the card"*) and `BaselineMonitorView.swift:84` passes `howOff: nil` for the right box, while the review's layout
row (`:152-155`) and the summary rule (*"HOW OFF vs path high"*, `:228`) require it. The shipped docs admit the
change (`FRWHOOP_BASELINE_CHANGE_SUMMARY_16_SEP.md:43`, `FRWHOOP_BASELINE_16_SEP_NOTES.md:25`) but no document
reconciles it with the acceptance row, and two app tests lock the hard-nil in (`StrandTests/BaselineStoreTests.swift:69, 403`).

**Partial evidence / residue.**
- The long box mixes sources: its TRUST comes from the **no-trial** evaluation
  (`BaselineStore.swift:239-243, 294-296`) while its verdict and z come from the trial-aware evaluation (`:323-328`).
  After a freeze the right box can show a no-trial TRUST next to a trial z.
- The legacy CONFIDENCE formula is still in the engine: `confidencePct7/Long`
  (`LongitudinalBaseline.swift:1064-1090`), `LBEvaluation.confidencePct7/8` (`:333-334`), the `phaseAStatisticLedger`
  keys `confidence_pct_7/long` (`:447-448`), the `consoleReport` line (`:398`) and a `.phaseA` row in
  `statisticalMethods` (`:627-628`). Two existing tests pin the formula
  (`LongitudinalBaselineTests.swift:196`, `LongitudinalBaselineMethodsTests.swift:202`). The card and the shadow
  keys are clean (`shadowPoints` writes only `usual_trust_pct_*` / `how_unusual_pct_*`, `:792-800`), so this is a
  regression risk rather than a live defect — but the acceptance row asks for the old formula to be *gone*, not
  merely unused.
- `scoreOneDay` hardcodes `freezeOk: 1, confoundToday: false` when it builds `LBTrustInputs`
  (`:1350-1357`); the two factors are applied afterwards only inside `evaluate` (`:760-766`). Any future caller that
  uses `scoreOneDay` directly (or a new screen that scores one day) gets TRUST that ignores a failed freeze and a
  chipped day. The effects are verified to work through `evaluate` today.

**Risk: MEDIUM-HIGH.** The engine separation of TRUST and HOW OFF is correct and verified numerically; the required
display contract is broken on one of the two boxes, and the item's own proof table is only partly asserted in-repo
(`LongitudinalBaselineReviewTests.swift:91-117` never asserts HRV vs RHR TRUST, and the HOW OFF hide rule is untested).

---

## 6. Item 5 — no causal claims; confounders, provenance, quality gates, excluded days: **PARTIAL**

**Required proof** (`:186-189, 345`): `preexisting_recovery` (path gap small, flat gap large, summary follows the
path); `confounded_start` (illness/diet/extra med → primary contrast ineligible, chip visible);
`provenance_break_after_start` (firmware change → not scored as change since start); card copy contains the
non-causal sentence.

**Passing evidence (gauntlet).**

| Test | Required case | Measured |
|---|---|---|
| `test_gauntlet_item5_confounderListAndNonCausalSentence` (`:553`) | diet + concomitant med exist; verbatim sentence | `LBConfounder.allCases ⊇ {illness, hospitalization, travel, sleepDisruption, exerciseChange, dietChange, concomitantMed}` (`LongitudinalBaselineTrial.swift:43-62`); `reviewDisclaimer` (`LongitudinalBaselineReview.swift:72-73`) is byte-identical to the review's sentence; rendered at `BaselineMonitorView.swift:206` |
| `test_gauntlet_item5_chippedDayIsIneligibleButStillVisible` (`:572`) | chipped start day ineligible | clean eligible `true` → chipped eligible `false`, `judgingResponse = false`, summary nil, chip still listed, `todayNative` non-nil and the point still plotted |
| `test_gauntlet_item5_preexistingRecoveryPathGapBeatsFlatGap` (`:639`) | path wins over flat | `L0 = 54.6`, `G0 = −0.25`, expected = 47.1, today = 43.65 → path gap −3.45 vs flat gap −10.95; `zPath = −0.67` vs `zFlat = −2.14`; the summary tracks the path |
| `test_gauntlet_item5_startTimeIsNeverInferredFromHeartRate` (`:666`) | t0 never inferred | a 110 bpm night with no start event leaves `phase = .none` and `freeze = nil`; two different post-start tapes produce an identical freeze |
| `test_gauntlet_item5_noCausalLanguageInTrialCopy` (`:697`) | no causal copy | card banner/titles/summary contain no "caused"; disclaimer always attached to the trial evaluation |
| engine capability | provenance break *can* work | with a persisted freeze built under firmware `1.0` and a later evaluation under `2.0`: `provenanceBreak = true`, `primaryContrastEligible = false`, summary nil |

**Failing evidence — the provenance break is dead at the app layer.**
`test_gauntlet_item5_provenanceBreakAfterStartIsNotScoredAsChange` (`:600`) fails on:

```
item 5: the app must feed LBProvenance into the trial request, or the provenance break is
structurally undetectable (BaselineStore.rescore)
```

`BaselineStore.rescore` loads the persisted freeze (`:230`) but builds `LBTrialRequest(events:freeze:confoundersByDay:)`
**without** `provenanceNow` (`:231-232`), so the request's provenance is a fresh default `LBProvenance()` and the
freeze's provenance is the same default that was current when it was written
(`LongitudinalBaselineTrial.swift:82, 723, 782`). `differs(from:)` can never be true, `provenanceBreak` is never
read by the app anyway (no grep hits in `Strand/`), and no "Device or math changed" copy exists. **A firmware or
decoder change after t0 will be presented as physiology.**

**Partial evidence.**
- Chips are editable only for the currently scored night (`BaselineStore.setConfounders` → `store.asOf`,
  `BaselineMonitorView.swift:588`); the review asked for day chips on the calendar (`:173`) and the shipped docs
  replaced them with a next-open sheet (`CHANGE_SUMMARY:53`).
- `confoundersByDay` is read only for today (`LongitudinalBaselineTrial.swift:733`), so chipped nights are excluded
  from *today's* contrast but still train the post-start "On {name}" usual. Item 5's *"primary 'change since start'
  uses days with no chip and quality-OK"* holds for the scored day only.
- The trial block (disclaimer + three columns) renders only when `trialFreezeOk` (`BaselineMonitorView.swift:97-99`),
  so the "always on-screen" sentence of `:177-179` is absent before a freeze qualifies.
- The quality-gate side is solid: out-of-range values are not data, a `<8`-slot SpO₂ night becomes missing, a
  `sleepHrOnly` night is `low_quality/sparse_sleep`, and none of these write 0
  (`test_gauntlet_lowQualityOutOfRangeAndSlotGates` `:1173`, `test_gauntlet_sleepHrOnlyNightIsLowQuality` `:1222`).

**Risk: HIGH for provenance** (a silent device/math change is exactly the failure item 5 exists to prevent),
**MEDIUM** for the chip scope and the gated disclaimer.

---

## 7. Item 6 — freeze a no-treatment model, expected path, flat fallback, post-start comparison: **PASS** (2 caveats)

**Required proof** (`:203-234, 346`): freeze `L0` + `G0` + spread, `r1`, `σ_meas`, window and provenance from days
strictly before t0; `expected_untreated(T) = L0 + G0·(T − T_freeze)` with a 30-day cap; thin slope → flat model with
the sentence *"Not enough pre-start trend to project; comparing to the usual level only."*; three equal columns and
plate-aware behaviour.

**Passing evidence (gauntlet, all green).**

| Test | Required behaviour | Measured |
|---|---|---|
| `test_gauntlet_item6_freezeStoresTheModelNotJustALevel` (`:724`) | the freeze is a model, pre-start only | `L0 = 54.6`, `G0 = −0.25`, `spread = 5.11`, `σ_meas = 0.839`, `MDC95 = 2.77·σ_meas = 2.323`, `r1` stored, provenance stored, `dLast = 2026-05-12 < t0 = 2026-05-21`; `expected(T_freeze+10) = L0 + 10·G0` and `≠ L0`; the card leads with the path |
| `test_gauntlet_item6_thinSlopeFreezesAFlatModelAndSaysSo` (`:757`) | flat fallback + copy | `slopeUsable = false`, `expected == L0`, `flatModelOnly = true`, sentence rendered at `BaselineMonitorView.swift:201-202` |
| `test_gauntlet_item6_postStartComparisonUpdatesEveryNight` (`:777`) | live copy moves, control does not, epoch resets | `nLong = 13` at t0+20 (not 140), `nLong = 33` and live center 71.4 → 79.9 at t0+40, freeze identical at both dates; titles `This week's usual | On Drug X usual | Expected without treatment` |
| `test_gauntlet_item6_phaseAwareSummaryAndTitles` (`:808`) | phase-aware comparison | settling in → `"Too early to judge a response."` with a 7 bpm gap; on treatment → *"Today is 7.0 bpm vs the no-treatment path (bigger than sensor noise)."*; washing out keeps `expectedT`; ended → `"After Drug X usual"` |

App layer: three equal columns with the required titles (`BaselineMonitorView.swift:171-178`), the ghost line
*"Vs the old flat usual it would look like …"* (`:195-200`), the flat-model sentence (`:201-205`) and the frozen path
as the right box's number (`BaselineStore.swift:280-288, 311-316`) are all present.

**Caveat 1 (MEDIUM) — the frozen `r1`/`n_eff` are computed on flat residuals, the live copy on detrended ones.**
`makeFreezeBundle` computes `r1` from `ys.map { $0 - cl }` — distance to the *level* (`LongitudinalBaselineTrial.swift:610-611`)
— while `scoreOneDay` computes `r1Long` on residuals about the detrended path (`LongitudinalBaseline.swift:1341-1345`).
Measured on the trending tape: freeze `r1 = 0.9775`, `nEff = 0.60` for a 53-night window (a value the UI can read via
`LBTrialEvaluation.nEff` and the console block `r1_freeze=`). Any future use of that number in TRUST would collapse
the drifting patient's TRUST to ~3 % — the very patient item 3 is about.

**Caveat 2 (LOW-MEDIUM) — the app hides the three numbers before a freeze.** `trialBlock` is gated by
`trialFreezeOk` (`BaselineMonitorView.swift:97-99`), so the review's *"Settling in: show the three numbers"* row is
unreachable in the product even though the engine populates `expectedT`, `zTrialLevel` and `zTrialTraj` during
settling in. Also the trial's flat-7 expectation uses a different cap rule (`LongitudinalBaselineTrial.swift:773`).

**Risk: MEDIUM** — the model, cap, fallback and post-start epoch separation are correct; the caveats are
diagnostic-number hygiene and one missing UI state.

---

## 8. Item 7 — patient-entered settling/washout clocks label only: **PARTIAL**

**Required proof** (`:297, 347`): *"Same physiology tape, washout 3 vs 14: **Ended** on different days;
`expected_untreated` and z identical. Patient says clear on day 2 of a 14-day washout: phase **Ended**, z unchanged.
'Expect RHR to fall' is not an engine input. If phase still uses only `Params.washoutDays`, this request failed."*

**Passing evidence (gauntlet, all green).**

| Test | Required behaviour | Measured |
|---|---|---|
| `test_gauntlet_item7_washoutClocksChangeLabelsOnly` (`:862`) | 3 vs 14 days differ in label only; patient-says-clear | 3 d → `ended`, 14 d → `washingOut`, `expectedT`, `zTrialTraj`, `deltaTrialTraj` and the whole freeze identical; says-clear on day 2 of a 14-day washout → `ended` with the same z |
| `test_gauntlet_item7_onsetDaysDriveSettlingInOnly` (`:895`) | onset days drive settle-in only | onset 3 → `onTreatment`, onset 10 → `settlingIn` at t0+5; `expectedT` and freeze identical; `washInDaysUsed` 3 vs 10 |
| `test_gauntlet_item7_clinicNotesAreNotAnEngineInput` (`:916`) | notes never an input | notes `"Expect RHR to fall; HRV should rise. Watch for a drop."` → identical `expectedT`, `zTrialTraj` and summary |
| `test_gauntlet_item7_washoutStartsAtLastDoseWhenLaterThanStop` (`:934`) | clock starts at the later last dose | 10-day washout from a stop 20 days ago → `ended`; the same stop with `lastDose = T−3` → `washingOut`; `expectedT` identical |

Engine: `trialClock` (`LongitudinalBaselineTrial.swift:441-488`) reads `onsetDays ?? 7`, the stop's washout override
with the start form as fallback, `lastDoseDay` as the clock start, and `patientSaysClear` → `ended` before any day
arithmetic. No phase value is ever an input to `z` or `expected` (the freeze is built only from pre-t0 nights).

**Partial evidence — three product paths are missing.**
1. Mid-washout check-ins have no UI: `patientSaysClear` / `patientStillFeeling` can only be set at the moment of
   ending (`TreatmentMarkingView.swift:576-577` → `BaselineStore.swift:479-493`); the edit sheet cannot change them.
2. `.interruption` and `.restart` are never constructed by the app (the store writes only `.start`, `.dose`, `.stop`
   at `BaselineStore.swift:377, 450, 485`), so the engine's *"restart → back to Settling in"* branch
   (`LongitudinalBaselineTrial.swift:458-460`) is unreachable, and a dose/restart after an end is impossible
   (`activeStart` is nil once a stop exists, `BaselineStore.swift:459-466`).
3. The caption omits the required clock: *"Washing out — you entered N days after last dose."*
   (`BaselineMonitorView.swift:180`) has no `{time}`, and `ended` never renders on Baseline because `activeTreatment`
   excludes it (`BaselineStore.swift:171-176`).

**Risk: MEDIUM.** The math is correct and provably untainted by the clocks; the product cannot yet express the
patient-entered states the requirement is about.

---

## 9. Item 8 — predeclared primaries, no post-treatment fishing: **FAIL**

**Required proof** (`:309-313, 318, 348`): pick 1–3 primaries before saving; *"Editing primaries after the first
post-start `evaluate` requires a new trial id (no fishing in the UI)"*; every other series is exploratory and
*"cannot write the summary sentence"*; empty primaries → *"No primary series chosen — not judging a treatment
response."*; fixture: 12 series, 1 primary.

**Passing evidence at the engine layer (gauntlet, all green).**

| Test | Required behaviour | Measured |
|---|---|---|
| `test_gauntlet_item8_twelveSeriesOnePrimaryAndMovingExploratorySeries` (`:964`) | 12 series, 1 primary, moving exploratory series | exactly **1** summary sentence (`sleep_rhr`); 8 exploratory series were `aboveMdc == true` and none wrote a sentence or judged a response |
| `test_gauntlet_item8_emptyPrimariesDoNotJudge` (`:1019`) | empty primaries | summary is exactly `"No primary series chosen — not judging a treatment response."`, `judgingResponse = false`, while `aboveMdc = true` |
| `test_gauntlet_item8_frozenPrimaryListWinsOverAnEditedStartEvent` (`:1037`) | the list is frozen at t0 | the freeze carries `primarySeries = [.sleepRHR]`; an edited start event that pins `.wakingSteps` cannot promote it; no summary |

**Failing evidence — the app re-pins under the same trial id, which defeats the engine's only guard.**
`BaselineStore.setWatchList` (`:424-435`) rewrites `events[index].primarySeries` **and** `bundle.primarySeries`
inside every saved freeze bundle, then rescores — with the *same* `trialId`. The engine's anti-fishing rule is
`let primaries = freeze?.primarySeries ?? start.primarySeries` (`LongitudinalBaselineTrial.swift:736`), which is
safe only while the freeze's list is immutable; the store mutates it. So after the first post-start evaluate a
caregiver can un-pin the series that did not move and pin one that did, keeping the same freeze and the same trial
id, and the summary will then fire on the newly pinned series. The review names this exact behaviour (`:310`), and no
document in `Baseline/` mentions the new-trial-id rule.

**Partial evidence — the "refuse to pick" path is pre-empted.** `logStart` fills an empty primary list from
`suggestWatchSeries(...)` (`BaselineStore.swift:368-375, 389-393`), which ranks by established usual, TRUST and
night count (not by movement), so it is not *t0* fishing — but the review's "they refuse to pick primaries" case
(`:313`) cannot occur from the start form. `StrandTests/BaselineStoreTests.swift:414-426` locks the auto-pick in.
The honest sentence is reachable only by un-pinning all three later or when the ranking is empty at t0.

**Risk: HIGH.** The engine half of item 8 is the strongest part of the whole review pack, and it is bypassed by the
app two files away. This is the highest-value cheap fix in the report.

---

## 10. Cross-cutting findings (not owned by one item)

**C1 — The Baseline tab scores a fixed synthetic tape, not the wearer's data. HIGH for validation.**
`BaselineStore.displayDays(from repoDays:)` ignores its argument (`_ = repoDays`) and returns `Self.demoTape()`
(`Strand/Data/BaselineStore.swift:186-189`), a fixed 81-night tape with `asOf = 2026-09-11` (`:597`). Consequences:
every one of the 22 `BaselineStoreTests` tests the demo tape; the production data path is never exercised; the tab's
own copy says "Demonstration series so each period can be read." (`:182`, `BaselineMonitorView.swift:101`); and item
1's real-WHOOP row cannot be filled from the app as it stands. Nothing here is a crash — it is the reason this
baseline cannot yet be trusted on real data.

**C2 — CUSUM / hold state is never persisted. MEDIUM.** `rescore` always passes the default `.empty` carry
(`Strand/Data/BaselineStore.swift:233-234`), and nothing writes `LBCarry` anywhere. Today the online state is rebuilt
because the whole tape is replayed on every rescore; if the tape is ever truncated (retention, a device with a short
history, a new install), `S`, `runLength`, `twoOfThree` and `held` silently restart. Oct 2026 note: the engine is
deterministic (`test_gauntlet_repeatedEvaluationsAreDeterministicAndCarryThreaded`, `:1234`) and the replay walk
equals a hand-threaded carry chain, so the risk is a state-loss risk, not a math risk.

**C3 — The drawn longer hatch does not follow the expected path. MEDIUM.** After a freeze the right box's *number*
is path-aware (`BaselineStore.swift:280-288`) but the band under it is a constant `center ± k·spread` with
`held: true` (`:342-353`), and the long *plot* falls back to an evaluation computed with `trial: .none`
(`:239-243`), i.e. the no-treatment epoch-free view. Item 3's dashboard row (*"the longer hatch follows the path"*)
is therefore not met visually even though the engine exposes `expectedLong`.

**C4 — Engine outputs the app never reads. MEDIUM (dead UI surface).** `provenanceBreak`,
`primaryContrastEligible`, `isPrimarySeries`, `judgingResponse`, `gapVsPathDisplay`, `aboveMdc`/`sigmaMeas`/`mdc95`,
`missingness`, `deltaTrialLevel/Trajectory`, `washInDaysUsed`, `r1/r1Live/nEff/nEffLive` are computed and never
consumed by `Strand/`. Items 5 and 8 depend on two of those (`primaryContrastEligible`, provenance), which is how
C-something gaps above stay invisible in the product.

**C5 — Naming residue around CONFIDENCE. LOW.** `shortConfidence`/`longConfidence`
(`Strand/Data/BaselineStore.swift:290-296`) carry TRUST, `BaselineMonitorView.swift:327` keeps an unused
`confidence` plot parameter, `:450` a `confidenceColor` helper, and the engine still exports the legacy formula
(§5). No user-visible CONFIDENCE string exists.

**C6 — No Android surface. INFORMATIONAL.** `android/` has zero references to the baseline or treatment engine
(repo-wide grep), so the patient/caregiver parity promise is not met for the baseline feature (Charge still is).

**C7 — Unrelated app-test failure found while running the app target. LOW for this audit, real defect.**
`SkinTempAbsoluteDisplayTests.testTheSecondaryLeadsTheCaptionSoItSitsUnderTheValue`
(`StrandTests/SkinTempAbsoluteDisplayTests.swift:32`) fails on this host: expected `25 Aug` for `day: "2026-08-25"`,
got `24 Aug`. The caption renders a civil-day string in local time, so any host west of UTC sees the previous day.
Not caused by the baseline code and not caused by this audit; it is pre-existing work in the same dirty tree.

**C8 — The engine has no `worse`-direction output, so "improving" and "worsening" are indistinguishable in every
consumer.** Same root cause as item 2's dormant knob; listed separately because it affects the OFF copy for HRV,
SpO₂, temperature and steps.

---

## 11. Stress, edge-case and robustness results

All rows from `FRWhoopBaselineGauntletTests.swift` (`swift test --filter FRWhoopBaselineGauntletTests`).
Log: `/tmp/frwhoop_audit/gauntlet_run3.log`; extracted diagnostics: `/tmp/frwhoop_audit/gauntlet_diagnostics.txt`.

| Scenario | Test (`:line`) | Result | Evidence |
|---|---|---|---|
| Stable RHR / HRV / resp / steps tapes | `:131` | PASS | one FPR row per series, real row `not run yet` |
| 150-night stable tape denominator | `:152` | **FAIL (gap)** | counts 8 nights (`for back in 0..<8`) |
| 12-night plateau inside a stable tape | `:178` | **FAIL (gap)** | `p_change` 0.0 isolated vs 0.9454 online (`S` 0 vs 58.17) |
| Two-night spike (72 over 60) | `:289` | PASS | `zLong = 5.8`, week usual 60.67, `twoOfThree` |
| 21-day 0.3 bpm/day shift | `:307` | **FAIL (gap)** | `zLong = −2.23`, slope −0.0247, expected 64.86 vs today 60.4 |
| Window-spanning drift | `:335` | PASS | slope −0.3, `zLong = −0.12`, `pChange = 0` |
| 30-day cap (trial + live) | `:357`, `:374` | PASS | +90 d = L0 + 30·G0 = 75.0; >30-day-old long night → flat |
| CUSUM on detrended residuals | `:391` | PASS | `S = 0.0` on a ramp |
| Missing nights (3-night gap, full week) | `:1082` | PASS | 3-night gap → `n7 = 4`, `copy7.n = 4`, `z = nil`, centre 60.06 (not 0); full week → `copy7 = nil`, TRUST 0 |
| Late-arriving sample | `:1121` | PASS | `n7` 6 → 7, TRUST 86 → 100, today untouched; no zero fill |
| Empty / thin / stale history | `:1142` | PASS | empty → all nil, TRUST 0; 5 nights → `showLong = false`, `zLong = nil`, `alertEligible = false`; 20 days stale → TRUST 0 |
| Low-quality / out-of-range / slot gates | `:1173` | PASS | 45 low-quality long nights → `nLong = 8`, not established, TRUST 2 vs 75; 200 bpm → not data, band unmoved; 5-slot SpO₂ → missing; step `0` real |
| `sleepHrOnly` night | `:1222` | PASS | `low_quality/sparse_sleep` |
| Repeated evaluation / carry threading | `:1234` | PASS | identical evaluations; replay `S` == hand-walked `S` |
| 1-year tape, full re-score (`measure`) | `:1257` | PASS (measurement) | **2.451 s** average, RSD 0.17 %; peak physical memory **66.2 MB** average (74.6 MB max) |
| 3-year tape, 6 wired series | `:1267` | PASS | **8.62 s** total = 7.87 ms per tape-night per series |

**Performance note.** The engine replays the whole tape on every `evaluate(replay: true)` (`LongitudinalBaseline.swift:729-751`),
so cost grows linearly with the wearer's history: ~2.4 s for a year and ~8.6 s for three years of 6-series re-score
on this machine, with 66 MB peak. A phone-class CPU is several times slower, and the app re-scores on every series /
period change (`BaselineStore.selectSeries`, `selectContext`, `shiftLongWeek`). No memory leak or unbounded growth
was observed across repeated evaluations, and no test exceeded its bound. This is a responsiveness risk, not a
correctness one.

---

## 12. Real WHOOP 5.0 calibration row: **NOT RUN**

No real WHOOP data was present or used. Nothing was fabricated: the item-1 table is synthetic-only and each row
prints `real … not run yet` (`LongitudinalBaselineReview.swift:275`). As long as this row is empty, item 2's `k`
values remain placeholders (per the review's own rule, `:22, 58`) and Pulse ±1.65 / Cadence |z| ≥ 1.5 must not be
adopted from this baseline. The app cannot currently produce a real tape either (C1).

---

## 13. Prioritized fix list — required before trusting this baseline on real WHOOP data

Ordered by risk × effort. "Fix" = code; "cap" = honest limitation to document until fixed. Each item names the
failing gauntlet row (if any) that will turn green.

**P0 — wrong physiology will be shown or claimed**

1. **Make the slow-shift fixture pass (item 3).** Anchor the longer path at the newest usable nights instead of the
   window midpoint, and let the drift fit see the nights inside the 7-day gap.
   - `LongitudinalBaseline.swift:1174-1175` — set `origin` to `lastLongNight` (or fit the slope on a shorter,
     recent block) so `dt` in `expectedOnPath` is measured from the last usable night.
   - `LongitudinalBaselineReview.swift:130-139` — keep the ±30 clamp but make the cap relative to `lastNight`
     (`LongitudinalBaseline.swift:1185`), which is already the horizon rule.
   - `LongitudinalBaseline.swift:1130` — consider a shorter slope window (e.g. 28 nights) or a two-block
     newest-vs-oldest slope check, so a 21-day ramp is representable.
   - Row to green: `test_gauntlet_item3_slowShiftThreeWeeksIsNotStuckOff`.
2. **Close the primary-fishing hole (item 8).** `BaselineStore.setWatchList` (`:424-435`) must not rewrite
   `freeze.primarySeries`; a post-start primary change must create a new `trialId` and a new freeze (review `:310`).
   Keep the engine guard at `LongitudinalBaselineTrial.swift:736` as the last line of defence and add a store test
   that the same trial id cannot re-pin.
3. **Feed provenance, or refuse to score across a break (item 5).** Pass `provenanceNow` in
   `BaselineStore.rescore` (`:231-232`) from the live device/decoder metadata, persist the freeze with the provenance
   in force at t0, surface `provenanceBreak` and add the "Device or math changed" copy.
   Row to green: `test_gauntlet_item5_provenanceBreakAfterStartIsNotScoredAsChange` (app-wiring assertion).
4. **Make item 1's counter real (item 1).**
   - Walk the stable stretch instead of `for back in 0..<8` (`LongitudinalBaselineReview.swift:251`), and classify
     each day with online state (`replay: true`, or a threaded carry) so `p_change` is not vacuous (`:253-254`).
   - Print per-series **rates** (`rateLonger`, `offThisWeek/rate`, `twoOfThree`, `aboveMdc`) — `:271-278`.
   - Add the filter conditions the review names: no confounder input, slope flat or residuals in-band (`:248-256`).
   - Keep the empty `real WHOOP 5.0 — not run yet` **row**, and add the three named fixtures
     (`stable_rhr_60`, `stable_hrv`, `stable_resp`) to `Baseline/packages`/`Baseline/fixtures/`.
   - Rows to green: `test_gauntlet_item1_stableDayCountCoversTheWholeStableStretch`,
     `test_gauntlet_item1_printedTableCarriesPerSeriesRates`,
     `test_gauntlet_item1_stableGatePChangeIsNotVacuous`.

**P1 — required display or copy is missing**

5. **HOW OFF on the longer box (item 4).** Remove `var longHowOff: Int? { nil }`
   (`BaselineStore.swift:303-304`) and pass the long copy's HOW OFF (or "NOT ENOUGH NIGHTS" under TRUST < 35) into
   `BaselineMonitorView.swift:84`. If the product still wants it hidden, that decision needs a written reconciliation
   against the acceptance row (`:152-155, 228, 344`) and, until then, item 4 stays PARTIAL.
   Row to green: `test_gauntlet_item4_cardShowsTrustAndHowOffWithoutLegacyConfidence`.
6. **Score the longer box from one source (item 4).** Derive `longConfidence`, `longVerdict` and the plot from the
   same evaluation (`BaselineStore.swift:239-243, 294-296, 323-328`), and draw the hatch on the expected path instead
   of a held flat band (`:342-353`, C3).
7. **Wire the patient-entered states (item 7).** Add the mid-washout check-ins, `.interruption`/`.restart`, and a
   dose/restart path after an end; show the last-dose clock in the caption (`BaselineMonitorView.swift:180`);
   make `ended` render a phase label on Baseline (`BaselineStore.swift:171-176`).
8. **Show the three numbers while settling in (item 6).** Stop gating the trial block on `trialFreezeOk` only
   (`BaselineMonitorView.swift:97-99`); the engine already has `expectedT`, `zTrialLevel`, `zTrialTraj`.
9. **Do not hide the disclaimer (item 5).** The non-causal sentence should be on the trial surface whenever a course
   is active, not only after a freeze qualifies (`:97-99, 206`).

**P2 — correctness hygiene and drift**

10. **Consume or delete the three dormant knobs (item 2):** `worse` (needs a direction-aware output before any "OFF"
    copy can distinguish improving from worsening, C7), `primaryOff`, `spo2EstablishExtraNights` (replace the
    hardcoded `okSlots < 10` in `LongitudinalBaselineTrial.swift:567-570`).
11. **Fix the freeze's `r1`/`n_eff` (item 6, caveat 1):** compute them on detrended residuals
    (`LongitudinalBaselineTrial.swift:610-611`) to match `scoreOneDay` (`LongitudinalBaseline.swift:1341-1345`).
12. **Move the confounder/freeze TRUST factors into the inputs (item 4):** pass real
    `confoundToday`/`freezeOk` into `LBTrustInputs` (`LongitudinalBaseline.swift:1350-1357`) instead of applying
    post-hoc multipliers, so any future caller of `scoreOneDay` gets the same TRUST.
13. **Remove or quarantine the legacy CONFIDENCE path (item 4):** `confidencePct7/Long`, its ledger keys and its
    `.phaseA` registry row (`LongitudinalBaseline.swift:333-334, 447-448, 627-628, 1064-1090`), and the two tests
    that pin it. Keep one archived formula only if a migration needs it.
14. **Retire the demo tape from the scored path (C1)** and add an app test that `displayDays` follows
    `Repository.days`; until then keep the "Demonstration series" copy prominent.
15. **Persist the carry (C2)** or document that the engine requires a full replay from the earliest retained night.
16. **Unify the cap rule** for `dTraj7` (`LongitudinalBaselineTrial.swift:773`) with `expectedUntreated`.
17. **Align the stale contract docs (`CONDENSED_PLAN`, `IMPLEMENTATION_PROGRESS`) with the review** (global `k`,
    global 7-day washout, `confidence_pct_*`, no primaries) so the next reader does not implement the superseded
    contract.
18. **Add the missing proof rows to the durable test pack** rather than leaving them only in this audit file:
    per-series FPR rates, the 21-day shift, HRV-vs-RHR TRUST, path-vs-flat gaps, provenance, 3-vs-14 washout with
    identical z, 12-series/1-primary, and the flat-model sentence.

---

## 14. Appendix

### 14.1 Gauntlet test inventory (47 tests; 41 pass, 6 fail)

`Packages/StrandAnalytics/Tests/StrandAnalyticsTests/FRWhoopBaselineGauntletTests.swift`

| Line | Test | Result |
|---|---|---|
| 131 | `test_gauntlet_item1_stableFPRTableHasOneRowPerSeriesAndRealRowNotRun` | pass |
| 152 | `test_gauntlet_item1_stableDayCountCoversTheWholeStableStretch` | **FAIL (gap)** |
| 165 | `test_gauntlet_item1_printedTableCarriesPerSeriesRates` | **FAIL (gap)** |
| 178 | `test_gauntlet_item1_stableGatePChangeIsNotVacuous` | **FAIL (gap)** |
| 201 | `test_gauntlet_item2_paramsTableMatchesTheReviewStartingTable` | pass |
| 228 | `test_gauntlet_item2_respExcursionIsJudgedWithRespsOwnK` | pass |
| 245 | `test_gauntlet_item2_hrvDropIsNotForcedThroughRHRsK` | pass |
| 260 | `test_gauntlet_item2_establishCountDiffersBySeriesAndIsUsed` | pass |
| 274 | `test_gauntlet_item2_thisWeekWindowFollowsTheSeriesSpan` | pass |
| 289 | `test_gauntlet_item3_spikeTwoNightsIsOffLongerUsualAndDoesNotTrainTheWeekTo72` | pass |
| 307 | `test_gauntlet_item3_slowShiftThreeWeeksIsNotStuckOff` | **FAIL (gap)** |
| 335 | `test_gauntlet_item3_slowShiftAcrossTheLongWindowIsNotStuckOff` | pass |
| 357 | `test_gauntlet_item3_thirtyDayProjectionCap` | pass |
| 374 | `test_gauntlet_item3_horizonBeyondLastLongNightDropsTheProjection` | pass |
| 391 | `test_gauntlet_item3_cusumRunsOnDetrendedResiduals` | pass |
| 410 | `test_gauntlet_item4_howOffMatchesStudentTTable` | pass |
| 427 | `test_gauntlet_item4_fullWeekInBandHasHighTrustAndLowHowOff` | pass |
| 438 | `test_gauntlet_item4_fullWeekOffHasHighTrustAndHighHowOff` | pass |
| 456 | `test_gauntlet_item4_threeNightsHasLowTrust` | pass |
| 476 | `test_gauntlet_item4_hrvTrustIsLowerThanRhrTrustOnTheSameCoverage` | pass |
| 497 | `test_gauntlet_item4_trustMovesForTonightQualityStalenessFreezeAndConfounder` | pass |
| 553 | `test_gauntlet_item5_confounderListAndNonCausalSentence` | pass |
| 572 | `test_gauntlet_item5_chippedDayIsIneligibleButStillVisible` | pass |
| 600 | `test_gauntlet_item5_provenanceBreakAfterStartIsNotScoredAsChange` | **FAIL (gap)** |
| 639 | `test_gauntlet_item5_preexistingRecoveryPathGapBeatsFlatGap` | pass |
| 666 | `test_gauntlet_item5_startTimeIsNeverInferredFromHeartRate` | pass |
| 697 | `test_gauntlet_item5_noCausalLanguageInTrialCopy` | pass |
| 724 | `test_gauntlet_item6_freezeStoresTheModelNotJustALevel` | pass |
| 757 | `test_gauntlet_item6_thinSlopeFreezesAFlatModelAndSaysSo` | pass |
| 777 | `test_gauntlet_item6_postStartComparisonUpdatesEveryNight` | pass |
| 808 | `test_gauntlet_item6_phaseAwareSummaryAndTitles` | pass |
| 862 | `test_gauntlet_item7_washoutClocksChangeLabelsOnly` | pass |
| 895 | `test_gauntlet_item7_onsetDaysDriveSettlingInOnly` | pass |
| 916 | `test_gauntlet_item7_clinicNotesAreNotAnEngineInput` | pass |
| 934 | `test_gauntlet_item7_washoutStartsAtLastDoseWhenLaterThanStop` | pass |
| 964 | `test_gauntlet_item8_twelveSeriesOnePrimaryAndMovingExploratorySeries` | pass |
| 1019 | `test_gauntlet_item8_emptyPrimariesDoNotJudge` | pass |
| 1037 | `test_gauntlet_item8_frozenPrimaryListWinsOverAnEditedStartEvent` | pass |
| 1082 | `test_gauntlet_missingNightsAreGapsNotZeros` | pass |
| 1121 | `test_gauntlet_lateArrivingSampleChangesTheScore` | pass |
| 1142 | `test_gauntlet_emptyThinAndStaleHistoriesStayQuiet` | pass |
| 1173 | `test_gauntlet_lowQualityOutOfRangeAndSlotGates` | pass |
| 1222 | `test_gauntlet_sleepHrOnlyNightIsLowQuality` | pass |
| 1234 | `test_gauntlet_repeatedEvaluationsAreDeterministicAndCarryThreaded` | pass |
| 1257 | `test_gauntlet_performance_measureOneYearRescore` | pass |
| 1267 | `test_gauntlet_stress_threeYearTapeStaysBounded` | pass |
| 1292 | `test_gauntlet_item4_cardShowsTrustAndHowOffWithoutLegacyConfidence` | **FAIL (gap)** |

### 14.2 Existing baseline test suites (inventory summary)

| File | Tests | Notes |
|---|---|---|
| `LongitudinalBaselineTests.swift` | 37 | Phase A math; strongest on windows/EWMA/borrowed spread; pins the legacy `confidencePct7` formula at `:196` |
| `LongitudinalBaselineMethodsTests.swift` | 16 | one test per registry row; pins the legacy formula at `:202`; `slopeLong`/`expectedLong` values never asserted |
| `LongitudinalBaselineReviewTests.swift` | 10 | the review pack; item 1 has no rate assertion (`:205-222`), item 6's core asserts sit inside `if slopeUsable` (`:136-139`), item 4 never asserts HRV vs RHR TRUST (`:113-117`), item 7 compares only `expectedT` (`:174-176`) |
| `LongitudinalBaselineTrialTests.swift` | 17 | freeze/qualify/clock coverage; only `decoderVersion` provenance variation (`:205, 211`) |
| `LongitudinalBaselineCatalogTests.swift` | 11 | catalog/ledger pinning; prints HRV span-10 numerics without asserting (`:276`) |
| `StrandTests/BaselineStoreTests.swift` (app) | 22 | 22/22 pass; 4 are smoke-level (`:91`, `:312`, `:354`); none asserts `primaryContrastEligible`, `provenanceBreak`, `gapVsPathDisplay`, MDC or the disclaimer text; `:69` and `:403` lock in the hard-nil `longHowOff`; `:414-426` locks in the primary auto-pick |

Per-requirement STRONG-test counts in the pre-existing pack: item 1 → 0, item 2 → 17, item 3 → 14, item 4 → 0
(the two that look strong pin the *legacy* formula), item 5 → 2, item 6 → 3, item 7 → 4, item 8 → 0.

### 14.3 Artifacts

| Path | Contents |
|---|---|
| `/tmp/frwhoop_audit/swift_test_full.log` | package suite before the gauntlet: 1973 tests, 0 failures |
| `/tmp/frwhoop_audit/swift_test_with_gauntlet.log` | package suite after: 2020 tests, 6 failures |
| `/tmp/frwhoop_audit/gauntlet_run3.log` | gauntlet run (47 tests, 6 failures) with all assertions |
| `/tmp/frwhoop_audit/gauntlet_diagnostics.txt` | 55 extracted diagnostic lines (ITEM/MISSING/LATE/…/STRESS) |
| `/tmp/frwhoop_audit/xcode_baselinestore_test.log` | `BaselineStoreTests`: 22 tests, 0 failures, `** TEST SUCCEEDED **` |
| `/tmp/frwhoop_audit/xcode_full_strandtests.log` | full `StrandTests` app target run |
| `/tmp/frwhoop_audit/w1_docs_map.md` | documentation → requirement map (claim vs proof) |
| `/tmp/frwhoop_audit/w2_app_side.md` | app-layer audit (store, views, persistence, 22 app tests) |
| `/tmp/frwhoop_audit/w3_test_inventory.md` | per-test inventory + missing proof cases |

### 14.4 What this audit did **not** verify

- Real WHOOP 5.0 tapes (item 1's empty row) — **NOT RUN**, nothing fabricated.
- iOS/Android runtime behaviour; no Android surface exists.
- SwiftUI rendering (no snapshot or view tests exist); item 4's label audit is a source-text check.
- Push/Edge/Supabase conformance (out of scope for this baseline).
- Cross-device persistence round-trips: every `BaselineStoreTests` case builds a fresh `UserDefaults` suite, so no
  test re-instantiates the store to prove events/freezes/chips survive a relaunch.
- Long-run stability of the replay cost on a real device (measured here on an M-series macOS host only).
- The whole app test target needed three attempts (rows E, E2, F, G in §1). Attempts 1-2 were killed while the run sat
  in `StrandTests/BugReportTemplateTests.testAttachZipCheckboxPresent`, which costs **1346 s on its first execution in a
  session** and 0.013 s afterwards; the case reads `.github/ISSUE_TEMPLATE/bug_report.yml` **by absolute path derived
  from `#filePath`** (`StrandTests/BugReportTemplateTests.swift:11-17, 49-53`), outside the sandboxed test host's
  container. Attempt 3 completed the target in 12.2 s with 1613 tests, 1 skipped and **1 unrelated failure**
  (`SkinTempAbsoluteDisplayTests`, see C7). Recommend resolving that YAML from the bundle or a repo-relative path so the
  suite has no multi-minute cold-start case.

### 14.5 App-target run notes (facts, including one correction)

The whole app test target **does** complete: attempt 3 ran **1613 tests, 1 skipped, 1 failure in 12.2 s**
(`/tmp/frwhoop_audit/xcode_full_strandtests3.log`), with all 22 `BaselineStoreTests` green inside it.

Two earlier observations needed correcting, and both are recorded here rather than deleted:

1. *"Stall."* Attempts 1-2 (killed at ~7 min) looked stalled because the run sat in
   `BugReportTemplateTests.testAttachZipCheckboxPresent`. That case is not slow by design: it takes **1346 s** on its
   first execution in a session and **0.013 s** on the next (`/tmp/frwhoop_audit/xcode_bugreport.log` vs attempt 3).
   The case reads `.github/ISSUE_TEMPLATE/bug_report.yml` through an absolute path derived from `#filePath`
   (`StrandTests/BugReportTemplateTests.swift:11-17, 49-53`), i.e. outside the sandboxed test host's container, so the
   first access pays a long one-time OS cost (macOS TCC/sandbox prompt). The audit observed the duration; it did not
   instrument the OS to prove the cause.
2. *One unrelated app failure.* `SkinTempAbsoluteDisplayTests.testTheSecondaryLeadsTheCaptionSoItSitsUnderTheValue`
   fails at `StrandTests/SkinTempAbsoluteDisplayTests.swift:32` on this host:
   `XCTAssertTrue failed - the day must still be there - got +0.9 Δ°F · 24 Aug · vs baseline · Typical range`.
   The expectation is `"25 Aug"` for `day: "2026-08-25"`, so the caption formats a civil-day string in local
   time (this host is America/Los_Angeles) and lands on the previous day. It is **not** a longitudinal-baseline
   failure (the baseline does not touch `BodyVitalReading.stateCaption`), it is pre-existing uncommitted work
   (the skin-temp change is in the same dirty tree), and it is flagged here only because the required audit command
   set includes app tests. Worth a separate fix: a west-of-UTC user can see the wrong day on the skin-temp tile.
