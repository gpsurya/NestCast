import Foundation
import Network

public final class AudioStreamServer: ObservableObject, @unchecked Sendable {
    @Published public var isRunning: Bool = false
    @Published public var localIP: String = "127.0.0.1"
    @Published public var port: UInt16 = 8088
    
    private var listener: NWListener?
    private let audioQueue = DispatchQueue(label: "com.gpsurya.NestCast.audioServer", qos: .userInitiated)
    private var chimeWavData: Data
    
    public init(port: UInt16 = 8088) {
        self.port = port
        self.localIP = Self.getWiFiIP() ?? "127.0.0.1"
        self.chimeWavData = Self.generateChimeWAV()
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
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
        }
        LogManager.shared.audio("HTTP server stopped")
    }
    
    public func streamURL(endpoint: String = "ping.wav") -> String {
        let ip = Self.getWiFiIP() ?? localIP
        return "http://\(ip):\(port)/\(endpoint)"
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: audioQueue)
        
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4096) { [weak self] data, _, _, err in
            guard let self = self else {
                connection.cancel()
                return
            }
            guard let reqData = data, let reqStr = String(data: reqData, encoding: .utf8) else {
                connection.cancel()
                return
            }
            
            let lines = reqStr.components(separatedBy: "\r\n")
            let firstLine = lines.first ?? ""
            let method = firstLine.components(separatedBy: " ").first?.uppercased() ?? "GET"
            let path = firstLine.components(separatedBy: " ").count > 1 ? firstLine.components(separatedBy: " ")[1] : "/"
            
            LogManager.shared.audio("Incoming HTTP [\(method)] \(path)")
            
            let audioData = self.chimeWavData
            let isHead = method == "HEAD"
            
            let headers = [
                "HTTP/1.1 200 OK",
                "Content-Type: audio/wav",
                "Content-Length: \(audioData.count)",
                "Accept-Ranges: bytes",
                "Connection: close",
                "Access-Control-Allow-Origin: *",
                "Cache-Control: no-cache",
                "",
                ""
            ].joined(separator: "\r\n")
            
            var response = Data(headers.utf8)
            if !isHead {
                response.append(audioData)
            }
            
            connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed({ sendErr in
                if let e = sendErr {
                    LogManager.shared.error("AudioServer", "Send error: \(e.localizedDescription)")
                } else {
                    LogManager.shared.audio("Successfully dispatched \(response.count) bytes (clean close)")
                }
                self.audioQueue.asyncAfter(deadline: .now() + 0.5) {
                    connection.cancel()
                }
            }))
        }
    }
    
    public static func getWiFiIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) {
                    let name = String(cString: ptr.pointee.ifa_name)
                    if name == "en0" || name.starts(with: "en") {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                            address = String(cString: hostname)
                            break
                        }
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
    
    public static func generateChimeWAV() -> Data {
        let sampleRate: Double = 44100.0
        let duration: Double = 1.2
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
        header.append(Data(bytes: [UInt32(44100).littleEndian], count: 4))
        header.append(Data(bytes: [UInt32(88200).littleEndian], count: 4))
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
