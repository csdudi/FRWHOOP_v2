# Watchdog (live Baseline) — how it actually works

Short map for colleagues. Head in tree: `config_version = watchdog-v2.5`, geometry `geometry-v2-selflabel`, band `band-v2-medium`. Review of today’s work: `docs/FRWHOOP_WATCHDOG_NEXT_24_SEP_2026.md`.

Charge / Recovery are not rewritten. Watchdog **never writes** Layer 1 usuals. It never infers `t0` from HR. It never names a drug or a disease. **No on-device training** (Core ML stays frozen).

## The question

**Did the last 30 minutes look like this person, given rest usuals and live motion?**

That is reconstruction on a short window, not the 7-day / 60-day usual.

## Loop (every 20 s, on the phone)

`WatchdogService.tick` → 30×60 s window → `Watchdog.evaluate`:

1. **Quality** — coverage, freshness, gaps. Wrist-off is **unavailable**, not “recovered.” Models do not run.
2. **Activity** — 30×20 features (IMU/steps/class). Class is a hint, not a calendar workout title.
3. **Prompt** — Layer 1 usuals (HR ≠ RHR). Optional 7-day phase×activity sidecar after it matures. Watchdog still does not write Layer 1.
4. **UniTS reconstruct** — dotted line \(\hat{x}\) and model \(\sigma\) for HR, RHR, HRV, temp, breathing, SpO₂. Swift owns the joint score. Quiet \(J_{\mathrm{recon}}\) means the hat **explains** the strip.
5. **Direction** — all six channels, **equal weight**. One loud vital cannot own the joint score.
6. **TimesFM student** — at most once a minute. Can raise an **Early** banner if the path is leaving. **Cannot** severe-notify.
7. **Events** — UniTS decides **what**; TimesFM helps **when**. A memory of residual signatures names repeats. **No human labels.** Workout only if reconstruction is quiet. Loud recon + walk class is **not** a workout.
8. **Green band** — small weighted updates on eligible still minutes (≤2% scale per tick, 0.75–1.40 of the first typical width). Workouts and spikes do not widen it.
9. **Safety** — still-wrist extrema can page without the models.

## Notifications (extreme only)

Daily event testing over-sent: cuts, Early, and the DEBUG **Test notification** button are not wearer alerts.

A real push happens only when:

- safety extrema fire, or
- reconstruction is **severe now** (\(J \ge 2.4\), two ticks) **and** the family is `safety_bound` or `abnormal_*`

No push for Early, forecast-only, workouts, normal still/sleep, or a new event cut. Copy: **not a diagnosis.**

## What the wearer sees

First card on Baseline: **Live baseline**. Live value, reconstructed dotted line, green corridor, in/out of sync. **Early** = forecast leaving the path (on-screen only). Test Centre (DEBUG) prints direction, \(J\), forecast \(J\), event label, cut reason.

## Models on the phone

| File | Job |
|---|---|
| `UniTS_AD.mlpackage` | Reconstruct this 30-minute strip (UniTS-AD **job**; Harvard public weights are not bundled) |
| `TimesFM3_Student.mlpackage` | Short forecast student (Google 330M TimesFM is **not** in the app) |
| Swift prior | Fallback if Core ML cannot load |

## Where to look

| Piece | Path |
|---|---|
| Evaluate | `Watchdog.swift` |
| Quality / safety / notify | `WatchdogV2.swift` |
| Direction, events, memory, band | `WatchdogDirection.swift`, `WatchdogEventGeometry.swift`, `WatchdogEventMemory.swift`, `WatchdogPhaseUsual.swift` |
| UI | `Strand/Screens/WatchdogView.swift` |
| Full 24 Sep review | `docs/FRWHOOP_WATCHDOG_NEXT_24_SEP_2026.md` |
