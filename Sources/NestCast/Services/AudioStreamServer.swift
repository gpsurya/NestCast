import Foundation
import Network

public final class AudioStreamServer: ObservableObject, @unchecked Sendable {
    public static var sharedInstance: AudioStreamServer?
    
    @Published public var isRunning: Bool = false
    @Published public var localIP: String = "127.0.0.1"
    @Published public var port: UInt16 = 8088
    
    private var listener: NWListener?
    private let audioQueue = DispatchQueue(label: "com.gpsurya.NestCast.audioServer", qos: .userInitiated)
    private var chimeWavData: Data
    private var chimeOggData: Data
    
    // Unified thread-safe socket tracking
    private var connections: [NWConnection] = []
    private var liveConnections: [NWConnection] = []
    private let stateLock = NSLock()
    
    public func broadcastLiveChunk(_ chunk: Data) {
        stateLock.lock()
        defer { stateLock.unlock() }
        var active: [NWConnection] = []
        for conn in liveConnections {
            if conn.state == .ready {
                conn.send(content: chunk, isComplete: false, completion: .contentProcessed({ [weak self, weak conn] err in
                    if err != nil, let c = conn {
                        self?.removeConnection(c)
                    }
                }))
                active.append(conn)
            }
        }
        liveConnections = active
    }
    
    public func closeLiveConnections() {
        stateLock.lock()
        defer { stateLock.unlock() }
        for conn in liveConnections {
            conn.cancel()
        }
        liveConnections.removeAll()
    }
    
    private func removeConnection(_ conn: NWConnection) {
        stateLock.lock()
        defer { stateLock.unlock() }
        conn.cancel()
        connections.removeAll { $0 === conn }
        liveConnections.removeAll { $0 === conn }
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
            let params = NWParameters.tcp
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
        stateLock.unlock()
        
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
        }
        LogManager.shared.audio("HTTP server stopped")
    }
    
    public func streamURL(endpoint: String = "live.mp3") -> String {
        let ip = Self.getWiFiIP() ?? localIP
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
                // Strictly schedule receive ONLY when socket enters .ready state to avoid error 57
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
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4096) { [weak self, weak conn] data, _, _, err in
            guard let self = self, let activeConn = conn else { return }
            
            if let err = err {
                LogManager.shared.error("AudioServer", "Receive error: \(err.localizedDescription)")
                self.removeConnection(activeConn)
                return
            }
            
            guard let reqData = data, let reqStr = String(data: reqData, encoding: .utf8) else {
                self.removeConnection(activeConn)
                return
            }
            
            let lines = reqStr.components(separatedBy: "\r\n")
            let firstLine = lines.first ?? ""
            let method = firstLine.components(separatedBy: " ").first?.uppercased() ?? "GET"
            let path = firstLine.components(separatedBy: " ").count > 1 ? firstLine.components(separatedBy: " ")[1] : "/"
            
            LogManager.shared.audio("Incoming HTTP [\(method)] \(path) from \(activeConn.endpoint)")
            
            // Route: Live Audio Stream (High-Definition 320kbps MP3)
            if path.contains("live.mp3") {
                let headers = [
                    "HTTP/1.1 200 OK",
                    "Content-Type: audio/mpeg",
                    "Access-Control-Allow-Origin: *",
                    "Cache-Control: no-cache, no-store",
                    "Pragma: no-cache",
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
                    self.liveConnections.append(liveConn)
                    self.stateLock.unlock()
                    LogManager.shared.audio("Client actively subscribed to /live.mp3 broadcast")
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
                let parts = rangeSpec.components(separatedBy: "-")
                if let startVal = Int(parts[0]), startVal < audioData.count {
                    let endVal = (parts.count > 1 && !parts[1].isEmpty) ? (Int(parts[1]) ?? (audioData.count - 1)) : (audioData.count - 1)
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
            headerStr += "Cache-Control: no-cache\r\n\r\n"
            
            var response = Data(headerStr.utf8)
            if !isHead {
                response.append(slice)
            }
            
            activeConn.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed({ [weak self, weak activeConn] sendErr in
                if let e = sendErr {
                    LogManager.shared.error("AudioServer", "Send error: \(e.localizedDescription)")
                } else {
                    LogManager.shared.audio("Successfully dispatched \(response.count) bytes")
                }
                if let c = activeConn {
                    self?.removeConnection(c)
                }
            }))
        }
    }
    
    public static func loadChimeOgg() -> Data {
        if let bundlePath = Bundle.main.path(forResource: "chime", ofType: "ogg"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: bundlePath)), !data.isEmpty {
            return data
        }
        // Fallback relative resource search for dev/CLI
        let possibleLocal = ["Resources/chime.ogg", "Resources/ping.wav"]
        for p in possibleLocal {
            if FileManager.default.fileExists(atPath: p), let d = try? Data(contentsOf: URL(fileURLWithPath: p)) {
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
                        if !ip.starts(with: "169.254.") && !ip.starts(with: "127.") {
                            if let target = targetIP {
                                // Match /24 prefix (e.g. 192.168.1.x)
                                let targetPrefix = target.components(separatedBy: ".").prefix(3).joined(separator: ".")
                                if ip.starts(with: targetPrefix) {
                                    bestAddress = ip
                                    break
                                }
                            }
                            if ifName == "en0" || ifName.starts(with: "en") {
                                if fallbackAddress == nil {
                                    fallbackAddress = ip
                                }
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
        let sampleRate: Double = 48000.0
        let duration: Double = 1.0
        let numSamples = Int(sampleRate * duration)
        var samples = [Int16]()
        
        for i in 0..<numSamples {
            let t = Double(i) / sampleRate
            let env = exp(-3.0 * t)
            let tone = 0.5 * sin(2.0 * .pi * 523.25 * t) + 0.5 * sin(2.0 * .pi * 659.25 * t)
            let val = Int16(tone * env * 28000.0)
            samples.append(val)
        }
        
        let subchunk2Size = UInt32(numSamples * 2)
        let chunkSize = 36 + subchunk2Size
        
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(Data(bytes: [UInt32(chunkSize).littleEndian], count: 4))
        header.append(contentsOf: "WAVEfmt ".utf8)
        header.append(Data(bytes: [UInt32(16).littleEndian], count: 4))
        header.append(Data(bytes: [UInt16(1).littleEndian], count: 2))
        header.append(Data(bytes: [UInt16(1).littleEndian], count: 2))
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
