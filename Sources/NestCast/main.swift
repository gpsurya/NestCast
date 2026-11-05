import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        let discovery = CastDiscovery()
        let cast = CastProtocol()
        let bridge = AirCastBridge()
        let server = AudioStreamServer()
        
        self.statusBarController = StatusBarController(
            discovery: discovery,
            cast: cast,
            bridge: bridge,
            server: server
        )
        discovery.startDiscovery()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // App will terminate cleanly
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
