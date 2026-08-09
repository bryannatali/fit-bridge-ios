//
//  GarminPeripheral.swift
//  FitBridge
//
//  Advertises as a Bluetooth LE Cycling Power Meter (Service 0x1818) so Garmin watches can
//  discover and subscribe to live power/cadence data — and, when `speedBroadcastEnabled`,
//  carries wheel-revolution data in the *same* 0x2A63 packet so the watch records speed and
//  distance indoors where it has no GPS to derive them from.
//
//  Claiming wheel-revolution data also obliges us to expose the Cycling Power Control Point
//  (0x2A66) with the Set Cumulative Value procedure — without it Garmin ignores the wheel field
//  entirely and shows no speed. See setupServices(); it is load-bearing, not boilerplate.
//
//  Speed deliberately does NOT get its own 0x1816 CSC service: one BLE peripheral offering both
//  0x1818 and 0x1816 asks a Garmin watch to hold two sensor identities over one connection, and
//  Garmin's sensor manager does not do that reliably. The Cycling Power Measurement
//  characteristic has a wheel-revolution field of its own (flags bit 4) — that's how hub-based
//  power meters report speed, and it's what the watch already expects from a power sensor.
//

import Combine
import CoreBluetooth
import Foundation

class GarminPeripheral: NSObject, ObservableObject, CBPeripheralManagerDelegate {

    @Published var isAdvertising: Bool = false
    @Published var subscriberCount: Int = 0

    /// Wheel circumference used to convert speed into wheel revolutions. **This must match the
    /// wheel size configured on the watch for the sensor** — the watch multiplies the revolutions
    /// we report by its own circumference to get speed back, so a mismatch scales the result.
    var wheelCircumferenceMm: Int = 2096

    private(set) var speedBroadcastEnabled: Bool = true

    private var peripheralManager: CBPeripheralManager!
    private var powerMeasurementChar: CBMutableCharacteristic?
    private var controlPointChar: CBMutableCharacteristic?

    // When updateValue returns false (transmit queue full), store the packet and
    // retry it from peripheralManagerIsReady(toUpdateSubscribers:).
    private var pendingPacket: Data?
    // Same idea for a control point response. Kept separate from pendingPacket and drained
    // first: a measurement packet is stale a second later and can be dropped, but a procedure
    // response the client is blocking on cannot.
    private var pendingControlPointResponse: Data?

    // Float accumulator so fractional crank revolutions carry over between updates
    private var crankRevAccumulator: Double = 0.0
    private var cumulativeCrankRevolutions: UInt16 = 0
    private var lastCrankEventTime: UInt16 = 0      // 1/1024 s resolution, wraps at 65535
    private var lastUpdateTime: Date = Date()

    // Last metrics reported by FitBridge, resent by transmitTimer as a keepalive so the
    // characteristic never goes quiet — Garmin watches drop the sensor a few seconds into
    // an activity if 0x2A63 stops notifying, even if the trainer itself paused sending data.
    private var lastPower: Int = 0
    private var lastCadence: Int = 0
    private var lastSendTime: Date = .distantPast
    private var transmitTimer: DispatchSourceTimer?

    // Wheel revolution accounting for the 0x2A63 wheel field. Same float-accumulator idea as the
    // crank counters, but the event time is derived rather than stepped: see appendWheelData().
    // Note the resolution: the Cycling Power Measurement's wheel event time is 1/2048 s, *not*
    // the 1/1024 s that CSC and the crank field use.
    private var lastSpeedKmh: Double = 0
    private var wheelRevAccumulator: Double = 0
    private var cumulativeWheelRevolutions: UInt32 = 0
    private var wheelTicksAccumulator: Double = 0   // 1/2048 s since the subscriber attached

    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("[GarminPeripheral] state=\(peripheral.state.rawValue) isAdvertising=\(peripheral.isAdvertising) subscribers=\(subscriberCount)")
        if peripheral.state == .poweredOn {
            // macOS can fire this callback multiple times without going through an off state —
            // notably during heavy BLE central activity (FTMS control writes, sim parameters).
            // Guard on isAdvertising so we don't call removeAllServices() on a live Garmin
            // connection, which would disconnect it and cause it to show "Searching".
            guard !peripheral.isAdvertising else {
                print("[GarminPeripheral] Already advertising — skipping spurious poweredOn callback")
                return
            }
            // Real (re-)initialization: prior subscriptions are gone, start fresh.
            subscriberCount = 0
            pendingPacket = nil
            setupServices()
        } else {
            isAdvertising = false
            subscriberCount = 0
            pendingPacket = nil
            pendingControlPointResponse = nil
            stopTransmitTimer()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else {
            print("GarminPeripheral: failed to add service – \(error!.localizedDescription)")
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: "FitBridge",
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "1818")]
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        isAdvertising = (error == nil)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        // didSubscribeTo fires once per characteristic, and the control point is subscribable too
        // (indications). Count only the measurement stream, so subscriberCount keeps meaning
        // "centrals receiving metrics" for the UI, the send gate and the reset guard below.
        guard characteristic.uuid == CBUUID(string: "2A63") else { return }
        subscriberCount += 1
        // Only on the 0 → 1 transition. Resetting on *every* subscribe would rewind the
        // cumulative counters underneath a central that is already streaming — the watch reads
        // the difference between consecutive packets, so a counter that jumps backwards decodes
        // as an enormous unsigned delta (garbage cadence/speed, and a sensor the watch drops).
        guard subscriberCount == 1 else { return }
        // A fresh subscriber has no baseline: reset the accounting so the first packet doesn't
        // compute elapsed time since app launch and produce a huge/garbage cadence.
        crankRevAccumulator = 0.0
        cumulativeCrankRevolutions = 0
        lastCrankEventTime = 0
        lastUpdateTime = Date()
        wheelRevAccumulator = 0
        cumulativeWheelRevolutions = 0
        wheelTicksAccumulator = 0
        startTransmitTimer()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == CBUUID(string: "2A63") else { return }
        subscriberCount = max(0, subscriberCount - 1)
        if subscriberCount == 0 {
            stopTransmitTimer()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        // Static characteristics (Feature, Location) have pre-set values; just respond OK.
        peripheral.respond(to: request, withResult: .success)
    }

