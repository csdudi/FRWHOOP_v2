# Watchdog — last 30 minutes

Did the last half-hour look like this person, given rest usuals and live motion?

That is reconstruction on a short window, not the 7-day / 60-day usual. Charge / Recovery are not rewritten. Watchdog **never writes** Layer 1 usuals. It never infers a treatment start from HR. It never names a drug. **No on-device training** (Core ML stays frozen). Wrist-off is **unavailable**, not recovered.

## Loop (on the phone)

`WatchdogService.tick` → 30×60 s window → `Watchdog.evaluate`:

1. **Quality** — coverage, freshness, gaps. Wrist-off does not run the models.
2. **Activity** — motion / steps / class as a hint, not a calendar workout title.
3. **Prompt** — Layer 1 usuals (HR ≠ RHR). A small phase×activity sidecar may blend after it matures. Still no Layer 1 write.
4. **UniTS reconstruct** — dotted expected line and predicted range for HR, RHR, HRV, temp, breathing, SpO₂.
5. **Direction** — all six channels, equal weight.
6. **TimesFM student** — at most once a minute. Can show **Looking ahead**. Cannot severe-notify.
7. **Events** — exclusive name after a short hold. No human labels. Workout only if reconstruction is quiet.
8. **Green band** — small updates on eligible still minutes. Workouts and spikes do not widen it.
9. **Safety** — still-wrist extrema can page without the models.

**TRUST** on the live card is how much to believe this half-hour’s in-range / off call. Below 35% the wearer card stays in **learning** and does not call a reading off.

## Notifications

A real push is extreme only: safety extrema, or a severe reconstruction that persists and is an abnormal / safety family. Not a diagnosis. No push for looking ahead, workouts, or normal still/sleep.

## What the wearer sees

First card on **Baseline**: live value, predicted range, TRUST, a short activity phrase. Empty minutes stay empty. DEBUG Test Centre can play short tapes (quiet, walk, learning, off wrist) so you are not limited to one live stretch.

## Models on the phone

| File | Job |
|---|---|
| `UniTS_AD.mlpackage` | Reconstruct this 30-minute strip |
| `TimesFM3_Student.mlpackage` | Short forecast student |
| Swift prior | Fallback if Core ML cannot load |

| Piece | Path |
|---|---|
| Evaluate | `Packages/StrandAnalytics/Sources/StrandAnalytics/Watchdog.swift` |
| Quality / notify | `WatchdogV2.swift` |
| Events / band | `WatchdogEventGeometry.swift`, `WatchdogEventLabeler.swift`, `WatchdogPhaseUsual.swift` |
| UI | `Strand/Screens/WatchdogView.swift` |
| Pins | `Packages/StrandAnalytics/Baseline/units/` |
