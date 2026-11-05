import Foundation
import Network

public enum CastState {
    case disconnected
    case connecting
    case connected
    case launching
    case playing
    case error(String)
}

@MainActor
public class CastProtocol: ObservableObject {
    @Published public var state: CastState = .disconnected
    @Published public var currentTransportId: String?
    @Published public var currentSessionId: String?
    @Published public var activeDevice: CastDevice?
    @Published public var currentVolume: Float = 0.5
    
    private var connection: NWConnection?
    private var heartbeatTimer: Timer?
    private var requestId: Int = 1
    
    public init() {}
    
    public func connect(to device: CastDevice, streamURL: String? = nil, completion: ((Bool) -> Void)? = nil) {
        disconnect()
        
        guard let host = device.ipAddress ?? Optional(device.host), !host.isEmpty else {
            self.state = .error("Invalid device host")
            completion?(false)
            return
        }
        
        self.activeDevice = device
        self.state = .connecting
        
        let tlsOpts = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tlsOpts.securityProtocolOptions, { _, _, comp in
            comp(true)
        }, .main)
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(device.port)) ?? 8009
        )
        
        let conn = NWConnection(to: endpoint, using: NWParameters(tls: tlsOpts))
        self.connection = conn
        
        conn.stateUpdateHandler = { [weak self] connState in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch connState {
                case .ready:
                    self.state = .connected
                    self.startHeartbeat()
                    self.sendConnect(destination: "receiver-0")
                    
                    if let stream = streamURL {
                        self.launchAndLoad(streamURL: stream, completion: completion)
                    } else {
                        completion?(true)
                    }
                    self.listenForMessages()
                    
                case .failed(let err):
                    self.state = .error("Connection failed: \(err.localizedDescription)")
                    completion?(false)
                case .cancelled:
                    self.state = .disconnected
                default:
                    break
                }
            }
        }
        
        conn.start(queue: .main)
    }
    
    public func disconnect() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        
        if let transportId = currentTransportId {
            sendStop(transportId: transportId)
        }
        
        connection?.cancel()
        connection = nil
        currentTransportId = nil
        currentSessionId = nil
        activeDevice = nil
        state = .disconnected
    }
    
    public func setVolume(level: Float) {
        let clamped = max(0.0, min(1.0, level))
        let payload: [String: Any] = [
            "type": "SET_VOLUME",
            "volume": ["level": clamped],
            "requestId": nextRequestId()
        ]
        sendJson(destination: "receiver-0", ns: "urn:x-cast:com.google.cast.receiver", dict: payload)
        
        if var dev = activeDevice {
            dev.volume = clamped
            activeDevice = dev
        }
    }
    
    public func launchAndLoad(streamURL: String, completion: ((Bool) -> Void)? = nil) {
        state = .launching
        let payload: [String: Any] = [
            "type": "LAUNCH",
            "appId": "CC1AD845", // Default Media Receiver
            "requestId": nextRequestId()
        ]
        
        sendJson(destination: "receiver-0", ns: "urn:x-cast:com.google.cast.receiver", dict: payload)
        
        // Wait for RECEIVER_STATUS to arrive with transportId, or timeout after 5s
        Task {
            for _ in 0..<25 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let transportId = self.currentTransportId {
                    self.sendConnect(destination: transportId)
                    self.loadMedia(transportId: transportId, streamURL: streamURL)
                    self.state = .playing
                    completion?(true)
                    return
                }
            }
            if self.currentTransportId == nil {
                self.state = .error("Timed out waiting for Media Receiver")
                completion?(false)
            }
        }
    }
    
    private func loadMedia(transportId: String, streamURL: String) {
        let mediaDict: [String: Any] = [
            "contentId": streamURL,
            "contentType": streamURL.hasSuffix(".wav") ? "audio/wav" : "audio/mp3",
            "streamType": "LIVE",
            "metadata": [
                "metadataType": 3,
                "title": "Mac System Audio",
                "artist": "NestCast"
            ]
        ]
        
        let payload: [String: Any] = [
            "type": "LOAD",
            "requestId": nextRequestId(),
            "autoplay": true,
            "currentTime": 0,
            "media": mediaDict
        ]
        
        sendJson(destination: transportId, ns: "urn:x-cast:com.google.cast.media", dict: payload)
    }
    
    private func sendConnect(destination: String) {
        sendJson(destination: destination, ns: "urn:x-cast:com.google.cast.tp.connection", dict: ["type": "CONNECT"])
    }
    
    private func sendStop(transportId: String) {
        sendJson(destination: transportId, ns: "urn:x-cast:com.google.cast.media", dict: [
            "type": "STOP",
            "requestId": nextRequestId()
        ])
    }
    
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendJson(destination: "receiver-0", ns: "urn:x-cast:com.google.cast.tp.heartbeat", dict: ["type": "PING"])
            }
        }
    }
    
    private func listenForMessages() {
        guard let conn = connection else { return }
        
        conn.receive(minimumIncompleteLength: 4, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let d = data, d.count >= 4 {
                    self.parseIncomingPacket(d)
                }
                if !isComplete && err == nil {
                    self.listenForMessages()
                }
            }
        }
    }
    
    private func parseIncomingPacket(_ data: Data) {
        // Strip 4-byte length prefix
        guard data.count > 4 else { return }
        let payload = data.advanced(by: 4)
        
        // Find field 6 (tag 0x32 = JSON string)
        let bytes = Array(payload)
        var i = 0
        while i < bytes.count {
            let tag = bytes[i]
            let fieldNum = tag >> 3
            let wireType = tag & 0x07
            i += 1
            
            if wireType == 0 { // Varint
                while i < bytes.count && (bytes[i] & 0x80) != 0 { i += 1 }
                i += 1
            } else if wireType == 2 { // Length-delimited
                var len: UInt64 = 0
                var shift: UInt64 = 0
                while i < bytes.count {
                    let b = bytes[i]
                    i += 1
                    len |= UInt64(b & 0x7F) << shift
                    if (b & 0x80) == 0 { break }
                    shift += 7
                }
                let intLen = Int(len)
                if fieldNum == 6 && i + intLen <= bytes.count {
                    let jsonBytes = bytes[i..<(i + intLen)]
                    if let jsonStr = String(bytes: jsonBytes, encoding: .utf8),
                       let data = jsonStr.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        handleJsonMessage(dict)
                    }
                }
                i += intLen
            } else {
                break
            }
        }
    }
    
    private func handleJsonMessage(_ dict: [String: Any]) {
        guard let type = dict["type"] as? String else { return }
        
        if type == "RECEIVER_STATUS",
           let status = dict["status"] as? [String: Any],
           let apps = status["applications"] as? [[String: Any]],
           let firstApp = apps.first {
            if let transportId = firstApp["transportId"] as? String {
                self.currentTransportId = transportId
            }
            if let sessionId = firstApp["sessionId"] as? String {
                self.currentSessionId = sessionId
            }
        }
    }
    
    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }
    
    private func sendJson(source: String = "sender-0", destination: String, ns: String, dict: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
        
        let packet = encodeCastMessage(source: source, dest: destination, ns: ns, json: jsonStr)
        connection?.send(content: packet, completion: .contentProcessed({ _ in }))
    }
    
    private func encodeCastMessage(source: String, dest: String, ns: String, json: String) -> Data {
        func makeVarint(_ val: UInt64) -> [UInt8] {
            var v = val
            var res: [UInt8] = []
            while v > 0x7F {
                res.append(UInt8((v & 0x7F) | 0x80))
                v >>= 7
            }
            res.append(UInt8(v))
            return res
        }
        
        func encodeString(tag: UInt8, str: String) -> [UInt8] {
            let utf8 = Array(str.utf8)
            return [tag] + makeVarint(UInt64(utf8.count)) + utf8
        }
        
        var body: [UInt8] = []
        body.append(contentsOf: [0x08, 0x00]) // field 1: CASTV2_1_0
        body.append(contentsOf: encodeString(tag: 0x12, str: source))
        body.append(contentsOf: encodeString(tag: 0x1A, str: dest))
        body.append(contentsOf: encodeString(tag: 0x22, str: ns))
        body.append(contentsOf: [0x28, 0x00]) // field 5: STRING
        body.append(contentsOf: encodeString(tag: 0x32, str: json))
        
        var packet = Data()
        var len = UInt32(body.count).bigEndian
        packet.append(Data(bytes: &len, count: 4))
        packet.append(contentsOf: body)
        return packet
    }
}
