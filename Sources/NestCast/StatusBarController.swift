import AppKit
import SwiftUI
import Combine

@MainActor
public final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    
    private let discovery: CastDiscovery
    private let cast: CastProtocol
    private let bridge: AirCastBridge
    private let server: AudioStreamServer
    private var cancellables = Set<AnyCancellable>()
    
    public init(
        discovery: CastDiscovery,
        cast: CastProtocol,
        bridge: AirCastBridge,
        server: AudioStreamServer
    ) {
        self.discovery = discovery
        self.cast = cast
        self.bridge = bridge
        self.server = server
        super.init()
        
        setupPopover()
        setupStatusButton()
        observeStateChanges()
    }
    
    private func setupPopover() {
        let contentView = MenuBarView(
            discovery: discovery,
            cast: cast,
            bridge: bridge,
            server: server
        )
        let hostingController = NSHostingController(rootView: contentView)
        hostingController.sizingOptions = [.preferredContentSize]
        
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = hostingController
    }
    
    private func setupStatusButton() {
        guard let button = statusItem.button else { return }
        statusItem.length = 28
        button.image = NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: "NestCast")
        button.action = #selector(togglePopover)
        button.target = self
    }
    
    private func observeStateChanges() {
        cast.$activeDevice
            .receive(on: RunLoop.main)
            .sink { [weak self] dev in
                self?.updateButtonIcon(hasActiveDevice: dev != nil, isBridgeRunning: self?.bridge.isRunning ?? false)
            }
            .store(in: &cancellables)
        
        bridge.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] running in
                self?.updateButtonIcon(hasActiveDevice: self?.cast.activeDevice != nil, isBridgeRunning: running)
            }
            .store(in: &cancellables)
    }
    
    private func updateButtonIcon(hasActiveDevice: Bool, isBridgeRunning: Bool) {
        guard let button = statusItem.button else { return }
        let symbolName = (hasActiveDevice || isBridgeRunning) ? "speaker.wave.3.fill" : "airplayaudio"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "NestCast")
        button.contentTintColor = (hasActiveDevice || isBridgeRunning) ? .systemGreen : nil
    }
    
    @objc public func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            LogManager.shared.info("UI", "Closing NestCast popover")
            popover.close()
        } else {
            LogManager.shared.info("UI", "Opening NestCast popover")
            discovery.startDiscovery()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    
    public func closePopover() {
        guard popover.isShown else { return }
        LogManager.shared.info("UI", "NestCast popover closed")
        popover.close()
    }
    
    public func popoverDidClose(_ notification: Notification) {
        LogManager.shared.info("UI", "popoverDidClose notification received")
    }
}
