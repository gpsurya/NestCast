import Foundation
import Network

private final class LiveClient: @unchecked Sendable {
    let connection: NWConnection
    var pendingChunks: Int = 0
    init(connection: NWConnection) {
        self.connection = connection
    }
}

public final class AudioStreamServer: ObservableObject, @unchecked Sendable {
    public static var sharedInstance: AudioStreamServer?
    
    @Published public var isRunning: Bool = false
    @Published public var localIP: String = "127.0.0.1"
    @Published public var port: UInt16 = 8088
    
    /// Random, expiring session token required for accessing `/live.mp3`
    public var activeSessionToken: String?
    
    private var listener: NWListener?
    private let audioQueue = DispatchQueue(label: "com.gpsurya.NestCast.audioServer", qos: .userInteractive)
    private var chimeWavData: Data
    private var chimeOggData: Data
    
    // Unified thread-safe socket tracking
    private var connections: [NWConnection] = []
    private var liveClients: [LiveClient] = []
    private var connectionBuffers: [ObjectIdentifier: Data] = [:]
    private let stateLock = NSLock()
    
    public func broadcastLiveChunk(_ chunk: Data) {
        stateLock.lock()
        defer { stateLock.unlock() }
        var active: [LiveClient] = []
        for client in liveClients {
            guard client.connection.state == .ready else { continue }
            
            // Bounded queue protection: if client is lagging by >15 chunks (~300ms backlog), drop it to prevent delay drift
            if client.pendingChunks > 15 {
                LogManager.shared.audio("Dropping stalled live client exceeding 15 unacknowledged chunks (~300ms buffer drift)")
                client.connection.cancel()
                continue
            }
            
            client.pendingChunks += 1
            client.connection.send(content: chunk, isComplete: false, completion: .contentProcessed({ [weak self, weak client] err in
                guard let self = self, let cl = client else { return }
                self.stateLock.lock()
                cl.pendingChunks = max(0, cl.pendingChunks - 1)
                if err != nil {
                    self.removeConnection(cl.connection)
                }
                self.stateLock.unlock()
            }))
            active.append(client)
        }
        liveClients = active
    }
    
    public func closeLiveConnections() {
        stateLock.lock()
        defer { stateLock.unlock() }
        for client in liveClients {
            client.connection.cancel()
        }
        liveClients.removeAll()
    }
    
    private func removeConnection(_ conn: NWConnection) {
        stateLock.lock()
        defer { stateLock.unlock() }
        conn.cancel()
        connections.removeAll { $0 === conn }
        liveClients.removeAll { $0.connection === conn }
        connectionBuffers.removeValue(forKey: ObjectIdentifier(conn))
    }
    
    public init(port: UInt16 = 8088) {
        self.port = port
        self.localIP = Self.getWiFiIP() ?? "127.0.0.1"
        self.chimeWavData = Self.generateChimeWAV()
        self.chimeOggData = Self.loadChimeOgg()
        Self.sharedInstance = self
    }
    
