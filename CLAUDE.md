# FitBridgeIOS — Project Guide for Claude

## What this app does

FitBridgeIOS is an iOS app that acts as a **BLE bridge** between an indoor bike trainer and Garmin watches (or any BLE cycling power consumer). It connects to the trainer as a BLE Central, reads power/cadence/speed, and re-broadcasts that data as a BLE Peripheral advertising as a Cycling Power Meter — so Garmin watches see FitBridgeIOS as a native sensor.

This is a port of the macOS menu bar app `~/dev/FitBridge` — same business logic, minimalist iOS UI. See "Porting notes" below for what changed.

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
| `ProfileStore.swift`, `RiderProfile.swift` | GRDB-backed rider profile (weight, FTP, Crr, CdA, SIM keep-alive) — verbatim from the macOS app |

## BLE details

### Central side (reading from trainer)

- Scans filtered to FTMS/Cycling Power service UUIDs and populates a live picker (`discoveredTrainers`) — the user taps a candidate to connect, nothing auto-connects
- Once picked, the device identifier is remembered for the running session only (never persisted to disk); a dropped connection auto-retries reconnecting to that same device up to 4 attempts (~44s total) before falling back to a fresh picker
- Prefers **FTMS** (service `0x1826`, characteristic `0x2AD2` Indoor Bike Data) over Cycling Power Service (`0x1818`, `0x2A63`)
- Requests ERG control via FTMS Control Point (`0x2AD9`)
- Power is smoothed with a **3-second rolling average** (matches Zwift/MyWhoosh display behavior)
- `parseIndoorBikeData` / `parseCyclingPowerMeasurement` bounds-check every field read (`readUInt16` returns `nil` instead of trapping) — a short or malformed packet from real trainer hardware logs and skips the field instead of crashing on an out-of-range index

### Peripheral side (serving Garmin)

`GarminPeripheral` advertises service `0x1818` with:
- `0x2A63` Cycling Power Measurement — notify, dynamic value (power + crank revolution data)
- `0x2A65` Cycling Power Feature — read, static (`0x00000008` = crank revolution data supported)
- `0x2A5D` Sensor Location — read, static (`0x00` = Other)

**Crank revolution encoding**: Garmin derives cadence from `(delta_revs / delta_time) * 60`. FitBridgeIOS uses a float accumulator (`crankRevAccumulator`) to carry fractional revolutions between updates, then advances `lastCrankEventTime` (UInt16, 1/1024 s resolution, wrapping) proportionally. This keeps cadence accurate even at 1 Hz update rates.

`GarminPeripheral` runs a 1 Hz `transmitTimer` (started on `didSubscribeTo`, stopped on `didUnsubscribeFrom`/state-off) that resends the last known power/cadence as a keepalive, independent of trainer cadence — Garmin's sensor manager drops a sensor whose characteristic goes quiet for more than a few seconds. Real trainer samples still send immediately; the timer only fills gaps.

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

## Toward the Dynamic Island (future, not implemented)

A Live Activity keeps the UI visible but does *not* by itself keep the process alive — the `bluetooth-peripheral` background mode is what does that, which is why it's enabled now. The next step when that work starts is adding `CBPeripheralManagerOptionRestoreIdentifierKey` + `peripheralManager(_:willRestoreState:)` to `GarminPeripheral` so iOS can relaunch the app into the background and hand the advertising session back.

## Known limitations / deferred work

- **Power calibration**: raw trainer power is used (after 3s averaging). Calibration UI/logic has not been implemented yet.
- **Trainer discovery**: picked device is remembered in-memory for the session only — a fresh app launch always starts over with an empty picker and no auto-reconnect to the previous device.
- **Speed**: forwarded to UI only; not broadcast to Garmin (Garmin uses wheel speed from its own GPS, not a sensor).
- **Heart rate**: not bridged; user connects HR monitor directly to Garmin.
- **ANT+**: not supported.
- **Dynamic Island / Live Activity**: not implemented — see "Toward the Dynamic Island" above.

## Adding a new feature — checklist

1. If reading new BLE data from the trainer: add UUID to `GATT` enum, subscribe in `didDiscoverCharacteristicsFor`, parse in `didUpdateValueFor`
2. If broadcasting new data to Garmin: add characteristic to `GarminPeripheral.setupServices()`, update `updateMetrics` packet
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

To run against real hardware: a `DEVELOPMENT_TEAM` must be selected once in Xcode's Signing & Capabilities tab (deliberately absent from the project file — simulator builds don't need it).

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

Pair, start a bike activity, and confirm the watch holds the sensor and cadence reads sanely — the crank-encoding regressions documented in the macOS `CLAUDE.md`'s "Known issue" section are the things to watch for; the fixes described there (timer-driven notify, crank counters reset on subscribe, stable packet layout) are all present in `GarminPeripheral.swift` here too, since it was carried over verbatim.
