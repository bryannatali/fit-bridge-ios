//
//  ComputerScreenView.swift
//  FitBridgeIOS
//

import SwiftUI

struct ComputerScreenView: View {
    @ObservedObject var bridge: FitBridge
    @ObservedObject var profileStore: ProfileStore

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
        }
        .navigationTitle("Computer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func readout(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.3)
            Text(unit)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(label.uppercased())
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
