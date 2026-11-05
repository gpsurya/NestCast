import SwiftUI

@main
struct NestCastApp: App {
    @StateObject private var discovery = CastDiscovery()
    @StateObject private var cast = CastProtocol()
    @StateObject private var bridge = AirCastBridge()
    @StateObject private var server = AudioStreamServer()
    
    init() {
        // Ensure app runs purely in status bar without dock icon
        NSApplication.shared.setActivationPolicy(.accessory)
    }
    
    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                discovery: discovery,
                cast: cast,
                bridge: bridge,
                server: server
            )
            .onAppear {
                discovery.startDiscovery()
            }
        } label: {
            let iconName = (cast.activeDevice != nil || bridge.isRunning)
                ? "airplayaudio.badge.checkmark"
                : "airplayaudio"
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.window)
    }
}
