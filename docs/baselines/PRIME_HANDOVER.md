# Prime handover — three engines

Use this file as the brief for a **new Prime agent test** before Rahul handover. It is not a second product spec. Scoring contracts stay in [LAYER1.md](LAYER1.md), [WATCHDOG.md](WATCHDOG.md), and [ADDONS.md](ADDONS.md).

Charge / Effort / Rest are a **fourth** engine. Do not rewrite them. Do not average them with Layer 1 or Watchdog.

```
Charge          ← out of scope (must stay untouched)
Layer 1         ← days / nights usuals
Watchdog        ← last 30 minutes
Add-ons F04/F08/F09  ← sidecars after evaluate / notify-sent
```

**Global locks for every new test**

- Three engines never averaged. Watchdog never writes Layer 1 7-day / 60-day snapshots.
- No `t0` from heart rate. Never name a drug. No on-device training.
- Wrist-off is **unavailable**, not recovered.
- Bundled graphs stay labelled **student** (`units-ad-coreml-v3`, `timesfm3-student-v3`). Word **official** is forbidden on students. TimesFM 3.0 must not ship.
- Counts use the **measurement civil minute**, not 20 s ticks.
- Active `deviceId` only. `liveAlerts == false` cannot page, open a survey, or append a ledger row.
- Existing pins must still pass. A Prime suite that moves V40 / biometric / addon hashes is a fail.

Existing suites to keep green: `LongitudinalBaseline*` (especially `LongitudinalBaselineBiometricLogicTests`), `WatchdogV40CloseoutTests`, `WatchdogStatisticsContractTests`, `WatchdogAddonSidecarTests`. Older `WatchdogPrime*` files are history, not the contract.

---

## 1 · Layer 1 — long-term baseline

### Question

What is usual for this person over **days and nights**? After they **log** a treatment start, how does tonight sit versus a **frozen** pre-start path?

Code: `LongitudinalBaseline.swift` (`param_set = v1.review`). App: `BaselineStore`, `BaselineMonitorView`, `TreatmentMarkingView`.

### Features the Prime agent must treat as shipped

| Feature | Contract |
|---|---|
| Two copies, never mixed | **7-day** finite EWMA on last 7 **completed** days (not tonight). **60-day** median + MAD on T−60…T−8 (53 slots, 7-day gap). Never average. Tonight is scored, not trained. |
| Show gates | Week copy shows at **4** nights (`n7Show`). Long copy shows at **14** nights for most vitals; **21** for steps, active minutes, IMU / waking-load. |
| TRUST / HOW OFF | TRUST = how much that copy may judge tonight. Week HOW OFF is hidden when TRUST &lt; 35. Long card does not show HOW OFF. |
| Catalog | **18** series. Sleep RHR is never mixed with awake-rest HR or steps. Sleep + steps from `DailyMetric`. IMU + daytime stubs from unique-minute `LBDayTape`. No rest+6 / ×0.88 twins. Missing stays missing. |
| Minute floors | HR/HRV ≥ 8 unique minutes; SpO₂ ≥ 4; SpO₂ nadir ≥ 3 unique fresh sleep percents; IMU coverage ≥ 60 unique minutes. |
| HRV | Math on ln(RMSSD); card shows ms. Day tapes store native RMSSD ms; `toMath` is the only ln. Leftover ln buckets migrate once (`daytape.v2`). |
| Last OK | Last **clean, habit-matched** night. Illness does not refresh freshness. Rest vs trained remap uses the last matching habit night. |
| Confounders | Only the **daily log** sets `LBDayLog.confoundsUsual`: felt ill, travel, extra/other med, alcohol, off-typical sleep or diet. Scheduled taken / missed scheduled do **not** confound. Unmarked night is clean. |
| Felt ill | Snapshots when-well / week copies for Watchdog personal-off. Does **not** open a new long epoch. Only a **logged treatment start** freezes and restarts the long path. |
| Treatment | Wearer-logged start only. Card never names a drug as the cause. |
| IMU | Own series `wakingImuEnergy`. Same window twice does not double-count. |
| Watchdog coupling | Layer 1 may **read** unique-minute observations Watchdog ingested when `shouldTrainUsual`. It does not score the last 30 minutes. |

### Display (Baseline tab, long-term card)

This is the Oct 4 visibility rule. Prime UI / store tests must pin it.

