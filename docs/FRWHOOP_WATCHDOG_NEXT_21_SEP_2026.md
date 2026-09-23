# Watchdog — twelve review items, as shipped (21 Sep 2026)

**For review.** This is the implementation record of the twelve Watchdog requests. It describes **what is in the iPhone app now** (`config_version = watchdog-v2.2`), not a future plan.

Keep copies in sync in git: `docs/FRWHOOP_WATCHDOG_NEXT_21_SEP_2026.md` and `Packages/StrandAnalytics/Baseline/FRWHOOP_WATCHDOG_NEXT_21_SEP_2026.md`.

**Hard rules (unchanged by all twelve items).** Charge and Recovery are not rewritten. Watchdog never writes Layer 1 usuals. It never infers a medication start (`t0`) from heart rate. It never names a drug or a disease. Scoring is on-device. Wrist-off is **unavailable**, not “recovered.” There is **no on-device training**; Core ML packages are frozen.

**What the wearer sees (Baseline → Live baseline).** Six equal vitals: heart rate, resting HR, HRV, wrist temp, breathing, SpO₂. Dotted line = reconstructed usual for this half-hour. Green band = calibrated \(\sigma\) around that line. Banner: **On** plus an activity class when IMU/steps support it (for example `On · Walking`). Heart rate caption is **Pulse · awake usual**. Resting HR caption is **Still minutes · sleep usual**. TRUST % is how much to believe the in/out call, not a diagnosis. Local notification only on **severe episode start**, **safety**, or **escalation** — not a 30-minute mute.

**Live loop (every 20 s, one function).** `WatchdogService.tick` → `WatchdogWindowBuilder.build` → `Watchdog.evaluate`:

1. `WatchdogQuality.gate` — if this fails, stop (no models, no notify).
2. `UniTSRuntime.reconstruct` — trained UniTS-AD Core ML, or Swift prior if the package cannot load.
3. `WatchdogAdaptive` — personal quiet \(\sigma\), artifact, still HR↔HRV correlation.
4. `WatchdogForecastRuntime` — TimesFM student at most once per minute.
5. `WatchdogScores` — joint \(J\), fused \(J\), severity vs calibrated \(T\).
6. `WatchdogSafety` — still-wrist extrema, can force severe without the models.
7. `WatchdogNotifyPolicy` — episode start / stable / escalate / safety.

Gate: `cd Packages/StrandAnalytics && swift test --filter Watchdog` (76 tests).

---

## 1. Split safety / data quality, learned physiology, and notify policy

### Request

The combiner must not mix three jobs: (a) hard data-quality and safety, (b) learned physiology, (c) whether to fire a banner. Mixing them produced weak TRUST on junk windows and mute rules that hid real events.

### Plan

Keep a single evaluate so the UI does not grow a second loop. After a successful 30-minute `build`, run quality. Only a passing window is reconstructed. Safety is a pure extrema check (no Core ML). Notify is a separate policy on the resulting severity and \(J\).

### In the app now

| Type | File | Job |
|---|---|---|
| `WatchdogQuality.gate` | `WatchdogV2.swift` | Coverage, freshness, empty-minute gap → `WatchdogUnavailable` |
| `UniTSRuntime` + `WatchdogForecastRuntime` | `UniTSRuntime.swift`, `WatchdogV2.swift` | Physiology |
| `WatchdogSafety.fired` | wraps `Watchdog.safetyCap` | Still-wrist HR / temp / resp / RMSSD bounds |
| `WatchdogNotifyPolicy.decision` | `WatchdogV2.swift` | Banner yes/no + reason string |

`WatchdogResult.qualityGate` is `"bucket-v1"` on a live scorable tick, or the unavailable reason (`wristOff`, `coverage`, `stale`, `gap`, `empty`) when the gate fires. Test Centre prints `qualityLine`, which includes **`units-ad-coreml-v2`** or **`prior fallback`** so a missed package is not silent. `WatchdogService` is still the only 20 s timer.

---

## 2. Train a real multivariate reconstructor (UniTS-AD job)

### Request

Do not ship occupancy equations labeled as UniTS. Train a reconstruct-then-residual model for this 30×6 wearable strip.

### Plan

