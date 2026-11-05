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
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.accentColor)
                
                Text("NestCast")
                    .font(.system(size: 15, weight: .bold))
                
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
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help("Rescan Wi-Fi for speakers")
                }
            }
            .padding(.bottom, 2)
            
            // System Audio Bridge Switcher
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("System Audio Bridge")
                            .font(.system(size: 12, weight: .semibold))
                        Text(bridge.isRunning ? "Nest available in macOS Sound Settings" : "Stream entire Mac system audio to Nest")
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
            .padding(8)
            .background(bridge.isRunning ? Color.green.opacity(0.1) : Color.secondary.opacity(0.08))
            .cornerRadius(8)
            
            // Active direct Cast Session
            if cast.activeDevice != nil {
                ActiveSessionView(
                    cast: cast,
                    onDisconnect: {
                        cast.disconnect()
                    }
                )
            }
            
            // Discovered Speakers Section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("SPEAKERS (\(discovery.devices.count))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if let ip = server.localIP as String?, ip != "127.0.0.1" {
                        Text("Mac: \(ip)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                
                if discovery.devices.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Searching for Google Nest Mini...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
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
            
            // Footer
            HStack {
                Text("v1.0.0 • gpsurya")
                    .font(.system(size: 10))
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
            }
        }
        .padding(14)
        .frame(width: 320)
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
