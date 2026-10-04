# Planned sidecars — F04 / F08 / F09

**Shipped 4 Oct 2026 as sidecars.** Charge, Layer 1 scoring, and `Watchdog.evaluate` stay as documented in [LAYER1.md](LAYER1.md) and [WATCHDOG.md](WATCHDOG.md). These add-ons **read** decisions those engines already made. They do not vote on Off, notify, or usuals. Pins: `WatchdogAddonSidecarTests`.

The Sep 08 brief listed them as adjacent P1 features. They reuse episode ids, the daily log, and Layer 1 copies. They must not become a second alert engine or a caregiver product (F02).

| Id | Name | Wearer / physician | Touches scoring? |
|---|---|---|---|
| F04 | Event recovery | Time back to the **pre-event** usual after an episode | No. Own persist. After `evaluate`. |
| F08 | Symptom feedback | Optional note **after a sent page** | No. Never writes `LBDayLog`. |
| F09 | Clinician export | Wearer-shared **7-day** pack | No. Read-only builder + episode ledger. |

Implemented together on 4 Oct. Stop and revert the sidecar files if any V40 / Layer 1 biometric pin moves.

Working detail (four-way walk, file lists, pin names) also lives in the local 4 Oct log (`docs/FRWHOOP_WATCHDOG_04_OCT_2026.md`, gitignored). This file is the GitHub-facing contract.

---

## Hard locks (all three)

- Charge / Recovery not rewritten.
- Two Layer 1 copies never averaged. Watchdog never writes 7-day / 60-day snapshots.
- No `t0` from HR. Never name a drug. No on-device training.
- Wrist-off is **unavailable**, not recovered.
- Students stay labelled `student`. No `official` on an export line.
- Counts use **measurement civil minutes**, not 20 s ticks.
- Active `deviceId` only. Backfill / `liveAlerts == false` cannot open a live page, a pending survey, or a new ledger row.
- `Watchdog.swift` `severity`, `fused`, `nextState`, `shouldTrainUsual`, `liveOff`, `NotifyPolicy` — **no logic change**.
- `LBDayLog.confoundsUsual` — **no new inputs**.

```
evaluate / Layer 1 / Charge     ← unchanged
        │
        ├─ F08  annotation     after notify **sent**
        ├─ F09  ledger         after evaluate (live upsert only)
        └─ F04  recovery       after evaluate; freeze copied once
```

---

## F08 · Symptom feedback

### What it is

The **daily log** (`LBDayLog`) is a civil-day form. Saving Felt ill / travel / extra med / alcohol / off-typical sleep or diet **does** set `confoundsUsual` and changes learning.

F08 is **not** that form. It is an optional **episode annotation** after the first severe / safety banner is **sent**.

| Daily log (shipped) | F08 (planned) |
|---|---|
| 21:00 reminder `DayLogReminder` | Prompt after `notifyDelivery == sent` |
| One row per civil day | One row per `episodeId` (optional) |
| Missing day = unmarked = clean for usuals | Missing / skipped / expired = **not** “no symptoms” |
| Felt ill **confounds** usuals | Illness chip is display + export only |

**Forbidden:** `setDayLog(feltIll: true)` from the survey. That would rewrite leftovers 3, 5, and 6.

### Record

Persist key: `noop.watchdog.annotations.v1.{deviceId}`  
Type: `WatchdogEpisodeAnnotation` in a new `WatchdogEpisodeAnnotation.swift`  
Keep ~30 newest rows.

```
episodeId: String
deviceId: String
eventUnix: Int                 // episode open, not Save
enteredUnix: Int?              // nil until entered
reporter: "wearer"             // caregiver is F02
status: pending | entered | skipped | expired
symptoms: String?              // nil ≠ "none"; "none" only if they picked it
exertion: rest | light | hard | nil
stress: low | high | nil
illness: felt_off | not | nil  // annotation only
sensor: loose | charging | just_on | other | nil
note: String?
```

Rules:

- Insert `pending` only in the **sent** callback (same door that stamps `notifiedSevereEpisodeId`). Not on `queued`, `denied`, `failed`, or backfill.
- `eventUnix` is episode open (`wd-{unix}` / first candidate / `wd-safety-{unix}`).
- `enteredUnix` is Save. Always `enteredUnix ≥ eventUnix`.
- No answer in 24 h → `expired`. Do not nag the next episode. Do not send a second Watchdog page.
- Skip → `skipped`. Export prints **missing**, not “no symptoms.”
- Save / skip does **not** resolve the episode and is **not** acknowledgement.
- Survey notification category `watchdog-episode-note` is **not** `WatchdogNotifier` extreme / `shouldNotify`.

### UI

Sheet from the Baseline live card when status is `pending`. Copy must say this note does not change the usual and is not a diagnosis. Daily log sheet stays the eight-question civil-day form. Optional read-only line on that form: “This day has an episode note” — **no** extra `LBDayLog` fields.

### Pins

| Pin | Must hold |
|---|---|
| `testAnnotationDoesNotSetConfoundsUsual` | Illness chip; `confoundsUsual` unchanged unless the daily log was saved separately |
| `testAnnotationDoesNotChangeSeverity` | Same `evaluate` before / after |
| `testSkippedIsNotNegativeLabel` | `skipped` / nil ≠ `symptoms=none` |
| `testEventTimeIsEpisodeOpenNotSave` | `eventUnix` frozen at open |
| `testNoAnnotationOnQueuedOrBackfill` | No `pending` |
| `testSurveyNotifyIsNotWatchdogPage` | Category ≠ extreme notify reason |

