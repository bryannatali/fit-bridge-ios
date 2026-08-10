//
//  ProfileStore.swift
//  FitBridge
//

import Combine
import Foundation
import GRDB

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profile: RiderProfile = .default

    let profileDidChange = PassthroughSubject<RiderProfile, Never>()

    private let dbQueue: DatabaseQueue

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("FitBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("fitbridge.sqlite").path

        dbQueue = try! DatabaseQueue(path: dbPath)
        runMigrations()
        loadProfile()
    }

    func update(_ mutate: (inout RiderProfile) -> Void) {
        var updated = profile
        mutate(&updated)
        Task {
            try? await dbQueue.write { db in
                try updated.save(db)
            }
            self.profile = updated
            self.profileDidChange.send(updated)
        }
    }

    private func runMigrations() {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_createRiderProfile") { db in
            try db.create(table: "rider_profile", ifNotExists: true) { t in
                t.column("id", .integer).primaryKey().check { $0 == 1 }
                t.column("rider_weight_kg", .real).notNull().defaults(to: 75.0)
                t.column("bike_weight_kg", .real).notNull().defaults(to: 9.0)
                t.column("ftp_watts", .integer).notNull().defaults(to: 200)
                t.column("crr", .real).notNull().defaults(to: 0.004)
                t.column("cda", .real).notNull().defaults(to: 0.30)
                t.column("wind_speed_mps", .real).notNull().defaults(to: 0.8)
                t.column("sim_keepalive_enabled", .integer).notNull().defaults(to: 1)
            }
        }
        migrator.registerMigration("v2_addUseVirtualSpeed") { db in
            try db.alter(table: "rider_profile") { t in
                t.add(column: "use_virtual_speed", .boolean).notNull().defaults(to: true)
            }
        }
        migrator.registerMigration("v3_addGarminSpeedBroadcast") { db in
            try db.alter(table: "rider_profile") { t in
                t.add(column: "broadcast_speed_to_garmin", .boolean).notNull().defaults(to: true)
                t.add(column: "wheel_circumference_mm", .integer).notNull().defaults(to: 2096)
            }
        }
        migrator.registerMigration("v4_addHeartRateSensor") { db in
            try db.alter(table: "rider_profile") { t in
                t.add(column: "heart_rate_sensor_id", .text)
                t.add(column: "heart_rate_sensor_name", .text)
            }
        }
        try? migrator.migrate(dbQueue)
    }

    private func loadProfile() {
        let loaded = try? dbQueue.read { db in
            try RiderProfile.fetchOne(db)
        }
        if let loaded {
            profile = loaded
        } else {
            Task {
                try? await dbQueue.write { db in
                    var seed = RiderProfile.default
                    try seed.insert(db, onConflict: .ignore)
                }
            }
        }
    }
}
