//
//  RootView.swift
//  FitBridgeIOS
//

import SwiftUI

struct RootView: View {
    @ObservedObject var bridge: FitBridge
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject private var garmin: GarminPeripheral
    @ObservedObject private var heartRate: HeartRateMonitor

    init(bridge: FitBridge, profileStore: ProfileStore) {
        self.bridge = bridge
        self.profileStore = profileStore
        _garmin = ObservedObject(wrappedValue: bridge.garminPeripheral)
        _heartRate = ObservedObject(wrappedValue: bridge.heartRate)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Trainer") {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(bridge.trainerName)
                            .font(.headline)
                    }
                    if bridge.connectionState == .connected {
                        HStack {
                            Text("ERG control:")
                            Text(bridge.controlGranted ? "Granted" : "Not granted")
                                .foregroundColor(bridge.controlGranted ? .green : .secondary)
                        }
                        .font(.caption)
                    }
                }

                if bridge.connectionState == .connected {
                    Section("Live") {
                        HStack {
                            metric(label: "Power", value: "\(bridge.currentPower) W")
                            metric(label: "Cadence", value: "\(bridge.currentCadence) rpm")
                            metric(
                                label: profileStore.profile.useVirtualSpeed ? "Speed (virtual)" : "Speed",
                                value: String(format: "%.1f km/h", bridge.currentSpeedKmh)
                            )
                            metric(label: "HR", value: heartRate.heartRateBpm.map { "\($0) bpm" } ?? "—")
                        }
                        if profileStore.profile.useVirtualSpeed, bridge.trainerReportedSpeedKmh > 0 {
                            Text(String(format: "Trainer reports %.1f km/h", bridge.trainerReportedSpeedKmh))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Section("Trainers") {
                        pickerSection
                    }
                }

                Section("Heart rate") {
                    HStack {
                        // A live GATT link is not the same as a live reading: a Garmin watch will
                        // hold the 0x180D connection open and simply stop notifying 0x2A37 once it
                        // is also connected to us as a power sensor. Green here would say
                        // "everything's fine" while the readout sits at "—".
                        Circle()
                            .fill(heartRateStatusColor)
                            .frame(width: 8, height: 8)
                        Text(heartRate.sensorName)
                            .font(.headline)
                        Spacer()
                        if let bpm = heartRate.heartRateBpm {
                            Text("\(bpm) bpm")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.red)
                        } else if heartRate.connectionState == .connected {
                            Text("no data")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    if heartRate.connectionState == .connected {
                        Button("Forget", role: .destructive) {
                            heartRate.forget()
                        }
                        .font(.caption)
                    } else {
                        heartRatePickerSection
                    }

                    if !heartRate.lastLogLine.isEmpty {
                        Text(heartRate.lastLogLine)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                }

                Section("Garmin") {
                    HStack {
                        Text("Garmin:")
                        if garmin.subscriberCount > 0 {
                            Text("Connected (\(garmin.subscriberCount))")
                                .foregroundColor(.green)
                        } else if garmin.isAdvertising {
                            Text("Advertising…")
                                .foregroundColor(.yellow)
                        } else {
                            Text("Not ready")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.caption)
                }

                Section("Simulation") {
                    HStack {
                        Text("SIM:")
                        simStatusText
                        Spacer()
                        Text("Expected: \(bridge.expectedResistivePower) W")
                            .foregroundColor(.secondary)
                    }
                    .font(.caption2)

                    if bridge.connectionState == .connected {
                        gradeControl
                    }
                }

                Section("Log") {
                    Text(bridge.lastLogLine)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                SettingsPanel(profileStore: profileStore, bridge: bridge)

                if bridge.connectionState == .connected {
                    Section {
                        Button("Disconnect", role: .destructive) {
                            bridge.rescan()
                        }
                    }
                }
            }
            .navigationTitle("FitBridge")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ComputerScreenView(bridge: bridge, profileStore: profileStore)
                    } label: {
                        Image(systemName: "gauge.open.with.lines.needle.33percent")
                    }
                    .accessibilityLabel("Computer screen")
                }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }

    /// Road gradient. Feeds the virtual speed model always, and the trainer's SIM parameters
    /// when the trainer supports them — that second path is what the legs actually feel.
    private var gradeControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Grade")
                Spacer()
                Text(String(format: "%+.1f %%", bridge.gradePercent))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Button("Flat") { bridge.gradePercent = 0 }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
            .font(.caption)

            Slider(value: $bridge.gradePercent, in: -10...15, step: 0.5)
        }
    }

    @ViewBuilder
    private var pickerSection: some View {
        if bridge.connectionState == .connecting {
            HStack(spacing: 6) {
                ProgressView()
                Text(bridge.isReconnecting ? "Reconnecting to \(bridge.trainerName)…" : "Connecting to \(bridge.trainerName)…")
                    .font(.caption)
            }
        } else {
            if bridge.discoveredTrainers.isEmpty {
                Text("Searching for trainers…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(bridge.discoveredTrainers) { candidate in
                    Button {
                        bridge.connect(to: candidate.id)
                    } label: {
                        HStack {
                            Circle()
                                .fill(rssiColor(candidate.rssi))
                                .frame(width: 8, height: 8)
                            Text(candidate.name)
                                .font(.caption)
                            Spacer()
                            Text(candidate.serviceKind.label)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Button("Rescan") {
                bridge.rescan()
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var heartRatePickerSection: some View {
        if heartRate.connectionState == .connecting {
            HStack(spacing: 6) {
                ProgressView()
                Text(heartRate.isReconnecting ? "Reconnecting to \(heartRate.sensorName)…" : "Connecting to \(heartRate.sensorName)…")
                    .font(.caption)
            }
        } else {
            if heartRate.discoveredSensors.isEmpty {
                Text("Searching for heart rate sensors…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(heartRate.discoveredSensors) { candidate in
                    Button {
                        heartRate.connect(to: candidate.id)
                    } label: {
                        HStack {
                            Circle()
                                .fill(rssiColor(candidate.rssi))
                                .frame(width: 8, height: 8)
                            Text(candidate.name)
                                .font(.caption)
                            Spacer()
                        }
                    }
                }
            }

            Button("Scan") {
                heartRate.startScanning()
            }
            .font(.caption)
        }
    }

    private func rssiColor(_ rssi: Int) -> Color {
        switch rssi {
        case -60...0: return .green
        case -75 ..< -60: return .yellow
        default: return .red
        }
    }

    private var simStatusText: some View {
        Group {
            if !bridge.simulationSupported {
                Text("unsupported")
                    .foregroundColor(.secondary)
            } else if bridge.simulationActive {
                Text("active")
                    .foregroundColor(.green)
            } else {
                Text("off")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusColor: Color {
        statusColor(for: bridge.connectionState)
    }

    /// Connected-but-silent is its own state — see the comment in the Heart rate section.
    private var heartRateStatusColor: Color {
        if heartRate.connectionState == .connected && heartRate.heartRateBpm == nil {
            return .orange
        }
        return statusColor(for: heartRate.connectionState)
    }

    private func statusColor(for state: ConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting, .scanning: return .yellow
        case .disconnected: return .red
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack {
            Text(value).font(.system(.body, design: .monospaced)).bold()
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Settings panel

private struct SettingsPanel: View {
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject var bridge: FitBridge

    @State private var riderWeight = ""
    @State private var bikeWeight = ""
    @State private var ftp = ""
    @State private var crr = ""
    @State private var cda = ""
    @State private var windSpeed = ""
    @State private var wheelCircumference = ""
    @State private var keepAlive = true

    var body: some View {
        Section("Profile") {
            settingRow("Rider weight (kg)", text: $riderWeight)
            settingRow("Bike weight (kg)", text: $bikeWeight)
            settingRow("FTP (W)", text: $ftp)

            Button("Save") { save() }
        }

        Section("Advanced") {
            settingRow("Crr", text: $crr)
            settingRow("CdA (m²)", text: $cda)
            settingRow("Headwind (m/s)", text: $windSpeed)
            Toggle("Virtual speed", isOn: Binding(
                get: { profileStore.profile.useVirtualSpeed },
                set: { on in profileStore.update { $0.useVirtualSpeed = on } }
            ))
            Text("Derives speed from power, weight, Crr and CdA the way Zwift/MyWhoosh do, instead of using the trainer's own speed field. Set headwind to 0 to match Zwift exactly.")
                .font(.caption2)
                .foregroundColor(.secondary)
            Toggle("Send speed to Garmin", isOn: Binding(
                get: { profileStore.profile.broadcastSpeedToGarmin },
                set: { on in profileStore.update { $0.broadcastSpeedToGarmin = on } }
            ))
            settingRow("Wheel size (mm)", text: $wheelCircumference)
            Text("Speed reaches the watch as wheel-revolution data inside the power sensor itself, the way a hub power meter reports it. Set the same wheel size on the watch for that sensor, or the speed it shows will be scaled. Re-pair the sensor after changing this toggle.")
                .font(.caption2)
                .foregroundColor(.secondary)
            Toggle("SIM keep-alive (30 s)", isOn: $keepAlive)
            Toggle("Mock trainer", isOn: Binding(
                get: { bridge.mockTrainerActive },
                set: { bridge.setMockTrainer($0) }
            ))
        }
        .onAppear { sync() }
    }

    private func settingRow(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .frame(width: 90)
        }
    }

    private func sync() {
        let p = profileStore.profile
        riderWeight = fmt(p.riderWeightKg)
        bikeWeight = fmt(p.bikeWeightKg)
        ftp = "\(p.ftpWatts)"
        crr = String(p.crr)
        cda = fmt(p.cda)
        windSpeed = fmt(p.windSpeedMps)
        wheelCircumference = "\(p.wheelCircumferenceMm)"
        keepAlive = p.simKeepaliveEnabled
    }

    private func save() {
        profileStore.update {
            if let v = Double(riderWeight) { $0.riderWeightKg = v }
            if let v = Double(bikeWeight) { $0.bikeWeightKg = v }
            if let v = Int(ftp) { $0.ftpWatts = v }
            if let v = Double(crr) { $0.crr = v }
            if let v = Double(cda) { $0.cda = v }
            if let v = Double(windSpeed) { $0.windSpeedMps = v }
            if let v = Int(wheelCircumference), v > 0 { $0.wheelCircumferenceMm = v }
            $0.simKeepaliveEnabled = keepAlive
        }
    }

    private func fmt(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", v)
            : String(v)
    }
}
