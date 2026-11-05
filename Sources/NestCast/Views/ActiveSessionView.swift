import SwiftUI

public struct ActiveSessionView: View {
    @ObservedObject var cast: CastProtocol
    public let onTestChime: () -> Void
    public let onDisconnect: () -> Void
    
    public init(
        cast: CastProtocol,
        onTestChime: @escaping () -> Void,
        onDisconnect: @escaping () -> Void
    ) {
        self.cast = cast
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
                    
                    VStack(alignment: .leading, spacing: 1) {
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
                    .opacity(0.5)
                
                // Volume Slider Row
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("SPEAKER VOLUME")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text("\(Int(cast.currentVolume * 100))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(width: 38, alignment: .trailing)
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
                
                // Test Sound Button
                Button(action: onTestChime) {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 10))
                        Text("Play Test Chime")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
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
