//
//  RideActivityAttributes.swift
//  Shared between the FitBridgeIOS app target and the FitBridgeWidgets extension.
//

import ActivityKit

struct RideActivityAttributes: ActivityAttributes {
    enum SimState: String, Codable, Hashable {
        case unsupported, active, off
    }

    /// A transient BLE dropout sets `.reconnecting` so the pill dims instead of the activity
    /// being torn down and restarted — see FitBridge's auto-reconnect handling.
    enum LinkState: String, Codable, Hashable {
        case riding, reconnecting
    }

    struct ContentState: Codable, Hashable {
        var powerWatts: Int
        var cadenceRpm: Int
        var speedKmh: Double
        var gradePercent: Double
        var expectedWatts: Int
        var sim: SimState
        var link: LinkState
    }

    var trainerName: String
}
