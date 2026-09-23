# Watchdog + Baseline — how it works

This is the short map of what is in the iPhone app now (`config_version = watchdog-v2.2`). Product contract: [FRWHOOP_WATCHDOG.md](FRWHOOP_WATCHDOG.md). Twelve review items as shipped: [FRWHOOP_WATCHDOG_NEXT_21_SEP_2026.md](FRWHOOP_WATCHDOG_NEXT_21_SEP_2026.md).

Charge and Recovery are not rewritten. All Watchdog and Baseline scoring is on-device. Nothing in this path runs in Supabase.

## Two products, one strap

| Product | Question | What it is not |
|---|---|---|
| **Baseline (Layer 1)** | What is usual for this person over days (7-day copy and 60-day copy)? After a **logged** treatment start, how does tonight sit vs a **frozen** pre-start path? | Not a drug predictor. The two usuals are never averaged. Start time (`t0`) is never inferred from heart rate. |
| **Watchdog** | Did the **last 30 minutes** look like this person, given rest usuals and live motion? | Not a 7-day usual. Does not write usuals. Does not name a drug or a disease. Does not train on the phone. |

Watchdog **reads** Layer 1 usuals as a prompt. It never writes them.

## Live Watchdog loop (every 20 s)

`WatchdogService.tick` → `WatchdogWindowBuilder.build` (30 × 60 s minutes) → `Watchdog.evaluate`:

1. **Quality** — coverage, freshness, gaps. Fail closed: wrist-off is **unavailable**, never “recovered.”
2. **Reconstruct** — Core ML `UniTS_AD.mlpackage` (`units-ad-coreml-v2`) emits \(\hat{x}\) (dotted line) and \(\sigma\) (green band) for six channels: HR, RHR, HRV, wrist temp, breathing, SpO₂. If the package cannot load, Swift prior `units-ad-recon-v3` runs and the Test Centre line says **prior fallback**.
3. **Adaptive σ** — personal quiet residual EMA, artifact widen, still HR↔HRV correlation.
4. **Forecast student** — `TimesFM3_Student.mlpackage` at most once per minute, fused only when reconstruction energy is already at note. Google TimesFM 330M weights are **not** in the app.
5. **Scores** — per-vital residual energy and joint \(J\) in Swift.
6. **Safety** — still-wrist extrema can force severe without the models.
7. **Notify** — local banner on severe episode start, safety, or escalation. Motion alone never pages.

HR prompt = awake-rest / continuous usual only. RHR prompt = sleep RHR usual only; walk/run/lift never enter the RHR strip. Motion is an 8-way IMU/step class, then a class-effort occupancy scalar into UniTS.

## What the wearer sees

First card on **Baseline** is **Live baseline**. For each vital: live value, reconstructed dotted line, green corridor, in/out of sync, TRUST % (belief in the call, not a diagnosis). Banner: **On** plus activity class when IMU/steps support it.

## Code map

| Path | Job |
|---|---|
| `Packages/StrandAnalytics/.../Watchdog.swift` | Combine evaluate |
| `WatchdogV2.swift` | Quality, adaptive σ, scores, safety, notify policy |
| `WatchdogWindow.swift` | 30-minute grid, WHOOP 4 vs 5/MG coverage |
| `WatchdogActivity.swift` | 8-way IMU/step class |
| `UniTSRuntime.swift` / `UniTSCoreML.swift` | Reconstruct hat + sigma |
| `TimesFMCoreML.swift` | Forecast student |
| `LongitudinalBaseline*.swift` | Layer 1 usuals + logged-treatment freeze |
| `Strand/Watchdog/WatchdogService.swift` | 20 s timer, SQLite/BLE feed |
| `Strand/Screens/WatchdogView.swift` | Live baseline card |
| `Tools/units-watchdog/` | Offline train + Core ML export |
| `Packages/StrandAnalytics/Baseline/units/` | Config, calibration JSON, SHA256 pins |

Gate: `cd Packages/StrandAnalytics && swift test --filter Watchdog`

## Hard rules

- Two usuals are never averaged.
- Watchdog never writes Layer 1 usuals.
- Never infer medication start from HR.
- Never name a drug or a disease.
- Off-wrist / coverage failure is unavailable, not recovered.
- No on-device training; Core ML packages are frozen.
