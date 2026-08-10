//
//  HeartRateMonitor.swift
//  FitBridgeIOS
//
//  A second, independent BLE Central for the Heart Rate Service (0x180D) — kept separate from
//  FitBridge's CBCentralManager because CoreBluetooth allows only one active scan per manager,
//  and FitBridge.connect(to:) already owns that manager's scan/connect state machine end to end.
//  The HR lifecycle (a strap or watch that comes and goes independently of the trainer) doesn't
//  need to share it.
//
//  HR is display-only. It is deliberately never re-broadcast to the watch as a service of our
//  own — that would mean a second advertised service, which CLAUDE.md hard rule #1 forbids, and
//  it would be pointless anyway since the watch is the source of the reading.
//

import Combine
import CoreBluetooth
import Foundation

struct HeartRateCandidate: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

/// Bounds-checked decode of a 0x2A37 Heart Rate Measurement packet. Byte 0 is flags — bit 0
/// selects UInt8 vs UInt16 for the HR value; bits 3/4 (Energy Expended, RR-Intervals) are
/// present-but-unused here. Returns nil on a short/malformed packet rather than trapping, the
/// same discipline FitBridge.readUInt16 applies to trainer packets — real straps do send
/// truncated frames.
func parseHeartRateMeasurement(_ data: Data) -> Int? {
    guard let flags = data.first else { return nil }
    if flags & 0x01 != 0 {
        guard data.count >= 3 else { return nil }
        return Int(UInt16(data[1]) | (UInt16(data[2]) << 8))
    } else {
        guard data.count >= 2 else { return nil }
        return Int(data[1])
    }
}

