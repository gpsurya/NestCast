import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var discovery: CastDiscovery
    @ObservedObject var cast: CastProtocol
    @ObservedObject var bridge: AirCastBridge
    @ObservedObject var server: AudioStreamServer
    
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
            
            // Now Casting Card (if an active direct session is ongoing)
            if cast.activeDevice != nil {
                ActiveSessionView(
                    cast: cast,
                    onTestChime: {
                        if let dev = cast.activeDevice {
                            handleTestChime(dev)
                        }
                    },
                    onDisconnect: {
                        cast.disconnect()
                    }
                )
            }
            
            // System Audio Bridge Card
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("System Audio Bridge")
                                .font(.system(size: 12, weight: .semibold))
                            
                            Circle()
                                .fill(bridge.isRunning ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                        }
                        
                        Text(bridge.isRunning ? "Nest visible in macOS Sound Settings" : "Route entire Mac sound to Nest via AirPlay")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: Binding(
                        get: { bridge.isRunning },
                        set: { enable in
                            if enable {
                                bridge.startBridge()
                            } else {
                                bridge.stopBridge()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .cornerRadius(8)
            
            // Discovered Speakers Section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("SPEAKERS (\(discovery.devices.count))")
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
                        Text("Searching for Google Nest Minis...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    VStack(spacing: 4) {
                        ForEach(discovery.devices) { device in
                            SpeakerRowView(
                                device: device,
                                isConnected: cast.activeDevice?.id == device.id,
                                onSelect: {
                                    handleSpeakerSelect(device)
                                },
                                onTestChime: {
                                    handleTestChime(device)
                                }
                            )
                        }
                    }
                }
            }
            
            Divider()
                .opacity(0.6)
            
            // Footer
            HStack {
                Text("v1.0.0 • gpsurya")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Quit") {
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
        .padding(12)
        .frame(width: 310)
    }
    
    private func handleSpeakerSelect(_ device: CastDevice) {
        if cast.activeDevice?.id == device.id {
            cast.disconnect()
        } else {
            if !server.isRunning {
                server.start()
            }
            let streamURL = server.streamURL(endpoint: "ping.wav")
            cast.connect(to: device, streamURL: streamURL)
        }
    }
    
    private func handleTestChime(_ device: CastDevice) {
        if !server.isRunning {
            server.start()
        }
        let streamURL = server.streamURL(endpoint: "ping.wav")
        cast.connect(to: device, streamURL: streamURL)
    }
}
