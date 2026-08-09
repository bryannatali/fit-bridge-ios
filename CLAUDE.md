# FitBridgeIOS — Project Guide for Claude

## What this app does

FitBridgeIOS is an iOS app that acts as a **BLE bridge** between an indoor bike trainer and Garmin watches (or any BLE cycling power consumer). It connects to the trainer as a BLE Central, reads power/cadence/speed, and re-broadcasts that data as a BLE Peripheral advertising as a Cycling Power Meter — so Garmin watches see FitBridgeIOS as a native sensor.

This is a port of the macOS menu bar app `~/dev/FitBridge` — same business logic, minimalist iOS UI. See "Porting notes" below for what changed.

## Commit conventions

Always write semantic commit messages: `<type>: <summary>`, imperative mood, under ~70 characters for the summary line. Common types here: `feat`, `fix`, `refactor`, `docs`, `chore`, `test`. Do not add Claude as a co-author.

## Platform

- iOS 26.0+, Swift 5.0, universal (iPhone + iPad)
- **Build with Xcode 26.6** (`/Applications/Xcode.app`), not whatever `xcode-select` currently points at — this repo has also had `/Applications/Xcode-16.app` (16.4, iOS 18.5 SDK) installed, which cannot build an iOS 26.0 deployment target. Prefix every `xcodebuild`/`xcrun` invocation with `DEVELOPER_DIR=/Applications/Xcode.app` rather than running `xcode-select -s` (that mutates global state for the whole machine).
- Bluetooth permission: `NSBluetoothAlwaysUsageDescription` set in build settings
- `UIBackgroundModes` (`bluetooth-central`, `bluetooth-peripheral`) set in `Config/Info.plist` — this key has no `INFOPLIST_KEY_*` build-setting equivalent since it's an array, so it lives in a real partial Info.plist that Xcode merges with the generated one (`GENERATE_INFOPLIST_FILE = YES`)
- Default actor isolation: `MainActor` (set in project build settings)

## Architecture

The app has two parallel BLE roles, both running simultaneously:

```
[Trainer hardware]
      │  BLE Central (CBCentralManager)
      ▼
  FitBridge.swift  ─── forwards metrics ───►  GarminPeripheral.swift
      │                                              │  BLE Peripheral (CBPeripheralManager)
      │                                              ▼
      │                                       [Garmin watch / any BLE power consumer]
      ▼
RootView.swift  (SwiftUI, observes both)
```

## Key files

| File | Role |
|---|---|
| `FitBridge.swift` | CBCentralManager — scans, connects to trainer, parses FTMS/Cycling Power data, owns `GarminPeripheral` instance |
| `GarminPeripheral.swift` | CBPeripheralManager — advertises Cycling Power Service (0x1818), streams power+cadence to Garmin |
| `RootView.swift` | SwiftUI `NavigationStack` + `List` — observes both `FitBridge` and `GarminPeripheral` |
| `FitBridgeIOSApp.swift` | App entry point, creates `FitBridge`/`ProfileStore` as `@StateObject`, hosts `WindowGroup` |
| `VirtualSpeedModel.swift` | Pure physics — integrates speed forward from power against the rider's mass/Crr/CdA/grade. No BLE, no UI, no `import` beyond Foundation, so it's directly testable |
| `ProfileStore.swift`, `RiderProfile.swift` | GRDB-backed rider profile (weight, FTP, Crr, CdA, wind, SIM keep-alive, virtual-speed toggle) — from the macOS app, plus the `use_virtual_speed` column added in migration `v2` |
| `RideActivityController.swift` | App-target-only. Thin wrapper around `Activity<RideActivityAttributes>` — start/throttled update/end |
| `Shared/RideActivityAttributes.swift`, `Shared/GradeIntents.swift` | Compiled into both the app and `FitBridgeWidgetsExtension` targets — Live Activity content type and the grade `LiveActivityIntent`s |
| `FitBridgeWidgets/RideActivityWidget.swift` | Widget-extension-only. Renders the Live Activity: Lock Screen, compact/minimal Dynamic Island, expanded view with grade buttons |

## BLE details

### Central side (reading from trainer)

