# Baseline engine assets

On-device math for **Layer 1** and **Watchdog**. Charge / Effort / Rest stay in their own files.

How the baselines work (the only published docs):

- [Overview](../../../docs/baselines/README.md)
- [Layer 1 — days and nights](../../../docs/baselines/LAYER1.md)
- [Watchdog — last 30 minutes](../../../docs/baselines/WATCHDOG.md)

| Path | Role |
|---|---|
| `units/` | Frozen Core ML pins, Watchdog config / calibration JSON |
| `fixtures/` | Synthetic daily tapes for tests |

**Code:** `LongitudinalBaseline.swift`, `Watchdog.swift`. App: `BaselineStore`, `BaselineMonitorView`, `WatchdogView`. Do not put Layer 1 or Watchdog inside `Baselines.swift`.
