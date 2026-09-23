# FRWHOOP Watchdog

**Status:** Watchdog **in tree 21 Sep 2026**. Live head is `config_version = watchdog-v2.1`, `model_version = units-ad-coreml-v2` (`UniTS_AD.mlpackage`). Forecast student is `timesfm3-student-v2`. Swift physics decoder is `units-ad-recon-v3` fallback. This file is the **implementation record + product contract**, not a pre-code plan.

Keep two copies in sync: `docs/FRWHOOP_WATCHDOG.md` and `Packages/StrandAnalytics/Baseline/FRWHOOP_WATCHDOG.md`.

Contract origin: Convexia brief (8 Sep 2026) **W01–W13** / **F01**. Baseline Layer 1 stays `LongitudinalBaseline` / `param_set = v1.review`. **Charge / Recovery are not rewritten.** Watchdog **never writes** usuals. Watchdog **never infers t0 from HR**. Watchdog **never names a drug or a disease**.

---

## Why UniTS for Watchdog (not TimesFM)

Watchdog’s question is: **did the last 30 minutes look like this person, given rest usuals and live motion?** That is **reconstruction anomaly detection** on a short, multivariate, gappy wearable window. It is not “what will HR be in 15 minutes,” not “is this a disease,” and not the 7-day / 60-day usual (that stays Layer 1).

**UniTS** (Gao et al., NeurIPS 2024) is a unified time-series transformer whose published heads include forecasting, classification, **imputation**, and **anomaly detection**. For AD it does not emit a diagnosis. It takes a window that may already contain odd values, **generates what that window should look like**, and scores reconstruction error. Large, coherent error across related channels means “this stretch does not match the pattern for this kind of series.” That is the Watchdog job.

| Watchdog constraint | Why UniTS is the right family |
|---|---|
| Score **this stretch that already happened** | Native **reconstruct-then-residual** AD, not a next-step forecast |
| Six vitals + **activity context** | Multivariate tokens; error per channel and as a **pattern**. Motion is an 8-way IMU/step embedding (still / stand / walk / run / cycle-like / lifting / artifact / unknown), then a class-effort occupancy scalar for the reconstructor — not a single 0–1 magnitude |
| WHOOP 4 ~1 Hz vs 5/MG ~30 s, holes, type-47 extra records in the same second | Pretrained across sampling rates; imputation / mask tokens; we never `GROUP BY ts` on PPG |
| Prompt is **this person’s** Layer 1 usual, occupancy-warped | Condition on a personal prompt + motion; two usuals are never averaged |
| Phone only, no cloud, no on-device training | Frozen 30-step graph, one tick, CPU Core ML (or Swift fallback) |
| Must not swallow a **flat** rest tachycardia | Prompt reconstruction, not instance-normalizing the window (a z-score of the last 30 min hides a stable 96 bpm) |

### Why not TimesFM (time-series FM)

**TimesFM** (Das et al., Google, 2024) is a strong **forecasting** foundation model: decoder-only, pretrained on a huge mix of series, aimed at **future horizons** (often univariate or channel-independent). That is a different product.

| If we used TimesFM here | What goes wrong for Watchdog |
|---|---|
| Predict the **next** minutes, then compare live BPM to the forecast | Error is **forecast skill**, not “unexpected given occupancy.” A walk, a gap, or a WHOOP 5 30 s sample looks like a miss even when physiology is explained. |
| No native **reconstruction-AD** head on the window you already have | Watchdog must score the **past half-hour**, including values that may already be odd. Reconstructing that window is the UniTS AD contract; TimesFM’s contract is “continue the series.” |
| Typically **one series at a time** | Instant HR, still RHR, 5-min RMSSD, lagged wrist temp, breathing, and SpO₂ do not share a sign, lag, or sleep-vs-wake state. A univariate FM would page (or ignore) each channel separately and could not use occupancy as a shared context token. |
| No **personal usual + occupancy prompt** in the public recipe | TimesFM’s prior is “series like those in pretraining.” Watchdog’s prior is **this wearer’s** shown usual, warped by **this minute’s** motion. Mixing those would either chase the live trace or treat every workout as an anomaly. |
| Size and runtime | TimesFM is a large forecast FM. Watchdog is a **30×6** strip every **20 s** on an iPhone, CPU-only, no network. A forecast FM is the wrong cost model even if you distilled it. |

Other forecast FMs (Chronos, Moirai, and similar) fail for the same reason: they answer **what comes next**, not **does this window match a reconstruction**. Univariate EWMA / Layer 1 `z` is already the **usual**; paging on one of those once is the failure mode Watchdog exists to avoid.

**Honesty about what is in the app today.** The on-device file `UniTS_AD.mlpackage` implements the **UniTS-AD job** (multivariate reconstruct + predicted \(\sigma_t\)). Harvard’s public UniTS transformer weights are **not** bundled. A TimesFM-style **student** (`TimesFM3_Student.mlpackage`, `timesfm3-student-v2`) is fused only when reconstruction energy is already at least `tNote`; Google’s 330M TimesFM 3.0 weights are **not** in the binary. Occupancy into Core ML is **class-effort** from `WatchdogActivityRuntime`, not raw gravity magnitude. Product detail and citations continue in **§2**.

---

## How it works now (21 Sep 2026, v2.1)

Watchdog is **reconstruction anomaly detection** on the last **30 minutes**, re-scored every **20 s** on the iPhone. It does not forecast the next minute, does not train on the phone, and does not move the 7-day / 60-day usual.

### What the wearer sees

The first card on Baseline is **Live baseline**. Six equal vitals: heart rate, resting HR, HRV (5-min RMSSD), wrist temp, breathing, SpO₂ %. For each:

| On the card | Meaning |
|---|---|
| Left number (orange/green) | Live value |
| Dotted line | \(\hat{x}_t\) — reconstructed usual **for this stretch** (awake HR usual vs sleep RHR usual, warped by **class-effort** occupancy, then a causal EMA) |
| Green band | \(\hat{x}_t \pm \sigma_t\) — predicted corridor from the model call, then **adaptive** quiet-residual floors, artifact widen, and still HR↔HRV correlation |
| Right number | Last reconstructed value (same as the dotted line at the paired minute) |
| In sync / Out of sync | Last minute that has **both** a live sample and a hat: off if \(\|x-\hat{x}\| > \sigma\) **or** energy ≥ `tau` |
| TRUST % | How much to believe that call (`50U+35C+15E`, caps 28 / 18). Not a diagnosis |

Local notification only if **severe** (safety cap, or ≥ 3 vitals far off for two ticks) with a 30-minute cooldown. Wrist-off is unavailable, never “recovered.”

### What the model is

UniTS (Gao et al., NeurIPS 2024) is the **job**: reconstruct a multivariate strip, score residual energy. The on-device head is **`UniTS_AD.mlpackage`**.

Every tick, `UniTSRuntime.reconstruct` does **one** inference (iPhone / Mac):

| Tensor | Shape | Role |
|---|---|---|
| `occupancy` | (1, 30) | Class-effort occupancy from the IMU/step embedding (still/stand=0, walk=0.32, run=0.85, …). Unknown falls back to gravity magnitude 0…1 |
| `prompt` | (1, 6) | Resolved usuals: **HR = shown awake-rest / continuous only**; **RHR = sleep RHR only**. Never fill one from the other |
| `personal_scale` | (1, 6) | Layer 1 MAD (or floor) |
| **`hat`** | (1, 6, 30) | \(\hat{x}_t\) dotted line |
| **`sigma`** | (1, 6, 30) | \(\sigma_t\) green half-width |

Channel order: HR, RHR, HRV, temp, breathing, SpO₂. Energy stays in Swift: \(\max(|\mathrm{median}((x-\hat{x})/\sigma)|,\; |x_{\mathrm{last}}-\hat{x}_{\mathrm{last}}|/\sigma_{\mathrm{last}})\). Hot if energy ≥ `tau` (1.0).

**watchOS** cannot `compileModel`; that target uses the Swift decoder (`units-ad-recon-v3`). Missing package ≠ recovered. **No on-device training.**

The graph is the frozen per-vital decoder (below) plus **zero-init** `delta_hat` / `delta_sigma` 1×1 convolutions. Tests require Core ML hat/sigma to match Swift. A later **trained** UniTS file keeps this I/O and can fill those slots without rewriting Watchdog. Re-export: `python3 Tools/units-watchdog/export_coreml.py`. Code map: **§6**.

### Per-vital reconstruction and \(\sigma_t\)

Two usuals are never averaged. Occupancy warps **this person’s** still value. \(\sigma_t = \max(\mathrm{floor},\; \mathrm{MAD},\; \rho|\hat{x}_t|,\; u_t)\). Scatter of this window does **not** set \(\sigma\).

| Vital | \(\hat{x}_t\) | \(\sigma_t\) extras |
|---|---|---|
| Heart rate | Shown awake-rest / continuous HR only, \(+ 0.50 R \times \mathrm{occ}_{\mathrm{effort}}\), EMA | \(\rho=0.12\); \(u=0.15 R \,\mathrm{occ}\); then quiet-EMA floor + artifact ×1.7 |
| Resting HR | Sleep RHR usual only; still/stand minutes; walk/run/lift/cycle/artifact **never** enter the RHR strip | \(\rho=0.07\); \(u=0\); adaptive quiet floor |
| HRV | Shown awake-rest RMSSD if TRUST ≥ 35, else sleep ms, minus occupancy-scaled Chen drop | \(\rho=0.22\); \(u=3.04\,\mathrm{occ}(S/50)\) |
| Wrist temp | Usual − 0.15 × lagged occupancy | floor 0.35 °C; \(u=0.10\,\mathrm{occ_{lag}}\) |
| Breathing | Rest \(+ 0.60 f_0 \times \mathrm{occ}\) | \(\rho=0.10\); \(u=0.20 f_0 \,\mathrm{occ}\) |
| SpO₂ | Flat usual (no predicted hypoxia) | floor 2 %; \(u=0\) |