Train offline in `Tools/units-watchdog/train_export.py`. Export `UniTS_AD.mlpackage` with `hat` and `sigma`. Keep `UniTSRuntime.reconstruct(window, prompt)` as the only API the combiner knows. Do not require Harvard UniTS transformer weights.

### In the app now

On iPhone/Mac, `UniTSCoreMLSession` loads the package **once**, compiles it, and runs on **`cpuAndNeuralEngine`**. Inputs: occupancy (1×30 class-effort), prompt (1×6 usuals), personal_scale (1×6), observed (1×6×30). Outputs: `hat` and `sigma` (1×6×30). Channel order: HR, RHR, HRV, temp, resp, SpO₂. `model_version = units-ad-coreml-v2`.

If load or predict fails (watchOS cannot `compileModel`), `priorResidual` runs and `qualityLine` says **prior fallback**. That tick is still scored; it is not marked recovered. The binary still **contains** the trained package.

**Honesty.** Joint \(J\) is computed in Swift from the six residual energies of that Core ML (or prior) strip. The package does not emit a separate `joint` tensor. The detector is still the trained mixer’s reconstruction, not six independent occupancy slopes.

---

## 3. Per-vital 0.50×HR / HRV / resp rules are priors, not the detector

### Request

Karvonen-style \(0.50 R \times \mathrm{occ}\), Chen HRV drop, lagged temp, and resp lift must not remain the long-term Watchdog.

### Plan

Keep those formulas as a cheap Swift **prior** (training teacher + crash-safety). The wearer is scored against **model hat** when Core ML loads.

### In the app now

`UniTSRuntime.priorResidual` (alias `physicsResidual`) still implements:

- HR: \(R + 0.50 R \times \mathrm{occ}_{\mathrm{effort}}\)
- RHR: flat sleep usual
- HRV: still RMSSD minus occupancy-scaled drop
- Temp: −0.15 × lagged occupancy
- Resp: \(+ 0.60 f_0 \times \mathrm{occ}\)
- SpO₂: flat usual (no predicted hypoxia)

The live dotted line and green band on a phone with the package loaded are Core ML `hat` ± `sigma`, then WatchdogAdaptive. Inject severe (96 / 16 / 34.3 / 22) still exceeds \(T_{\mathrm{severe}}\) under that head.

---

## 4. Joint physiology, not six independent tests

### Request

A combination (HR up, HRV down, resp up) can be unusual with no single extreme. Severity must not be “OR of six 2× tests.”

### Plan

One multivariate forward. Swift bridge \(J = \max(\|z\|_2/\sqrt{6},\; \max_i |z_i|)\). Per-row In/Out still uses that channel’s \(z\). Two Layer 1 usuals are never averaged into a joint “safe” point.

### In the app now

`WatchdogScores.joint` on the six energies → `WatchdogResult.jointEnergy`. Severity uses **fused \(J\)** vs calibrated \(T\) (item 6), or safety (item 11). The card still flips In/Out per vital for display. Contributing names (`HR`, `HRV`, …) are which channels are above \(T_{\mathrm{note}}\), not a count that defines notify.

---

## 5. Calibrate \(\sigma\) / the green band

### Request

The green band must be a residual interval with statistical meaning. Never set \(\sigma\) from **this** window’s scatter (that hides a flat rest tachycardia).

### Plan

Ship `WatchdogCalibration.json`: `quiet_coverage` 0.95, per-channel `sigma_scale`, `cold_start_gain` 2.5. After enough quiet ticks, a Watchdog-only EMA of |x − hat| floors \(\sigma\). Not Layer 1 MAD as the only width, and not written into usuals.

### In the app now

Runtime: \(\sigma = \sigma_{\mathrm{model}} \times \mathrm{scale}[c] \times (2.5\ \mathrm{if\ that\ channel\ has\ no\ personal\ usual})\). File `Packages/StrandAnalytics/Baseline/units/WatchdogCalibration.json` is checked against Swift in `testHardCalibrationFileMatchesSwift`. `scale` is currently **1.0** on every channel: the trained mixer already emits \(\sigma\); the JSON temperature is identity until an offline quiet-tape sweep retunes it.

`WatchdogAdaptive` then:

