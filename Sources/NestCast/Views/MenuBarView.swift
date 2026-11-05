import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var discovery: CastDiscovery
    @ObservedObject var cast: CastProtocol
    @ObservedObject var bridge: AirCastBridge
    @ObservedObject var server: AudioStreamServer
    @ObservedObject var streamer: DesktopAudioStreamer = .shared
    
    public init(
        discovery: CastDiscovery,
        cast: CastProtocol,
        bridge: AirCastBridge,
        server: AudioStreamServer,
        streamer: DesktopAudioStreamer = .shared
    ) {
        self.discovery = discovery
        self.cast = cast
        self.bridge = bridge
        self.server = server
        self.streamer = streamer
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Bar
            HStack(spacing: 8) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.accentColor)
                
                Text("NestCast")
                    .font(.system(size: 14, weight: .bold))
                
                Spacer()
                
                if discovery.isScanning {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                } else {
                    Button(action: {
                        discovery.refresh()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Rescan Wi-Fi for speakers")
                }
            }
            .padding(.bottom, 2)
            
            // Active Session Card
            if cast.activeDevice != nil {
                ActiveSessionView(
                    cast: cast,
                    streamer: streamer,
                    onTestChime: {
                        handlePlayTestSound()
                    },
                    onDisconnect: {
                        handleDisconnect()
                    }
                )
            }
            
            // Available Speakers Section
            let otherDevices = discovery.devices.filter { $0.id != cast.activeDevice?.id }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(cast.activeDevice != nil ? "OTHER SPEAKERS (\(otherDevices.count))" : "AVAILABLE SPEAKERS (\(discovery.devices.count))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if let ip = server.localIP as String?, ip != "127.0.0.1" {
                        Text("Mac: \(ip)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                
                if discovery.devices.isEmpty {
                    VStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Searching for Google Nest Minis on Wi-Fi...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                } else if otherDevices.isEmpty && cast.activeDevice != nil {
                    Text("All discovered speakers are in use.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 5) {
                        ForEach(otherDevices) { device in
                            SpeakerRowView(
                                device: device,
                                isConnected: false,
                                onSelect: {
                                    handleSpeakerConnect(device)
                                }
                            )
                        }
                    }
                }
            }
            
            Divider()
                .opacity(0.5)
            
            // Footer
            HStack {
                Text("v1.0.2 • gpsurya")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Quit") {
                    streamer.stopStreaming()
                    cast.disconnect()
                    bridge.stopBridge()
                    server.stop()
                    NSApplication.shared.terminate(nil)
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
    
    private func handleSpeakerConnect(_ device: CastDevice) {
        streamer.startStreaming(to: device, server: server, cast: cast)
    }
    
    private func handleDisconnect() {
        streamer.stopStreaming()
        cast.disconnect()
    }
    
    private func handlePlayTestSound() {
        if cast.activeDevice != nil {
            cast.playChime()
        }
    }
}
