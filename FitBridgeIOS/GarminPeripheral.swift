//
//  GarminPeripheral.swift
//  FitBridge
//
//  Advertises as a Bluetooth LE Cycling Power Meter (Service 0x1818) so
//  Garmin watches can discover and subscribe to live power/cadence data.
//

import Combine
import CoreBluetooth
import Foundation

class GarminPeripheral: NSObject, ObservableObject, CBPeripheralManagerDelegate {

    @Published var isAdvertising: Bool = false
    @Published var subscriberCount: Int = 0

    private var peripheralManager: CBPeripheralManager!
    private var powerMeasurementChar: CBMutableCharacteristic?

    // When updateValue returns false (transmit queue full), store the packet and
    // retry it from peripheralManagerIsReady(toUpdateSubscribers:).
    private var pendingPacket: Data?

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
        subscriberCount += 1
        // A fresh subscriber has no baseline: reset crank accounting so the first packet
        // doesn't compute elapsed time since app launch and produce a huge/garbage cadence.
        crankRevAccumulator = 0.0
        cumulativeCrankRevolutions = 0
        lastCrankEventTime = 0
        lastUpdateTime = Date()
        startTransmitTimer()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
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
        guard let char = powerMeasurementChar, let packet = pendingPacket else { return }
        pendingPacket = nil
        let sent = peripheral.updateValue(packet, for: char, onSubscribedCentrals: nil)
        if !sent {
            pendingPacket = packet  // still congested, keep waiting
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
        peripheralManager.removeAllServices()

        // 0x2A63 – Cycling Power Measurement: notify-only, value is dynamic
        let measChar = CBMutableCharacteristic(
            type: CBUUID(string: "2A63"),
            properties: [.notify],
            value: nil,
            permissions: []
        )
        powerMeasurementChar = measChar

        // 0x2A65 – Cycling Power Feature: Bit 3 = Crank Revolution Data supported
        var featureVal: UInt32 = 0x00000008
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

        let service = CBMutableService(type: CBUUID(string: "1818"), primary: true)
        service.characteristics = [measChar, featureChar, locationChar]
        peripheralManager.add(service)
    }

    // MARK: - Data forwarding (call this whenever trainer metrics update)

    func updateMetrics(power: Int, cadence: Int) {
        lastPower = power
        lastCadence = cadence
        sendUpdate(power: power, cadence: cadence, force: true)
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

        // Crank Revolution Data (bit 5) is always present once a subscriber exists — the
        // Feature characteristic advertises support for it, and Garmin sensors don't expect
        // a notify-only characteristic to change its payload layout between packets.
        let flags: UInt16 = 0x0020

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

        var crankBytes = Data()
        withUnsafeBytes(of: cumulativeCrankRevolutions.littleEndian) { crankBytes.append(contentsOf: $0) }
        withUnsafeBytes(of: lastCrankEventTime.littleEndian) { crankBytes.append(contentsOf: $0) }

        var packet = Data()
        withUnsafeBytes(of: flags.littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: Int16(clamping: power).littleEndian) { packet.append(contentsOf: $0) }
        packet.append(crankBytes)

        let sent = peripheralManager.updateValue(packet, for: char, onSubscribedCentrals: nil)
        if !sent {
            // Queue was full; buffer the latest packet and retry when
            // peripheralManagerIsReady(toUpdateSubscribers:) fires.
            pendingPacket = packet
        }
    }
}
