//
//  ComputerScreenView.swift
//  FitBridgeIOS
//

import SwiftUI

struct ComputerScreenView: View {
    @ObservedObject var bridge: FitBridge
    @ObservedObject var profileStore: ProfileStore
    @ObservedObject private var heartRate: HeartRateMonitor

    init(bridge: FitBridge, profileStore: ProfileStore) {
        self.bridge = bridge
        self.profileStore = profileStore
        _heartRate = ObservedObject(wrappedValue: bridge.heartRate)
    }

    var body: some View {
        VStack(spacing: 0) {
            readout(
                label: profileStore.profile.useVirtualSpeed ? "Speed (virtual)" : "Speed",
                value: String(format: "%.1f", bridge.currentSpeedKmh),
                unit: "km/h"
            )
            Divider()
            readout(label: "Power", value: "\(bridge.currentPower)", unit: "W")
            Divider()
            readout(label: "Cadence", value: "\(bridge.currentCadence)", unit: "rpm")
            if heartRate.connectionState == .connected {
                Divider()
                readout(
                    label: "Heart rate",
                    value: heartRate.heartRateBpm.map { "\($0)" } ?? "—",
                    unit: "bpm",
                    tint: .red,
                    compact: true
                )
            }
        }
        .navigationTitle("Computer")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// `compact` halves the type size and, more importantly, makes the row non-greedy: the primary
    /// readouts claim the screen with `maxHeight: .infinity` and split it evenly between them,
    /// while a compact row takes only its intrinsic height. Heart rate is a secondary metric here —
    /// it shouldn't get an equal quarter of the screen just by being present.
    private func readout(label: String, value: String, unit: String,
                         tint: Color = .primary, compact: Bool = false) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: compact ? 60 : 120, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .foregroundColor(tint)
            Text(unit)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(label.uppercased())
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
        .padding(.vertical, compact ? 12 : 0)
    }
}
