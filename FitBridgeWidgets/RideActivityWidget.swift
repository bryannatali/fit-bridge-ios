//
//  RideActivityWidget.swift
//  FitBridgeWidgets
//
//  Renders the Live Activity FitBridge pushes while a ride is connected. Grade control is
//  buttons only — Live Activities cannot host a Slider — and each button fires a
//  LiveActivityIntent that runs back in the *app's* process and reaches the live FitBridge
//  instance through GradeCommandCenter (see Shared/GradeIntents.swift). No App Group involved.
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct RideActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 12) {
                        metric("\(context.state.powerWatts) W")
                        metric("\(context.state.cadenceRpm) rpm")
                        metric(String(format: "%.1f km/h", context.state.speedKmh))
                    }
                    .opacity(context.state.link == .reconnecting ? 0.4 : 1.0)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        HStack {
                            Button(intent: AdjustGradeIntent(delta: -0.5)) {
                                Image(systemName: "minus")
                            }
                            Spacer()
                            Text(String(format: "%+.1f %%", context.state.gradePercent))
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(intent: AdjustGradeIntent(delta: 0.5)) {
                                Image(systemName: "plus")
                            }
                        }
                        HStack {
                            Text("SIM \(simLabel(context.state.sim))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Flat", intent: SetGradeIntent(value: 0))
                                .font(.caption2)
                        }
                    }
                    .opacity(context.state.link == .reconnecting ? 0.4 : 1.0)
                }
            } compactLeading: {
                Text("⚡\(context.state.powerWatts)W")
                    .font(.system(.caption, design: .monospaced))
                    .opacity(context.state.link == .reconnecting ? 0.4 : 1.0)
            } compactTrailing: {
                Text(String(format: "%.1f · %d", context.state.speedKmh, context.state.cadenceRpm))
                    .font(.system(.caption2, design: .monospaced))
                    .opacity(context.state.link == .reconnecting ? 0.4 : 1.0)
            } minimal: {
                Text("\(context.state.powerWatts)")
                    .font(.system(.caption2, design: .monospaced))
                    .opacity(context.state.link == .reconnecting ? 0.4 : 1.0)
            }
        }
    }

    private func metric(_ value: String) -> some View {
        Text(value)
            .font(.system(.body, design: .monospaced))
            .bold()
    }

    private func simLabel(_ sim: RideActivityAttributes.SimState) -> String {
        switch sim {
        case .unsupported: return "unsupported"
        case .active: return "active"
        case .off: return "off"
        }
    }
}

private struct LockScreenView: View {
    let state: RideActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                metric(label: "Power", value: "\(state.powerWatts) W")
                metric(label: "Cadence", value: "\(state.cadenceRpm) rpm")
                metric(label: "Speed", value: String(format: "%.1f km/h", state.speedKmh))
            }

            HStack {
                Button(intent: AdjustGradeIntent(delta: -0.5)) {
                    Image(systemName: "minus")
                }
                Spacer()
                Text(String(format: "%+.1f %%", state.gradePercent))
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Button(intent: AdjustGradeIntent(delta: 0.5)) {
                    Image(systemName: "plus")
                }
                Spacer()
                Button("Flat", intent: SetGradeIntent(value: 0))
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .opacity(state.link == .reconnecting ? 0.4 : 1.0)
    }

    private func metric(label: String, value: String) -> some View {
        VStack {
            Text(value).font(.system(.body, design: .monospaced)).bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