- Scans filtered to FTMS/Cycling Power service UUIDs and populates a live picker (`discoveredTrainers`) — the user taps a candidate to connect, nothing auto-connects
- Once picked, the device identifier is remembered for the running session only (never persisted to disk); a dropped connection auto-retries reconnecting to that same device up to 4 attempts (~44s total) before falling back to a fresh picker
- Prefers **FTMS** (service `0x1826`, characteristic `0x2AD2` Indoor Bike Data) over Cycling Power Service (`0x1818`, `0x2A63`)
- Requests ERG control via FTMS Control Point (`0x2AD9`)
- Power is smoothed with a **3-second rolling average** (matches Zwift/MyWhoosh display behavior)
- `parseIndoorBikeData` / `parseCyclingPowerMeasurement` bounds-check every field read (`readUInt16` returns `nil` instead of trapping) — a short or malformed packet from real trainer hardware logs and skips the field instead of crashing on an out-of-range index

### Virtual speed (`VirtualSpeedModel.swift`)

The trainer's own FTMS instantaneous-speed field (`trainerReportedSpeedKmh`) is derived from flywheel/belt speed using the trainer's fixed internal assumptions — a generic rider, a fixed virtual wheel circumference — so it reads **several km/h low** next to Zwift/MyWhoosh. Those apps ignore that field entirely and integrate speed from power against a rider-specific drag model; `VirtualSpeedModel` does the same, and `currentSpeedKmh` is its output whenever `RiderProfile.useVirtualSpeed` is on (the default). Turning the toggle off in Settings → Advanced falls back to the trainer's field.

