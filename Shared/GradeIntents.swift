//
//  GradeIntents.swift
//  Shared between the FitBridgeIOS app target and the FitBridgeWidgets extension.
//
//  LiveActivityIntents run in the *app's* process, not the extension's — so the handler here
//  reaches the live FitBridge instance directly. No App Group, no Darwin notification, no
//  second GRDB connection. This file has to compile standalone in the extension too, so it
//  cannot reference FitBridge (or any other app-only type) directly — only the protocol.
//

import AppIntents

@MainActor
protocol GradeCommandHandling: AnyObject {
    func nudgeGrade(by delta: Double)
    func setGrade(_ value: Double)
}

@MainActor
enum GradeCommandCenter {
    static weak var handler: (any GradeCommandHandling)?
}

struct AdjustGradeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Adjust grade"
    static var isDiscoverable = false

    @Parameter(title: "Delta")
    var delta: Double

    init() {}

    init(delta: Double) {
        self.delta = delta
    }

    // Written nonisolated with an explicit MainActor hop: the project sets
    // SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, and a @MainActor method cannot witness
    // AppIntent's nonisolated async `perform()` requirement.
    nonisolated func perform() async throws -> some IntentResult {
        await MainActor.run { GradeCommandCenter.handler?.nudgeGrade(by: delta) }
        return .result()
    }
}

struct SetGradeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Set grade"
    static var isDiscoverable = false

    @Parameter(title: "Value")
    var value: Double

    init() {}

    init(value: Double) {
        self.value = value
    }

    nonisolated func perform() async throws -> some IntentResult {
        await MainActor.run { GradeCommandCenter.handler?.setGrade(value) }
        return .result()
    }
}