- Context pills and vital chips stay visible even when the **selected** series is still building.
- A series that has met `show7` or `showLong` is **ready**. Unready chips stay on screen, dimmed, with nights remaining (`Params.n7Show − n7`).
- `rescore(preferReadySeries: true)` (calendar swipe, context change) lands on the first ready series if the current one is not ready.
- `selectSeries` must **not** snap away from a wearer tap (`preferReadySeries: false`).
- Do not hide every plot because one vital is still learning.

### Must-hold for a new Prime Layer 1 suite

1. Week and long centers stay distinct on a fever / walk-up tape; no blended usual.
2. Three nights → week hidden; four nights → week shown, not alert-eligible by itself.
3. Illness night does not stamp `lastOK` / week `lastUpdate`.
4. Extra med drops the night; scheduled taken does not.
5. Sleep RHR observations never enter `awakeRest*`.
6. Zero / nil steps are not trained as `.ok`.
7. Charge EWMA is a different engine (existing pin).
8. Felt-ill freeze exists without resetting the long path; a week-vs-long split **without** a log does not freeze.
9. **New:** two series, only HR week-ready → readiness map says HR ready / temp not; `preferReadySeries` would select HR; explicit `selectSeries(temp)` stays on temp.

### Must-not

- Do not call `Watchdog.evaluate` from Layer 1 scoring.
- Do not invent overnight → daytime formulas or a SpO₂ nadir from mean.
- Do not let F08 annotations write `confoundsUsual`.

---

## 2 · Watchdog — last 30 minutes

### Question

Did **this half-hour** look like this person, given live motion and a reconstruction of this strip?

Code: `Watchdog.swift` `evaluate`. Window / quality: `WatchdogWindow`, `WatchdogV2`. Band: `WatchdogPhaseUsual` (`WatchdogBand.firstMinutes = 14`). App: `WatchdogService`, `WatchdogView`, `WatchdogNotifier`, `WatchdogBackgroundScheduler`.

### Features the Prime agent must treat as shipped

| Feature | Contract |
|---|---|
| Window | 30 one-minute bins. Foreground tick ~20 s. Active strap only. |
| Live line | Observed minutes. Empty minutes stay empty. Appears as soon as that vital has a finite sample in the window (often the first tick if 30 minutes already exist on the phone). |
| Dotted hat | \(\hat{x}\) from UniTS student or Swift prior. Not Layer 1 center. |
| Green band | \(\hat{x} \pm \sigma\) after **14 present minutes of that channel** on the current phase×activity key. Per-vital `nPresent`. Missing temp does not inherit HR ready. Same civil minute does not increment `n`. |
| σ | \(\max(\text{floor},\ \text{optional shown Layer 1 MAD},\ |\hat{x}|\times\text{reconFraction},\ \text{motion})\). Not this window’s residual scatter. Not Layer 1 \(k \times\) MAD. |
| Learning freeze | Band / sidecar / rest tape learn only when `shouldTrainUsual`: quality ok, not confounded, not candidate/active/severe, not personal-off. Post-workout 20 min is not learnable still. Walk key does not write still key. |
| Clocks | Per-vital freshness (HR packet clock; HRV 5 min; temp 8 min; resp / SpO₂ 6 min). Stale wiped **before** models. Missing is nil, not 0. |
| Activity | 20-col row. Unknown is not walk. First exercise family holds 120 s. Sleep from interval or last fresh col-19, not wall clock. |
| Dual J | Tanh `joint` names the strip. Clip-sum `severityJoint` (RHR out, each \|r\| ≤ 1) decides severe. Severe cannot stay `normal_*`. |
| TimesFM | At most once a minute. `forecastSource` student / hold / inject. Cannot severe-notify. Hold cube keeps emit clocks `now+60…now+300`. Wearer Early is shadow on student / hold. `present_mask` required (1 = measured). |
| Personal-off | Last fresh **native** HR / HRV vs logged felt-ill freeze or shown **60-day** usual. Never walking 7-day. Never UniTS hat. Sustained personal-off is **candidate** even if the hat is quiet. |
| Safety | Still-rest **extrema** (HR max/min, not minute mean). Out-of-band RMSSD kept. Duration held across thin / UniTS-fail ticks. Thin window still runs safety. |
| Live Off | `severity ≥ candidate` **or** safety **or** personal-off. Not Layer 1 HOW OFF. Not “last point outside the painted band.” |
| Notify | First severe of an episode pages once **after sent**. Persist / recovery = new valid observation minutes. Missing pauses recovery, does not resolve. Escalate needs a larger jump **and** 30 quiet minutes. Backfill / `liveAlerts: false` cannot notify. |
| Day tape | After tick, unique gated minutes → `LBDayTape` only if `shouldTrainUsual`. Sleep never writes `awakeRest*`. Observations, not snapshot write. |
| Carry | `v2.{deviceId}`. Switching straps clears live rings. v1 blob is not cloned onto a new id. |
| TRUST | \(50U + 35C + 15E\). Below 35 the row stays learning and does not call off. Sparse TRUST (temp / resp / SpO₂) sticks until **that** vital’s last observation changes. Layer 1 nights are **not** required to leave learning. |
| Calibration | Thresholds stay `prior-untuned`. |

