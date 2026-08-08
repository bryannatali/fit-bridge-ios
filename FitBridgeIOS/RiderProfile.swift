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
    }
}