@MainActor
final class HeartRateMonitor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    @Published var heartRateBpm: Int? = nil
    @Published var connectionState: ConnectionState = .scanning
    @Published var sensorName: String = "—"
    @Published var discoveredSensors: [HeartRateCandidate] = []
    @Published var isReconnecting: Bool = false
    /// Last `[HR]` line, mirrored into the UI's Heart rate section so the GATT handshake can be
    /// diagnosed on-device without attaching Xcode. Everything also goes to the console.
    @Published var lastLogLine: String = ""

    private var centralManager: CBCentralManager!
    private var sensor: CBPeripheral?
    private let profileStore: ProfileStore

    // MARK: - Picker / reconnect state
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var rememberedIdentifier: UUID?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private let connectTimeout: TimeInterval = 8
    private var reconnectWorkItem: DispatchWorkItem?
    // Unlike the trainer (session-only, gives up after 4 attempts), a remembered HR sensor is a
    // personal strap/watch that's expected to come back — keep trying indefinitely.
    private let reconnectDelay: TimeInterval = 5

    // Stop scanning after a while with nobody picked — with the trainer link, the Garmin
    // peripheral link and this link all live at once, an indefinitely-running scan is needless
    // radio contention.
    private var scanIdleTimer: DispatchSourceTimer?
    private let scanIdleTimeout: TimeInterval = 60

    // If the sensor goes quiet, drop the reading rather than freezing on a stale number —
    // mirrors FitBridge.powerStaleAfter.
    private var staleTimer: DispatchSourceTimer?
    private var lastReadingDate: Date = .distantPast
    private let staleAfter: TimeInterval = 5

    init(profileStore: ProfileStore) {
        self.profileStore = profileStore
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        if let idString = profileStore.profile.heartRateSensorId, let id = UUID(uuidString: idString) {
            rememberedIdentifier = id
            sensorName = profileStore.profile.heartRateSensorName ?? "Unknown sensor"
        }
    }

    private func log(_ message: String) {
        lastLogLine = message
        print("[HR] \(message)")
    }

    // MARK: - Public controls

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        connectionState = .scanning
        centralManager.scanForPeripherals(withServices: [GATT.heartRateService], options: nil)
        armScanIdleTimeout()
    }

    /// Called by the UI when the user taps a discovered candidate row.
    func connect(to id: UUID) {
        guard let peripheral = discoveredPeripherals[id] else { return }
        centralManager.stopScan()
        scanIdleTimer?.cancel()
        rememberedIdentifier = id
        isReconnecting = false
        sensorName = peripheral.name ?? "Unknown sensor"
        persistSensor(id: id, name: sensorName)
        beginConnect(to: peripheral)
    }

    /// Clears the remembered sensor and returns to the picker.
    func forget() {
        connectTimeoutWorkItem?.cancel()
        reconnectWorkItem?.cancel()
        if let s = sensor {
            centralManager.cancelPeripheralConnection(s)
        }
        centralManager.stopScan()
        stopStaleTimer()
        sensor = nil
        rememberedIdentifier = nil
        isReconnecting = false
        heartRateBpm = nil
        sensorName = "—"
        discoveredSensors.removeAll()
        discoveredPeripherals.removeAll()
        persistSensor(id: nil, name: nil)
        startScanning()
    }

    private func persistSensor(id: UUID?, name: String?) {
        profileStore.update {
            $0.heartRateSensorId = id?.uuidString
            $0.heartRateSensorName = name
        }
    }

    // MARK: - Connect / reconnect

    private func beginConnect(to peripheral: CBPeripheral) {
        connectTimeoutWorkItem?.cancel()
        connectionState = .connecting
        sensor = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.connectionState == .connecting else { return }
            self.centralManager.cancelPeripheralConnection(peripheral)
            self.scheduleReconnect(to: peripheral)
        }
        connectTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeout, execute: timeout)
    }

    private func scheduleReconnect(to peripheral: CBPeripheral) {
        connectionState = .disconnected
        isReconnecting = true
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let id = self.rememberedIdentifier, id == peripheral.identifier else { return }
            self.beginConnect(to: peripheral)
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: work)
    }

    private func resumeScanningOrReconnect() {
        guard centralManager.state == .poweredOn else {
            connectionState = .scanning
            return
        }
        if let id = rememberedIdentifier, let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first {
            discoveredPeripherals[id] = peripheral
            isReconnecting = true
            sensorName = profileStore.profile.heartRateSensorName ?? peripheral.name ?? "Unknown sensor"
            beginConnect(to: peripheral)
        } else {
            sensorName = "—"
            startScanning()
        }
    }

    // MARK: - Staleness

    private func armStaleTimer() {
        lastReadingDate = Date()
        guard staleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.checkStale()
        }
        timer.resume()
        staleTimer = timer
    }

    private func stopStaleTimer() {
        staleTimer?.cancel()
        staleTimer = nil
    }

    private func checkStale() {
        guard heartRateBpm != nil else { return }
        if Date().timeIntervalSince(lastReadingDate) > staleAfter {
            log("no 0x2A37 notification for \(Int(staleAfter))s — clearing reading")
            heartRateBpm = nil
        }
    }

    private func handleHeartRateData(_ data: Data) {
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        guard let bpm = parseHeartRateMeasurement(data) else {
            log("0x2A37 UNPARSEABLE (\(data.count) bytes) [\(hex)]")
            return
        }
        let flags = data.first ?? 0
        log("0x2A37 [\(hex)] flags=0x\(String(format: "%02X", flags)) \(flags & 0x01 != 0 ? "uint16" : "uint8") → \(bpm) bpm")
        heartRateBpm = bpm
        lastReadingDate = Date()
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("BT state: \(central.state.rawValue)")
        resumeScanningOrReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discoveredPeripherals[peripheral.identifier] = peripheral
        let candidate = HeartRateCandidate(
            id: peripheral.identifier,
            name: peripheral.name ?? "Unknown sensor",
            rssi: RSSI.intValue
        )
        if let idx = discoveredSensors.firstIndex(where: { $0.id == candidate.id }) {
            discoveredSensors[idx] = candidate
        } else {
            // Only on first sight — advertisement packets repeat several times a second.
            let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            log("discovered \(candidate.name) rssi=\(candidate.rssi) adv=[\(advertised.map { $0.uuidString }.joined(separator: ", "))]")
            discoveredSensors.append(candidate)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimeoutWorkItem?.cancel()
        reconnectWorkItem?.cancel()
        sensor = peripheral
        isReconnecting = false
        connectionState = .connected
        sensorName = peripheral.name ?? "Unknown sensor"
        log("connected to \(sensorName) — discovering 0x180D")
        armStaleTimer()
        peripheral.discoverServices([GATT.heartRateService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("failed to connect: \(error?.localizedDescription ?? "unknown")")
        guard peripheral.identifier == rememberedIdentifier else { return }
        scheduleReconnect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("disconnected: \(error?.localizedDescription ?? "clean")")
        stopStaleTimer()
        heartRateBpm = nil
        connectionState = .disconnected
        if peripheral.identifier == rememberedIdentifier {
            scheduleReconnect(to: peripheral)
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("discoverServices failed: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        log("services=[\(services.map { $0.uuid.uuidString }.joined(separator: ", "))]")
        let hrServices = services.filter { $0.uuid == GATT.heartRateService }
        if hrServices.isEmpty {
            log("no 0x180D on this peripheral — it is not broadcasting HR")
            return
        }
        for service in hrServices {
            peripheral.discoverCharacteristics([GATT.heartRateMeasurement], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("discoverCharacteristics failed: \(error.localizedDescription)")
            return
        }
        let characteristics = service.characteristics ?? []
        log("0x180D chars=[\(characteristics.map { $0.uuid.uuidString }.joined(separator: ", "))]")
        guard let measurement = characteristics.first(where: { $0.uuid == GATT.heartRateMeasurement }) else {
            log("0x2A37 missing from 0x180D — nothing to subscribe to")
            return
        }
        log("0x2A37 properties=[\(describe(measurement.properties))] — subscribing")
        peripheral.setNotifyValue(true, for: measurement)
    }

    /// Without this, a rejected subscribe is completely silent: the peripheral stays connected, the
    /// UI shows a healthy link, and no 0x2A37 notification ever arrives. A watch that wants bonding
    /// answers here with "Insufficient Authentication"/"Encryption is insufficient".
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == GATT.heartRateMeasurement else { return }
        if let error {
            log("subscribe to 0x2A37 FAILED: \(error.localizedDescription)")
        } else {
            log("subscribe to 0x2A37 ok — isNotifying=\(characteristic.isNotifying)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("didUpdateValue error on \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == GATT.heartRateMeasurement else {
            log("value from unexpected characteristic \(characteristic.uuid.uuidString), ignoring")
            return
        }
        guard let data = characteristic.value else {
            log("0x2A37 notification with no value")
            return
        }
        handleHeartRateData(data)
    }

    private func describe(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.writeWithoutResponse) { names.append("writeNoResp") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        return names.isEmpty ? "none" : names.joined(separator: "|")
    }

    // MARK: - Scan idle timeout

    private func armScanIdleTimeout() {
        scanIdleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + scanIdleTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, self.connectionState == .scanning else { return }
            self.centralManager.stopScan()
        }
        timer.resume()
        scanIdleTimer = timer
    }
}
