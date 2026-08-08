//
//  RootView.swift
//  FitBridgeIOS
//

import SwiftUI

struct RootView: View {
    @ObservedObject var bridge: FitBridge
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject private var garmin: GarminPeripheral

    init(bridge: FitBridge, profileStore: ProfileStore) {
        self.bridge = bridge
        self.profileStore = profileStore
        _garmin = ObservedObject(wrappedValue: bridge.garminPeripheral)
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
                            metric(label: "Speed", value: String(format: "%.1f km/h", bridge.currentSpeedKmh))
                        }
                    }
                } else {
                    Section("Trainers") {
                        pickerSection
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
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
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
        switch bridge.connectionState {
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
        keepAlive = p.simKeepaliveEnabled
    }

    private func save() {
        profileStore.update {
            if let v = Double(riderWeight) { $0.riderWeightKg = v }
            if let v = Double(bikeWeight) { $0.bikeWeightKg = v }
            if let v = Int(ftp) { $0.ftpWatts = v }
            if let v = Double(crr) { $0.crr = v }
            if let v = Double(cda) { $0.cda = v }
            $0.simKeepaliveEnabled = keepAlive
        }
    }

    private func fmt(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", v)
            : String(v)
    }
}