### Display (first card on Baseline)

- Status **Live** while the channel is still counting toward 14 minutes.
- Same graph always: solid live line + faint dotted hat if quality allows.
- Green fill and hi/lo range **only** when `channelBandReady` and TRUST ≥ 35.
- Caption states remaining good HR minutes (`14 − presentMinutes(0)`).
- Per-vital TRUST. No page TRUST headline.

### Timing the Prime agent should encode (not wall-clock sleep)

| Visible | Gate |
|---|---|
| Live line | First finite observed minute of that channel in the 30-bin window |
| Dotted hat | Finite reconstruction on that minute |
| Green band | `nPresent[k] ≥ 14` on the current key, eligible minutes only |

Heart rate often reaches 14 in ~15 minutes of wear. Sparse temp / resp / SpO₂ take longer. Confound / open Off / wrist-off pause the count.

### Must-hold for a new Prime Watchdog suite

Re-pin leftovers 1–10 as **one file** with explicit names (do not rely only on V40 titles):

1. Day-tape HRV is milliseconds, not ln.
2. Re-reading a window or holding sparse temp does not raise `n` / tape / band.
3. Sleep minutes never train `awakeRest*`. `shouldTrainUsual` false is a tape no-op.
4. Independent channel ready: HR ready, temp not.
5. Illness does not refresh Layer 1 last-OK (Watchdog must not write that stamp).
6. Personal-off uses freeze / 60-day, not week, not hat; quiet hat + sustained personal-off → candidate.
7. Safety uses extrema; 3-tap median must not erase out-of-band RMSSD; wrist-off stays unavailable.
8. First severe pages once; persist / recovery on measurement minutes; missing does not resolve.
9. `liveOff` matches severity / safety / personal-off; sparse C is not 1.0 from one pair.
10. Students + present-mask; hold forecast cannot Early or notify; emit horizon does not slide.

**New display helpers (do not change `evaluate` to make them pass):**

- `WatchdogCarry.presentMinutes(channel:)` and `channelBandReady` follow `WatchdogBandState.nPresent` / `WatchdogBand.firstMinutes`.
- A 13-minute HR tape is not band-ready; the 14th **new civil minute** is.

### Must-not

- Do not rewrite `severity`, `fused`, `nextState`, `shouldTrainUsual`, `liveOff`, `NotifyPolicy`.
- Do not label students official. Do not add TimesFM 3.0.
- Do not infer treatment start from HR.
- Do not recover wrist-off into a green band.

---

## 3 · Add-ons — F04 / F08 / F09

Shipped **4 Oct 2026** as sidecars. They **read** Watchdog / Layer 1 decisions. They do not vote on Off, notify, or usuals.

Hook order in `WatchdogService.tick`:

```
evaluate / Layer 1 / Charge     ← unchanged
        │
        ├─ F08  annotation     after notify **sent**
        ├─ F09  ledger         after evaluate (live upsert only)
        └─ F04  recovery       after evaluate; freeze copied once
```

Pins already in `WatchdogAddonSidecarTests`. A Prime add-on file should **extend** that file or sit beside it, not replace it.

### F08 · Symptom feedback

Optional note **after a sent page**. Not the daily log.

| | Daily log | F08 |
|---|---|---|
| When | Civil-day reminder | `notifyDelivery == sent` |
| Key | Day | `episodeId` |
| Confounds usuals? | Yes, if felt-ill / extra med / … | **Never** |
| Skip / expire | Unmarked = clean | **Missing**, not “no symptoms” |

Persist: `noop.watchdog.annotations.v1.{deviceId}` (`WatchdogEpisodeAnnotation`). ~30 newest.

