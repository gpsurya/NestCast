import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent macOS from killing the app when windows close or focus changes
        ProcessInfo.processInfo.disableAutomaticTermination("NestCast menu bar resident service")
        ProcessInfo.processInfo.disableSuddenTermination()
        
        LogManager.shared.info("Lifecycle", "applicationDidFinishLaunching - Initializing services")
        NSApp.setActivationPolicy(.accessory)
        
        let discovery = CastDiscovery()
        let cast = CastProtocol()
        let bridge = AirCastBridge()
        let server = AudioStreamServer()
        server.start()
        
        self.statusBarController = StatusBarController(
            discovery: discovery,
            cast: cast,
            bridge: bridge,
            server: server
        )
        discovery.startDiscovery()
        LogManager.shared.info("Lifecycle", "NestCast initialized and scanning for speakers")
    }

    func applicationWillTerminate(_ notification: Notification) {
        LogManager.shared.info("Lifecycle", "applicationWillTerminate received - Cleaning up")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