Floors (minima): HR 5 bpm, HRV 8 ms, temp 0.35 °C, resp 3 /min, SpO₂ 2 %. Full citations: **§1.3.2**. Why v2’s static tube was wrong: **§1.3.3**.

### Pipeline (as coded)

```
strap / SQLite last 30 min
  → WatchdogWindowBuilder (30×60 s; WHOOP 4 vs 5/MG coverage)
  → UniTSRuntime.reconstruct  (Core ML hat+sigma, else Swift)
  → Watchdog.evaluate         (lastPaired, safety, tau, Layer 1 read-only)
  → BaselineStore + local notify if severe
  → Live baseline card        (band = hat_t ± rangeSeries[t])
```

Nothing in this path imports Charge, `Baselines.swift`, or Recovery.

---

## Hard rules (unchanged)

- Two usuals are never averaged.
- All scoring is on-device. Nothing Watchdog-related runs in Supabase.
- Off-wrist / coverage failure is **`dataUnavailable`**, never “recovered.”
- **“No current deviation detected”** only after a successful window with enough coverage. Otherwise the card says monitoring is not current.
- Local notification **only** for **severe**, with a 30-minute cooldown and a stable episode id.
- Motion is context. Motion-only never pages.
- SpO₂ is a Watchdog **percent** channel (50…110 % samples only). Optical ADC is never treated as %.
- Core ML on iPhone/Mac as above; watchOS Swift fallback. Missing package ≠ recovered. **No on-device training.**

---

## 1. Engineering log (19 Sep 2026, plus v2.1 on 21 Sep)

### 1.0 v2.1 — HR ≠ RHR, IMU activity, adaptive σ (21 Sep 2026)

Three product gaps closed without rewriting Charge or Layer 1.

**1. Instant HR and resting HR are separate prompts.** `UniTSPrompt.from` fills `hr` from shown `awakeRestHR` / `continuousHR` only. `rhr` is `sleepRHR` only. Sleep RHR never back-fills the pulse prompt; daytime HR never back-fills still RHR. TRUST for the HR row ignores the sleep copy; TRUST for RHR uses sleep only. Physics reconstruction for RHR is a flat sleep usual. Window RHR minutes are still-gated by **activity class**: walk, run, cycle-like, lifting, and motion artifact never enter the RHR strip (occupancy 0.15 alone was not enough when walk and tremor share magnitude).

**2. Motion context is an 8-way embedding, not occupancy 0–1.** `WatchdogActivityRuntime.embed` consumes 1 Hz gravity (`WatchdogIMUSample`, including `dynAccel`), step `@63` activity class, occupancy, and live HR. Classes: still, standing, walking, running, cycle-like, lifting, motion artifact, unknown. Effort occupancy mapped into UniTS is class-specific (still/stand/artifact → 0 so they do not raise expected HR; walk 0.32; run 0.85; cycle 0.55; resistance 0.42; unknown → gravity mag). Last 10 minutes blend in-tree `WorkoutTypeClassifier` (same Auto Workout job already in StrandAnalytics). **Jev / Typesafe is not used:** that stack wants ~100 Hz IMU; WHOOP gravity here is ~1 Hz. GitHub workout nets that need phone IMU at gym sample rates are the same mismatch.

**3. σ is adaptive after the frozen decoder.** Quiet EMA now also updates when the **last paired** residual is inside \(1\sigma\) even if window-median joint is noisy (Core ML mixer). After 8 quiet ticks the quiet EMA is a floor under \(\sigma_t\) (and therefore under 2×σ energy). Motion artifact multiplies \(\sigma\) by 1.7 and damps joint J (artifact is not a physiology page). Still windows: HR off + HRV quiet **widens** (uncoupled); both off **tightens** (expected correlation). `WatchdogResult.sigmaAdaptive` is true once `quietN ≥ 8`. Carry persists quiet stats in `noop.watchdog.carry.v1`.

**UI (visible):** Live baseline chips for current activity, **HR ≠ RHR**, and Adaptive σ vs Calibrated σ. Heart-rate caption “Pulse · awake usual”; resting HR “Still minutes · sleep usual.” Footnote states the split and that the green band follows quiet residual + IMU context.

**Feed:** `WatchdogService` now passes IMU vectors and `stepSamples` into `WatchdogFeed`. Occupancy scalar is still stored for interpolation, but reconstruction uses `UniTSRuntime.occupancy(window)` = effort occupancy.

`config_version = watchdog-v2.1`. Tests: prompt split, walk vs run at the same 0.40 occupancy, artifact σ widen, quiet adaptive flag. `swift test --filter Watchdog`.

---

This section is the build diary (window knobs, per-vital papers, tests, files). Product examples remain in §3 onward. **Why UniTS** and **How it works now** are the sections above.

### 1.1 What the “model” is today

UniTS (Gao et al., NeurIPS 2024) is the **job**: reconstruct a multivariate 30-minute strip and score residual energy. The on-device head is `UniTS_AD.mlpackage` (`coreml_checkpoint` in `WatchdogConfig.json`).

The same AD contract as a GEN-token reconstructor:

| Name | What it is |
|---|---|
| `units-ad-coreml-v1` | Bundled Core ML program. One call returns **hat** `(1,6,30)` and **sigma** `(1,6,30)` for HR, RHR, HRV, temp, resp, SpO₂. Loaded once per process; ticks are inference only. |
| Prompt | Read-only Layer 1 centers. Shown awake-rest HR/HRV if TRUST ≥ 35; else sleep copies. Taken from `copyLong.centerDisplay`, else `copy7`. **Never written back.** If no usual exists, the channel median of the window is the fallback base. |
| Energy | Median **and last-paired-minute** residual vs reconstruction, each divided by **per-minute predicted \(\sigma_t\)**. The plotted band is \(\hat{x}_t \pm \sigma_t\). It does **not** widen with this window’s scatter. Motion energy is always 0 (context only). |
| Why not full-window z-score | Instance-normalizing the 30-minute strip hides a **flat** rest tachycardia. Prompt-plus-motion lets rest 96 bpm disagree with usual 58 while a workout with occupancy 1.0 reconstructs a raised HR. |

Pin note: `Packages/StrandAnalytics/Baseline/units/COMMIT.txt`. Knobs duplicated in Swift (`WatchdogConfig`) and JSON (`Baseline/units/WatchdogConfig.json`).

**Later swap:** replace `UniTS_AD.mlpackage` with a trained UniTS graph that keeps the same I/O. Combiner thresholds (`tau = 1.0`, `tau_severe = 2.0`) stay until a quiet-window calibration replaces them. Re-export: `python3 Tools/units-watchdog/export_coreml.py`.

### 1.2 End-to-end pipeline as coded

```
WHOOP strap
  ├─ Live BLE (LiveState.heartRate, LiveState.worn)     UI + one sample appended to the window
  └─ Type-47 / SQLite (WhoopStore)
         hrSamples, rrIntervals, skinTempSamples, gravitySamples, events
         └─ last 30 minutes

WatchdogService  (AppModel.watchdog)
  start() after repo.refresh() on launch
  loop: tick every **20 s** (`WatchdogConfig.tickSeconds`); live interval 1|2|5|10 min is not the reconstruct cadence
         │
         ▼
WatchdogWindowBuilder.build(WatchdogFeed)
  …
         │
         ▼
UniTSRuntime.reconstruct(window, prompt)
  iPhone/Mac: UniTSCoreMLSession.predict → hat (1,6,30) + sigma (1,6,30)
  else / watchOS: UniTSRuntime.physicsResidual (same decoder, tagged units-ad-recon-v3)
  then finishResidual → energy, last-paired residual, UniTSResidual
         │
         ▼
Watchdog.evaluate  combiner
  lastPaired(obs, hat) per vital  |  safety caps  |  residual vs tau  |  read-only LBEvaluation
  WatchdogResult (severity + reconstructed* + rangeHR…rangeSpO2)
         │
         ├─ BaselineStore.applyWatchdog
         ├─ persist WatchdogCarry
         └─ WatchdogNotifier  only if shouldNotify (severe + cooldown)
         │
         ▼
WatchdogView  (struct still WatchdogPlaceholderView)
  expected = reconstructed last  |  In/Out from lastAligned minute vs σ_t
  green band = hat_t ± rangeSeries[t]  |  °C/°F from setup
```

Nothing in this path imports Charge, `Baselines.swift`, or Recovery.

### 1.3 Frozen knobs (`WatchdogConfig` / JSON)