- EMA-updates quiet |x − hat| when joint energy is below \(T_{\mathrm{note}}\) **or** the last paired residual is inside \(1\sigma\)
- after **8** quiet ticks, that EMA is a floor under \(\sigma\) (`sigmaAdaptive = true`)
- **artifact** class multiplies \(\sigma\) by 1.7 and damps \(J\) (tremor is not a physiology page)
- **still** windows: HR off + HRV quiet widens (uncoupled); both off tightens (expected correlation)

This-window SD is never \(\sigma\). Tests: `testPredictedScaleIsNotThisWindowScatter`, `testQuietTicksAdaptSigmaFloor`, `test14ArtifactWidensAdaptiveSigma`.

---

## 6. Calibrate thresholds (stop universal 1× / 2×)

### Request

Hot ≥ 1 and “three vitals at 2×” are arbitrary until \(\sigma\) is calibrated. Thresholds should come from quiet / workout / transition / inject behavior, then a personal quiet-\(J\) offset.

### Plan

Put \(T_{\mathrm{note,active,severe}}\), persist, escalate \(\Delta\), re-arm, and forecast \(\alpha\) in the same calibration file. TRUST uses energy / \(T_{\mathrm{note}}\). Delete three-channel counting.

### In the app now

| Knob | Value |
|---|---|
| \(T_{\mathrm{note}}\) | 1.0 |
| \(T_{\mathrm{active}}\) | 1.6 |
| \(T_{\mathrm{severe}}\) | 2.4 |
| persist ticks | 2 (40 s at 20 s/tick) |
| escalate \(\Delta\) | 0.5 |
| re-arm ticks | 15 (~5 min) |
| forecast \(\alpha\) | 0.5 |

`WatchdogScores.severity`: safety → severe; Daily-log confound → at most candidate; else map fused \(J\) + persist through those \(T\). After 8 quiet ticks, fused \(J\) is reduced by \(\min(0.4, \mathrm{quietJointEma})\) so a calm wearer is not scored on a population \(T\) forever.

`WatchdogConfig.tau` / `tauSevere` remain **display** floors for an empty band, not the notify rule. Tests: `test06ThresholdsComeFromCalibrationNotThreeChannels`, `test11SustainedStillTachycardiaCanSevereWithoutThreeVitals`.

---

## 7. Episode notify, not a 30-minute mute

### Request

Notify at the start of a severe episode. Do not re-page while the picture is stable. Re-page immediately if \(J\) jumps or a hard safety cap newly fires. Re-arm only after a **sustained** in-range stretch. Delete `notifyCooldownSeconds = 1800`.

### Plan

`WatchdogNotifyPolicy.decision`. Card recovering/resolved can still flip after two quiet ticks (~40 s). **Notify re-arm** waits `rearm_ticks` before clearing `episodeId`. Escalate follows **reconstruction** \(J\), not forecast skill (otherwise TimesFM would re-page every 20 s).

### In the app now

| Event | Notify? | `notifyReason` |
|---|---|---|
| Not severe | No | `not-severe` |
| New `episodeId` and severe | Yes | `episode-start` |
| Safety newly true | Yes | `safety` |
| Recon \(J\) rose ≥ 0.5 | Yes | `escalate` |
| Same episode, recon \(J\) stable | No | `stable-episode` |
| `dataUnavailable` | No | `unavailable` |

`WatchdogConfig.notifyCooldownSeconds = 0`. `lastNotifiedAt` is stored and **does not mute**. `episodeId` stays until 15 consecutive in-range ticks, so a two-tick “resolved” on the card does not immediately allow a duplicate start banner. `WatchdogNotifier` posts only when `shouldNotify` is true. Tests: `test07StableSevereDoesNotRepageAndEscalateDoes`, `testHardLastNotifiedAtDoesNotMute`, `testHardSafetyPagesDuringStableEpisode`.

---

## 8. Coverage / freshness must fail closed

### Request

A window with too few minutes or a stale last HR must be **unavailable**, not an anomaly with low TRUST. WHOOP 5 (~30 s) and sparse WHOOP 4 live must still score.

### Plan

