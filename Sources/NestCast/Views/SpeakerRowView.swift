import SwiftUI

public struct SpeakerRowView: View {
    public let device: CastDevice
    public let isConnected: Bool
    public let onSelect: () -> Void
    public let onTestChime: () -> Void
    
    public init(
        device: CastDevice,
        isConnected: Bool,
        onSelect: @escaping () -> Void,
        onTestChime: @escaping () -> Void
    ) {
        self.device = device
        self.isConnected = isConnected
        self.onSelect = onSelect
        self.onTestChime = onTestChime
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isConnected ? "speaker.wave.3.fill" : "speaker.wave.2")
                .font(.system(size: 16))
                .foregroundColor(isConnected ? .accentColor : .primary)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                
                HStack(spacing: 6) {
                    Text(device.model)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    if let ip = device.ipAddress {
                        Text("•")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text(ip)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            Button(action: onTestChime) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Play test chime on speaker")
            
            Button(action: onSelect) {
                Text(isConnected ? "Active" : "Cast")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isConnected ? Color.accentColor : Color.secondary.opacity(0.2))
                    .foregroundColor(isConnected ? .white : .primary)
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isConnected ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(6)
    }
}