| Knob | V1 value | Role |
|---|---|---|
| `seqLen` | 30 | Minute marks in the window |
| `gridSeconds` | 60 | Bucket width |
| `contextSeconds` | 1800 | Lookback |
| Live interval | 1, 2, 5, 10 min (default **5**; other values clamp to 5) | Stored `noop.watchdog.liveIntervalMinutes`. **Not** the reconstruct loop. `WatchdogService.tick` currently always passes `defaultLiveIntervalMinutes` into `evaluate`. |
| Tick | **20 s** | `WatchdogService` re-reads SQLite + live rings and calls `evaluate`. Not a patient control. |
| Notify cooldown | 1800 s | Same episode does not re-banner |
| `tau` / `tau_severe` | 1.0 / 2.0 | Hot if energy ≥ 1; UniTS severe lane needs ≥ 3 vitals at ≥ 2 |
| WHOOP 4/5 gap, freshness, `minCoverage` | 5 s / 90 s; 60 s / 90 s; 0.80 | **JSON + Swift knobs.** The live builder **does not fail** the window on gap/coverage/stale. Coverage is recorded and is TRUST **C**. Empty HR or wrist-off still fail. Sparse WHOOP 4 still **displays**. |
| Motion HR gain | 28 bpm | **Test/inject helper only.** Live HR hat uses `hrEffortFraction × rest`, not +28. |
| Rest HR / temp / resp / RMSSD safety | < 35 or > 120 bpm (still, last motion < 0.15); temp 28…38 °C; resp 6…30 /min; RMSSD 8…250 ms | Valid extrema while still; RMSSD 0 is missing, not a cap |
| RHR lookback | last **10 min**, still / standing **activity class** (not occupancy 0.15 alone) | Walk / run / lift / cycle / artifact minutes are dropped. Display is held across the 30-min strip. |
| SpO₂ | last 30 min, **50…110 %** samples only | Optical ADC is never a percent. |
| HR effort | \(0.50 R \times \mathrm{occ}^{1.0}\), 1-min smooth, EMA α=0.40 | Instant HR decoder |
| HRV occupancy | 2-min smooth, drop \(4.96 \times \mathrm{occ} \times (S/50)\), EMA 0.28 | Live RMSSD decoder |
| Temp occupancy | gain −0.15, **6-min** lag, EMA 0.18 | Wrist skin, not core |
| Resp occupancy | \(0.60 f_0 \times \mathrm{occ}^{1.0}\), 1-min smooth, EMA 0.32 | Breathing decoder |
| Predicted \(\sigma\) | \(\rho\) 0.12 / 0.07 / 0.22 / 0 / 0.10 / 0; floors 5 / 8 / 0.35 / 3 / 2 | See §1.3.3 |
| HRV series | trailing **5 min RMSSD**, 60 s step, Malik + range, ≥ 20 beats, clamp 8…250 ms | Prompt is Layer 1 **display ms** (awake-rest if shown, else sleep). Never ln(RMSSD) in the live residual. |

Engineering defaults, **not** clinical limits.

### 1.3.1 How live bounds are chosen (time + prediction)

This is the contract the phone implements. Nothing here is a clinical limit.

**Time bounds (what “now” means per vital)**

The shared canvas is always **30 minutes**, 30 buckets × 60 s, ending at wall-clock `now` (samples with `ts ≥ now` are dropped). The scheduler re-scores every **20 seconds**. Patients do not pick a timeframe.

| Vital | What is scored | What the strip shows |
|---|---|---|
| Heart rate | Mean BPM in each of the 30 minutes | Full 30 min |
| Resting HR | Still / standing minutes in the **last 10 min** (class-gated) | Same 30-min width; last good still BPM is held across gaps so the line is not a stub on the right |
| HRV | Trailing 5-minute RMSSD (ms) at each minute mark | Full 30 min; 8…250 ms clamp (outside that is missing, not a spike) |
| Wrist temp | Mean °C per minute | Full 30 min; last good value held across gaps while on-wrist |
| Breathing | Vendor breaths/min if present, else RSA from RR in 5-min blocks | Full 30 min; last good rate **held across gaps while the strap is on**. Wrist-off clears the hold and does not invent a rate. |
| SpO₂ | Percent samples only (50…110), last 30 min | Full 30 min; ADC never plotted as % |

On-wrist is required. Wrist-off is `dataUnavailable`, never “recovered,” and never a filled breathing/HRV/temp/SpO₂ hold.

**Prediction bounds (what “usual for this stretch” means)**

Layer 1 usuals are **read-only**. Watchdog never writes `center`, `spread`, `k`, freeze, or trial.

1. **Prompt (the usual).** For each vital, `UniTSPrompt` takes `copyLong.centerDisplay`, else `copy7.centerDisplay`:
   - HR: shown **awake-rest HR** if TRUST ≥ 35, else **sleep RHR**, else continuous. Demo rest/active columns are not the live prompt.
   - RHR: **sleep RHR**, else awake-rest HR.
   - HRV: shown **awake-rest HRV** if TRUST ≥ 35, else **sleep HRV in milliseconds** (`centerDisplay` after exp from ln(RMSSD)).
   - Temp / resp / SpO₂: sleep temp, sleep resp, sleep SpO₂ mean.
   - If that usual does not exist yet, the fallback base is the **median of the current 30-minute channel**, not a population chart.
2. **Reconstructed strip \(\hat{x}_t\) (`units-ad-coreml-v1`, else `units-ad-recon-v3`).** Each vital is a **different** function of this person’s usual and live occupancy (full reasoning and citations in **§1.3.2**). The dotted line **is** \(\hat{x}_t\), same y-scale as observed. Occupancy is smoothed on a horizon that matches that signal. No screenshot-derived constants.
3. **Residual energy and the green band (v3).** See **§1.3.3**. Every tick (20 s) UniTS rebuilds \(\hat{x}_t\) **and** a predicted half-width \(\sigma_t\) for that minute. Energy is the larger of the median |normalized residual| and the last paired minute’s |residual|/σ. Channel is **hot** if energy ≥ `tau` (1.0). The live graph band is \(\hat{x}_t \pm \sigma_t\). This window’s residual scatter does **not** set \(\sigma_t\).
4. **Safety caps (still wrist only, last motion < 0.15).** Rest HR < 35 or > 120 bpm; temp < 28 or > 38 °C; resp < 6 or > 30 /min; RMSSD > 0 and (< 8 or > 250) ms. These can page **severe** without waiting for UniTS.
5. **TRUST % (card header only, v2).** Not a diagnosis. How much to believe this live in-range / off call.
   \[
   \mathrm{TRUST} = \mathrm{round}(50\,U + 35\,C + 15\,E)
   \]
   - **U** = Layer 1 usual TRUST (0…1) for **that vital’s series** (sleep HRV for HRV, sleep RHR for HR/RHR, …). Used only if that TRUST is ≥ 35 (a shown usual). Two copies are never averaged; each series uses `max(long, week)`.
   - **C** = HR coverage of the 30-minute window (0…1).
   - **E** = evidence. In-range: \(1 - \mathrm{energy}/\tau\) (close to the reconstruction). Off: \(0.4 + 0.6 \times \min(1,\mathrm{energy}/\tau_{\mathrm{severe}}) \times \max(0.35, \min(1, \mathrm{ticks}/2))\) (large, persistent residual).
   - **Caps:** no shown personal usual → **≤ 28**. No prompt number at all → **≤ 18**. Always 0…100.
   - Card number is the **minimum** TRUST among hot vitals; if none are hot, the minimum among vitals that scored above 0.

Two usuals are never averaged. Motion-only never pages.

### 1.3.2 Per-vital reconstruction (why each biometric is a different model)

Live Watchdog is reconstruction anomaly detection: build \(\hat{x}_t\) for the last 30 minutes, then score residual energy. A **single** `prompt + g·motion` is the wrong model. Instant HR, still-gated rest HR, RMSSD, wrist temperature, breathing rate, and SpO₂ do not share a sign, a lag, or a state (sleep vs wake). Frozen priors below are **not trained** and **not taken from one wearer’s screenshot**. They are (a) that person’s Layer 1 usual, (b) this window’s occupancy 0…1, (c) a published direction of effect. Population constants are used only as **scale**, never as that person’s usual.

**Individualization rule.** Two usuals are never averaged. If a **shown** awake-rest copy exists (TRUST ≥ 35), live still HR / HRV use that copy. Overnight sleep RHR / sleep HRV remain the rest-HR and sleep-HRV prompts. If only sleep exists, live expected **is that sleep usual** until an awake copy is shown — Watchdog does **not** invent a sleep→wake ratio. Occupancy then warps **that person’s** still value, every tick (20 s).

#### Heart rate (instant)

Sleep / SWS is a different autonomic state than wake (Elsenbruch, Harnish & Orr 1999; Burgess et al. 1997). Instant HR must be allowed to rise with effort so a walk is not scored as rest tachycardia.

- Still prompt: shown **awake-rest HR** if it exists, else sleep RHR.
- \(\hat{\mathrm{HR}}_t = R + 0.50\,R\,\mathrm{occ}_t^{1.0}\) with occupancy trailing-smoothed **1 min**, then EMA α=0.40 (`hrTrackAlpha`).
- **Why 0.50×R, not a global +28 bpm:** Karvonen / %HRR is intensity × (HRmax − HRrest) (Swain & Leutholtz 1997). We do not have age or HRmax on this path. Occupancy is a **proxy for effort, not %VO2**. Using half of **this person’s** rest HR as the occupancy-1 bump scales with them (a 50 bpm rester gets +25 at full occupancy; a 70 bpm rester gets +35). `motionHrGain = 28` remains only for inject/tests that add a round bpm bump.
- **Why occ^1.0:** linear occupancy so small motion changes show on the dotted line. An exponent > 1 was tried; current code is power 1.0.
- **Why 1 min smooth + EMA 0.40:** keep the dotted line causal without teleporting on a single occupancy spike.

#### Resting HR

Resting HR on this card is still-gated BPM in the last 10 minutes vs **sleep RHR**. Motion must not raise the expected line (that would duplicate instant HR). \(\hat{\mathrm{RHR}} =\) sleep RHR, constant. Energy still uses only the last 10 still minutes.

#### HRV (RMSSD)

HF / vagal HRV differs across wake, NREM, and REM (Elsenbruch et al. 1999; Burgess et al. 1997). Live Watchdog is a 5-minute RMSSD **now**, not the overnight sleep usual. Those states are not interchangeable, but papers do **not** give a stable RMSSD sleep÷wake ratio that is safe to hard-code for every wearer.

- Still prompt: shown **awake-rest HRV** if TRUST ≥ 35; else **this person’s sleep HRV in ms**. No 0.72 population factor.
- Acute exercise **lowers** RMSSD vs pre-exercise (Chen et al. 2024 meta-analysis, MD −4.96 ms; Michael, Graham & Davis 2017 review: RMSSD falls as intensity rises).
- \(\hat{\mathrm{HRV}}_t = S - 4.96\,\mathrm{occ}_t\cdot(S/50)\), occupancy smoothed **2 min**, EMA 0.28.
- **Why scale by S/50:** the −4.96 ms is a **mean difference** across mixed rest RMSSD, not “this wearer.” Scaling by still RMSSD / 50 ms makes the drop **personal** (a 50 ms still value drops ~5 ms at occupancy 1; a 100 ms still value drops ~10 ms). Direction is from the papers; the 50 ms reference is an engineering scale so the meta MD applies to people who are not the meta mean.

