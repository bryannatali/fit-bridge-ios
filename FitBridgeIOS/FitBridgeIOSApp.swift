//
//  FitBridgeIOSApp.swift
//  FitBridgeIOS
//

import SwiftUI

@main
struct FitBridgeIOSApp: App {
    @StateObject private var profileStore: ProfileStore
    @StateObject private var bridge: FitBridge

    init() {
        let store = ProfileStore()
        _profileStore = StateObject(wrappedValue: store)
        _bridge = StateObject(wrappedValue: FitBridge(profileStore: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView(bridge: bridge, profileStore: profileStore)
        }
    }
}
