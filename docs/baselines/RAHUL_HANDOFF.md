# Rahul handoff — 4 Oct 2026

Branch: `nara-baseline-watchdog`. Wearer on-device engine. Not the full Sep 08 Convexia caregiver service.

Product contracts: [LAYER1.md](LAYER1.md), [WATCHDOG.md](WATCHDOG.md), [ADDONS.md](ADDONS.md).  
Prime pins: [PRIME_HANDOVER.md](PRIME_HANDOVER.md).

## Status vs original feature brief

| Brief item | Status | What shipped | Gap vs Sep 08 PDF |
|---|---|---|---|
| **Live status** | **Implemented** | Baseline first card: live line, dotted hat, per-vital TRUST, Off = candidate / safety / personal-off. Green band after 14 good minutes of that vital. | No care-team live board. Students, not official Harvard graphs. |
| **Caregiver review / acknowledgment** | **Missing** | — | F02: no inbox, ack portal, quiet hours, consented third party. |
| **Recovery tracking** | **Partial** | F04 sidecar: time back to pre-event freeze or shown 60-day. Missing → `unknown`. | Watchdog `recovering` is two quiet reconstruct minutes — a different clock. No caregiver recovery board. |
| **Medication comparisons** | **Partial** | Treatment tab + daily-log scheduled / extra med. Extra med confounds usuals; scheduled taken does not. | No F05 before/after dose contrast. Card never names a drug. |
| **Symptom feedback** | **Implemented** | F08 sheet after notify **sent**. Does not write `LBDayLog.confoundsUsual`. Skip / expire = missing, not “no symptoms.” | Wearer-only. Caregiver reporter is F02. |
| **Activity response** | **Partial** | Occupancy, 120 s workout hold, 20 min post-workout still freeze, walk key ≠ still key. | No VAR / activity-response score. |
| **Overnight summaries** | **Partial** | Layer 1 scores completed nights (two copies). Charge keeps its own overnight recovery. | No caregiver overnight digest. Watchdog does not score “last night” as a page. |
| **Clinician export** | **Implemented** | F09 wearer-shared 7-day pack + episode ledger. Students labelled. Week and long printed separately. | Not a medical device. Not a 14-day clinical activation. |

## Out of scope — hand off, do not treat as done

- **F02** caregiver review, acknowledgment, quiet hours, third-party inbox.
- **F05** medication / dose comparison engine.
- Official Harvard UniTS and TimesFM 2.5 on the phone (convert still blocked). TimesFM **3.0 must not ship**.
- Charge / Effort / Rest rewrite.
- Hosted `supabase/` push receiver (separate fork lane).
- Patient calibration / promoting `prior-untuned` thresholds.
- Android Watchdog parity.
- Broader catalog / FPR work after this handoff.

## Focused test results (this handoff)

Run from `Packages/StrandAnalytics`:

| Ask | Pin | Result |
|---|---|---|
| Correct HRV (ms, ln once) | `WatchdogV40CloseoutTests.testDayTapeHRVIsMillisecondsNotLn` | run this drop |
| No duplicate samples | `testOverlappingWindowDoesNotRaiseHRVCount` | run this drop |
| Sleep / rest split | `testSleepMinuteDoesNotEnterAwakeRest` | run this drop |
| Sustained personal deviation | `testSustainedPersonalOffIsCandidateEvenIfHatIsQuiet` | run this drop |
| Startup high/low | `testThinWindowRestHR135IsSafetySevere` | run this drop |
| Gradual severe, notify once | `testFirstSevereNotifiesOnce` | run this drop |
| Sidecars do not score | `WatchdogAddonSidecarTests` (19) | **pass** |
| Prime handover | `WatchdogPrimeHandover*` (38) | **38/38 pass** |

All of the above plus the six V40 pins were re-run together: **63/63 pass**.  
`LongitudinalBaselineBiometricLogicTests`: **11/11 pass**.

## Runnable build (iPhone)

```bash
cd /path/to/FRWHOOP_v2
xcodegen generate
# Xcode: scheme NOOPiOS, your device, Run
```

`Strand.xcodeproj` is gitignored; generate locally. Signing uses your existing NOOPiOS profile.

## Short demo (wearer)

1. Open **NOOPiOS** on the phone with the strap connected.
2. **Baseline** tab: first card is Watchdog. Live line can appear before the green band.
3. Heart-rate minutes caption counts toward 14 good minutes. Status stays **Live** until that channel is ready and TRUST ≥ 35; then the green fill appears.
4. Scroll to long-term: chips stay visible if one vital is still building; a ready vital still plots.
5. Force-quit and reopen: live card returns from `v2.{deviceId}` carry; you should not get a second severe page from restart alone.
6. Optional: DEBUG Test Centre quiet / off-wrist tapes. Test-centre notify is debug, not a live episode.
7. After a **sent** page (if one occurs): F08 note sheet. Share **7-day summary for a clinician** from the Baseline toolbar.

## Remaining limitations

- Bundled graphs are **students**. Early is shadow. Thresholds `prior-untuned`.
- Green band is per vital, 14 eligible measurement minutes; illness / Off / wrist-off pause learning.
- Wrist-off is **unavailable**, not recovered.
- Breathing / SpO₂ stay empty without a rate / percent row (WHOOP 5 v18 often has none).
- F02 / F05 / official models / calibration are not in this drop.
- Phone live + restart must be confirmed on-device (this handoff ran package tests, not a worn night).