    // Called when the BLE transmit queue drains after a full-queue false return from
    // updateValue. Retry the buffered packet so no update is permanently lost.
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        if let char = controlPointChar, let response = pendingControlPointResponse {
            pendingControlPointResponse = nil
            if !peripheral.updateValue(response, for: char, onSubscribedCentrals: nil) {
                pendingControlPointResponse = response  // still congested, keep waiting
                return
            }
        }
        guard let char = powerMeasurementChar, let packet = pendingPacket else { return }
        pendingPacket = nil
        if !peripheral.updateValue(packet, for: char, onSubscribedCentrals: nil) {
            pendingPacket = packet  // still congested, keep waiting
        }
    }

    // MARK: - Cycling Power Control Point (0x2A66)

    private enum ControlPointResult: UInt8 {
        case success = 0x01
        case opCodeNotSupported = 0x02
        case invalidParameter = 0x03
        case operationFailed = 0x04
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard first.characteristic.uuid == CBUUID(string: "2A66") else {
            peripheral.respond(to: first, withResult: .writeNotPermitted)
            return
        }
        // Respond to the *first* request only — that acknowledges the whole batch at the ATT
        // layer. Each procedure's actual result then comes back as a separate indication.
        peripheral.respond(to: first, withResult: .success)
        for request in requests {
            handleControlPointWrite([UInt8](request.value ?? Data()))
        }
    }

    private func handleControlPointWrite(_ bytes: [UInt8]) {
        guard let opCode = bytes.first else { return }
        switch opCode {
        case 0x01:  // Set Cumulative Value — reset the wheel revolution total to the supplied
                    // UInt32. This is the procedure whose mere existence is what a picky client
                    // checks for before trusting our wheel data, but honour it properly anyway:
                    // a watch resetting the odometer at the start of a ride is a real use.
            guard bytes.count == 5 else {
                indicateControlPointResponse(for: opCode, result: .invalidParameter)
                return
            }
            let newValue = UInt32(bytes[1])
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3]) << 16
                | UInt32(bytes[4]) << 24
            cumulativeWheelRevolutions = newValue
            wheelRevAccumulator = Double(newValue)
            indicateControlPointResponse(for: opCode, result: .success)

        case 0x03:  // Request Supported Sensor Locations — we only ever report 0x00 (Other),
                    // matching the static 0x2A5D value.
            indicateControlPointResponse(for: opCode, result: .success, parameter: Data([0x00]))

        default:
            // Includes Update Sensor Location (0x02), which is only mandatory when the Feature
            // characteristic claims Multiple Sensor Locations — it doesn't.
            indicateControlPointResponse(for: opCode, result: .opCodeNotSupported)
        }
    }

    private func indicateControlPointResponse(for opCode: UInt8,
                                              result: ControlPointResult,
                                              parameter: Data = Data()) {
        guard let char = controlPointChar else { return }
        // 0x20 = Response Code, then the op code being answered, then the result.
        var response = Data([0x20, opCode, result.rawValue])
        response.append(parameter)
        if !peripheralManager.updateValue(response, for: char, onSubscribedCentrals: nil) {
            pendingControlPointResponse = response
        }
    }

    // MARK: - Transmit keepalive

    // Fires at 1 Hz and resends the last known metrics. FitBridge only calls updateMetrics
    // when the trainer sends a new sample, but the trainer can go quiet (rider stops
    // pedaling, exactly what tends to happen right as an activity starts on the watch) —
    // without a steady stream, Garmin's sensor manager decides 0x2A63 is dead and drops us.
    private func startTransmitTimer() {
        stopTransmitTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.sendUpdate(power: self.lastPower, cadence: self.lastCadence, force: false)
        }
        timer.resume()
        transmitTimer = timer
    }

    private func stopTransmitTimer() {
        transmitTimer?.cancel()
        transmitTimer = nil
    }

    // MARK: - Private setup

    private func setupServices() {
        pendingPacket = nil
        pendingControlPointResponse = nil
        peripheralManager.removeAllServices()

        // 0x2A63 – Cycling Power Measurement: notify-only, value is dynamic
        let measChar = CBMutableCharacteristic(
            type: CBUUID(string: "2A63"),
            properties: [.notify],
            value: nil,
            permissions: []
        )
        powerMeasurementChar = measChar

        // 0x2A65 – Cycling Power Feature: bit 3 = Crank Revolution Data supported,
        // bit 2 = Wheel Revolution Data supported (only when we actually send the wheel field —
        // the watch reads this once at pairing to decide whether to record speed from us).
        var featureVal: UInt32 = speedBroadcastEnabled ? 0x0000000C : 0x00000008
        let featureChar = CBMutableCharacteristic(
            type: CBUUID(string: "2A65"),
            properties: [.read],
            value: Data(bytes: &featureVal, count: 4),
            permissions: [.readable]
        )

        // 0x2A5D – Sensor Location: 0x00 = Other (trainer bridge, not a real crank sensor)
        let locationChar = CBMutableCharacteristic(
            type: CBUUID(string: "2A5D"),
            properties: [.read],
            value: Data([0x00]),
            permissions: [.readable]
        )

        // 0x2A66 – Cycling Power Control Point. DO NOT REMOVE while the Feature value above sets
        // the Wheel Revolution Data bit: the two ship together or not at all.
        //
        // The CPS spec makes the "Set Cumulative Value" procedure conditional-mandatory on that
        // bit, so claiming wheel data without this characteristic is a malformed GATT database,
        // and a client may simply ignore the wheel field. Garmin does. Confirmed on hardware
        // 2026-08-08: without 0x2A66 the watch paired, streamed power and cadence fine, showed no
        // speed, and offered only "Crank Length" under its Power sensor settings. Adding it made a
        // "Wheel Size" entry appear there and speed start working. (Same trap is documented for
        // CSC's equivalent SC Control Point, 0x2A55.)
        //
        // Left out when speed broadcast is off so that mode stays byte-identical to the macOS
        // app's layout — the known-good baseline to fall back to when a watch won't pair at all.
        var serviceCharacteristics: [CBCharacteristic] = [measChar, featureChar, locationChar]
        if speedBroadcastEnabled {
            let controlChar = CBMutableCharacteristic(
                type: CBUUID(string: "2A66"),
                properties: [.write, .indicate],
                value: nil,
                permissions: [.writeable]
            )
            controlPointChar = controlChar
            serviceCharacteristics.append(controlChar)
        } else {
            controlPointChar = nil
        }

        let service = CBMutableService(type: CBUUID(string: "1818"), primary: true)
        service.characteristics = serviceCharacteristics
        peripheralManager.add(service)
    }

    /// Rebuilds the GATT database when the speed-broadcast setting changes — it moves the Wheel
    /// Revolution Data bit in the (static, read-once) Feature characteristic and changes the
    /// measurement packet's layout. The watch has to be re-paired afterwards: the sensor it
    /// remembers no longer matches what we expose.
    func setSpeedBroadcastEnabled(_ enabled: Bool) {
        guard enabled != speedBroadcastEnabled else { return }
        speedBroadcastEnabled = enabled
        guard peripheralManager?.state == .poweredOn else { return }
        peripheralManager.stopAdvertising()
        isAdvertising = false
        subscriberCount = 0
        stopTransmitTimer()
        setupServices()
    }

    // MARK: - Data forwarding (call this whenever trainer metrics update)

    func updateMetrics(power: Int, cadence: Int) {
        lastPower = power
        lastCadence = cadence
        sendUpdate(power: power, cadence: cadence, force: true)
    }

    /// Latest speed to convert into wheel revolutions. Stored only — the transmit timer sends it.
    func updateSpeed(kmh: Double) {
        lastSpeedKmh = max(0, kmh)
    }

    // `force` distinguishes a real trainer sample (always sent immediately) from the
    // transmitTimer's keepalive tick (skipped if a real sample went out too recently, so we
    // don't double-transmit when the trainer itself is already updating at ~1 Hz).
    private func sendUpdate(power: Int, cadence: Int, force: Bool) {
        guard let char = powerMeasurementChar, subscriberCount > 0 else { return }
        if !force && Date().timeIntervalSince(lastSendTime) < 0.5 { return }

        let now = Date()
        // Clamp elapsed: App Nap / a long gap since the last sample must not be interpreted
        // as that many seconds of continuous pedaling, which would blow out the crank math.
        let elapsed = min(now.timeIntervalSince(lastUpdateTime), 5.0)
        lastUpdateTime = now
        lastSendTime = now

        // Bit 5 = Crank Revolution Data, bit 4 = Wheel Revolution Data. Both are fixed for the
        // lifetime of the GATT database (speedBroadcastEnabled only changes across a rebuild):
        // Garmin sensors don't expect a notify-only characteristic to change its payload layout
        // between packets, and the Feature characteristic they read at pairing has to agree.
        let flags: UInt16 = speedBroadcastEnabled ? 0x0030 : 0x0020

        if cadence > 0 && elapsed > 0 {
            // Accumulate fractional revolutions so rounding errors don't drift cadence
            crankRevAccumulator += Double(cadence) / 60.0 * elapsed
            let newWholeRevs = UInt16(truncatingIfNeeded: UInt64(crankRevAccumulator))
            let addedRevs = newWholeRevs &- cumulativeCrankRevolutions

            if addedRevs > 0 {
                cumulativeCrankRevolutions = newWholeRevs
                // Advance "last crank event time" by the time those revolutions took
                let ticksPerRev = UInt16(clamping: Int(60.0 / Double(cadence) * 1024.0))
                lastCrankEventTime = lastCrankEventTime &+ ticksPerRev &* addedRevs
            }
        }
        // cadence == 0: resend the same cumulative counters unchanged (no new revolutions).

        var packet = Data()
        withUnsafeBytes(of: flags.littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: Int16(clamping: power).littleEndian) { packet.append(contentsOf: $0) }
        // Field order is fixed by the spec: wheel data (bit 4) precedes crank data (bit 5).
        if speedBroadcastEnabled {
            appendWheelData(to: &packet, elapsed: elapsed)
        }
        withUnsafeBytes(of: cumulativeCrankRevolutions.littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: lastCrankEventTime.littleEndian) { packet.append(contentsOf: $0) }

        let sent = peripheralManager.updateValue(packet, for: char, onSubscribedCentrals: nil)
        if !sent {
            // Queue was full; buffer the latest packet and retry when
            // peripheralManagerIsReady(toUpdateSubscribers:) fires.
            pendingPacket = packet
        }
    }

    /// Appends the Cycling Power Measurement's Wheel Revolution Data field: Cumulative Wheel
    /// Revolutions (UInt32) + Last Wheel Event Time (UInt16, **1/2048 s** — the power service uses
    /// twice the resolution CSC does).
    ///
    /// The watch recovers speed as `delta_revs * circumference / delta_event_time`, so the event
    /// time has to be the timestamp of the *last whole revolution*, not "now" — a real sensor
    /// times a magnet passing. Stepping it to now instead would pair a truncated revolution count
    /// with a full interval and make the displayed speed jitter by up to a quarter at road speeds.
    /// So: carry the elapsed time in a Double tick accumulator, and back off from it by however
    /// long the leftover fractional revolution has been in progress.
    private func appendWheelData(to packet: inout Data, elapsed: TimeInterval) {
        let circumferenceM = Double(max(1, wheelCircumferenceMm)) / 1000.0
        let speedMps = lastSpeedKmh / 3.6
        let revsPerSecond = speedMps / circumferenceM

        wheelTicksAccumulator += elapsed * 2048.0
        wheelRevAccumulator += revsPerSecond * elapsed
        cumulativeWheelRevolutions = UInt32(truncatingIfNeeded: Int(wheelRevAccumulator.rounded(.down)))

        // Ticks since the last whole revolution, at the current rate. At a standstill there is no
        // rate to extrapolate from, so the offset is 0 and the revolution count stops advancing —
        // an unchanged count over any interval is exactly what the watch needs to read 0.
        let fractionalRev = wheelRevAccumulator - wheelRevAccumulator.rounded(.down)
        let ticksSinceLastRev = revsPerSecond > 0 ? fractionalRev / revsPerSecond * 2048.0 : 0
        let eventTicks = max(0, wheelTicksAccumulator - ticksSinceLastRev)
        let lastWheelEventTime = UInt16(truncatingIfNeeded: Int(eventTicks.rounded()))

        withUnsafeBytes(of: cumulativeWheelRevolutions.littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: lastWheelEventTime.littleEndian) { packet.append(contentsOf: $0) }
    }
}
