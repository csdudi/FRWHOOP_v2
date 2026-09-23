# Longitudinal baseline — plan and 12 Sep 2026 update (engine)

This is a working summary of **what the personal baseline project is**, **how it is meant to be built**, and **what landed on 12 Sep 2026**. It is not a replacement for the math spec ([`FRWHOOP_BASELINE_CONDENSED_PLAN.md`](FRWHOOP_BASELINE_CONDENSED_PLAN.md)) or the full implementation map ([`FRWHOOP_BASELINE_IMPLEMENTATION.md`](FRWHOOP_BASELINE_IMPLEMENTATION.md)). Screens: [`FRWHOOP_BASELINE_FRONTEND_PROGRESS.md`](FRWHOOP_BASELINE_FRONTEND_PROGRESS.md).

---

## Overall plan — what this work is for

FRWHOOP already scores **Charge** (the 0–100 recovery number on Today) with a long Winsorized EWMA. That number is useful as a daily score. It is **not** a personal usual: a fever week can pull it, it does not keep a slower “what was typical before this week,” and it does not freeze when someone starts a medication.

The baseline project adds a **second, separate engine** on the phone/Mac (`Packages/StrandAnalytics`). No Node backend. No scoring in strap firmware. Optional Supabase push only stores rows the device already computed.

**The question it answers, one biometric at a time:** how does last night compare to *this person’s* usual — this week, and over the last couple of months — without mixing series, without filling missing nights as 0 bpm, and without calling that a diagnosis.

### Two usuals (never averaged)

Every scored civil day `T` (last completed night) is compared to two copies. `T` itself is **not** folded into either window.

```
oldest                                                                 newest
|← longer usual (up to 53 nights; this week cannot vote) →|← this week (7) →|T|
T−60                                                  T−8  T−7          T−1  T
```

| Copy | Math | What it is for |
|---|---|---|
| **This week’s usual** | 7-day EWMA (`α = 0.25`) on `[T−7, T−1]` | Recency. A fever week is **downweighted / held** so the band must not sprint to 72. |
| **Longer usual** | Median on `[T−60, T−8]` (53 slots) | Slower typical, with this week excluded so a rough week cannot vote. Not a medical “when well.” |

Bands are `center ± 2 × MAD spread`. HRV math is on ln(RMSSD), display in ms. Each series (sleep RHR, HRV, temp, …) is independent. Charge stays on Today; this tab never shows a 0–100 blend of “off usual.”

**Confidence** (0–100, two percents) is how much to trust each copy: enough nights, coverage, quality, stability. It is not Charge. A weak percent should quiet an “off” claim, not invent a band.

### Treatment (the freeze)

If someone **marks a start with a clock time** (never inferred from HR), nights after that clock must not rewrite the pre-treatment control.

- Qualify first (enough quality nights). Thin data → no freeze; adaptive copies still run.
- **Non-treatment usual** = frozen slow copy from before the start.
- **On {name} usual** = live slow copy of nights *after* start, once they are old enough.
- Change since start is in native units, plus “bigger than sensor noise?” — physiology vs the frozen path, **not** “the drug worked.”
- End → washing out (7 days), then history. A new course gets a new trial id. Patient and caregiver see the **same** metrics.

### How it is supposed to be built (phases)

| Phase | Job | Product |
|---|---|---|
| **A** | Both copies, quality reasons, confidence, CUSUM / hold | Tests on synthetic tapes. No UI required. |
| **B** | Event store, qualify-before-freeze, phase clocks | Same API, trial fields on `evaluate`. Still no UI required. |
| **C** | NARA Baseline + Treatment screens | Read the API. Do not re-implement EWMA in the view. |

After C: persist nightly snapshots (`lb_v1_*`) from `IntelligenceEngine`, Android twin, real rest/active/24h columns, optional later successor math as a new `param_set`.

**Series in scope (17).** Wired to `DailyMetric` today: sleep RHR, HRV, temp, resp, SpO₂ mean, steps. Still need real daily numbers for SpO₂ nadir, awake-rest, awake-active, continuous, active minutes. Still vs moving is a **minute gate**, not a sixth series. Do not mix Apple SDNN into WHOOP RMSSD.

---

## Where the engine stood before today

Swift Phase A and B **math** was already in the tree:

- `LongitudinalBaseline.evaluate(asOf:series:observations:trial:)`
- Confidence percents, quality status/reason, Student-t hold, MAD, CUSUM `p_change`
- Trial freeze bundle, qualify fail vs pass, 68→61 worked example in tests
- Shadow helper `lb_v1_{series}_*` in memory (not written to SQLite yet)

Not done then (and still not done): call site in `IntelligenceEngine`, Kotlin twin, live WHOOP nights on the Baseline tab.

Charge / `RecoveryScorer` was and is **untouched**.

---

## What got done today (engine + how the app uses it)

The formulas did not change. The work was to **use** two independent scored days and to **surface confidence** the engine already had.

1. **Confidence on each usual.** `confidence_pct_7` and `confidence_pct_long` are now what the 7-day and 60-day range boxes show, so a reader can see how much to trust that band (full quality week pins at 100; four-night borrow at 40; stale at 0).

2. **Longer usual updates every week pan.** Short EWMA already moved with ±1 day on the scored night. The 60-day chart now has its own `longAsOf`. Each ±1 week **rescores that week** and rebuilds the gapped median. A week four weeks ago is a new 60-day window, not a frozen screenshot of tonight’s median. Tests: demo-tape spike at T−20…T−16 vs shift −4 weeks changes the center.

3. **Freeze vs inspection.** Treatment freeze still applies to the **scored night** (control must not eat on-treatment nights). The long **chart** is a rolling inspection of history (`trial: none`) so week-stepping stays honest. The missing product piece is a trial **block** on the UI (non-treatment vs on-treatment numbers) — see the frontend summary.

4. **Tests.** `BaselineStoreTests` includes confidence-when-ranges-show and weekly median rebuild. Engine: `cd Packages/StrandAnalytics && swift test --filter LongitudinalBaseline`.

---

## What is still open (engine)

| Next | Why it matters |
|---|---|
| `IntelligenceEngine` after `DailyMetric` persist → `evaluate` / `shadowPoints` | Baseline can score real WHOOP nights; late samples write a **new** `T`, they do not edit yesterday |
| Persist `lb_v1_*` in WhoopStore | Durable snapshots; UI should not walk 17 series × 60 days on every appear |
| Real rest / active / 24h / nadir / active-minute columns | Stop synthesizing those periods from sleep RHR |
| Map strap flags into `quality_reason` | Holes stay holes with a why; never 0 bpm |
| Kotlin / Android twin | Same literals as Swift tests |
| Named CSVs for every fixture in the map | Some tapes are still in-memory in tests only |

Until persist exists, the app tab may still use a demonstration tape. That is a wiring gap, not a math gap.

---

## How to check

```bash
cd Packages/StrandAnalytics && swift test --filter LongitudinalBaseline
```

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/BaselineStoreTests test
```