Gate on **filled 60 s buckets / 30**, not unique-seconds / 1800 (that would fail a 30 s 4.0 tape). Freshness: 60 s (WHOOP 4), 90 s (WHOOP 5). Consecutive empty minutes ≥ 6 → `.gap`.

### In the app now

`WatchdogQuality.gate` after `build`:

- `bucketCoverage < 0.80` → `.coverage`
- `newestAgeSeconds` above family limit → `.stale`
- `maxEmptyMinutes ≥ 6` → `.gap`

No reconstruct, no TimesFM, no notify. Card: Waiting / not recovered. Sparse 30 s WHOOP 4 still fills 30 buckets (`testSparseWhoop4CadenceStillDisplays`, `test08Whoop5AndSparseWhoop4StayScorable`). Five HR minutes → unavailable (`test08FewMinuteBucketsIsUnavailableNotHot`). TRUST **C** still uses coverage only on **scorable** windows.

---

## 9. Cold start must not hide a stable shift

### Request

Do not use the current 30-minute median as a usual (a stable 96 bpm would look “normal”). Do not park daytime pulse on overnight RHR. Population prior + wide \(\sigma\). Instant HR and resting HR are different copies.

### Plan

`WatchdogPopulationPriors` (HR 60, RMSSD 40 ms, temp 33 °C, resp 14, SpO₂ 97). Prompt: **HR** = shown awake-rest or continuous only; **RHR** = sleep RHR only. Missing channel → that channel’s \(\sigma \times 2.5\). Sleep HRV used while awake → TRUST cap 28 and inflated HRV \(\sigma\). Never write priors into Layer 1.

### In the app now

`UniTSPrompt.from`:

- `hr` from `awakeRestHR` / `continuousHR` with TRUST ≥ 35. Sleep RHR **cannot** fill this slot (`testPromptNeverFillsInstantHRFromSleepRHR`, `test12PromptKeepsHRAndRHROnSeparateCopies`).
- `rhr` from `sleepRHR` only.
- `hrvAnchoredInSleep` when overnight HRV exists and awake-rest HRV does not.

`resolvedBases` uses population numbers, not window median (`testMissingUsualUsesPopulationPriorAndWideBand`, `test03MissingPromptUsesPopulationNotWindowMedian`). Window RHR minutes drop walk / run / cycle / lift / artifact (`restHr` in `WatchdogWindow.swift`). TRUST: no number → cap 18; no shown usual → cap 28; sleep-anchored HRV → cap 28 even if overnight TRUST is high. Reconstruct HR comment and code no longer mention median fallback.

---

## 10. Motion is an activity embedding, not occupancy 0–1

### Request

Walking, running, lifting, standing, tremor, and motion artifact can share magnitude and differ in physiology. Need an activity/context embedding and auto-workout context. Use Jev or GitHub only if they map onto the same classes on this strap.

### Plan

Freeze **K = 8**: still, stand, walk, run, cycle-like, resistance, artifact, unknown. Occupancy remains a covariate. Missing IMU → **unknown** one-hot (tensor shape never changes). Artifact widens \(\sigma\) / damps \(J\). In-tree Auto Workout as a 0/1 overlap bit. Jev wants ~100 Hz IMU; WHOOP gravity here is ~1 Hz, so Jev is **not** wired.

### In the app now

`WatchdogService` loads gravity as `WatchdogIMUSample` (x, y, z, `dynAccel`) and `stepSamples`. `WatchdogActivityRuntime.embed` builds 30×8 logits from IMU, step `@63` class (0 still / 1 walk / 2 run), occupancy, and HR. Last 10 minutes may blend `WorkoutTypeClassifier` (same Auto Workout type job). `AutoWorkoutDetector` overlap is a length-30 0/1 vector on the window; still/unknown minutes overlapping a bout are nudged toward **walk**.

Effort occupancy into UniTS (so similar magnitude is not similar physiology):

| Class | Effort occupancy |
|---|---|
| still / stand / artifact | 0 |
| walk | 0.32 |
| resistance | 0.42 |
| cycle-like | 0.55 |
| run | 0.85 |
| unknown | raw gravity 0…1 |

Banner shows the class when it is not unknown. Tests: `test10ActivityLogitsAreAlwaysPresentUnknownClass` (no IMU → unknown), `test13SameOccupancyWalkVersusRunUsesClassEffort` (same 0.40 occupancy, walk vs run split).