#### Wrist temperature

Wrist skin temperature is **not** core temperature. In free-living data, activity **decreases** wrist temperature via peripheral vasoconstriction / masking (Martínez-Nicolás et al. 2013). Moderate aerobic exercise also drops regional skin temperature within ~10 minutes, with a different recovery time course (Fernández-Cuevas et al. / Neves et al. infrared studies; see Fernandes et al. 2016-style TSK drop after 10 min of activity).

- \(\hat{T}_t = T_0 - 0.15\,\mathrm{occ}^{\mathrm{lag}}_{6\mathrm{min}}\), then EMA 0.18.
- Sign is from Martínez-Nicolás (activity ↓ WT), not a fever model. Magnitude 0.15 °C is a small occupancy warp so a real ~1 °C excursion still reads off. Lag **6 min** in code (`tempLagMinutes`); literature on ~10 min of activity was used for **direction of lag**, not the exact tap count.

#### Breathing

Ventilation rises with exercise. At rest, breathing is on the order of ~15 /min; at **maximal** exercise it can reach 40–60 /min (ERS *Breathe* factsheet, 2016). Occupancy 1 on a strap is **not** VO2max, and at moderate intensity tidal volume does much of the work before rate (standard exercise-ventilation description).

- \(\hat{f}_t = f_0 + 0.60\,f_0\,\mathrm{occ}_t^{1.0}\) (1-min smooth, EMA 0.32).
- Occupancy 1 adds 60% of **this person’s** rest rate (14 → ~22), i.e. moderate, not 40–60. Power 1.0 (linear), same as instant HR.

#### SpO₂

Motion artifact makes pulse-oximetry **less accurate** and can bias readings, often downward (Petterson, Begnoche & Graybeal 2007; Clarke, Chan & Adler 2014: hand motion decreased measured SpO2 while true saturation was unchanged). That is a **sensor failure mode**, not a physiological desaturation we should predict.

- \(\hat{\mathrm{SpO}_2} =\) this person’s usual, **flat**. We do not subtract occupancy from expected %. If live % collapses with motion, energy may rise; TRUST / coverage / still-wrist caps handle junk. We do not invent an expected hypoxia.

#### Residual energy (unchanged meaning)

After \(\hat{x}\) is built per channel, energy and the green band use **per-minute \(\sigma_t\)** from the reconstructor (`units-ad-coreml-v1` / Swift `units-ad-recon-v3`) — see **§1.3.3**. Floors stay HR 5 bpm, HRV 8 ms, temp 0.35 °C, resp 3 /min, SpO₂ 2 % as **minima**. Live HRV is 5-minute RMSSD after the same range + Malik cleaning as nightly HRV (`HRVAnalyzer.rollingRmssd`, ≥ 20 beats).

#### Sources (cited)

