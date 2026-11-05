import Foundation

public struct CastDevice: Identifiable, Hashable, Codable {
    public let id: String
    public var name: String
    public var model: String
    public var host: String
    public var port: Int
    public var ipAddress: String?
    public var status: String
    public var volume: Float
    public var isMuted: Bool
    public var isConnected: Bool
    
    public init(
        id: String,
        name: String,
        model: String = "Google Cast Device",
        host: String,
        port: Int = 8009,
        ipAddress: String? = nil,
        status: String = "Available",
        volume: Float = 0.5,
        isMuted: Bool = false,
        isConnected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.host = host
        self.port = port
        self.ipAddress = ipAddress
        self.status = status
        self.volume = volume
        self.isMuted = isMuted
        self.isConnected = isConnected
    }
    
    public static func == (lhs: CastDevice, rhs: CastDevice) -> Bool {
        lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
