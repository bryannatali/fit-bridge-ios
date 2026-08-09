# FitBridgeIOS

An iOS app that bridges an indoor bike trainer to Garmin watches over Bluetooth Low Energy.

## The problem

Indoor bike trainers speak BLE (FTMS or Cycling Power Service). Garmin watches can read
that data directly, but many riders want to run the trainer through a phone — for a nicer
UI, virtual speed that actually matches Zwift, or grade control during a workout. There's
no built-in way to sit a phone in the middle of that connection.

FitBridgeIOS does exactly that: it connects to the trainer as a BLE **Central**, and
simultaneously re-advertises itself as a BLE **Peripheral** — a standards-compliant Cycling
Power Meter — so a Garmin watch pairs with the phone exactly as it would with any other
power meter, with no idea a phone is in between.

```
[Trainer hardware]
      │  BLE Central
      ▼
  FitBridge  ──forwards metrics──►  GarminPeripheral
                                          │  BLE Peripheral
                                          ▼
                                  [Garmin watch]
```

This is a port of a macOS menu bar app of the same lineage — same bridging logic, rebuilt
for iOS so it can run on the phone that's usually already on the handlebars.

## What it does

- **Reads from the trainer**: connects over FTMS or Cycling Power Service, parses power,
  cadence, and speed, with a live picker for discovered devices (nothing auto-connects).
- **Serves Garmin a real sensor**: advertises a single Cycling Power Service (`0x1818`)
  carrying power, cadence, and — optionally — speed, indistinguishable to the watch from a
  dedicated power meter.
- **Computes realistic virtual speed**: trainers report speed derived from generic,
  fixed assumptions about the rider and wheel, which reads noticeably low. FitBridgeIOS
  instead integrates speed from power against the rider's actual mass, rolling resistance,
  and aerodynamic drag — the same approach Zwift and MyWhoosh use — so the number on the
  watch matches what those apps would show.
- **Drives grade**: a slider sets simulated gradient, which feeds both the virtual speed
  model and the trainer's resistance control, so the legs and the displayed numbers agree.
- **Mock trainer mode**: a synthetic data source for testing in the Simulator, which has no
  Bluetooth hardware at all.

## Main challenges

**Fitting two sensor identities through one BLE connection.** A Garmin watch treats one
peripheral as one sensor. Early on, a second GATT service was added to carry an extra data
stream (cycling speed & cadence, alongside cycling power) — the watch could not hold both
identities over one connection and dropped mid-ride. The fix was structural, not
incremental: **exactly one service, ever.** New data rides inside the existing Cycling
Power Service's characteristics instead of a service of its own.

**Claiming wheel-revolution (speed) data without the control point that must ship with it.**
The Cycling Power spec makes the *Set Cumulative Value* control point conditionally
mandatory the moment a sensor claims wheel-revolution support. Advertising that support
without it produces a GATT database a spec-compliant client is entitled to silently
distrust — which Garmin's watches do. The visible symptom was oddly specific and became the
diagnostic for it: the watch's sensor settings screen simply never grew a "Wheel Size" entry
until the control point was implemented for real.

**Recovering speed from a wheel-revolution counter without visible jitter.** Cycling Power's
wheel-revolution field pairs a cumulative count with an event timestamp; a receiver derives
speed from the deltas between packets. Naively timestamping "now" on every send pairs a
truncated revolution count with a full time interval, producing a jittery speed reading at
typical trainer sample rates. The fix carries fractional revolution progress in an
accumulator and backdates the event time to the last *whole* revolution, verified by
round-tripping the encoding through a decoder to within 0.018 km/h.

**A Garmin watch can't be a sensor and a phone at once.** Garmin Connect pairs a watch to
the iPhone as a *phone*; asking the same iPhone to also act as a *BLE sensor* asks the
watch's stack to hold two simultaneous, role-reversed connections to one device, which it
won't do — the watch hangs indefinitely on "Connecting" with no packet-level symptom to
chase. The watch's phone connection has to be turned off before pairing FitBridgeIOS as a
sensor.

**No Bluetooth in the iOS Simulator.** Both the Central and Peripheral managers report
`.unsupported` in Simulator, so the outbound Garmin-facing half of the app can only be
exercised on real hardware. A mock-trainer mode fills the gap for the inbound half — parsing,
averaging, and metric forwarding — leaving the peripheral/GATT layer to be validated with a
second BLE device (a bench tool or a real watch).

## Requirements

- iOS 26.0+
- Xcode 26.6
- A BLE trainer (FTMS or Cycling Power Service) and/or a Garmin watch to bridge to

## Building

```bash
open FitBridgeIOS.xcodeproj
```

For real devices, create a gitignored `Config/Local.xcconfig` with your own
`DEVELOPMENT_TEAM`. See `CLAUDE.md` for full build, testing, and architecture details.
