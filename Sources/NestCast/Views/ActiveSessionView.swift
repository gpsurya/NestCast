import SwiftUI

public struct ActiveSessionView: View {
    @ObservedObject var cast: CastProtocol
    public let onDisconnect: () -> Void
    
    public init(
        cast: CastProtocol,
        onDisconnect: @escaping () -> Void
    ) {
        self.cast = cast
        self.onDisconnect = onDisconnect
    }
    
    public var body: some View {
        if let device = cast.activeDevice {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NOW CASTING")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        Text(device.name)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    
                    Spacer()
                    
                    Button("Disconnect", action: onDisconnect)
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    Slider(value: Binding(
                        get: { self.cast.currentVolume },
                        set: { newVal in
                            self.cast.setVolume(level: newVal)
                        }
                    ), in: 0.0...1.0)
                    
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    Text("\(Int(cast.currentVolume * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
    }
}
