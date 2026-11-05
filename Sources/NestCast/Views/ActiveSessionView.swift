import SwiftUI

public struct ActiveSessionView: View {
    @ObservedObject var cast: CastProtocol
    @ObservedObject var streamer: DesktopAudioStreamer = .shared
    public let onTestChime: () -> Void
    public let onDisconnect: () -> Void
    
    public init(
        cast: CastProtocol,
        streamer: DesktopAudioStreamer = .shared,
        onTestChime: @escaping () -> Void,
        onDisconnect: @escaping () -> Void
    ) {
        self.cast = cast
        self.streamer = streamer
        self.onTestChime = onTestChime
        self.onDisconnect = onDisconnect
    }
    
    public var body: some View {
        if let device = cast.activeDevice {
            VStack(alignment: .leading, spacing: 10) {
                // Header Row
                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NOW CASTING")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        Text(device.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    Button(action: onDisconnect) {
                        Text("Disconnect")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
                
                Divider()
                    .opacity(0.4)
                
                // Volume Slider Section
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("SPEAKER VOLUME")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text("\(Int(cast.currentVolume * 100))%")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    
                    HStack(spacing: 8) {
                        Image(systemName: volumeIconName)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        
                        Slider(
                            value: Binding(
                                get: { self.cast.currentVolume },
                                set: { newVal in
                                    self.cast.setVolume(level: newVal)
                                }
                            ),
                            in: 0.0...1.0
                        )
                        
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                    }
                }
                
                // Quick Test Sound Action
                Button(action: onTestChime) {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 10))
                        Text("Play Test Sound on Speaker")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                // Live Desktop Audio Status Card
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(streamer.isStreaming ? .green : .accentColor)
                        
                        Text("HI-FI WI-FI STREAMING")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if streamer.isStreaming {
                            Text("320 KBPS • 48 kHz")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .cornerRadius(4)
                        } else if !streamer.statusText.isEmpty {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        }
                    }
                    
                    if streamer.isStreaming {
                        Text("Streaming studio-quality 320kbps audio to \(device.name) over Wi-Fi without Bluetooth compression (Audio-only music listening).")
                            .font(.system(size: 10))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !streamer.statusText.isEmpty {
                        Text(streamer.statusText)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Click Cast to stream uncompressed Mac audio over Wi-Fi.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(6)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
            )
            .cornerRadius(8)
        }
    }
    
    private var volumeIconName: String {
        if cast.currentVolume <= 0.01 {
            return "speaker.slash.fill"
        } else if cast.currentVolume < 0.33 {
            return "speaker.wave.1.fill"
        } else if cast.currentVolume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}
