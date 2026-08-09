//
//  FitBridge.swift
//  FitBridge
//
//  Created by Bryan Natali on 14/07/26.
//

import CoreBluetooth
import Foundation
import Combine

enum ConnectionState: Equatable {
    case scanning
    case connecting
    case connected
    case disconnected
}

struct TrainerCandidate: Identifiable, Equatable {
    enum ServiceKind: Equatable {
        case ftms, cyclingPower, both

        var label: String {
            switch self {
            case .ftms: return "FTMS"
            case .cyclingPower: return "Power"
            case .both: return "FTMS+Power"
            }
        }
    }

    let id: UUID
    var name: String
    var rssi: Int
    var serviceKind: ServiceKind
}

@MainActor
class FitBridge: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: - Published state the UI observes
    @Published var connectionState: ConnectionState = .scanning
    @Published var trainerName: String = "—"
    @Published var currentPower: Int = 0
    @Published var currentCadence: Int = 0
    /// Speed shown in the UI — physics-derived when `RiderProfile.useVirtualSpeed` is on,
    /// otherwise whatever the trainer reported.
    @Published var currentSpeedKmh: Double = 0
    /// The trainer's own instantaneous-speed field, kept separately so the two can be compared.
    @Published var trainerReportedSpeedKmh: Double = 0
    /// Road gradient fed to both the virtual speed model and the trainer's SIM parameters.
    @Published var gradePercent: Double = 0
    @Published var controlGranted: Bool = false
    @Published var lastLogLine: String = ""
    @Published var simulationSupported: Bool = true
    @Published var simulationActive: Bool = false
    @Published var expectedResistivePower: Int = 0
    @Published var discoveredTrainers: [TrainerCandidate] = []
    @Published var isReconnecting: Bool = false
    @Published private(set) var mockTrainerActive: Bool = false

    var statusIcon: String {
        switch connectionState {
        case .connected: return "bolt.fill"
        case .connecting, .scanning: return "bolt.slash"
        case .disconnected: return "bolt.horizontal"
        }
    }

    var menuBarPowerText: String {
        "\(max(0, currentPower))W"
    }

    let garminPeripheral = GarminPeripheral()

    private var centralManager: CBCentralManager!
    private var trainer: CBPeripheral?
    private var usingFTMS = false
    private var controlPointChar: CBCharacteristic?
    private var featureChar: CBCharacteristic?
    private var hasRequestedControl = false
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var simKeepAliveTimer: DispatchSourceTimer?
    private var mockTrainerTimer: DispatchSourceTimer?
    private let profileStore: ProfileStore
    private var profileSub: AnyCancellable?
    private var gradeSub: AnyCancellable?

    // MARK: - Trainer picker / reconnect state
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var rememberedIdentifier: UUID?
    private var reconnectAttemptsUsed = 0
    private let maxConnectAttempts = 4
    private let connectAttemptTimeout: TimeInterval = 8
    private let connectRetryDelay: TimeInterval = 3

    // 3-second rolling average for power (industry standard, matches MyWhoosh/Zwift display)
    private var powerSamples: [(date: Date, watts: Int)] = []
    private let powerAveragingWindow: TimeInterval = 3

    // MARK: - Virtual speed
    //
    // Integrated at a steady 10 Hz rather than on packet arrival: trainers send at ~1–4 Hz and
    // the whole point of the model is smooth, momentum-carrying speed between samples.
    private let speedModel = VirtualSpeedModel()
    private var speedTimer: DispatchSourceTimer?
    private var lastSpeedTick = Date()
    private let speedTickInterval: TimeInterval = 0.1
    /// Raw (un-averaged) power drives the model — its own inertia is the smoothing, so feeding it
    /// the 3-second average as well would just add lag.
    private var lastRawPowerWatts: Int = 0
    private var lastPowerSampleDate: Date = .distantPast
    /// No packet for this long means the trainer went quiet — coast down rather than hold speed.
    private let powerStaleAfter: TimeInterval = 5

    // Throttle expected-power delta logging to ~1 Hz
    private var lastExpectedPowerLogDate: Date = .distantPast

    init(profileStore: ProfileStore) {
        self.profileStore = profileStore
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)

        refreshSpeedModelParameters()

        profileSub = profileStore.profileDidChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSpeedModelParameters()
                self?.resendSimulationParameters()
            }

        // The grade slider fires continuously while dragging; the model tracks it live but the
        // control-point write is debounced so a drag doesn't flood the trainer.
        gradeSub = $gradePercent
            .removeDuplicates()
            .handleEvents(receiveOutput: { [weak self] grade in
                self?.speedModel.parameters.gradePercent = grade
            })
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resendSimulationParameters()
            }
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        connectionState = .scanning
        log("Scanning for FTMS/Cycling Power trainer...")
        centralManager.scanForPeripherals(
            withServices: [GATT.ftmsService, GATT.cyclingPowerService],
            options: nil
        )
    }

    /// Called by the UI when the user taps a discovered candidate row.
    func connect(to id: UUID) {
        guard let peripheral = discoveredPeripherals[id] else { return }
        centralManager.stopScan()
        rememberedIdentifier = id
        reconnectAttemptsUsed = 0
        isReconnecting = false
        trainerName = peripheral.name ?? "Unknown trainer"
        beginConnectAttempt(to: peripheral)
    }

    /// Clears the live candidate list and any remembered device, then restarts discovery.
    func rescan() {
        connectTimeoutWorkItem?.cancel()
        if let t = trainer {
            centralManager.cancelPeripheralConnection(t)
        }
        centralManager.stopScan()
        stopVirtualSpeed()
        currentSpeedKmh = 0
        trainerReportedSpeedKmh = 0
        expectedResistivePower = 0
        discoveredTrainers.removeAll()
        discoveredPeripherals.removeAll()
        rememberedIdentifier = nil
        reconnectAttemptsUsed = 0
        isReconnecting = false
        trainer = nil
        startScanning()
    }

    // MARK: - Mock trainer (--mock-trainer launch argument, or the Settings toggle)
    //
    // Feeds synthetic Indoor Bike Data packets straight into parseIndoorBikeData,
    // bypassing CBCentralManager scanning/connecting entirely. The iOS Simulator has no
    // CoreBluetooth at all (state is always .unsupported), so this is the only way to
    // exercise the parsing → averaging → GarminPeripheral pipeline there; on a real device
    // it also sidesteps the same-radio scan/advertise contention a single Mac hits when
    // testing against TrainerSimulator.
    private var mockTrainerRequested: Bool {
        CommandLine.arguments.contains("--mock-trainer")
            || UserDefaults.standard.bool(forKey: "mockTrainerEnabled")
    }

    /// Called by the Settings toggle to flip mock mode on/off at runtime.
    func setMockTrainer(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "mockTrainerEnabled")
        if enabled {
            connectTimeoutWorkItem?.cancel()
            centralManager.stopScan()
            if let t = trainer {
                centralManager.cancelPeripheralConnection(t)
            }
            startMockTrainer()
        } else {
            stopMockTrainer()
        }
    }

    private func startMockTrainer() {
        guard mockTrainerTimer == nil else { return }
        mockTrainerActive = true
        connectionState = .connected
        trainerName = "Mock Trainer"
        startVirtualSpeed()
        log("Mock trainer active — injecting synthetic Indoor Bike Data, no BLE central connection.")
        let start = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.tickMockTrainer(elapsed: Date().timeIntervalSince(start))
        }
        timer.resume()
        mockTrainerTimer = timer
    }

    private func stopMockTrainer() {
        mockTrainerTimer?.cancel()
        mockTrainerTimer = nil
        mockTrainerActive = false
        powerSamples.removeAll()
        currentPower = 0
        currentCadence = 0
        stopVirtualSpeed()
        currentSpeedKmh = 0
        trainerReportedSpeedKmh = 0
        expectedResistivePower = 0
        trainerName = "—"
        connectionState = .scanning
        if centralManager.state == .poweredOn {
            startScanning()
        }
    }

    private func tickMockTrainer(elapsed: TimeInterval) {
        let period = 60.0
        let phase = elapsed * (2 * Double.pi / period)
        let power = Int(200 + 80 * sin(phase) + Double.random(in: -6...6))
        let cadence = max(0, Int(85 + 10 * sin(phase + 0.6) + Double.random(in: -2...2)))
        let speedKmh = 15.0 + Double(power) / 20.0
        parseIndoorBikeData(buildMockIndoorBikeDataPacket(power: power, cadence: cadence, speedKmh: speedKmh))
    }

    /// Same byte layout as Tools/TrainerSimulator's buildIndoorBikeDataPacket — instantaneous
    /// speed + cadence + power, flags 0x0044.
    private func buildMockIndoorBikeDataPacket(power: Int, cadence: Int, speedKmh: Double) -> Data {
        let flags: UInt16 = 0x0044
        var data = Data()
        data.append(UInt8(flags & 0xFF))
        data.append(UInt8((flags >> 8) & 0xFF))

        let speedRaw = UInt16(clamping: Int(speedKmh * 100))
        data.append(UInt8(speedRaw & 0xFF))
        data.append(UInt8((speedRaw >> 8) & 0xFF))

        let cadenceRaw = UInt16(clamping: cadence * 2)
        data.append(UInt8(cadenceRaw & 0xFF))
        data.append(UInt8((cadenceRaw >> 8) & 0xFF))

        let powerRaw = Int16(clamping: power)
        let powerBits = UInt16(bitPattern: powerRaw)
        data.append(UInt8(powerBits & 0xFF))
        data.append(UInt8((powerBits >> 8) & 0xFF))

        return data
    }

    private func beginConnectAttempt(to peripheral: CBPeripheral) {
        connectTimeoutWorkItem?.cancel()
        connectionState = .connecting
        trainer = peripheral
        centralManager.connect(peripheral, options: nil)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.connectionState == .connecting else { return }
            self.log("Connect attempt timed out.")
            self.centralManager.cancelPeripheralConnection(peripheral)
            self.retryOrGiveUp(peripheral)
        }
        connectTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + connectAttemptTimeout, execute: timeout)
    }

    private func retryOrGiveUp(_ peripheral: CBPeripheral) {
        reconnectAttemptsUsed += 1
        if reconnectAttemptsUsed >= maxConnectAttempts {
            giveUpAndReturnToPicker()
            return
        }
        isReconnecting = true
        log("Reconnect attempt \(reconnectAttemptsUsed)/\(maxConnectAttempts) failed, retrying in \(Int(connectRetryDelay))s...")
        DispatchQueue.main.asyncAfter(deadline: .now() + connectRetryDelay) { [weak self] in
            guard let self = self, let id = self.rememberedIdentifier, id == peripheral.identifier else { return }
            self.beginConnectAttempt(to: peripheral)
        }
    }

    private func giveUpAndReturnToPicker() {
        log("Giving up reconnecting after \(maxConnectAttempts) attempts, returning to picker.")
        rememberedIdentifier = nil
        rescan()
    }

    private func applyPowerSample(_ watts: Int) {
        let now = Date()
        lastRawPowerWatts = watts
        lastPowerSampleDate = now
        powerSamples.append((date: now, watts: watts))
        let cutoff = now.addingTimeInterval(-powerAveragingWindow)
        powerSamples.removeAll { $0.date < cutoff }
        let sum = powerSamples.reduce(0) { $0 + $1.watts }
        currentPower = Int((Double(sum) / Double(powerSamples.count)).rounded())
        log("current power: \(currentPower)W (raw: \(watts)W, \(powerSamples.count) samples)")
    }

    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.lastLogLine = message
        }
        print(message)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("BT state: \(central.state.rawValue), authorization: \(CBManager.authorization.rawValue)")
        // Checked BEFORE the poweredOn guard: the iOS Simulator reports .unsupported, so a
        // guard-first ordering would make mock mode unreachable there.
        if mockTrainerRequested {
            startMockTrainer()
            return
        }
        guard central.state == .poweredOn else {
            log("Bluetooth not available (state: \(central.state.rawValue))")
            return
        }
        if let id = rememberedIdentifier, let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first {
            discoveredPeripherals[id] = peripheral
            isReconnecting = true
            beginConnectAttempt(to: peripheral)
        } else {
            startScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasFTMS = serviceUUIDs.contains(GATT.ftmsService)
        let hasPower = serviceUUIDs.contains(GATT.cyclingPowerService)
        let kind: TrainerCandidate.ServiceKind = (hasFTMS && hasPower) ? .both : (hasPower ? .cyclingPower : .ftms)

        discoveredPeripherals[peripheral.identifier] = peripheral

        let candidate = TrainerCandidate(
            id: peripheral.identifier,
            name: peripheral.name ?? "Unknown trainer",
            rssi: RSSI.intValue,
            serviceKind: kind
        )

        if let idx = discoveredTrainers.firstIndex(where: { $0.id == candidate.id }) {
            discoveredTrainers[idx] = candidate
        } else {
            discoveredTrainers.append(candidate)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimeoutWorkItem?.cancel()
        log("Connected to \(peripheral.name ?? "trainer")")
        trainer = peripheral
        reconnectAttemptsUsed = 0
        isReconnecting = false
        connectionState = .connected
        trainerName = peripheral.name ?? "Unknown trainer"
        startVirtualSpeed()
        peripheral.delegate = self
        peripheral.discoverServices([GATT.ftmsService, GATT.cyclingPowerService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        guard peripheral.identifier == rememberedIdentifier else { return }
        retryOrGiveUp(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected: \(error?.localizedDescription ?? "no error")")
        stopSimKeepAlive()
        hasRequestedControl = false
        controlPointChar = nil
        featureChar = nil
        powerSamples.removeAll()
        currentPower = 0
        stopVirtualSpeed()
        currentSpeedKmh = 0
        trainerReportedSpeedKmh = 0
        expectedResistivePower = 0
        connectionState = .disconnected
        controlGranted = false
        simulationActive = false

        if peripheral.identifier == rememberedIdentifier {
            isReconnecting = true
            beginConnectAttempt(to: peripheral)
        } else {
            rescan()
        }
    }

    // MARK: CBPeripheralDelegate — discovery

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == GATT.ftmsService {
                usingFTMS = true
                peripheral.discoverCharacteristics(
                    [GATT.indoorBikeData, GATT.ftmsControlPoint, GATT.ftmsFeature],
                    for: service
                )
            } else if service.uuid == GATT.cyclingPowerService, !usingFTMS {
                peripheral.discoverCharacteristics([GATT.cyclingPowerMeasurement], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for char in characteristics {
            switch char.uuid {
            case GATT.indoorBikeData:
                peripheral.setNotifyValue(true, for: char)
            case GATT.cyclingPowerMeasurement:
                peripheral.setNotifyValue(true, for: char)
            case GATT.ftmsControlPoint:
                controlPointChar = char
                peripheral.setNotifyValue(true, for: char)
                requestControl(on: peripheral)
            case GATT.ftmsFeature:
                featureChar = char
                readMachineFeature()
            default:
                break
            }
        }
    }

    // MARK: CBPeripheralDelegate — incoming data

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case GATT.indoorBikeData:
            parseIndoorBikeData(data)
        case GATT.cyclingPowerMeasurement:
            parseCyclingPowerMeasurement(data)
        case GATT.ftmsControlPoint:
            handleControlPointIndication(data)
        case GATT.ftmsFeature:
            parseMachineFeature(data)
        default:
            break
        }
    }

    // MARK: Parsing

    /// Bounds-checked little-endian UInt16 read, advancing `offset` by 2. Returns nil (and
    /// leaves offset unchanged) if the field would run past the end of `data` — guards against
    /// a short or malformed packet from real trainer hardware crashing on an out-of-range index.
    private func readUInt16(_ data: Data, _ offset: inout Int) -> UInt16? {
        guard offset + 1 < data.count else { return nil }
        defer { offset += 2 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func parseIndoorBikeData(_ data: Data) {
        guard data.count >= 2 else {
            print("[FTMS-IBD] data too short (\(data.count) bytes), cannot parse flags")
            return
        }
        var offset = 2
        let flags = UInt16(data[0]) | (UInt16(data[1]) << 8)

        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let flagBits = [
            flags & 0x0001 == 0 ? "InstSpeed" : nil,
            flags & 0x0002 != 0 ? "AvgSpeed" : nil,
            flags & 0x0004 != 0 ? "InstCadence" : nil,
            flags & 0x0008 != 0 ? "AvgCadence" : nil,
            flags & 0x0010 != 0 ? "Distance" : nil,
            flags & 0x0020 != 0 ? "Resistance" : nil,
            flags & 0x0040 != 0 ? "InstPower" : nil,
            flags & 0x0080 != 0 ? "AvgPower" : nil,
            flags & 0x0100 != 0 ? "Energy" : nil,
            flags & 0x0200 != 0 ? "HR" : nil,
        ].compactMap { $0 }.joined(separator: "|")
        print("[FTMS-IBD] flags=0x\(String(format: "%04X", flags)) fields=[\(flagBits)] bytes=[\(hex)]")

        var speed: Double = currentSpeedKmh
        var cadence: Int = currentCadence
        var power: Int? = nil

        if flags & 0x0001 == 0 {
            if let raw = readUInt16(data, &offset) {
                speed = Double(raw) * 0.01
                print("[FTMS-IBD]   InstSpeed offset=\(offset) raw=\(raw) → \(speed) km/h")
            } else {
                print("[FTMS-IBD]   InstSpeed offset=\(offset) truncated, skipping")
            }
        }
        if flags & 0x0002 != 0 {
            print("[FTMS-IBD]   AvgSpeed   offset=\(offset) (skipping 2)")
            offset += 2
        }
        if flags & 0x0004 != 0 {
            if let raw = readUInt16(data, &offset) {
                cadence = Int(Double(raw) * 0.5)
                print("[FTMS-IBD]   InstCadence offset=\(offset) raw=\(raw) → \(cadence) rpm")
            } else {
                print("[FTMS-IBD]   InstCadence offset=\(offset) truncated, skipping")
            }
        }
        if flags & 0x0008 != 0 {
            print("[FTMS-IBD]   AvgCadence  offset=\(offset) (skipping 2)")
            offset += 2
        }
        if flags & 0x0010 != 0 {
            print("[FTMS-IBD]   Distance    offset=\(offset) (skipping 3)")
            offset += 3
        }
        if flags & 0x0020 != 0 {
            if let rawU = readUInt16(data, &offset) {
                let raw = Int16(bitPattern: rawU)
                print("[FTMS-IBD]   Resistance  offset=\(offset) raw=\(raw)")
            } else {
                print("[FTMS-IBD]   Resistance  offset=\(offset) truncated, skipping")
            }
        }
        if flags & 0x0040 != 0 {
            if let rawU = readUInt16(data, &offset) {
                let raw = Int16(bitPattern: rawU)
                print("[FTMS-IBD]   InstPower   offset=\(offset) raw=\(raw) W ← THIS IS WHAT WE USE")
                power = Int(raw)
            } else {
                print("[FTMS-IBD]   InstPower   offset=\(offset) truncated, skipping")
            }
        } else {
            print("[FTMS-IBD]   InstPower flag NOT set — power will not be updated")
        }

        DispatchQueue.main.async {
            self.trainerReportedSpeedKmh = speed
            self.currentCadence = cadence
            if let watts = power {
                self.applyPowerSample(watts)
            }
            if !self.profileStore.profile.useVirtualSpeed {
                self.currentSpeedKmh = speed
            }
            self.garminPeripheral.updateMetrics(power: self.currentPower, cadence: self.currentCadence)

            let now = Date()
            if now.timeIntervalSince(self.lastExpectedPowerLogDate) >= 1.0 {
                self.lastExpectedPowerLogDate = now
                let expected = self.expectedResistivePower
                let delta = self.currentPower - expected
                print("[SIM-Physics] virtual=\(String(format: "%.1f", self.speedModel.speedKmh)) km/h trainer=\(String(format: "%.1f", speed)) km/h expected=\(expected)W actual=\(self.currentPower)W delta=\(delta)W")
            }
        }
    }

    private func parseCyclingPowerMeasurement(_ data: Data) {
        var offset = 2
        guard let rawU = readUInt16(data, &offset) else {
            print("[CP] data too short (\(data.count) bytes), cannot read power field")
            return
        }
        let watts = Int(Int16(bitPattern: rawU))
        DispatchQueue.main.async {
            self.applyPowerSample(watts)
            self.garminPeripheral.updateMetrics(power: self.currentPower, cadence: self.currentCadence)
        }
    }

    // MARK: Machine Feature

    private func readMachineFeature() {
        guard let peripheral = trainer, let char = featureChar else { return }
        peripheral.readValue(for: char)
    }

    private func parseMachineFeature(_ data: Data) {
        guard data.count >= 8 else {
            print("[FTMS-Feat] data too short (\(data.count) bytes), cannot parse")
            return
        }
        let machineFeatures = UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
        let targetSettings  = UInt32(data[4]) | (UInt32(data[5]) << 8) | (UInt32(data[6]) << 16) | (UInt32(data[7]) << 24)
        let simBit = (targetSettings >> 13) & 1
        let supported = simBit == 1
        print("[FTMS-Feat] machineFeatures=0x\(String(format: "%08X", machineFeatures)) targetSettings=0x\(String(format: "%08X", targetSettings)) sim=\(supported ? "YES" : "NO")")
        DispatchQueue.main.async {
            self.simulationSupported = supported
            if !supported {
                self.log("Trainer does not support simulation mode (bit 13 not set).")
            }
        }
    }

    // MARK: Control Point

    private func requestControl(on peripheral: CBPeripheral) {
        guard let char = controlPointChar else { return }
        peripheral.writeValue(Data([FTMSOpCode.requestControl.rawValue]), for: char, type: .withResponse)
    }

    func setTargetPower(watts: Int16) {
        guard let peripheral = trainer, let char = controlPointChar, hasRequestedControl else {
            log("Cannot set target power — control not granted yet.")
            return
        }
        var payload = Data([FTMSOpCode.setTargetPower.rawValue])
        withUnsafeBytes(of: watts.littleEndian) { payload.append(contentsOf: $0) }
        peripheral.writeValue(payload, for: char, type: .withResponse)
        log("Sent target power: \(watts) W")
    }

    func setSimulationParameters(grade: Double = 0.0, crr: Double? = nil, windSpeedMps: Double? = nil, cda: Double? = nil) {
        guard hasRequestedControl else {
            log("Cannot set simulation parameters — control not granted yet.")
            return
        }
        guard simulationSupported else {
            log("Trainer does not support simulation parameters.")
            return
        }
        let profile = profileStore.profile
        let effectiveCrr = crr ?? profile.crr
        let effectiveWind = windSpeedMps ?? profile.windSpeedMps
        let effectiveCda = cda ?? profile.cda
        let payload = encodeSimPayload(grade: grade, crr: effectiveCrr, wind: effectiveWind, cda: effectiveCda)
        guard let peripheral = trainer, let char = controlPointChar else { return }
        peripheral.writeValue(payload, for: char, type: .withResponse)
        print("[FTMS-Ctl] Sending setSimulationParameters grade=\(grade)% crr=\(effectiveCrr) wind=\(effectiveWind)m/s cda=\(effectiveCda)")
    }

    private func encodeSimPayload(grade: Double, crr: Double, wind: Double, cda: Double) -> Data {
        // Wind Speed: SInt16 LE, resolution 0.001 m/s
        let windRaw = Int16(clamping: Int(round(wind * 1000.0)))
        // Grade: SInt16 LE, resolution 0.01 %
        let gradeRaw = Int16(clamping: Int(round(grade * 100.0)))
        // Crr: UInt8, resolution 0.0001
        let crrRaw = UInt8(clamping: Int(round(crr / 0.0001)))
        // Cw = 0.5 * rho * CdA; wire units 0.01 kg/m
        let cw = 0.5 * 1.225 * cda
        let cwRaw = UInt8(clamping: Int(round(cw / 0.01)))

        var data = Data([FTMSOpCode.setSimulationParameters.rawValue])
        withUnsafeBytes(of: windRaw.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: gradeRaw.littleEndian) { data.append(contentsOf: $0) }
        data.append(crrRaw)
        data.append(cwRaw)
        return data
    }

    /// Always re-sends the *current* grade — the 30 s keep-alive would otherwise flatten the road
    /// back to 0 % every time it fired.
    private func resendSimulationParameters() {
        setSimulationParameters(grade: gradePercent)
    }

    private func startSimKeepAlive(interval: TimeInterval = 30) {
        stopSimKeepAlive()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.resendSimulationParameters()
        }
        timer.resume()
        simKeepAliveTimer = timer
    }

    private func stopSimKeepAlive() {
        simKeepAliveTimer?.cancel()
        simKeepAliveTimer = nil
    }

    // MARK: Virtual speed

    /// Mirrors the rider profile (and current grade) into the speed model.
    private func refreshSpeedModelParameters() {
        let profile = profileStore.profile
        speedModel.parameters.totalMassKg = profile.riderWeightKg + profile.bikeWeightKg
        speedModel.parameters.crr = profile.crr
        speedModel.parameters.cda = profile.cda
        speedModel.parameters.headwindMps = profile.windSpeedMps
        speedModel.parameters.gradePercent = gradePercent

        garminPeripheral.wheelCircumferenceMm = profile.wheelCircumferenceMm
        garminPeripheral.setSpeedBroadcastEnabled(profile.broadcastSpeedToGarmin)
    }

    private func startVirtualSpeed() {
        refreshSpeedModelParameters()
        guard speedTimer == nil else { return }
        speedModel.reset()
        lastSpeedTick = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + speedTickInterval, repeating: speedTickInterval)
        timer.setEventHandler { [weak self] in
            self?.tickVirtualSpeed()
        }
        timer.resume()
        speedTimer = timer
    }

    private func stopVirtualSpeed() {
        speedTimer?.cancel()
        speedTimer = nil
        speedModel.reset()
        lastRawPowerWatts = 0
        lastPowerSampleDate = .distantPast
        // The keepalive timer keeps notifying after a disconnect; leave the watch at 0 rather
        // than holding whatever speed we were doing when the trainer dropped.
        garminPeripheral.updateSpeed(kmh: 0)
    }

    private func tickVirtualSpeed() {
        let now = Date()
        let dt = now.timeIntervalSince(lastSpeedTick)
        lastSpeedTick = now

        let stale = now.timeIntervalSince(lastPowerSampleDate) > powerStaleAfter
        let watts = stale ? 0 : max(0, lastRawPowerWatts)
        speedModel.advance(dt: dt, powerWatts: Double(watts))

        if profileStore.profile.useVirtualSpeed {
            currentSpeedKmh = speedModel.speedKmh
        }
        expectedResistivePower = resistivePower(atSpeedKmh: currentSpeedKmh)
        garminPeripheral.updateSpeed(kmh: currentSpeedKmh)
    }

    /// Steady-state power the rider would need to hold `speedKmh` — the "Expected: N W" readout.
    private func resistivePower(atSpeedKmh speedKmh: Double) -> Int {
        guard speedKmh > 0 else { return 0 }
        return Int(speedModel.parameters.resistivePower(atSpeedMps: speedKmh / 3.6).rounded())
    }

    private func handleControlPointIndication(_ data: Data) {
        guard data.count >= 3, data[0] == FTMSOpCode.responseCode.rawValue else { return }
        let requestOpCode = data[1]
        let resultCode = data[2]

        if requestOpCode == FTMSOpCode.requestControl.rawValue && resultCode == FTMSResultCode.success.rawValue {
            hasRequestedControl = true
            DispatchQueue.main.async { self.controlGranted = true }
            log("Control granted by trainer.")
            if simulationSupported {
                resendSimulationParameters()
            }
        } else if requestOpCode == FTMSOpCode.setSimulationParameters.rawValue {
            if resultCode == FTMSResultCode.success.rawValue {
                print("[FTMS-Ctl] setSimulationParameters → 0x01 (success)")
                DispatchQueue.main.async {
                    self.simulationActive = true
                    self.log("SIM mode active.")
                }
                if profileStore.profile.simKeepaliveEnabled {
                    startSimKeepAlive()
                }
            } else {
                print("[FTMS-Ctl] setSimulationParameters → result=\(resultCode) (failed)")
                DispatchQueue.main.async {
                    self.log("SIM parameters rejected (code \(resultCode)).")
                }
            }
        }
    }
}

// MARK: - GATT UUIDs / op-codes

enum GATT {
    static let cyclingPowerService = CBUUID(string: "1818")
    static let ftmsService = CBUUID(string: "1826")
    static let cyclingPowerMeasurement = CBUUID(string: "2A63")
    static let indoorBikeData = CBUUID(string: "2AD2")
    static let ftmsControlPoint = CBUUID(string: "2AD9")
    static let ftmsFeature = CBUUID(string: "2ACC")
}

enum FTMSOpCode: UInt8 {
    case reset = 0x01
    case requestControl = 0x00
    case setTargetPower = 0x05
    case setSimulationParameters = 0x11
    case responseCode = 0x80
}

enum FTMSResultCode: UInt8 {
    case success = 0x01
    case opCodeNotSupported = 0x02
    case invalidParameter = 0x03
    case operationFailed = 0x04
    case controlNotPermitted = 0x05
}