### Files when built

| File | Change |
|---|---|
| `WatchdogEpisodeAnnotation.swift` | New |
| `WatchdogService` / sent callback | Insert `pending` |
| `BaselineStore` + sheet | Enter / skip |
| `Watchdog.swift`, `LBDayLog`, `LongitudinalBaseline` | No scoring change |

---

## F09 · Clinician export

### What it is

A **wearer-triggered** 7-day summary for a physician (share sheet / Files). Not Settings SQLite backup. Not Charge `WeeklyDigestView`. Not a caregiver inbox.

Window: last **7 completed civil days** + today so far, **active `deviceId` only**.

The live `WatchdogCarry` cannot be the source of truth: `episodeId` is cleared on rearm. F09 needs an append-only **episode ledger** that journals what `evaluate` already decided.

### Ledger (write after live evaluate only)

Persist key: `noop.watchdog.episodeLedger.v1.{deviceId}`  
Type: `WatchdogEpisodeLedger` in a new `WatchdogEpisodeLedger.swift`  
Cap: 21 days; prune older. Fail-soft: a journal error must not skip carry persist or notify.

Upsert when a live tick **creates** `episodeId` or **steps** max severity (candidate → active → severe):

```
episodeId, deviceId
openedUnix, lastUnix, closedUnix?
maxSeverity                    // candidate | active | severe
safety: Bool
personalOff: Bool
notifyDelivery                 // queued | sent | denied | failed | ""
liveAlerts: true               // rows with liveAlerts false are never inserted
offMinutes: [civilMinute]      // unique Off observation minutes (request 2)
unavailableMinutes: Int
```

On Watchdog resolve / rearm: set `closedUnix` if nil. **Do not delete** the row.

`liveAlerts == false` → no insert, no burden minute.

### Pack (pure builder, no BLE)

`WatchdogClinicianExport.build(...)` in `WatchdogClinicianExport.swift`.

JSON and a one-page text file **must print the same numbers**. Banner: not a medical device; not a diagnosis; bundled graphs are students.

| Block | Contents |
|---|---|
| Header | App build, `WatchdogConfig.configVersion`, `units-ad-coreml-v3`, `timesfm3-student-v3`, Layer 1 `param_set=v1.review`. Word **student** required. Word **official** forbidden. |
| Source | `deviceId`, strap family |
| Episodes | Ledger rows in the window |
| Deviation burden | Count of unique Off **civil minutes**; nights HOW OFF / TRUST on **each** copy |
| Baseline comparison | `copy7` and `copyLong` (and freeze if any): center, spread, n, last-OK, held? HR bpm, HRV ms. Never one blended usual. |
| Annotations | F08 rows: event time, entry time, reporter, chips. `pending` / `skipped` / `expired` = missing |
| Event recovery | F04 if present: hoursToReturn / unknown / no_reference |
| Daily logs | `dayLogsByDay` as logged (these **are** the confounders) |
| Monitored time | Minutes coverage-ok and not wrist-off, per day. Unavailable listed, not recovered |
| Evidence | Window bounds, episode ids, `calibrationSource`. No raw PPG / ADC |

Burden and monitored time use **measurement civil minutes**. Two ticks in one minute count once.

Share from Baseline toolbar: “7-day summary for a clinician.” The wearer holds the file.

### Pins

| Pin | Must hold |
|---|---|
| `testExportDoesNotCallLiveAlerts` | Builder does not queue a page |
| `testExportDoesNotWriteLayer1` | Usual hashes unchanged |
| `testExportBurdenUsesEligibleMinutes` | Two ticks, one minute → one burden minute |
| `testExportKeepsTwoCopies` | Week and long printed separately |
| `testExportMarksStudents` | Version line contains `student`, not `official` |
| `testExportSkippedAnnotationIsMissing` | Skipped F08 ≠ “no symptoms” |
| `testExportActiveStrapOnly` | Other `deviceId` omitted |
| `testLedgerIgnoresBackfill` | No append when `liveAlerts` is false |

### Files when built

| File | Change |
|---|---|
| `WatchdogEpisodeLedger.swift` | New journal |
| `WatchdogClinicianExport.swift` | New builder |
| `WatchdogService.tick` | Live upsert only |
| Baseline toolbar | Share |
| `Watchdog.swift` scoring / `LongitudinalBaseline` | No logic change |

---

## F04 · Event recovery (sibling)

After an episode opens, **copy** `Watchdog.personalReference` (felt-ill freeze long copy, else shown 60-day). Score later eligible HR/HRV against **that** copy. Status: `open` / `returning` / `returned` / `unknown` / `no_reference`.

Watchdog `recovering` / `resolved` (two quiet reconstruct minutes) is a **different** clock. F04 persist key `noop.watchdog.eventRecovery.v1.{deviceId}` must **survive** carry rearm. Missing data → `unknown`, not returned. No freeze and no shown long copy → `no_reference`, not population 60 bpm.

Does not change `severity`, `liveOff`, notify, or `shouldTrainUsual`. Full walk is in the 4 Oct log.

---

## What this is not

| Brief item | Status |
|---|---|
| F02 caregiver review | Not these add-ons. No ack portal, quiet hours, or consented third-party inbox. |
| F05 medication comparison | Treatment tab + `LBDayLog` scheduled/extra med already exist. Not this work. |
| Clinical activation (V07–V08) | Export is not a 14-day shadow pilot or a production clinical gate. |
