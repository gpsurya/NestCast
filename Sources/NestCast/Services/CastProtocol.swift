import Foundation
import Network

public enum CastState: Equatable {
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
    
    private var isAdjustingVolume: Bool = false
    private var volumeAdjustGeneration: Int = 0
    private var connection: NWConnection?
    private var heartbeatTimer: Timer?
    private var volumeDebounceTimer: Timer?
    private var volumeSettleTimer: Timer?
    private var onReceiverReady: ((String) -> Void)?
    
    private var requestId: Int = 1
    private let reqLock = NSLock()
    private let tlsQueue = DispatchQueue(label: "com.gpsurya.NestCast.tls", qos: .userInitiated)
    
    // Persistent TCP stream reassembly buffer
    private var tcpBuffer = Data()
    
    public init() {}
    
    public func connect(to device: CastDevice, streamURL: String? = nil, completion: ((Bool) -> Void)? = nil) {
        disconnect()
        
        guard let host = device.ipAddress ?? Optional(device.host), !host.isEmpty else {
            let errMsg = "Invalid device host"
            self.state = .error(errMsg)
            LogManager.shared.error("CastProtocol", errMsg)
            completion?(false)
            return
        }
        
        self.activeDevice = device
        self.currentVolume = device.volume
        self.state = .connecting
        LogManager.shared.cast("Connecting to \(device.name) at \(host):\(device.port)...")
        
        let tlsOpts = NWProtocolTLS.Options()
        // Dedicated queue for TLS verification to avoid blocking .main
        sec_protocol_options_set_verify_block(tlsOpts.securityProtocolOptions, { _, _, comp in
            comp(true)
        }, tlsQueue)
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(device.port)) ?? 8009
        )
        
        let conn = NWConnection(to: endpoint, using: NWParameters(tls: tlsOpts))
        self.connection = conn
        self.tcpBuffer.removeAll()
        
        conn.stateUpdateHandler = { [weak self] connState in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch connState {
                case .ready:
                    LogManager.shared.cast("TLS handshake succeeded with \(device.name)")
                    self.state = .connected
                    self.startHeartbeat()
                    self.sendConnect(destination: "receiver-0")
                    self.sendGetStatus(destination: "receiver-0")
                    
                    if let stream = streamURL {
                        self.launchAndLoad(streamURL: stream, completion: completion)
                    } else {
                        completion?(true)
                    }
                    self.listenForMessages()
                    
                case .failed(let err):
                    let errMsg = "Connection failed: \(err.localizedDescription)"
                    LogManager.shared.error("CastProtocol", errMsg)
                    self.state = .error(errMsg)
                    completion?(false)
                case .cancelled:
                    LogManager.shared.cast("Connection cancelled")
                    self.state = .disconnected
                default:
                    break
                }
            }
        }
        
        conn.start(queue: .main)
    }
    
    public func disconnect(completion: (() -> Void)? = nil) {
        LogManager.shared.cast("Disconnecting active Cast session instantly")
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        volumeDebounceTimer?.invalidate()
        volumeDebounceTimer = nil
        volumeSettleTimer?.invalidate()
        volumeSettleTimer = nil
        isAdjustingVolume = false
        onReceiverReady = nil
        
        let conn = self.connection
        let transId = self.currentTransportId
        
        // Immediately notify speaker hardware to halt playback and drop media buffers
        if let transportId = transId {
            sendStop(destination: transportId)
            sendClose(destination: transportId)
        }
        sendStop(destination: "receiver-0")
        sendClose(destination: "receiver-0")
        
        self.connection = nil
        self.currentTransportId = nil
        self.currentSessionId = nil
        self.activeDevice = nil
        self.tcpBuffer.removeAll()
        self.state = .disconnected
        
        // Give 120ms for STOP and CLOSE packets to flush through TLS socket before cancellation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            conn?.cancel()
            completion?()
        }
    }
    
    public func setVolume(level: Float) {
        let clamped = max(0.0, min(1.0, level))
        self.isAdjustingVolume = true
        self.volumeAdjustGeneration += 1
        let currentGen = self.volumeAdjustGeneration
        
        self.currentVolume = clamped
        if var dev = activeDevice {
            dev.volume = clamped
            activeDevice = dev
        }
        
        volumeDebounceTimer?.invalidate()
        volumeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let payload: [String: Any] = [
                    "type": "SET_VOLUME",
                    "volume": ["level": clamped],
                    "requestId": self.nextRequestId()
                ]
                self.sendJson(destination: "receiver-0", ns: "urn:x-cast:com.google.cast.receiver", dict: payload)
                LogManager.shared.cast("Dispatched SET_VOLUME -> \(Int(clamped * 100))%")
                
                self.volumeSettleTimer?.invalidate()
                self.volumeSettleTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        if self.volumeAdjustGeneration == currentGen {
                            self.isAdjustingVolume = false
                        }
                    }
                }
            }
        }
    }
    
    public func sendGetStatus(destination: String = "receiver-0") {
        sendJson(destination: destination, ns: "urn:x-cast:com.google.cast.receiver", dict: [
            "type": "GET_STATUS",
            "requestId": nextRequestId()
        ])
    }
    
    public func launchAndLoad(streamURL: String, streamType: String = "LIVE", title: String = "Mac Desktop Audio", completion: ((Bool) -> Void)? = nil) {
        state = .launching
        // Clear any stale transport/session ID from prior sessions to prevent race conditions
        self.currentTransportId = nil
        self.currentSessionId = nil
        
        let dispatchLoad = { [weak self] (transportId: String) in
            guard let self = self else { return }
            LogManager.shared.cast("Receiver ready (transportId=\(transportId)). Dispatching CONNECT and LOAD immediately...")
            self.sendConnect(destination: transportId)
            self.loadMedia(transportId: transportId, streamURL: streamURL, streamType: streamType, title: title)
            self.state = .playing
            completion?(true)
        }
        
        self.onReceiverReady = dispatchLoad
        
        LogManager.shared.cast("Launching Default Media Receiver (CC1AD845)...")
        let payload: [String: Any] = [
            "type": "LAUNCH",
            "appId": "CC1AD845",
            "requestId": nextRequestId()
        ]
        
        sendJson(destination: "receiver-0", ns: "urn:x-cast:com.google.cast.receiver", dict: payload)
        
        // Safety timeout fallback (6s) in case network packets are dropped
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self.onReceiverReady != nil {
                self.onReceiverReady = nil
                if self.currentTransportId == nil {
                    let timeoutMsg = "Timed out waiting for Media Receiver launch"
                    LogManager.shared.error("CastProtocol", timeoutMsg)
                    self.state = .error(timeoutMsg)
                    completion?(false)
                }
            }
        }
    }
    
    public func playChime(streamURL: String? = nil, completion: ((Bool) -> Void)? = nil) {
        let soundURL = streamURL ?? "https://actions.google.com/sounds/v1/alarms/medium_bell_ringing_near.ogg"
        launchAndLoad(streamURL: soundURL, streamType: "BUFFERED", title: "NestCast Chime", completion: completion)
    }
    
    private func loadMedia(transportId: String, streamURL: String, streamType: String = "LIVE", title: String = "Mac Desktop Audio") {
        let mimeType: String
        if streamURL.contains("live.mp3") || streamURL.hasSuffix(".mp3") {
            mimeType = "audio/mpeg"
        } else if streamURL.hasSuffix(".ogg") {
            mimeType = "audio/ogg"
        } else if streamURL.hasSuffix(".m4a") || streamURL.hasSuffix(".mp4") {
            mimeType = "audio/mp4"
        } else {
            mimeType = "audio/mpeg"
        }
        
        let mediaDict: [String: Any] = [
            "contentId": streamURL,
            "contentType": mimeType,
            "streamType": streamType,
            "metadata": [
                "metadataType": 3,
                "title": title,
                "artist": "NestCast"
            ]
        ]
        
        var payload: [String: Any] = [
            "type": "LOAD",
            "requestId": nextRequestId(),
            "autoplay": true,
            "currentTime": 0,
            "media": mediaDict
        ]
        
        if let sid = currentSessionId {
            payload["sessionId"] = sid
        }
        
        LogManager.shared.cast("Dispatching LOAD (\(streamType)) to \(transportId) with URL: \(streamURL)")
        sendJson(destination: transportId, ns: "urn:x-cast:com.google.cast.media", dict: payload)
    }
    
    private func sendConnect(destination: String) {
        sendJson(destination: destination, ns: "urn:x-cast:com.google.cast.tp.connection", dict: ["type": "CONNECT"])
    }
    
    private func sendStop(destination: String) {
        sendJson(destination: destination, ns: "urn:x-cast:com.google.cast.media", dict: [
            "type": "STOP",
            "requestId": nextRequestId()
        ])
    }
    
    private func sendClose(destination: String) {
        sendJson(destination: destination, ns: "urn:x-cast:com.google.cast.tp.connection", dict: ["type": "CLOSE"])
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
        
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let d = data, !d.isEmpty {
                    self.tcpBuffer.append(d)
                    self.processTcpBuffer()
                }
                if !isComplete && err == nil && self.connection != nil {
                    self.listenForMessages()
                }
            }
        }
    }
    
    // Framing parser: extracts complete length-prefixed Cast V2 packets from TCP stream
    private func processTcpBuffer() {
        while tcpBuffer.count >= 4 {
            let lengthPrefix = tcpBuffer.prefix(4).withUnsafeBytes { ptr -> UInt32 in
                ptr.load(as: UInt32.self).bigEndian
            }
            let frameLength = Int(lengthPrefix)
            let totalPacketSize = 4 + frameLength
            
            guard tcpBuffer.count >= totalPacketSize else {
                // Incomplete frame; wait for next TCP chunk
                break
            }
            
            let packetData = tcpBuffer.subdata(in: 4..<totalPacketSize)
            tcpBuffer.removeSubrange(0..<totalPacketSize)
            parsePacketData(packetData)
        }
    }
    
    private func parsePacketData(_ payload: Data) {
        guard let text = String(data: payload, encoding: .utf8) ?? String(data: payload, encoding: .isoLatin1) else { return }
        
        var searchStart = text.startIndex
        while let startIdx = text[searchStart...].range(of: "{\"")?.lowerBound {
            var braceCount = 0
            var foundEnd: String.Index? = nil
            var curr = startIdx
            while curr < text.endIndex {
                let char = text[curr]
                if char == "{" {
                    braceCount += 1
                } else if char == "}" {
                    braceCount -= 1
                    if braceCount == 0 {
                        foundEnd = text.index(after: curr)
                        break
                    }
                }
                curr = text.index(after: curr)
            }
            
            if let endIdx = foundEnd {
                let candidate = String(text[startIdx..<endIdx])
                if let jsonData = candidate.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    handleJsonMessage(dict)
                }
                searchStart = endIdx
            } else {
                break
            }
        }
    }
    
    public func handleJsonMessage(_ dict: [String: Any]) {
        let type = dict["type"] as? String ?? ""
        if type == "MEDIA_STATUS" {
            LogManager.shared.cast("Packet [MEDIA_STATUS]: \(dict)")
        } else {
            LogManager.shared.cast("Packet: [\(type)]")
        }
        
        if type == "LOAD_FAILED" {
            LogManager.shared.error("CastProtocol", "LOAD_FAILED: \(dict)")
            self.state = .error("Speaker rejected media load")
            return
        }
        
        if let status = dict["status"] as? [String: Any] {
            if !isAdjustingVolume,
               let volDict = status["volume"] as? [String: Any],
               let lvl = volDict["level"] as? Double {
                let floatLvl = Float(lvl)
                self.currentVolume = floatLvl
                if var dev = self.activeDevice {
                    dev.volume = floatLvl
                    self.activeDevice = dev
                }
            }
            
            if let apps = status["applications"] as? [[String: Any]],
               let firstApp = apps.first {
                if let transportId = firstApp["transportId"] as? String {
                    self.currentTransportId = transportId
                    if let callback = self.onReceiverReady {
                        self.onReceiverReady = nil
                        callback(transportId)
                    }
                }
                if let sessionId = firstApp["sessionId"] as? String {
                    self.currentSessionId = sessionId
                }
            }
        } else if !isAdjustingVolume,
                  let devDict = dict["device"] as? [String: Any],
                  let volDict = devDict["volume"] as? [String: Any],
                  let lvl = volDict["level"] as? Double {
            let floatLvl = Float(lvl)
            self.currentVolume = floatLvl
            if var dev = self.activeDevice {
                dev.volume = floatLvl
                self.activeDevice = dev
            }
        }
    }
    
    private func nextRequestId() -> Int {
        reqLock.lock()
        defer { reqLock.unlock() }
        requestId += 1
        return requestId
    }
    
    private func sendJson(source: String = "sender-0", destination: String, ns: String, dict: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
        
        let packet = encodeCastMessage(source: source, dest: destination, ns: ns, json: jsonStr)
        connection?.send(content: packet, completion: .contentProcessed({ _ in }))
    }
    
    public func encodeCastMessage(source: String, dest: String, ns: String, json: String) -> Data {
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