Must-hold:

- `pending` only on **sent** + `liveAlerts`. No pending on queued / denied / failed / backfill.
- `eventUnix` is episode open, not Save. `enteredUnix ≥ eventUnix`.
- Illness chip does not set `LBDayLog.confoundsUsual`.
- Skip / expire ≠ `symptoms=none`.
- Survey category `watchdog-episode-note` is not Watchdog extreme notify.
- Save / skip does not resolve the episode and is not acknowledgement.
- UI copy: note does not change the usual; not a diagnosis.

### F09 · Clinician export

Wearer-triggered **7-day** pack (completed days + today so far), active `deviceId` only. Not Charge digest. Not a caregiver inbox.

Ledger persist: `noop.watchdog.episodeLedger.v1.{deviceId}`. Cap 21 days. Upsert on live create / severity step. Set `closedUnix` on rearm; **do not delete**. `liveAlerts == false` → no insert.

Builder: `WatchdogClinicianExport.build`. JSON and text print the **same numbers**. Banner: not a medical device; not a diagnosis; graphs are **students**. Word **official** forbidden.

Must print separately: week copy, long copy, freeze if any. Burden = unique Off **civil minutes**. Skipped F08 = missing. Wrist-off listed as unavailable.

Must-hold:

- Builder does not queue a page or write Layer 1 hashes.
- Two ticks in one minute → one burden minute.
- Other `deviceId` omitted.
- Ledger ignores backfill.

### F04 · Event recovery

After an episode opens, **copy** `Watchdog.personalReference` (felt-ill freeze long copy, else shown 60-day). Score later eligible HR/HRV against **that** frozen ruler.

Status: `open` / `returning` / `returned` / `unknown` / `no_reference`.

Persist: `noop.watchdog.eventRecovery.v1.{deviceId}` — must **survive** carry rearm.

Must-hold:

- Walking 7-day is not the freeze.
- Missing / unavailable → `unknown`, not returned.
- No freeze and no shown long copy → `no_reference`, not population 60 bpm.
- Held minute does not advance return.
- Two eligible in-range minutes → `returned`.
- Does not change `severity`, `liveOff`, notify, or `shouldTrainUsual`.
- Watchdog reconstruct `recovering` / `resolved` is a **different** clock.

### Must-not (all add-ons)

- F02 caregiver portal, quiet hours, third-party inbox.
- Clinical activation / 14-day shadow pilot.
- Any new input into `LBDayLog.confoundsUsual`.
- Averaging the two Layer 1 copies on the export.

---

## How the Prime agent should work

1. Read this file, then [LAYER1.md](LAYER1.md) / [WATCHDOG.md](WATCHDOG.md) / [ADDONS.md](ADDONS.md). Do not invent a fourth usual.
2. Add **one** new XCTest file per section (or one file with three `// MARK:` types):  
   `WatchdogPrimeHandoverLayer1Tests`, `WatchdogPrimeHandoverLiveTests`, `WatchdogPrimeHandoverAddonTests`.
3. Prefer calling published APIs (`LongitudinalBaseline.evaluate`, `Watchdog.evaluate`, addon builders). Do not stub Off by painting a band miss.
4. After the new file is green, run `WatchdogV40CloseoutTests`, `LongitudinalBaselineBiometricLogicTests`, and `WatchdogAddonSidecarTests` again. Any move is a revert.
5. Do not commit unless asked. Do not push `main`.
6. Charge, BLE pairing, and hosted `supabase/` push are **out of scope** for this Prime pass.

### Suggested new pins (gaps as of 4 Oct)

| Section | Gap | Suggested name |
|---|---|---|
| Layer 1 | Ready vitals stay listed when another is building | `testReadinessMapDoesNotHideReadySeries` |
| Layer 1 | Auto-land on ready; tap keeps unreadied series | `testPreferReadyDoesNotOverrideSelectSeries` |
| Watchdog | 14 **minutes** not 14 ticks | already in V37 / V40; restate in handover file |
| Watchdog | `presentMinutes` / `channelBandReady` per channel | `testChannelBandReadyIsPerVital` |
| Watchdog | Live line exists before band ready | document-only unless UI tests are added; engine: hat + obs finite, `channelBandReady == false` |
| F08/F09/F04 | Cross-hook: sent → pending; evaluate → ledger + recovery; hashes unchanged | `testSidecarHooksDoNotMoveEvaluate` |