    public func start() {
        guard !isRunning else { return }
        let currentIP = Self.getWiFiIP() ?? "127.0.0.1"
        
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true // Disable Nagle's algorithm for near-zero network latency
            tcpOptions.enableKeepalive = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            let newListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            
            newListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.localIP = currentIP
                        LogManager.shared.audio("HTTP server listening on http://\(self.localIP):\(self.port)")
                    case .failed(let err):
                        self.isRunning = false
                        LogManager.shared.error("AudioServer", "Server failed: \(err.localizedDescription)")
                    default:
                        break
                    }
                }
            }
            
            newListener.newConnectionHandler = { [weak self] newConnection in
                self?.handleConnection(newConnection)
            }
            
            self.listener = newListener
            newListener.start(queue: audioQueue)
        } catch {
            LogManager.shared.error("AudioServer", "Failed to start listener: \(error.localizedDescription)")
        }
    }
    
    public func stop() {
        closeLiveConnections()
        stateLock.lock()
        for conn in connections {
            conn.cancel()
        }
        connections.removeAll()
        connectionBuffers.removeAll()
        activeSessionToken = nil
        stateLock.unlock()
        
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
        }
        LogManager.shared.audio("HTTP server stopped")
    }
    
    public func streamURL(endpoint: String = "live.mp3", token: String? = nil) -> String {
        let ip = Self.getWiFiIP() ?? localIP
        if let tok = token ?? activeSessionToken {
            return "http://\(ip):\(port)/\(endpoint)?token=\(tok)"
        }
        return "http://\(ip):\(port)/\(endpoint)"
    }
    
    private func handleConnection(_ connection: NWConnection) {
        stateLock.lock()
        connections.append(connection)
        stateLock.unlock()
        
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            switch state {
            case .ready:
                self.receiveHttpRequest(from: conn)
            case .failed(let err):
                LogManager.shared.error("AudioServer", "Connection failed for \(conn.endpoint): \(err.localizedDescription)")
                self.removeConnection(conn)
            case .cancelled:
                self.removeConnection(conn)
            default:
                break
            }
        }
        
        connection.start(queue: audioQueue)
    }
    
    private func receiveHttpRequest(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak conn] data, _, isComplete, err in
            guard let self = self, let activeConn = conn else { return }
            
            if let err = err {
                LogManager.shared.error("AudioServer", "Receive error: \(err.localizedDescription)")
                self.removeConnection(activeConn)
                return
            }
            
            guard let incomingData = data, !incomingData.isEmpty else {
                if isComplete {
                    self.removeConnection(activeConn)
                }
                return
            }
            
            let connKey = ObjectIdentifier(activeConn)
            self.stateLock.lock()
            var currentBuf = self.connectionBuffers[connKey] ?? Data()
            currentBuf.append(incomingData)
            
            // Check for complete HTTP headers delimiter \r\n\r\n
            guard let delimiterRange = currentBuf.range(of: Data("\r\n\r\n".utf8)) else {
                if currentBuf.count > 8192 {
                    // Header too large; reject to prevent unbounded memory growth
                    self.stateLock.unlock()
                    LogManager.shared.error("AudioServer", "HTTP header exceeded 8KB limit")
                    self.removeConnection(activeConn)
                    return
                }
                self.connectionBuffers[connKey] = currentBuf
                self.stateLock.unlock()
                // Continue receiving rest of fragmented request
                self.receiveHttpRequest(from: activeConn)
                return
            }
            
            let headerData = currentBuf.subdata(in: 0..<delimiterRange.lowerBound)
            self.connectionBuffers.removeValue(forKey: connKey)
            self.stateLock.unlock()
            
            guard let reqStr = String(data: headerData, encoding: .utf8) else {
                self.removeConnection(activeConn)
                return
            }
            
            self.dispatchHttpRequest(reqStr: reqStr, activeConn: activeConn)
        }
    }
    
    private func dispatchHttpRequest(reqStr: String, activeConn: NWConnection) {
        let lines = reqStr.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            removeConnection(activeConn)
            return
        }
        
        let method = parts[0].uppercased()
        let rawURI = parts[1]
        
        let urlComponents = URLComponents(string: rawURI)
        let path = urlComponents?.path ?? rawURI
        let queryItems = urlComponents?.queryItems ?? []
        
        LogManager.shared.audio("Incoming HTTP [\(method)] \(path) from \(activeConn.endpoint)")
        
        // Route: CORS / Private Network Access Preflight (OPTIONS)
        if method == "OPTIONS" {
            let optionsHeaders = [
                "HTTP/1.1 204 No Content",
                "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Methods: GET, HEAD, OPTIONS",
                "Access-Control-Allow-Headers: *",
                "Access-Control-Allow-Private-Network: true",
                "Access-Control-Max-Age: 86400",
                "Content-Length: 0",
                "",
                ""
            ].joined(separator: "\r\n")
            activeConn.send(content: Data(optionsHeaders.utf8), isComplete: true, completion: .contentProcessed({ [weak self, weak activeConn] _ in
                if let c = activeConn { self?.removeConnection(c) }
            }))
            return
        }
        
        // Route: Live Audio Stream (High-Definition 320kbps MP3)
        if path == "/live.mp3" || path.hasSuffix("/live.mp3") {
            // Validate session token if authentication is enabled
            if let expectedToken = self.activeSessionToken {
                let providedToken = queryItems.first(where: { $0.name == "token" })?.value
                guard providedToken == expectedToken else {
                    LogManager.shared.error("AudioServer", "Unauthorized stream access: invalid or missing session token")
                    let unauthorizedResp = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    activeConn.send(content: Data(unauthorizedResp.utf8), isComplete: true, completion: .contentProcessed({ [weak self, weak activeConn] _ in
                        if let c = activeConn { self?.removeConnection(c) }
                    }))
                    return
                }
            }
            
            // Method HEAD: respond with headers only; DO NOT subscribe to live connections
            if method == "HEAD" {
                let headHeaders = [
                    "HTTP/1.1 200 OK",
                    "Content-Type: audio/mpeg",
                    "Access-Control-Allow-Origin: *",
                    "Access-Control-Allow-Private-Network: true",
                    "Accept-Ranges: none",
                    "Content-Length: 0",
                    "Connection: close",
                    "",
                    ""
                ].joined(separator: "\r\n")
                activeConn.send(content: Data(headHeaders.utf8), isComplete: true, completion: .contentProcessed({ [weak self, weak activeConn] _ in
                    if let c = activeConn { self?.removeConnection(c) }
                }))
                return
            }
            
            // Method GET: subscribe to live chunk broadcast
            guard method == "GET" else {
                let notAllowed = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                activeConn.send(content: Data(notAllowed.utf8), isComplete: true, completion: .contentProcessed({ [weak self, weak activeConn] _ in
                    if let c = activeConn { self?.removeConnection(c) }
                }))
                return
            }
            
            let headers = [
                "HTTP/1.1 200 OK",
                "Content-Type: audio/mpeg",
                "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Private-Network: true",
                "Accept-Ranges: none",
                "Cache-Control: no-cache, no-store, must-revalidate",
                "Pragma: no-cache",
                "Expires: 0",
                "Connection: keep-alive",
                "",
                ""
            ].joined(separator: "\r\n")
            
            activeConn.send(content: Data(headers.utf8), isComplete: false, completion: .contentProcessed({ [weak self, weak activeConn] sendErr in
                guard let self = self, let liveConn = activeConn, sendErr == nil else {
                    if let c = activeConn { self?.removeConnection(c) }
                    return
                }
                self.stateLock.lock()
                self.liveClients.append(LiveClient(connection: liveConn))
                self.stateLock.unlock()
                LogManager.shared.audio("Client actively subscribed to /live.mp3 broadcast (token verified)")
            }))
            return
        }
        
        // Route: Chime audio
        let isOgg = path.hasSuffix(".ogg")
        let audioData = isOgg ? self.chimeOggData : self.chimeWavData
        let contentType = isOgg ? "audio/ogg" : "audio/wav"
        let isHead = method == "HEAD"
        
        var statusLine = "HTTP/1.1 200 OK"
        var slice = audioData
        var contentRangeHeader = ""
        
        if let rangeLine = lines.first(where: { $0.lowercased().starts(with: "range: bytes=") }) {
            let rangeSpec = rangeLine.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""
            let rangeParts = rangeSpec.components(separatedBy: "-")
            if let startVal = Int(rangeParts[0]), startVal < audioData.count {
                let endVal = (rangeParts.count > 1 && !rangeParts[1].isEmpty) ? (Int(rangeParts[1]) ?? (audioData.count - 1)) : (audioData.count - 1)
                let boundedEnd = min(endVal, audioData.count - 1)
                if startVal <= boundedEnd {
                    statusLine = "HTTP/1.1 206 Partial Content"
                    slice = audioData.subdata(in: startVal..<(boundedEnd + 1))
                    contentRangeHeader = "Content-Range: bytes \(startVal)-\(boundedEnd)/\(audioData.count)\r\n"
                }
            }
        }
        
        var headerStr = "\(statusLine)\r\n"
        headerStr += "Content-Type: \(contentType)\r\n"
        headerStr += "Content-Length: \(slice.count)\r\n"
        if !contentRangeHeader.isEmpty {
            headerStr += contentRangeHeader
        }
        headerStr += "Accept-Ranges: bytes\r\n"
        headerStr += "Connection: close\r\n"
        headerStr += "Access-Control-Allow-Origin: *\r\n"
        headerStr += "Access-Control-Allow-Private-Network: true\r\n"
        headerStr += "Cache-Control: no-cache\r\n\r\n"
        
        var response = Data(headerStr.utf8)
        if !isHead {
            response.append(slice)
        }
        
        activeConn.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed({ [weak self, weak activeConn] sendErr in
            if let e = sendErr {
                LogManager.shared.error("AudioServer", "Send error: \(e.localizedDescription)")
            } else {
                LogManager.shared.audio("Successfully dispatched \(response.count) bytes for \(path)")
            }
            if let c = activeConn {
                self?.removeConnection(c)
            }
        }))
    }
    
    public static func loadChimeOgg() -> Data {
        if let bundlePath = Bundle.main.path(forResource: "chime", ofType: "ogg"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: bundlePath)), !data.isEmpty {
            return data
        }
        let possibleLocal = [
            "Resources/chime.ogg",
            "Resources/ping.wav"
        ]
        for p in possibleLocal {
            if FileManager.default.fileExists(atPath: p), let d = try? Data(contentsOf: URL(fileURLWithPath: p)), !d.isEmpty {
                return d
            }
        }
        return generateChimeWAV()
    }
    
    public static func getWiFiIP(matchingSubnetOf targetIP: String? = nil) -> String? {
        var bestAddress: String?
        var fallbackAddress: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        let ifName = String(cString: ptr.pointee.ifa_name)
                        
                        // Avoid internal/link-local 169.254.x.x
                        if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") {
                            // Check target subnet match (e.g. 192.168.1.x)
                            if let target = targetIP, !target.isEmpty {
                                let targetComponents = target.components(separatedBy: ".")
                                let ipComponents = ip.components(separatedBy: ".")
                                if targetComponents.count >= 3 && ipComponents.count >= 3 &&
                                    targetComponents[0...2] == ipComponents[0...2] {
                                    bestAddress = ip
                                    break
                                }
                            }
                            
                            // Prefer en0 (standard Wi-Fi on Mac)
                            if ifName == "en0" {
                                bestAddress = ip
                            } else if fallbackAddress == nil {
                                fallbackAddress = ip
                            }
                        }
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return bestAddress ?? fallbackAddress
    }
    
    public static func generateChimeWAV() -> Data {
        let sampleRate: Double = 48000.0 // Native 48kHz matching CoreAudio DAC
        let duration: Double = 1.0
        let numSamples = Int(sampleRate * duration)
        var samples = [Int16]()
        
        for i in 0..<numSamples {
            let t = Double(i) / sampleRate
            let env = exp(-3.0 * t)
            let tone = 0.5 * sin(2.0 * .pi * 523.25 * t) + 0.5 * sin(2.0 * .pi * 659.25 * t)
            samples.append(Int16(tone * env * 28000.0))
        }
        
        let subchunk2Size = UInt32(numSamples * 2)
        let chunkSize = 36 + subchunk2Size
        
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(Data(bytes: [UInt32(chunkSize).littleEndian], count: 4))
        header.append(contentsOf: "WAVEfmt ".utf8)
        header.append(Data(bytes: [UInt32(16).littleEndian], count: 4))
        header.append(Data(bytes: [UInt16(1).littleEndian], count: 2)) // PCM
        header.append(Data(bytes: [UInt16(1).littleEndian], count: 2)) // Mono
        header.append(Data(bytes: [UInt32(48000).littleEndian], count: 4))
        header.append(Data(bytes: [UInt32(96000).littleEndian], count: 4))
        header.append(Data(bytes: [UInt16(2).littleEndian], count: 2))
        header.append(Data(bytes: [UInt16(16).littleEndian], count: 2))
        header.append(contentsOf: "data".utf8)
        header.append(Data(bytes: [UInt32(subchunk2Size).littleEndian], count: 4))
        
        var wav = header
        samples.withUnsafeBufferPointer { ptr in
            wav.append(Data(buffer: ptr))
        }
        return wav
    }
}
