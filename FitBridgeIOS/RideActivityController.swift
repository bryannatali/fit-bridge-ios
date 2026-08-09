//
//  RideActivityController.swift
//  FitBridgeIOS
//
//  Thin wrapper around the Live Activity that mirrors power/cadence/speed/grade into the
//  Dynamic Island and Lock Screen. Kept separate from FitBridge so the throttling and
//  change-detection live in one place instead of scattered through the BLE delegate methods.
//

import ActivityKit
import Foundation

@MainActor
final class RideActivityController {
    typealias ContentState = RideActivityAttributes.ContentState

    private var activity: Activity<RideActivityAttributes>?
    private var lastPushedState: ContentState?
    private var lastPushDate: Date = .distantPast
    private let minPushInterval: TimeInterval = 1.0

    func start(trainerName: String) {
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[RideActivityController] Live Activities not enabled — skipping start")
            return
        }
        let attributes = RideActivityAttributes(trainerName: trainerName)
        let initialState = ContentState(
            powerWatts: 0,
            cadenceRpm: 0,
            speedKmh: 0,
            gradePercent: 0,
            expectedWatts: 0,
            sim: .off,
            link: .riding
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: Date().addingTimeInterval(10))
            )
            lastPushedState = initialState
            lastPushDate = Date()
        } catch {
            print("[RideActivityController] Failed to start activity: \(error.localizedDescription)")
        }
    }

    /// Throttled to ~1 Hz and only when a value actually changed — ActivityKit budgets updates,
    /// and the caller ticks at 10 Hz. `force` bypasses both checks so a grade-button tap feels
    /// instant instead of waiting for the next throttle window.
    func update(_ state: ContentState, force: Bool = false) {
        guard let activity else { return }
        if !force {
            guard Date().timeIntervalSince(lastPushDate) >= minPushInterval else { return }
            guard !isEquivalent(state, lastPushedState) else { return }
        }
        lastPushedState = state
        lastPushDate = Date()
        Task {
            await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(10)))
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastPushedState = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Compares at the resolution actually shown on screen so an update isn't skipped or sent
    /// for a change too small to render (e.g. speed drifting by 0.01 km/h at 10 Hz).
    private func isEquivalent(_ a: ContentState, _ b: ContentState?) -> Bool {
        guard let b else { return false }
        return a.powerWatts == b.powerWatts
            && a.cadenceRpm == b.cadenceRpm
            && Int(a.speedKmh * 10) == Int(b.speedKmh * 10)
            && a.gradePercent == b.gradePercent
            && a.expectedWatts == b.expectedWatts
            && a.sim == b.sim
            && a.link == b.link
    }
}