- **Forces**: gravity (`m·g·sin θ`) + rolling (`Crr·m·g·cos θ`) + aero (`½·ρ·CdA·(v + headwind)²`), propulsion `P/v`. `ρ` is fixed at 1.225 — the same value `encodeSimPayload` assumes for the wire `Cw`.
- **Inertia is the "road feel"**: `a = F_net / (m + rotatingMassKg)`, so a surge takes seconds to build and stopping pedalling coasts down instead of dropping to zero. Steady-state speed is unaffected by `rotatingMassKg`.
- **Integrated at a steady 10 Hz** by `speedTimer` in `FitBridge`, started on connect (and on mock-trainer start), stopped on disconnect/rescan. Trainers only send at ~1–4 Hz; the timer is what makes the speed smooth and what lets it coast while packets are quiet.
- **Fed raw, un-averaged power** (`lastRawPowerWatts`), not the 3-second average — the model's own inertia is the smoothing, so the average would only add lag. A gap longer than `powerStaleAfter` (5 s) is treated as 0 W so a dropped trainer coasts down rather than holding speed forever.
- Guards: propulsive force is capped as if `v ≥ 1 m/s` (`P/v` diverges at a standstill), acceleration is clamped to ±3 m/s², a tick longer than 2 s (app was suspended) is not integrated in full, and rolling resistance is switched off below 0.05 m/s so it can't push the bike backwards.
- **Cycling-Power-only trainers get speed too** — they report no speed field at all, so `currentSpeedKmh` used to sit at 0 for them.
- Sanity values (84 kg total, Crr 0.004, CdA 0.30, no wind): 100 W → 26.8, 200 W → 34.9, 300 W → 40.6 km/h; 250 W at 5 % → 18.3 km/h. The profile's default 0.8 m/s headwind costs ~1.8 km/h at 200 W — **set headwind to 0 to match Zwift exactly**, which models no wind.
- `expectedResistivePower` (the UI's "Expected: N W") now comes from `VirtualSpeedParameters.resistivePower(atSpeedMps:)`, the exact inverse of what the model integrates, so it includes grade and wind. During acceleration it reads *below* actual power — the difference is what's accelerating the simulated bike.

### Grade

`FitBridge.gradePercent` (session state, not persisted) drives two things: the virtual speed model, and the trainer's FTMS SIM parameters — the second is what the legs actually feel. The slider in the Simulation section writes it; the write to the control point is debounced 250 ms so a drag doesn't flood the trainer, while the model tracks it live. `resendSimulationParameters()` must always pass the current grade — the 30 s SIM keep-alive would otherwise flatten the road back to 0 % every time it fired.

### Peripheral side (serving Garmin)

> **Hard rule #1: advertise exactly one service. Never more than one.**
>
> A Garmin watch treats one BLE peripheral as one sensor. Advertising a second service asks it to hold two sensor identities over a single connection, which its sensor manager does not do reliably — **the watch loses its connection to the app**, mid-ride and repeatedly, and whatever the second service carried arrives wrong or not at all.
>
> This is not theoretical: it was tried with `0x1816` CSC alongside `0x1818` and reverted on 2026-08-08 after exactly those symptoms. Don't re-add it, and don't add `0x1826`, `0x180D`, or anything else next to `0x1818` either — the rule is about the *count*, not about which service.
>
> **To send the watch a new kind of data, extend the existing `0x1818` service** — add a field to the `0x2A63` measurement packet (and the matching bit in the `0x2A65` Feature value), or add a characteristic to that service. The Cycling Power spec already carries power, wheel revolutions (speed/distance) and crank revolutions (cadence) in one characteristic. If something genuinely cannot be expressed inside `0x1818`, that is a design conversation, not a second `peripheralManager.add(...)` call.

`GarminPeripheral` advertises **exactly one service, `0x1818`**, with:
- `0x2A63` Cycling Power Measurement — notify, dynamic value (power + wheel + crank revolution data)
- `0x2A65` Cycling Power Feature — read, static (`0x0000000C` = crank **and** wheel revolution data supported; `0x00000008`, crank only, when `broadcastSpeedToGarmin` is off)
- `0x2A5D` Sensor Location — read, static (`0x00` = Other)
- `0x2A66` Cycling Power Control Point — write + indicate, **present only when `broadcastSpeedToGarmin` is on**

> **Hard rule #2: the wheel-revolution claim and the control point ship together.**
>
> If bit 2 (Wheel Revolution Data Supported) is set in the `0x2A65` Feature value, `0x2A66` **must** be in the service, and it must answer *Set Cumulative Value* (op `0x01`). If bit 2 is clear, `0x2A66` is left out. Never change one side without the other.
>
> The CPS spec makes the Set Cumulative Value procedure conditional-mandatory on that bit, so claiming wheel data without the control point is a malformed GATT database — and a client is entitled to silently ignore the wheel field, which is exactly what Garmin does. The same trap is documented on the CSC service: a sensor missing CSC's `0x2A55` SC Control Point is [detected but never reports speed](https://ihaque.org/posts/2021/01/04/pelomon-part-iv-software/), and adding it with even a no-op handler fixes it.
>
> **Confirmed on real hardware, 2026-08-08.** Before `0x2A66` existed: the watch paired, streamed power and cadence happily, and showed no speed — and the watch's `Settings → Sensors & Accessories → Power → <sensor>` menu offered *Crank Length* only. After adding it: the same menu gained a **Wheel Size** entry, and speed appeared. So the watch does implement the speed-from-power-meter path (the one PowerTap hubs use) — it just refuses to believe a sensor whose control point is missing.
>
> **That menu entry is the diagnostic.** If *Wheel Size* is absent from the watch's Power sensor settings, the watch has rejected our wheel-revolution claim; go look at the GATT database, not at the packet layout. If it's present but the speed reads proportionally wrong, it's the circumference (see below).

`handleControlPointWrite` implements Set Cumulative Value (`0x01`) for real — it rewinds `cumulativeWheelRevolutions` and `wheelRevAccumulator` together — and Request Supported Sensor Locations (`0x03`) as `[0x00]`, matching the static `0x2A5D`. Everything else answers *Op Code Not Supported*, including Update Sensor Location (`0x02`), which is only mandatory when the Feature value claims Multiple Sensor Locations; it doesn't. Responses are indications in the spec's `[0x20, opCode, result]` form and get their own `pendingControlPointResponse` retry slot, drained **before** `pendingPacket` in `peripheralManagerIsReady` — a stale measurement packet is droppable, a procedure response the watch is blocking on is not.

The characteristic is deliberately absent when `broadcastSpeedToGarmin` is off, so that mode stays byte-identical to the macOS app's known-good power-only layout and remains usable as the fallback described below.

**`didSubscribeTo`/`didUnsubscribeFrom` filter on `0x2A63`.** The control point is subscribable too (indications), and those callbacks fire once per characteristic — without the filter a watch subscribing to both would push `subscriberCount` to 2, which is wrong for the UI, for the send gate, and for the 0 → 1 reset guard described below. **Any future subscribable characteristic must be filtered out the same way.**

**Speed rides inside the power characteristic** — the worked example of the one-service rule above. The Cycling Power Measurement has a wheel-revolution field of its own (flags bit 4); that is how hub-based power meters report speed, and it is what a watch already expects from a power sensor. Because there is only ever one service, `didAdd` fires once and calls `startAdvertising` directly — no pending-service bookkeeping.

Toggling `broadcastSpeedToGarmin` calls `setSpeedBroadcastEnabled`, which tears down and rebuilds the GATT database — **the watch must be re-paired afterwards**. The rebuild is required because the toggle moves a bit in the static Feature characteristic (read once at pairing) *and* changes the measurement packet's layout; the two must always agree. That toggle is still the first thing to try if a watch that used to pair stops pairing: it reverts the peripheral to exactly the macOS app's power-only layout.

**Crank revolution encoding**: Garmin derives cadence from `(delta_revs / delta_time) * 60`. FitBridgeIOS uses a float accumulator (`crankRevAccumulator`) to carry fractional revolutions between updates, then advances `lastCrankEventTime` (UInt16, 1/1024 s resolution, wrapping) proportionally. This keeps cadence accurate even at 1 Hz update rates.

**Wheel revolution encoding** (`appendWheelData`): the watch recovers speed as `delta_revs * circumference / delta_event_time`, so the event time must be the timestamp of the **last whole revolution**, not "now". Stepping it to "now" would pair a truncated revolution count with a full interval — at ~4 rev/s and 1 Hz notifies that's a quarter-revolution of quantisation, i.e. visible speed jitter on the watch. Instead `wheelTicksAccumulator` (Double) carries the elapsed time and the event time backs off from it by how long the leftover fractional revolution has been in progress. Round-trip checked against a decoder: within 0.018 km/h at 8/20/35/50 km/h, correct across the UInt16 event-time wrap, and 0 at a standstill (revolution count stops advancing).

**Watch the tick resolution.** The Cycling Power Measurement's Last Wheel Event Time is **1/2048 s**; the crank event time in the same packet, and CSC's wheel event time, are 1/1024 s. Using 1024 for the wheel field would halve the reported speed. At 1/2048 the UInt16 wraps every ~32 s, still far longer than the ≥1 Hz notify interval. Field order is fixed by the spec: flags(2), power(2), wheel(4+2), crank(2+2) — wheel precedes crank.

Wheel data is built **in the same packet as power**, so it goes out on every trainer sample and on the 1 Hz keepalive; the accumulators are interval-driven, so a variable send rate is fine. `FitBridge.tickVirtualSpeed` just calls `updateSpeed(kmh:)` at 10 Hz to park the latest value.

**Wheel circumference must match the watch.** `RiderProfile.wheelCircumferenceMm` (default 2096 mm = 700x23C, Garmin's own default) converts speed → revolutions here; the watch multiplies back by whatever wheel size *it* has configured for that sensor, under `Settings → Sensors & Accessories → Power → <sensor> → Wheel Size` (an entry that only appears once `0x2A66` exists — see hard rule #2). A mismatch scales the displayed speed linearly — 2105 vs 2096 is +0.4%. Garmin auto-calibrates wheel size from GPS, which indoors it has none of, so set it to Manual and enter the value explicitly rather than trusting Auto.

`GarminPeripheral` runs a 1 Hz `transmitTimer` (started on `didSubscribeTo`, stopped on `didUnsubscribeFrom`/state-off) that resends the last known power/cadence as a keepalive, independent of trainer cadence — Garmin's sensor manager drops a sensor whose characteristic goes quiet for more than a few seconds. Real trainer samples still send immediately; the timer only fills gaps.

**`didSubscribeTo` resets the revolution counters only on the 0 → 1 subscriber transition.** The counters are cumulative and the watch reads the *difference* between consecutive packets, so rewinding them underneath a central that is already streaming decodes as an enormous unsigned delta — a garbage cadence/speed spike, and typically a sensor the watch then drops. This mattered the moment a second notify characteristic existed (`didSubscribeTo` fires once per characteristic, so the second subscribe rewound the first one's stream); the guard stays regardless, since a second central subscribing mid-ride would do the same.

## Data flow for a metric update

1. Trainer sends BLE notification → `FitBridge.peripheral(_:didUpdateValueFor:)`
2. `parseIndoorBikeData` or `parseCyclingPowerMeasurement` decodes raw bytes
3. `applyPowerSample` applies 3-second rolling average → sets `currentPower`
4. `garminPeripheral.updateMetrics(power:cadence:)` is called on the main thread
5. `GarminPeripheral` builds a Cycling Power Measurement BLE packet and calls `peripheralManager.updateValue` → Garmin watch receives it

## GATT UUID constants

All GATT UUIDs live in the `GATT` enum at the bottom of `FitBridge.swift`. Add new ones there.

## Porting notes (from `~/dev/FitBridge`, the macOS app)

- **Mock trainer is reachable in the Simulator.** The macOS app only checked `--mock-trainer` *after* a `central.state == .poweredOn` guard; the iOS Simulator has no CoreBluetooth at all (state is always `.unsupported`), so that ordering would make mock mode permanently unreachable there. `centralManagerDidUpdateState` checks `mockTrainerRequested` first.
- **Mock trainer is also a runtime toggle**, not just a launch argument: `FitBridge.setMockTrainer(_:)` (backed by a `UserDefaults` flag) lets the in-app Settings → Advanced → "Mock trainer" switch start/stop the synthetic data stream without relaunching. This is the only genuinely new UI control versus the macOS app, and it exists because the Simulator can't do real BLE at all.
- **Fixed a double-`ProfileStore` bug carried over from the macOS app**: the old `FitBridgeApp.swift` declared `@StateObject private var profileStore = ProfileStore()` *and* re-assigned it in `init()`, opening two `DatabaseQueue`s on the same SQLite file at every launch. `FitBridgeIOSApp.init()` now declares `profileStore` without an inline initializer so only the `init()`-created store is ever built.
- **No App Nap equivalent needed at the app-entry level.** The macOS app held a process-lifetime `ProcessInfo.beginActivity` token to opt out of App Nap coalescing background timers. iOS has no App Nap; the iOS analogue, `UIApplication.shared.isIdleTimerDisabled = true`, just prevents the *screen* from locking while the app is foregrounded, and is set in `RootView.onAppear` (not in `FitBridgeIOSApp.init`, since `UIApplication.shared` isn't safely usable before the app finishes launching).
- **UI is a plain `NavigationStack` + `List`**, not a menu bar panel — no fixed 260pt width, no `DisclosureGroup`s (flattened to `Section`s), no checkbox toggle style, decimal-pad keyboards on numeric fields, no Quit button (no iOS equivalent).

## Background BLE reality

`UIBackgroundModes` is enabled, so the process keeps running and the 1 Hz keepalive timer keeps firing when backgrounded. But **iOS strips `CBAdvertisementDataLocalNameKey` and moves service UUIDs into the "overflow" area** once backgrounded — the overflow area is only readable by other iOS devices. A Garmin watch that has *already paired and subscribed* generally keeps its connection (the GATT link survives; only discovery is degraded), but a watch trying to **discover** FitBridgeIOS while the app is backgrounded will not find it. **Practical rule: keep the app foregrounded while the watch pairs.**

## Known issue: the watch must not be connected to the phone as a *phone*

Symptom: the Garmin watch discovers FitBridge in its sensor list and adds it, but hangs forever on the **"Connecting"** screen. `subscriberCount` stays 0 in the app UI (the watch never reaches the GATT subscribe step), so no packet-level fix applies.

**Cause**: a role conflict. Garmin Connect pairs the watch to the iPhone as a *phone*; using the same iPhone as a *sensor* asks the two devices to hold two simultaneous BLE connections with reversed roles. Garmin's stack won't do it. Confirmed empirically 2026-08-08.

**Fix / workaround**: disconnect the phone on the watch (Settings → Connectivity → Phone → toggle off) before pairing the sensor. This is enough — do **not** "Forget This Device" in iOS Settings → Bluetooth, which breaks Garmin Connect sync. Once FitBridge is connected as a sensor the phone link can generally stay off for the duration of the activity.

**This is not a bug in `GarminPeripheral.swift`** — the GATT server is spec-conformant. Don't go looking for packet-layout causes when this symptom appears. (`GarminPeripheral.swift` is no longer a verbatim copy of the macOS file — the measurement packet gained the wheel-revolution field — but the service, its characteristics and the crank half of the layout are unchanged. If a watch stuck at "Connecting" ever *does* turn out to be layout-related, turn off "Send speed to Garmin" to get back to exactly the macOS layout and confirm before digging further.) Note the macOS bridge never hits this, because the Mac isn't the watch's paired phone.

Related but distinct dead end investigated at the same time: iOS can only advertise the peripheral role with a rotating Resolvable Private Address (CoreBluetooth exposes no way to use a public address), and several Garmin forum threads blame RPA handling for the identical stuck-at-connecting symptom ([Edge X30](https://forums.garmin.com/developer/connect-iq/f/discussion/318804/connecting-a-phone-using-a-resolvable-private-address-to-an-edge-x30-gps), [FR965/Edge 1040](https://forums.garmin.com/sports-fitness/running-multisport/f/forerunner-965/440391/ble-heart-rate-sensors-using-private-addresses-are-not-discovered)). That turned out **not** to be the cause here. Kept as a pointer in case a future watch/firmware fails even with the phone link off.

## Dynamic Island Live Activity

Connecting the trainer (real or mock) starts a Live Activity showing power/cadence/speed in the Dynamic Island and on the Lock Screen; long-press expands it to all three metrics, SIM status, and grade controls. A Live Activity keeps the *UI* visible but does *not* by itself keep the process alive — the `bluetooth-peripheral` background mode is what does that, and it was already in place before this work started.

- **`Shared/RideActivityAttributes.swift` and `Shared/GradeIntents.swift` are compiled into both the `FitBridgeIOS` app target and the `FitBridgeWidgetsExtension` widget target.** They can't live in either target's `PBXFileSystemSynchronizedRootGroup` (a synchronized group belongs to one target only) — they're a plain `PBXGroup` in `project.pbxproj` with a `PBXBuildFile` entry in *each* target's Sources phase.
- **No `Slider` in Live Activities** — `Button`/`Toggle` backed by App Intents are the only interactive controls ActivityKit allows. Grade control is `AdjustGradeIntent(delta:)` (±0.5) and `SetGradeIntent(value:)` (Flat), matching `RootView.gradeControl`'s step and range.
- **`LiveActivityIntent`s run in the *app's* process, not the extension's.** `AdjustGradeIntent`/`SetGradeIntent` reach the live `FitBridge` instance directly through `GradeCommandCenter.handler`, a weak `@MainActor` reference `FitBridge` sets on itself at init. This is why no App Group, no Darwin notification, and no second GRDB connection were needed.
- **Updates are throttled to ~1 Hz in `RideActivityController.update(_:force:)`.** `FitBridge.tickVirtualSpeed()` calls it at 10 Hz; ActivityKit budgets updates, so pushing every tick would blow through the budget. Grade-button intents call it with `force: true` so a tap feels instant instead of waiting out the throttle window.
- **A transient BLE dropout dims the pill (`link = .reconnecting`) rather than ending the activity.** `didDisconnectPeripheral`'s auto-reconnect path (up to 4 attempts) sets this instead of calling `rideActivity.end()` — ending/restarting on every blip would flash the pill. `rescan()` and `stopMockTrainer()` are the only places that actually end it.
- **The widget extension's `NSExtensionPointIdentifier` needs a real partial Info.plist, not an `INFOPLIST_KEY_*` build setting.** `INFOPLIST_KEY_NSExtensionPointIdentifier` does *not* produce the nested `NSExtension.NSExtensionPointIdentifier` dict the OS requires to load the extension (confirmed by inspecting the built `.appex`'s `Info.plist` — the key was silently dropped) — the same class of gap `Config/Info.plist` already exists for (`UIBackgroundModes`). `Config/WidgetInfo.plist` holds it and is wired in via `INFOPLIST_FILE` alongside `GENERATE_INFOPLIST_FILE = YES`, same pattern as the app target. Symptom if this regresses: `simctl install` fails with "Failed to create app extension placeholder" / "Invalid placeholder attributes".
- Not yet done: `CBPeripheralManagerOptionRestoreIdentifierKey` + `peripheralManager(_:willRestoreState:)` on `GarminPeripheral`, so iOS can relaunch the app into the background and hand the advertising session back after termination. This solves a different problem (a *terminated* app) than the Live Activity above (a foregrounded/backgrounded one) and was deliberately left out of this work.

## Known limitations / deferred work

- **Power calibration**: raw trainer power is used (after 3s averaging). Calibration UI/logic has not been implemented yet.
- **Trainer discovery**: picked device is remembered in-memory for the session only — a fresh app launch always starts over with an empty picker and no auto-reconnect to the previous device.
- **Speed**: working end to end on real hardware as of 2026-08-08 — broadcast to Garmin as the Cycling Power Measurement's wheel-revolution field (see "Peripheral side"), derived from the virtual speed model. Requires `0x2A66` to be present (hard rule #2) and the watch's Wheel Size to match `wheelCircumferenceMm`.
- **Distance / elevation**: not accumulated *in the app* — the watch derives distance from the wheel revolution count. `VirtualSpeedModel.speedMps` is the obvious thing to integrate if an in-app readout is ever wanted.
- **Grade is manual**: there's no route or workout file driving it — the user moves the slider. No auto-undulation, no course profile.
- **Air density is fixed** at 1.225 kg/m³; there's no altitude input, so riding a real high-altitude course's numbers won't match.
- **Heart rate**: not bridged; user connects HR monitor directly to Garmin.
- **The watch's phone link is mutually exclusive with FitBridge**: pairing requires turning off the watch's phone connection, so notifications/LiveTrack/live sync are unavailable on the watch while riding with FitBridge as the sensor. Activities sync once the phone link is turned back on afterwards. No workaround from the app side — see the "Known issue" section above.
- **ANT+**: not supported.

## Adding a new feature — checklist

1. If reading new BLE data from the trainer: add UUID to `GATT` enum, subscribe in `didDiscoverCharacteristicsFor`, parse in `didUpdateValueFor`
2. If broadcasting new data to Garmin: extend the **existing `0x1818` service** in `GarminPeripheral.setupServices()` — a new field in the `0x2A63` packet (plus its `0x2A65` Feature bit), or a new characteristic on that service. **Never add a second service**: the watch loses its connection to the app. See hard rule #1 in "Peripheral side (serving Garmin)".
   - **Setting a Feature bit can oblige you to add a characteristic.** Bit 2 (wheel data) requires `0x2A66`; that cost a debugging cycle once already, so check the CPS spec's conditional-requirement table for whatever bit you're setting before assuming a bit is free. See hard rule #2.
   - **Anything notify/indicate must be filtered out of `didSubscribeTo`/`didUnsubscribeFrom`**, which count `0x2A63` subscribers only.
   - Any change to the GATT database or the packet layout means **the watch has to be re-paired** — say so in the PR/commit, and re-test pairing from scratch, not just reconnection.
3. If adding UI: edit `RootView.swift`
4. New Swift files placed under `FitBridgeIOS/` are picked up automatically — the target uses a `PBXFileSystemSynchronizedRootGroup`, not per-file project entries

## Build & run

```bash
open FitBridgeIOS.xcodeproj
```
Xcode should auto-select 26.6 for this project once opened directly; if `xcodebuild` is invoked from the command line, prefix it with `DEVELOPER_DIR=/Applications/Xcode.app` (see "Platform" above).

Build for the simulator (no signing team needed):
```bash
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild \
  -project FitBridgeIOS.xcodeproj -scheme FitBridgeIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.1' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

To run against real hardware, create `Config/Local.xcconfig` (gitignored) with your own team:

```
DEVELOPMENT_TEAM = YOURTEAMID
```

`Config/Signing.xcconfig` is the target's base configuration and pulls that in via `#include?`, so a clone without the file still builds and runs in the Simulator. `DEVELOPMENT_TEAM` is deliberately kept **out of `project.pbxproj`** — it's a personal Apple team ID, and having it there means every device build Xcode touches shows up as project-file churn in the diff. Setting the team in Xcode's Signing & Capabilities tab does work, but it writes the value straight back into `project.pbxproj`; if that happens, delete the line and put it in `Local.xcconfig` instead.

## Testing without a real trainer

### In the Simulator — mock trainer mode

**The Simulator has no CoreBluetooth at all** — both `CBCentralManager` and `CBPeripheralManager` report `.unsupported`. Use mock-trainer mode to exercise parse → 3s average → `updateMetrics` end to end (the outbound `GarminPeripheral` will not actually advertise there):

- Launch-argument form: enable `--mock-trainer` in the scheme (Product → Scheme → Edit Scheme → Run → Arguments — it's defined but disabled by default), or pass it to `simctl launch`:
  ```bash
  xcrun simctl launch --console booted com.bryan.FitBridgeIOS --mock-trainer
  ```
- In-app form: run normally, then flip Settings → Advanced → **Mock trainer**. Both paths call the same `startMockTrainer()`/`stopMockTrainer()` machinery.

### On a physical iPhone, across two machines — `Tools/TrainerSimulator` (in the macOS repo)

The macOS repo's same-Mac radio-contention limitation (one Bluetooth chip can't reliably scan and advertise at once) **does not apply here** — a Mac running `TrainerSimulator` and an iPhone running FitBridgeIOS are two separate radios. Run `./run.sh` from `~/dev/FitBridge/Tools/TrainerSimulator` on the Mac, then pick **"FitBridge-Sim"** from the FitBridgeIOS picker on the iPhone. See that repo's `CLAUDE.md` for `TrainerSimulator` details (why it must run via `run.sh` and not `swift run`, TCC/Info.plist requirements, flags).

### Against the real trainer + Garmin watch

**First turn off the watch's phone connection** (Settings → Connectivity → Phone), or the watch will hang on "Connecting" and never subscribe — see "Known issue: the watch must not be connected to the phone as a *phone*" above.

Then pair, start a bike activity, and confirm the watch holds the sensor and cadence reads sanely — the crank-encoding regressions documented in the macOS `CLAUDE.md`'s "Known issue" section are the things to watch for; the fixes described there (timer-driven notify, crank counters reset on subscribe, stable packet layout) are all present in `GarminPeripheral.swift` here too, since the power service was carried over unchanged.

Then check speed and distance on the watch against the app's own readout. The whole peripheral path (advertising, GATT database, wheel-revolution encoding) **can only be exercised on real hardware** — the Simulator reports `CBPeripheralManager.state == .unsupported`, so `setupServices()` never runs there. What can be verified off-device is the arithmetic: a decoder fed `appendWheelData`'s output recovers the sent speed to within 0.018 km/h.

Diagnosing speed on the watch, in the order that actually narrows it down:

1. **No *Wheel Size* entry** under `Settings → Sensors & Accessories → Power → <sensor>` → the watch has rejected our wheel-revolution claim. Check `0x2A66` is in the service and answering (hard rule #2), then re-pair. Do not go looking at the packet layout.
2. **Speed off by a constant percentage** → wheel circumference mismatch between the watch's Wheel Size and `RiderProfile.wheelCircumferenceMm`.
3. **Speed off by a clean factor of 2** → the event-time resolution got flipped between 1/1024 and 1/2048 s.
4. **No speed at all, but Wheel Size is present** → look at the encoding.

**Bench-test the GATT database without the watch.** Point nRF Connect or LightBlue at FitBridge from a second phone: confirm `0x1818` exposes `2A63` / `2A65` / `2A5D` / `2A66`, that `2A65` reads `0C 00 00 00`, and that subscribing to `2A66` and writing `01 00 00 00 00` (Set Cumulative Value) indicates `20 01 01` back. That separates "our GATT server is wrong" from "Garmin doesn't like something", and it's much faster than a pair-and-ride cycle.