**Honesty.** The Core ML graph still consumes a **30-long occupancy vector**, not a 30×8 logit cube. The embedding is applied **before** the net as class-effort occupancy plus window logits for \(\sigma\) / RHR gating / UI. A later package can take logits without changing evaluate.

---

## 11. Multivariate score vs “three abnormal vitals”; keep hard safety

### Request

Keep a hard safety lane for one-channel extrema (still rest tachycardia). Learned severe is joint \(J\) vs \(T\), including 1–2 channel events. Delete “three channels at 2×.”

### Plan

1. Safety → severe (and may notify even in a stable episode if the cap **newly** fires).
2. Else Daily log confound → note / candidate.
3. Else \(J\) + persist through \(T\). One large \(z\) can severe because \(J \ge \max_i |z_i|\).

### In the app now

`Watchdog.safetyCap`: still (activity still/stand **or** occupancy < 0.15) and HR max > 120, HR min < 35, temp / resp / RMSSD bounds. Workout high HR with motion does not fire (`testWorkoutHighHRIsNotSafetyCap`). Still 96 vs 58 can severe without three vitals (`test11…`). `WatchdogScores.severity` has **no channel count**. In/Out on a single row is display only.

---

## 12. UniTS reconstruct and TimesFM 3.0 student, then fuse

### Request

Two jobs. Reconstruction answers “does this half-hour match expected state?” Forecast answers “are we diverging from the trajectory we predicted a few minutes ago?” Combine after calibration. Forecast model is **TimesFM 3.0**. Do not ship 330M non-commercial weights. Do not replace the dotted line. Do not infer \(t0\).

### Plan

Teacher: [google-research/timesfm](https://github.com/google-research/timesfm), checkpoint `google/timesfm-3.0-pytorch`, trained/distilled in `Tools/units-watchdog`. Student: `TimesFM3_Student.mlpackage` (`timesfm3-student-v2`) in the iOS target. Horizon 5 minutes. \(J_{\mathrm{fused}} = \max(J_{\mathrm{recon}},\; \alpha J_{\mathrm{forecast}})\) with \(\alpha = 0.5\). On the phone, run the student at most every 60 s.

### In the app now

`WatchdogForecastRuntime.step` compares the last 5 minutes of **observed** vitals to the forecast stored on `WatchdogCarry` (not hat-vs-hat). Then, at most once per minute, it runs the student on 30-min reconstructed history + prompt + occupancy and stores a new 5-minute strip. Other ticks reuse carry (heat). Fusion runs only when recon \(J \ge T_{\mathrm{note}}\), so a quiet window is not paged on forecast skill. Escalation (item 7) uses recon \(J\), so Lane B cannot re-page a stable reconstruction.

The dotted line is **only** reconstruct `hat` (`testHardForecastDoesNotReplaceDottedLine`). Google 330M weights are not in `NOOPiOS`. `WatchdogResult.forecastEnergy` / `fusedEnergy` are filled every scorable tick.

---

## Phone cost (why this can run on the iPhone)

| Choice | Effect |
|---|---|
| Quality fail → no Core ML | Unscorable windows do not infer |
| UniTS every 20 s, TimesFM ≤ 1/min | Reconstruct is the product; forecast is a second score |
| Compile each `.mlpackage` once | No per-tick compile |
| `cpuAndNeuralEngine` | ANE instead of spinning CPU |
| Activity / Auto Workout in Swift | No extra neural net for 1 Hz gravity |
| Fixed 30×6 tensors | No 1 Hz model |

---

## What this pass does **not** claim

- Harvard UniTS transformer weights, or Google TimesFM 3.0 330M in the App Store binary.
- A Core ML `joint` output tensor (Swift \(J\) on the six residuals).
- 30×8 logits **inside** the neural net (they condition occupancy, \(\sigma\), RHR, and UI).
- Jev / Typesafe 100 Hz IMU.
- Offline quiet-tape retune of `sigma_scale` away from 1.0 (personal quiet EMA is the live personalization).
- Charge / Recovery rewrite, Layer 1 writes, drug names, cloud scoring, on-device training.
