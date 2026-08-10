//
//  RiderProfile.swift
//  FitBridge
//

import Foundation
import GRDB

struct RiderProfile: Codable, FetchableRecord, PersistableRecord {
    var id: Int64 = 1
    var riderWeightKg: Double = 75.0
    var bikeWeightKg: Double = 9.0
    var ftpWatts: Int = 200
    var crr: Double = 0.004
    var cda: Double = 0.30
    var windSpeedMps: Double = 0.8
    var simKeepaliveEnabled: Bool = true
    /// Show physics-derived speed instead of the trainer's own instantaneous-speed field.
    var useVirtualSpeed: Bool = true
    /// Expose the Cycling Speed and Cadence service (0x1816) so the watch records speed/distance.
    var broadcastSpeedToGarmin: Bool = true
    /// Must match the wheel size configured on the watch for the sensor. 2096 mm = 700x23C,
    /// which is also Garmin's own default.
    var wheelCircumferenceMm: Int = 2096
    /// `CBPeripheral.identifier` of the remembered heart rate sensor. Unlike the trainer
    /// (session-only by design — a gym trainer isn't "yours"), a personal strap/watch is a
    /// stable device worth reconnecting to automatically across launches.
    var heartRateSensorId: String? = nil
    var heartRateSensorName: String? = nil

    static let databaseTableName = "rider_profile"
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    static let `default` = RiderProfile()

    enum Columns: String, ColumnExpression {
        case id
        case riderWeightKg  = "rider_weight_kg"
        case bikeWeightKg   = "bike_weight_kg"
        case ftpWatts       = "ftp_watts"
        case crr
        case cda
        case windSpeedMps   = "wind_speed_mps"
        case simKeepaliveEnabled = "sim_keepalive_enabled"
        case useVirtualSpeed = "use_virtual_speed"
        case broadcastSpeedToGarmin = "broadcast_speed_to_garmin"
        case wheelCircumferenceMm = "wheel_circumference_mm"
        case heartRateSensorId = "heart_rate_sensor_id"
        case heartRateSensorName = "heart_rate_sensor_name"
    }
}