1. Elsenbruch S, Harnish MJ, Orr WC. Heart rate variability during waking and sleep in healthy males and females. *Sleep*. 1999;22(8):1067–1071. [doi:10.1093/sleep/22.8.1067](https://doi.org/10.1093/sleep/22.8.1067)
2. Burgess HJ, Trinder J, Kim Y, Luke D. Sleep and circadian influences on cardiac autonomic nervous system activity. *Am J Physiol*. 1997;273(4):H1761–H1768. [doi:10.1152/ajpheart.1997.273.4.h1761](https://doi.org/10.1152/ajpheart.1997.273.4.h1761)
3. Swain DP, Leutholtz BC. Heart rate reserve is equivalent to %VO2 reserve, not to %VO2max. *Med Sci Sports Exerc*. 1997;29(3):410–414. [doi:10.1097/00005768-199703000-00024](https://doi.org/10.1097/00005768-199703000-00024)
4. Chen Y-C, et al. The impact on autonomic nervous system activity during and following exercise in adults: a meta-regression study and trial sequential analysis. *Medicina*. 2024;60(8):1223. [doi:10.3390/medicina60081223](https://doi.org/10.3390/medicina60081223) — RMSSD MD −4.96 ms (95% CI −8.00 to −1.91) vs pre-exercise.
5. Michael S, Graham KS, Davis GM. Cardiac autonomic responses during exercise and post-exercise recovery using heart rate variability and systolic time intervals—a review. *Front Physiol*. 2017;8:521. [doi:10.3389/fphys.2017.00521](https://doi.org/10.3389/fphys.2017.00521)
6. Martínez-Nicolás A, Ortiz-Tudela E, Rol MA, Madrid JA. Uncovering different masking factors on wrist skin temperature rhythm in free-living subjects. *PLOS ONE*. 2013;8(4):e61142. [doi:10.1371/journal.pone.0061142](https://doi.org/10.1371/journal.pone.0061142)
7. Fernandes AA, et al. Regional skin temperature response to moderate aerobic exercise measured by infrared thermography. *Asian J Sports Med*. 2016. TSK reduced by ~10 min of activity in most regions (not wrist-specific; used only for **lag**, not magnitude).
8. European Respiratory Society. Your lungs and exercise. *Breathe (Sheff)*. 2016;12(1):97–100. [doi:10.1183/20734735.ELF121](https://doi.org/10.1183/20734735.ELF121) — rest ~15 breaths/min; **maximal** exercise ~40–60 /min.
9. Petterson MT, Begnoche VL, Graybeal JM. The effect of motion on pulse oximetry and its clinical significance. *Anesth Analg*. 2007;105(6 Suppl):S78–S84. [doi:10.1213/01.ane.0000278134.47777.a5](https://doi.org/10.1213/01.ane.0000278134.47777.a5) — PubMed 18048903.
10. Clarke GWJ, Chan ADC, Adler A. Effects of motion artifact on the blood oxygen saturation estimate in pulse oximetry. *IEEE MeMeA*. 2014. [doi:10.1109/MeMeA.2014.6860071](https://doi.org/10.1109/MeMeA.2014.6860071)

**Occupancy path (so the dotted line can move).** Gravity is often missing in some minutes. Those minutes were occupancy 0, so every expected strip was a flat rest line. Gaps are now **linearly interpolated** (held at the ends). Each channel then runs a causal EMA over its target (`track`, α 0.12–0.40) so small occupancy changes stay on the 30-minute path instead of snapping. Resting HR is still a constant rest usual (it is not a second instant-HR graph).

### 1.3.3 How UniTS is used per biometric, and how the green band is built

This section is the live-range contract. `units-ad-recon-v2` **was not** dynamic enough: it ran the reconstructor every tick for the **dotted line**, then drew a **constant** tube `max(floor, Layer 1 MAD)` around it. Instant HR and 5-minute RMSSD were scored against a sleep-usual floor (5 bpm / 8 ms). That is why a half-hour could look like a normal live trace while Heart rate / Resting HR / HRV flipped **Out of sync** at the last minute — the band was a statistic, not the model’s uncertainty.

`units-ad-coreml-v1` is the same reconstruction **job** as UniTS (Gao et al., NeurIPS 2024): reconstruct the 30×60 s window, score residual energy. **Both** \(\hat{x}_t\) and \(\sigma_t\) come from `UniTS_AD.mlpackage` on every 20 s tick. The Swift physics decoder (§1.3.2) is compiled into that package (plus a zero-init 1×1 residual slot for a later trained checkpoint). If the package cannot load, Swift still runs and tags `units-ad-recon-v3`.

| Series | Meaning |
|---|---|
| \(\hat{x}_t\) | Dotted line. Decoder prior: this person’s Layer 1 usual (never averaging two copies) warped by **this minute’s** occupancy. If no usual exists, the window median is the base. Observed live values are **not** mixed into \(\hat{x}\) when a usual exists (that would chase a spike). |
| \(\sigma_t\) | Green half-width at that minute. **Predicted reconstruction error of this frozen model**, not the SD of this window. |

\[
\sigma_t = \max(\text{floor},\; \text{Layer 1 MAD},\; \rho\,|\hat{x}_t|,\; u_t)
\]

- **floor** — instrument / physiology minimum (same numbers as v2).
- **Layer 1 MAD** — this person’s shown usual spread, same copy as the prompt.
- **\(\rho|\hat{x}_t|\)** — reconstructor SNR. The model is a point decoder; it cannot be more precise than the signal it is reconstructing (1-min BPM, 5-min RMSSD, …). This term **moves every tick** as \(\hat{x}\) moves.
- **\(u_t\)** — occupancy **coefficient uncertainty**. Effort coupling is a prior interval, not a delta. When occupancy is 0, \(u_t = 0\). When occupancy rises, the band widens around the **raised** dotted line because the 0.50 / 0.60 / −4.96 coefficients are not exact.

What we still refuse: setting \(\sigma\) from this window’s \(|x-\hat{x}|\) scatter. That would paint the green band over a rest tachycardia or a last-minute spike.

**In sync / Out of sync** uses the **last minute that has both** a live value and a reconstruction. Off if \(|x-\hat{x}| > \sigma\) at that minute, **or** if energy ≥ τ. Energy is \(\max(|\mathrm{median}((x-\hat{x})/\sigma)|,\; |x_{\mathrm{last}}-\hat{x}_{\mathrm{last}}|/\sigma_{\mathrm{last}})\). Severe notify is unchanged (several vitals, persistence, still-wrist caps).

#### Per vital (decoder + band)

| Vital | What UniTS reconstructs every tick (\(\hat{x}_t\)) | How \(\sigma_t\) is predicted | Why this is the model, not a chart statistic |
|---|---|---|---|
| **Heart rate** | Shown awake-rest / continuous usual \(R\) (never sleep RHR) \(+ 0.50 R \,\mathrm{occ}_{\mathrm{effort}}^{1}\), 1-min occupancy smooth, then causal EMA (`hrTrackAlpha` 0.40). | \(\rho = 0.12\) of \(\hat{x}_t\). Plus \(u_t = 0.15 R \,\mathrm{occ}_t\). After 8 quiet ticks, quiet residual EMA is a floor; artifact ×1.7. | Dotted line rises with **class effort** this minute, not raw tremor magnitude. |
| **Resting HR** | Constant rest prompt (sleep RHR else awake-rest). Motion must not lift it. Energy uses **still minutes, last 10 min** only. | \(\rho = 0.07\) of \(\hat{x}\) (10-min still mean is stabler than instant HR). \(u_t = 0\). | Same decoder every tick; band is a rest reconstruction width, not a second copy of instant-HR scatter. |
| **HRV** | Shown awake-rest RMSSD if TRUST ≥ 35, else this person’s sleep RMSSD (ms), minus \(4.96 \cdot \mathrm{occ} \cdot (S/50)\), 2-min occupancy smooth, EMA 0.28. Live series is cleaned 5-min RMSSD, ≥ 20 beats. | \(\rho = 0.22\) of \(\hat{x}_t\) (5-min RMSSD is a noisy reconstructable). Plus Chen 2024 CI half-width \(3.04 \cdot \mathrm{occ} \cdot (S/50)\) ms. | An 8 ms floor is a **sleep-usual** minimum, not a 5-min RMSSD corridor. The model now predicts ~0.22 × expected ms at rest (~21 ms around a 94 ms usual) and wider if occupancy is dropping HRV on purpose. |
| **Wrist temp** | \(T_0 + (-0.15) \times\) occupancy lagged 6 min, EMA 0.18. | \(\rho = 0\) (slow skin). Floor 0.35 °C or Layer 1 MAD wins. Plus \(u_t = 0.10 \,\mathrm{occ}^{\mathrm{lag}}\) °C around the masking prior. | Hat moves with lagged motion every tick. Band stays tight; a real ~1 °C excursion still reads off. |
| **Breathing** | \(f_0 + 0.60 f_0 \,\mathrm{occ}^{1}\), 1-min smooth, EMA 0.32. Held across on-wrist gaps. | \(\rho = 0.10\) of \(\hat{x}_t\). Plus \(u_t = 0.20 f_0 \,\mathrm{occ}_t\). | Same shape as HR (effort lifts the dotted line; coefficient uncertainty widens the band only while moving). |
| **SpO₂** | Flat usual (or window median). Motion is **not** predicted hypoxia. | \(\rho = 0\). Floor 2 % or Layer 1 MAD. \(u_t = 0\). | The model is used every tick to **refuse** an occupancy mix. A live desaturation is residual vs a stable reconstruction, not a moving “expected hypoxia.” |

#### Verdict: is v2 the best dynamic approach?

No. v2 used UniTS only as a **level** (prompt + occupancy) and then a **frozen statistic** for the corridor. That under-uses the model (the reconstructor already knows 5-min RMSSD is noisier than SpO₂, and that occupancy coupling is an interval) and over-uses Layer 1 MAD / floors that were sized for nightly usuals.

v3/v1 Core ML is the on-device UniTS head: **same tick, same window, predicted \(\hat{x}\) and \(\sigma\) from one `reconstruct` call**. A trained transformer checkpoint replaces the `.mlpackage` only — combiner, window, UI, and tests stay. We still must not (a) fit \(\sigma\) to this window’s residuals, (b) mix live \(x_t\) into \(\hat{x}\) when a usual exists, or (c) average two usuals.

### 1.4 Window builder (`WatchdogWindow.swift`) — what was implemented

**Inputs (`WatchdogFeed`):** family, `hrSource`, unix `now`, HR, RR, skin temp °C, optional breaths/min, occupancy 0…1 (interpolated), **IMU x/y/z/`dynAccel`**, **step samples**, optional PPG identities, `wristOff`.

**Type-47 identity:** `uniquePPGIdentities` keys on `ts#recordIndex`. Two records in the same unix second both survive. Tests fail if someone `GROUP BY ts`.

**Carry-forward:** `collapseCarryForward` keeps the first sample per timestamp. Duplicate BPM at the same `ts` is not a second observation.

**Coverage:**

- WHOOP 4: unique seconds with HR / 1800.
- WHOOP 5: filled 60 s buckets / 30.

**Unavailable from the live builder:** `wristOff` (feed flag) and `empty` (no HR in the 30 min). `coverage` / `gap` / `stale` exist on `WatchdogUnavailable` and the combiner treats a `.failure` as `dataUnavailable` (no notify, not recovery) — Test Centre / unit tests can inject those reasons. **`build` itself does not reject** a sparse tape on gap or coverage. Coverage and `maxGapSeconds` are stored on the window and feed TRUST **C**.

**Motion:** empty occupancy minutes are **linearly interpolated** (`interpolateGaps`), held at the ends. Occupancy 0 is not invented for a hole in gravity.

**Hold-forward:** breathing, HRV, temp, SpO₂ fill on-wrist gaps with last-good (optional `WatchdogHoldSeeds`). Wrist-off never reaches hold.

**Replay:** samples with `ts >= now` are excluded from buckets (`ts < end`). A future HR of 140 bpm cannot leak into a window ending at `now`.

**HRV:** v26-style HR-only feeds still **build** (coverage on HR). RMSSD series is `HRVAnalyzer.rollingRmssd` (5 min window, 60 s step, ≥ 20 beats, Malik + 8…250 ms). Empty RR → all `nil`; UniTS cannot claim HRV severe on that stretch.

**Resp:** if the feed already has breaths/min (inject path), those buckets are used. Otherwise RSA estimate from RR. Raw WHOOP resp ADC is **not** treated as breaths/min.

### 1.5 Combiner (`Watchdog.swift`) — exact v1 rules

`Watchdog.evaluate` is the only scoring entry. Inject, if present, **replaces** the real window with a synthetic 30-minute feed and then runs the same combiner (no second code path for UI).

**Hot channels:** energy ≥ `tau` on **HR, RHR, HRV, Temp, Resp, SpO2** (not motion). Severe UniTS lane counts how many of those six are ≥ `tau_severe`.

**Mismatch tick counter** increments when `hot.count ≥ 2` **or** Layer 1 `twoOfThree` / `runLength ≥ 2` **or** `alertEligible && isOffUsual(zLong, k)`. Otherwise it resets.

**Severity (first match):**

1. **Safety cap** (still wrist) → `severe` (may notify without UniTS or a second vital).
2. Else **Daily log `confoundsUsual`** (illness, travel, extra med, alcohol, untypical sleep/diet) → `note` if no hot channels, else **`candidate`** (never active/severe from UniTS). Safety still wins if it fired first.
3. Else ≥ 3 vitals at `tau_severe` **and** persist ticks ≥ 2 **and** TRUST ≥ 35% (or no evaluations yet) → `severe`.
4. Else (≥ 2 hot **or** persistEval) and persist ticks ≥ 2 and TRUST ok → `active`.
5. Else ≥ 2 hot or persistEval → `candidate`.
6. Else one hot channel or personal-off → `note`.
7. Else `withinLimits`.

**Notify:** `severity == severe` and (`lastNotifiedAt` nil or ≥ 30 min ago). Sets `lastNotifiedAt`. Acknowledgement does not clear the card (F02).

**Episode id:** `wd-<unix>` when leaving withinLimits/note into candidate/active/severe. Cleared on `resolved` or quiet `withinLimits`. Kept across `dataUnavailable` so a gap is not a new episode.

**Episode state machine** (`WatchdogCarry.priorState`, `consecutiveQuietTicks`):

| From | Event | To |
|---|---|---|
| any | window failure | `dataUnavailable` (quiet counter **reset**; **not** recovering/resolved) |
| — | candidate severity | `candidate` |
| — | active or severe | `active` (severe is a **severity**; the episode state is still active) |
| candidate / active / recovering | withinLimits or note | `recovering` (first quiet tick) |
| recovering | second quiet tick | `resolved` |
| nil / withinLimits / resolved | note | stay `withinLimits` (note is a level, not an episode) |

Copy:

- recovering: “This stretch is settling toward your usual.”
- resolved: “This stretch looks like you.” / “Resolved · episode closed”
- withinLimits (successful window only): “Within limits · no current deviation detected”
- unavailable: “Watching is not current.” / “Data unavailable (…) · not recovered”

**Inject quiet:** synthetic still 58 bpm / 48 ms / 33.1 °C / 14 /min / motion 0.

**Inject severe:** combined vignette 96 / 16 / 34.3 / 22 / motion 0, and `consecutiveMismatchTicks` forced to at least 1 so the first inject can meet persist ≥ 2 after the increment.

### 1.6 App wiring

| Piece | What it does |
|---|---|
| `AppModel.watchdog` | `WatchdogService` instance. `start(on:)` after first `repo.refresh()` on launch. |
| `WatchdogService.loadWindow` | Reads SQLite + merges `liveHRRing` / `liveRRRing`. Family from `selectedWhoopModel`. Skin temp via `skinTempCelsius(raw:family:)`. Gravity becomes both interpolated occupancy **and** `WatchdogIMUSample` (x,y,z,`dynAccel`). Steps from `store.stepSamples`. Wrist off if last event prefix `WRIST_OFF` **or** `!live.worn`. |
| `WatchdogService.bindLive` | Subscribes to `live.$heartRate` and `live.$rr` **only to capture** samples into 30-min rings. Reconstruction still runs on the 20 s loop, not on every BLE sample. |
| `WatchdogNotifier` | `UNUserNotificationCenter` alert+sound. Title “Watchdog” or “Watchdog test”. Body = headline + episode line. Thread id = episode id, or `watchdog-test` when `test: true`. **The live card does not show that headline**; Test Centre does. |
| `BaselineStore` | `watchdogResult`, `liveIntervalMinutes`, `setLiveInterval`, `applyWatchdog`. Interval persisted. Result is **not** a Layer 1 column. Reconstruct cadence is `tickSeconds`, not this store field. |
| Carry persist | JSON `WatchdogCarry` under `noop.watchdog.carry.v1` so cooldown / episode survive process death. |

Scheduler is **not** named `WatchdogScheduler.swift`; the loop lives in `WatchdogService`.

### 1.7 UI (as shipped)

Watchdog is **not a tab** and **not a collapsed fold**. `BaselineMonitorView` puts `WatchdogPlaceholderView(embedded: true)` **first** (`WatchdogView.swift`; the struct name is still `WatchdogPlaceholderView`).

**Live baseline card** (this is what the wearer sees):

- Title **Live baseline**. Teal is not required; the card uses `NoopCard` + status tokens.
- Banner: pulsing **On** when `monitoringCurrent` and not unavailable, else waiting copy (`Just now` / `Waiting on a reading`).
- **Context chips (v2.1):** current activity class, **HR ≠ RHR**, Adaptive σ or Calibrated σ.
- **TRUST %** at the top of the vitals (not per row). Caption includes activity and that HR / RHR usuals are separate.
- One footnote: pulse vs still RHR are never mixed; green band adapts to quiet residual and IMU context; **not a diagnosis**.
- **Six equal rows:** Heart rate (caption: Pulse · awake usual), Resting HR (Still minutes · sleep usual), HRV, Wrist temp, Breathing, SpO₂. Each row: live number, 30-mark strip, reconstructed number, **In sync / Out of sync**.
- Combiner `headline` / `episodeLine` / NOW–USUAL–THIS STRETCH / `LiquidThread` / SIGNALS chips / interval buttons are **not** on this card. Headlines still exist on `WatchdogResult` for **notifications** and **Test Centre**.
- Before the first tick: Waiting, TRUST caption “Usual is still being learned.”, rows `—`. **Does not** say “no current deviation detected.”
- Notification permission requested on appear.

Test Centre (`#if DEBUG` only): WATCHDOG card with last **headline**, quality line, Tick now, Quiet, Severe, Test notification (`threadIdentifier = watchdog-test`). Interval 1/2/5/10 buttons are **not** on the live card.

Release: Test Centre block compiled out. Live baseline card remains.

### 1.8 Tests (`swift test --filter Watchdog`)

**45 tests** in `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/WatchdogTests.swift` (`WatchdogWindowTests`, `WatchdogTests`, `WatchdogIsolationTests`).

There is **no** `testWhoop5FailsIfFiveSecondGapRuleWereApplied`. Sparse 30 s live on WHOOP 4 is `testSparseWhoop4CadenceStillDisplays` (must still display).

**Window**

| Test | Asserts |
|---|---|
| `testWhoop4OneHzThirtyMinutesIsAvailable` | 30 buckets, coverage ≥ 0.80 |
| `testWhoop5ThirtySecondCadenceIsAvailable` | 30 s spacing is **available** on 5/MG |
| `testSparseWhoop4CadenceStillDisplays` | same 30 s tape **displays** on WHOOP 4 |
| `testRestingHRUsesLastTenStillMinutesOnly` | RHR strip is last-10 still BPM, full width |
| `testSpo2KeepsPercentAndDropsOpticalADC` | 97 kept; 12450 dropped |
| `testPPGRecordIndexKeepsTwoRecordsInTheSameSecond` | two identities, same `ts` |
| `testCarryForwardSameTimestampIsNotANewObservation` | 3600 rows → 1800 unique ts |
| `testEmptyHRIsUnavailable` | empty feed fails |
| `testHoldForwardFillsBreathingGapsWhileOnWrist` / `testHoldForwardUsesSeedWhenWindowHasAGap` | last-good / seed hold |
| `testMotionGapsAreInterpolatedNotZeroed` | occupancy holes are not occupancy 0 |
| `testRmssdGridDropsEctopicJumps` | Malik + range on live RMSSD |
| `testWristOffIsUnavailableNotRecovered` | no notify; not resolved; no “looks like you”; no “no current deviation” |

**UniTS / reconstructor**

| Test | Asserts |
|---|---|
| `testQuietWindowEnergyBelowTau` | in-band strip, HR/temp/resp energy < 1 |
| `testCombinedVignetteExceedsTauSevereOnThreeVitals` | 96/16/34.3/22 vs 58/48/33.1/14 → ≥ 3 channels ≥ 2.0; version pin |
| `testCoreMLHatAndSigmaMatchPhysicsDecoder` | bundled `UniTS_AD.mlpackage` loads; Core ML hat/sigma match Swift physics |
| `testPredictedScaleIsNotThisWindowScatter` | \(\sigma\) ignores a noisy window |
| `testHRVBandUsesReconstructionSNRNotEightMsFloor` | HRV half-width follows \(\rho \times \hat{x}\), not 8 ms |
| `testOccupancyWidensHRBandFromTheModelNotFromLiveScatter` | HR \(\sigma\) widens with occupancy |
| `testLiveEndOutsideTheBandIsHotEvenIfMedianIsQuiet` | last paired minute can flag when the 30-min median is quiet |
| `testTrailingHatWithoutLiveSampleIsNotAFalseOff` | occupancy-only trailing hat is not paired |
| `testFlatShiftStaysHotEvenWhenEveryMinuteIsTheSame` / `testFlatRestShiftStaysHotWithPredictedScale` | rest tachycardia vs prompt |
| `testWidePersonalMADRaisesTheOffThreshold` | Layer 1 MAD in \(\sigma\) |
| `testMotionExplainsHighHRSoWorkoutIsNotARestMiss` | HR = usual + 28 at occupancy 1 → energy < tau_severe |
| `testEachVitalHasItsOwnReconstructionShape` | six channels are not one occupancy mix |
| `testHRDottedLineRisesWhenOccupancyRamps` / `testHRHatDoesNotChaseARestingSpike` | hat follows occupancy, not a live spike |
| `testMissingUsualFallsBackToWindowMedianSoTheStripHasAHat` | no Layer 1 → window median base |
| `testSleepHRVStaysPersonalUntilAwakeUsualExists` | no population sleep÷wake factor |
| `testOneMinuteSpikeIsNotSevere` | last second 95 bpm → not severe, no notify |
| `testOneChannelShiftIsNoteNotNotify` | HR 70 only → `note`, contributing `["HR"]` |
| `testV26WindowWithoutRRStillBuilds` | HR-only, empty RMSSD, coverage ok |
| `testLiveHRVPromptUsesSleepDisplayMillisecondsNotDemoAwakeRest` | `prompt.hrv` is sleep `centerDisplay` (ms), not demo awake 20 ms |

**Episodes**

| Test | Asserts |
|---|---|
| `testQuietInjectDoesNotNotify` | inject quiet |
| `testSevereInjectNotifiesOnSecondTickOnlyOncePerCooldown` | first inject notifies; +60 s does not; same `episodeId` |
| `testIllnessLogCapsAtCandidate` | feltIll + vignette + persist → candidate, no notify |
| `testReplayDoesNotUseFutureSamples` | HR at now+120 ignored |
| `testSafetyCapStillRestTachycardiaNotifies` | still, 132 bpm → severe + notify |
| `testWorkoutHighHRIsNotSafetyCap` | motion 1, 132 bpm → not severe |
| `testQuietAfterSevereGoesRecoveringThenResolved` | severe → quiet → recovering → second quiet → resolved |
| `testUnavailableAfterActiveIsNotRecovery` | prior active + `.failure(.coverage)` keeps episode id, state unavailable |
| `testFourteenQuietWindowsNeverSevere` | 14×24 quiet ticks, 0 severe, 0 notify |
| `testLiveIntervalClamp` | 7 → 5; model version pin; TRUST v2 examples |

**Isolation**

| Test | Asserts |
|---|---|
| `testWatchdogDoesNotMoveUsualHashes` | 100 Watchdog evals (including off-usual windows) then re-`evaluate` Layer 1; `center_7`, `center_long`, spreads, `k`, `nCleanLong` identical |

### 1.9 Files (as shipped)

| Path | Role |
|---|---|
| `Packages/StrandAnalytics/Sources/StrandAnalytics/WatchdogConfig.swift` | Frozen knobs |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/WatchdogWindow.swift` | Cadence adapter |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/UniTSRuntime.swift` | Prompt + reconstruct (Core ML first) |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/UniTSCoreML.swift` | Process-wide `MLModel` load + inference |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/Resources/UniTS_AD.mlpackage` | Bundled checkpoint |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/Watchdog.swift` | Combiner, inject, synthetic feed |
| `Packages/StrandAnalytics/Baseline/units/COMMIT.txt` | UniTS pin note |
| `Packages/StrandAnalytics/Baseline/units/WatchdogConfig.json` | Same knobs for humans / later Core ML |
| `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/WatchdogTests.swift` | 45 Watchdog tests (window, UniTS, Core ML, episodes, isolation) |
| `Tools/units-watchdog/export_coreml.py` | Trace `UniTSAD` → mlprogram FLOAT32 |
| `Strand/Resources/Watchdog/UniTS_AD.mlpackage` | App-side copy of the same checkpoint |
| `Packages/StrandAnalytics/Baseline/units/UniTS_AD.sha256` | SHA256 of `weight.bin` |
| `Strand/Watchdog/WatchdogService.swift` | 20 s loop, SQLite + live rings, persist carry |
| `Strand/Watchdog/WatchdogNotifier.swift` | Local severe / test notify |
| `Strand/Data/BaselineStore.swift` | Result + interval |
| `Strand/App/AppModel.swift` | Owns service, starts after refresh |
| `Strand/Screens/BaselineMonitorView.swift` | Live baseline card first |
| `Strand/Screens/WatchdogView.swift` | Six-row live card (`WatchdogPlaceholderView`) |
| `Strand/Screens/TestCentreView.swift` | DEBUG Watchdog block |
| `docs/FRWHOOP_WATCHDOG.md` | This record (copy under `Packages/StrandAnalytics/Baseline/`) |

**Not shipped:** remote fan-out, SpO₂ **ADC** alerts, on-device **training**. Core ML export + `UniTS_AD.mlpackage` **are** shipped. SpO₂ **percent** is a live channel.

### 1.10 Honest gaps vs the original plan (do not paper over)

| Plan item | V1 |
|---|---|
| Bundled Core ML UniTS | **Shipped.** `UniTS_AD.mlpackage`; `reconstruct` reads hat + sigma. Swift decoder is fallback. |
| Python golden residuals | **Not yet.** Swift unit tests (including Core ML match) are the goldens for `units-ad-coreml-v1` / `units-ad-recon-v3`. |
| Extra Watchdog pass immediately after every `BaselineStore.rescore` | Live loop + launch tick only. Night rescore does not itself call Watchdog. |
| Test Centre: cadence profile toggle, disable-UniTS switch, isolation stamp on screen | Inject quiet/severe, Tick now, test notify. Isolation is a **unit test**, not a UI stamp. |
| Quiet-hours pref | Follow-up. |
| Persist full `WatchdogResult` across launches | Carry (episode / cooldown) persists; the last result is in-memory until the next tick. |
| `UniTSPrompt` HRV | `hrv` is sleep `centerDisplay` (**ms** after Layer 1 exp). Shown awake-rest fills `hrvAwake` and reconstruction uses `hrvAwake ?? hrv`. Live residual is never ln(RMSSD). `hrvAnchoredInSleep` is a flag only; there is **no** sleep÷wake multiplier. |
| Live interval 1/2/5/10 min | Stored and clamped. The reconstruct loop is **20 s**. `tick` currently does not read the stored interval. |
| Gap / freshness gates | Knobs exist. Live `build` does not fail on them; sparse WHOOP 4 still displays. |
| PPG waveform → `ppgHr` inside the window | Identity helper is tested; live window currently uses stored HR samples + live BPM, with `hrSource` flagged `ppgHr` on 5/MG. Full 24 Hz concat is still a follow-up. |
| Horizon chrome (NOW / USUAL / THIS STRETCH, LiquidThread) | **Not on the live card.** Six equal vitals + In/Out. Combiner copy is for notify / Test Centre. |

### 1.11 Phone checklist (Primeagent / DEBUG)

1. Grant notifications. Open **Baseline**. The **Live baseline** card is first. Pair WHOOP. After a tick with HR in the last 30 minutes, six rows should fill (dotted hat + green band). If the window is empty or wrist-off, expect Waiting / not current — that is correct, not a crash.
2. Test Centre → **WATCHDOG**: **Quiet** → no banner. **Severe** twice quickly → **one** notification (cooldown). Card stays severe until two quiet ticks. Headlines appear here, not as a sentence on the live card.
3. Reconstruct cadence is **20 s**, not 1 Hz. Stored live-interval minutes are not the loop.
4. Wrist off / kill BLE → unavailable, “not recovered”, no notify, not “resolved.”
5. After inject severe, Baseline usual plots (`center_long`, band) **unchanged**.

Gate on a laptop: `cd Packages/StrandAnalytics && swift test --filter Watchdog`.

---

## 2. Why UniTS is the detector (product)

The opening **Why UniTS for Watchdog (not TimesFM)** is the decision. This section is the shorter product restatement.

UniTS is a **single transformer** trained for forecasting, classification, imputation, and **anomaly detection** (Gao et al., NeurIPS 2024). For AD it does **not** output a disease label. It takes a window that may already contain odd values, **generates** what that window should look like, and measures reconstruction error. Large, coherent error means “this stretch does not match the patterns for this kind of series.” That is the Watchdog question.

It was pretrained across sampling rates. That matches WHOOP 4 live (~1 Hz), WHOOP 5/MG live (~30 s), historical 1 Hz, and 24 Hz PPG that type-47 stores with identity `(ts, recordIndex)` so two records in the same unix second both survive.

TimesFM and other forecast FMs are the wrong head: they continue a series into the **future**. Watchdog scores the **last 30 minutes** against a reconstruction conditioned on this person’s usual and occupancy. Detail: opening section.

**What UniTS is not.** It is not the 7-day or 60-day usual. Those stay Layer 1 so the person can still see “today vs this week vs longer usual” when the neural net is unavailable. It does not name a diagnosis, prove a medication effect, or replace Charge.

Nearby published work (context, not a claim we have replicated it): UniTS AD tables; Prenkaj et al. on personal HRV / stress AD with UniTS; NightSignal / RHRAD (Nature Medicine 2022) for the **job** of consecutive overnight RHR flags — we copy **persistence**, not their detector.

---

## 3. Product job and output contract

Two timescales stay separate:

| Layer | Timescale | Owner | Reconstruction? |
|---|---|---|---|
| **Usual** | Days (this week + 60-day longer copy) | `LongitudinalBaseline.evaluate` | **Never.** Does not move center, spread, `k`, slope, CUSUM, freeze, or trial. |
| **Watchdog** | Re-score every **20 s** while the iPhone loop is running | `Watchdog` + `UniTSRuntime` | **Yes.** Residual is the main “unexpected pattern” score. |

Three lanes, then **one episode**:

| Lane | Role | V1 |
|---|---|---|
| **High / low** | A valid serious breach does not wait for UniTS or a second vital | Rest HR / temp / resp / RMSSD caps while still |
| **Personal change** | Signed `z` vs the prior usual (read-only) | `LBEvaluation` `zLong`, `runLength`, `twoOfThree`, `alertEligible`, TRUST |
| **Temporal mismatch** | Reconstruct the last 30 minutes | `units-ad-coreml-v1` (`UniTS_AD.mlpackage`); Swift `units-ad-recon-v3` if Core ML cannot run |

| Level | Meaning | Local notify |
|---|---|---|
| 0 **note** | One weird reading, one window | No |
| 1 **candidate** | Persists or 2+ channels, or context explained | No |
| 2 **active** | Unexplained after persistence | No |
| 3 **severe** | Safety cap **or** large multi-signal miss across consecutive ticks | **Yes**, cooldown |
| **unavailable** | Wrist off, coverage, gap, stale, empty | No (and **not** recovery) |

### 3.1 What “reconstructed” means on the card

| UI | Meaning |
|---|---|
| Left number | Observed at the last aligned minute (native units; temp follows °C/°F setup) |
| Dotted line | \(\hat{x}_t\) for each of the 30 minutes |
| Green band | \(\hat{x}_t \pm \sigma_t\) from the same reconstruct call |
| Right number | Last reconstructed value |
| In sync / Out of sync | Off if \(\|x-\hat{x}\| > \sigma\) at last aligned minute **or** energy ≥ `tau` |
| Residual (engine, not printed) | \(\max(\|\mathrm{median}((x-\hat{x})/\sigma)\|,\; |x_{\mathrm{last}}-\hat{x}_{\mathrm{last}}|/\sigma_{\mathrm{last}})\) |

Horizon (1- and 5-minute ahead) stays **shadow** if a future checkpoint has it. Notifications use **observed vs reconstructed** on the window that already happened. Combiner sentences (`headline`, `episodeLine`) are for notify / Test Centre, not the six-row card.

Numbers below are **first-pass engineering examples** for inject and for reading this file. They are not clinically validated safety limits.

### 3.2 Severe examples

Worked person: longer-usual sleep RHR **58 bpm**, RMSSD **48 ms**, wrist **33.1 °C**, **14** breaths/min. Wrist on, Daily log not ill. Two live ticks unless noted.

**Intended notify vignette (inject severe):** still wrist, HR 96, RMSSD 16, temp 34.3, resp 22. Energy high on three+ vitals, persist ticks ≥ 2 → severe local notification. Copy lists numbers vs usual, **not** a disease name.

**Note-only:** one minute 78 bpm then back; one channel +12 bpm; workout 160 with high `dynAccel`.

**Must not notify:** off-wrist (looks like temp drop + no HR), coverage holes, one UniTS channel for one tick, motion alone, raw PPG ADC, SpO₂ ADC, battery.

Wrist on/off comes from the EVENT stream (`WRIST_OFF*` / `WRIST_ON*`) plus `LiveState.worn`.

### 3.3 Live baseline card (F01)

Watchdog is the **first card on Baseline**, always expanded. Usual is never titled as clinically safe.

| On screen | Field |
|---|---|
| Live baseline | Title |
| On / waiting | Freshness banner (`monitoringCurrent`) |
| TRUST % | Header only |
| Six vital rows | Live, strip (hat + \(\sigma_t\)), reconstructed, In/Out |
| Footnote | Green band / dotted / not a diagnosis |
| Local notify body | Combiner headline + episode line (severe only) |

---

## 4. Live vs historical (NOOP + type-47 identity)

Official WHOOP-app mental model: continuous ~1 Hz wrist HR. **NOOP is not that on every generation.**

| Path | Cadence we assume | Watchdog use |
|---|---|---|
| **Live** BLE `0x2A37` / type-40 | 4.0 ~1 Hz; 5/MG often ~30 s | Samples captured into 30-min rings; UI Hz is **not** physiology |
| **Historical** type-47 | v18/v24 ~1 Hz records; v26 24 Hz PPG, HR may be derived `ppgHr` (not HRV) | Default 30-minute tape |

Type-47 PPG identity is `(ts, recordIndex)`. Several records can share a unix second. Deduping on `ts` alone threw away extras. UniTS must never `GROUP BY ts` on PPG.

**Coverage (as coded):** WHOOP 4 coverage = unique seconds with HR / 1800. WHOOP 5 = filled 60 s buckets / 30. Those fractions feed TRUST **C**. Gap and freshness numbers are still in `WatchdogConfig` / JSON. The live builder **does not** fail the window on them; `testSparseWhoop4CadenceStillDisplays` requires a 30 s WHOOP 4 tape to still display. Wrist-off and empty HR still fail. Duplicate BPM at the same `ts` is collapsed. iOS ticks only when the system grants execution; a skipped tick is not back-alerted as a new live event.

---

## 5. Isolation from long usuals (release-blocker if violated)

Watchdog APIs take `[LBEvaluation]` and windows **by value**. No `LongitudinalBaseline` mutators. No averaging the two usuals because reconstruction “agrees.” Freeze L0/G0 only from the treatment form. Daily log already drops confounded nights from usual; UniTS must not add a second drop rule. Missing samples are masked, not filled with 0. t0 is never inferred from an HR residual. Live ticks do not rescore the 60-day median.

Golden test: hash Layer 1 → 100 Watchdog evals including severe → hashes identical (`testWatchdogDoesNotMoveUsualHashes`).

`k` stays Layer 1’s band width. Residual is **not** a new `k`.

---

## 6. Core ML UniTS-AD (code as shipped)

Product: same Watchdog functions (window, combiner, notify, live card). The **reconstruction call** is Core ML on iPhone/Mac. It does **not** yet change \(\hat{x}\) vs the Swift decoder — tests require them to match. What **did** change vs the first live card is \(\sigma_t\) (per-vital predicted width) and last-minute alignment. A trained UniTS graph can later fill `delta_hat` / `delta_sigma` (or replace the package) without changing Watchdog.

### 6.1 Call graph

```
UniTSRuntime.reconstruct(_ window:, prompt:)
  occupancy = effortOccupancy(window.motion, window.activityLogits)
  if let r = coreMLResidual(window, prompt, occupancy) { return r }   // iPhone / Mac
  return physicsResidual(window, prompt, occupancy)                  // watchOS, missing package, load fail

coreMLResidual
  bases[6] = resolved Layer 1 usual else window median   // nil channel stays nil after inference
  personal[6] = prompt.scale*
  (hat, sigma) = UniTSCoreMLSession.shared.predict(occupancy, bases, personal)
  finishResidual(...)  modelVersion = units-ad-coreml-v1

physicsResidual
  reconstructHR / RHR / HRV / Temp / Resp / SpO2  (Swift, §1.3.2)
  predictedScale(...)                                 (§1.3.3)
  finishResidual(...)  modelVersion = units-ad-recon-v3

finishResidual
  score(obs, hat, predicted: sigma) per channel
  RHR: maskLookback last 10 min still
  energy = max(|median((x−hat)/σ)|, |x_last−hat_last|/σ_last)
```

`Watchdog.combine` then uses `UniTSRuntime.lastPaired(observed, hat)` so status never pairs a live sample with a later occupancy-only hat. `WatchdogResult.rangeHR`…`rangeSpO2` are the per-minute \(\sigma\) series for the green band.

### 6.2 Checkpoint (`UniTSAD` in `export_coreml.py`)

Class `UniTSAD(nn.Module)` is traced to an mlprogram (`compute_precision=FLOAT32`, `minimum_deployment_target=iOS16`).

**Inputs** (already resolved in Swift; the graph does not invent a usual):

| Name | Shape | Channel order |
|---|---|---|
| `occupancy` | (1, 30) | class-effort occupancy (embedding → 0…1) |
| `prompt` | (1, 6) | HR, RHR, HRV ms, temp °C, resp /min, SpO₂ % |
| `personal_scale` | (1, 6) | Layer 1 MAD (or floor) |

**Outputs:** `hat` and `sigma`, both `(1, 6, 30)`.

**Decoder (same knobs as `WatchdogConfig`):**

| ch | \(\hat{x}\) | \(\sigma\) extra |
|---|---|---|
| 0 HR | \(R + 0.50 R \,\mathrm{occ}\), EMA α=0.40, clamp 35…190 | \(\rho=0.12\), \(u=0.15 R \,\mathrm{occ}\) |
| 1 RHR | \(R\) broadcast, clamp 35…120 | \(\rho=0.07\), \(u=0\) |
| 2 HRV | \(S - 4.96\,\mathrm{occ}_{\mathrm{2min}}(S/50)\), EMA 0.28, clamp 8…250 | \(\rho=0.22\), \(u=3.04\,\mathrm{occ}(S/50)\) |
| 3 Temp | \(T_0 - 0.15\,\mathrm{occ}_{\mathrm{6min}}\), EMA 0.18, clamp 28…38 | \(\rho=0\), \(u=0.10\,\mathrm{occ_{lag}}\) |
| 4 Resp | \(f_0 + 0.60 f_0 \,\mathrm{occ}\), EMA 0.32, clamp 6…30 | \(\rho=0.10\), \(u=0.20 f_0 \,\mathrm{occ}\) |
| 5 SpO₂ | \(S_0\) broadcast then EMA 0.12, clamp 88…100 | \(\rho=0\), \(u=0\) |

Then \(\sigma = \max(\mathrm{floor},\; \mathrm{personal},\; \rho|\hat{x}|,\; u)\).

**Residual slot (for a later trained swap, zero at export):**

```python
hat = physics + self.delta_hat(physics)           # Conv1d 6→6, k=1, zeros
sigma = sigma_phys + self.delta_sigma(sigma_phys).abs()
```

Re-export after knob changes:

```
python3 Tools/units-watchdog/export_coreml.py
```

Writes:

- `Packages/StrandAnalytics/Sources/StrandAnalytics/Resources/UniTS_AD.mlpackage` (SPM `Bundle.module`)
- `Strand/Resources/Watchdog/UniTS_AD.mlpackage`
- `Packages/StrandAnalytics/Baseline/units/UniTS_AD.sha256` (SHA256 of `weight.bin`; current pin `15d9d37ff035522958352abeb8d6e69779416646d8f4624fd56c64479c3f0822`)

### 6.3 Loader (`UniTSCoreML.swift`)

`UniTSCoreMLSession` is process-wide, `@unchecked Sendable`, `NSLock`, **CPU-only**.

1. Resource URL: `Bundle.module` `UniTS_AD.mlpackage`, else `Bundle.main` `Watchdog/UniTS_AD.mlpackage`.
2. **iOS / macOS:** `MLModel.compileModel(at:)` unless the URL is already `.mlmodelc`, then `MLModel(contentsOf:configuration:)`.
3. **watchOS:** `compileModel` is unavailable. `loadIfNeeded` returns `nil`; `reconstruct` uses `physicsResidual`. Watchdog live UI is an iPhone path.
4. `predict` builds `MLMultiArray` FLOAT32 inputs and reads `hat` / `sigma` planes `[channel][minute]`.

`Packages/StrandAnalytics/Package.swift` copies the mlpackage into the library:

```swift
.target(name: "StrandAnalytics",
        dependencies: ["WhoopProtocol", "WhoopStore"],
        resources: [.copy("Resources/UniTS_AD.mlpackage")])
```

### 6.4 Swift scoring / UI that wrap the model (not inside Core ML)

These stay in Swift so a future `.mlpackage` swap does not rewrite the combiner or card:

| Code | Role |
|---|---|
| `UniTSRuntime.lastPaired` | Last minute where **both** live and hat exist |
| `UniTSRuntime.score` | Energy from median + last paired, divided by \(\sigma_t\) |
| `Watchdog.combine` | Hot channels, TRUST, `rangeHalf` on `WatchdogSignalEvidence`, range series on `WatchdogResult` |
| `WatchdogLiveSnapshot.row` / `lastAligned` | Expected = reconstructed; Out of sync if \(\|x-\hat{x}\| > \sigma\) at that minute |
| `WatchdogTraitStrip` | AreaMark `hat_t ± rangeSeries[t]`; y-labels at the live-end corridor |

### 6.5 What is and is not “more ML” on device today

| Same as before Core ML | Different for the wearer |
|---|---|
| Occupancy-warped rest usuals (dotted line) | Green band is \(\sigma_t\) from the reconstructor, not a frozen ±5 bpm / ±8 ms tube |
| Combiner, notify, isolation from Layer 1 | Last minute can flag even if the 30-min median is quiet |
| Core ML hat **equals** Swift hat (tested) | Expected column follows the dotted reconstruction, not a sleep copy |

Harvard’s public UniTS transformer weights are **not** in this package. This checkpoint **is** the UniTS-AD **job** (reconstruct + predicted width) as an mlprogram. Filling `delta_*` or dropping in a trained graph is the next model change, not a Watchdog rewrite.

Never train on the phone. Recalibrate `tau` on quiet windows only.

Architecture sentence: **on-phone Core ML reconstruction, same Watchdog protocol as UniTS AD**, not a cloud model.

---

## 7. Risks

| Risk | Mitigation in v1 |
|---|---|
| Core ML export slips | Tracked; Swift physics fallback + tests still exercise combiner, notify, isolation |
| 5/MG live too sparse | Generation-specific gap/coverage; honest unavailable |
| Phone heat | 20 s ticks, 30 steps, CPU-only Core ML; not 1 Hz inference |
| Notification fatigue | Severe bar; cooldown; quiet inject must not notify |
| Mixing v18 HR and `ppgHr` | `hr_source` on the result; do not silent-splice |
| Flat-shift blindness | Prompt reconstruction instead of window z-score |

---

## 8. Out of this pass

Remote push / SMS / server fan-out, predicted-only pages, a care-team threshold form, on-device UniTS **training**, rewriting Charge. Live interval minutes as the reconstruct loop. Failing the window on gap/freshness (knobs exist; live `build` does not). Python residual goldens outside Swift tests.
