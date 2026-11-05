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
        HStack(spacing: 10) {
            // Speaker Icon Badge
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isConnected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: 28, height: 28)
                
                Image(systemName: isConnected ? "speaker.wave.3.fill" : "speaker.wave.2")
                    .font(.system(size: 13))
                    .foregroundColor(isConnected ? .accentColor : .primary)
            }
            
            // Name & Subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 12, weight: isConnected ? .semibold : .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Text(device.model)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    if let ip = device.ipAddress {
                        Text("•")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                        Text(ip)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // Action Buttons
            HStack(spacing: 6) {
                Button(action: onTestChime) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Play test chime on speaker")
                
                if isConnected {
                    Button(action: onSelect) {
                        Text("Active")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button(action: onSelect) {
                        Text("Cast")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isConnected ? Color.accentColor.opacity(0.06) : Color.clear)
        .cornerRadius(6)
    }
}
