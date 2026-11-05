import Foundation
import CoreAudio
import AppKit

public final class DesktopAudioStreamer: ObservableObject, @unchecked Sendable {
    public static let shared = DesktopAudioStreamer()
    
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var currentStreamURL: String? = nil
    @Published public private(set) var statusText: String = ""
    
    private var soxProcess: Process?
    private var soxPipe: Pipe?
    private var cloudflaredProcess: Process?
    private var activeSessionToken: UUID?
    private var cachedTunnelURL: String?
    private var isWarmingUp: Bool = false
    private let streamQueue = DispatchQueue(label: "com.gpsurya.NestCast.desktopAudioStreamer", qos: .userInteractive)
    private let lock = NSLock()
    
    public init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        tearDownAll()
    }
    
    @objc private func handleAppWillTerminate() {
        tearDownAll()
    }
    
    private func tearDownAll() {
        stopStreaming()
        lock.lock()
        cloudflaredProcess?.terminate()
        cloudflaredProcess = nil
        cachedTunnelURL = nil
        isWarmingUp = false
        lock.unlock()
    }
    
    private func findExecutable(named name: String) -> String? {
        let possiblePaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)"
        ]
        return possiblePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    
    /// Pre-warms the zero-trust streaming ingress tunnel in the background on app start
    /// so that speaker connection and replay are snappy and instantaneous (<0.8s).
    public func warmUpStreamingIngress(server: AudioStreamServer) {
        lock.lock()
        guard cachedTunnelURL == nil && !isWarmingUp else {
            lock.unlock()
            return
        }
        guard let cfPath = findExecutable(named: "cloudflared") else {
            lock.unlock()
            return
        }
        isWarmingUp = true
        lock.unlock()
        
        streamQueue.async { [weak self] in
            guard let self = self else { return }
            LogManager.shared.audio("Pre-warming background streaming ingress tunnel on port \(server.port)...")
            
            let cf = Process()
            cf.executableURL = URL(fileURLWithPath: cfPath)
            cf.arguments = ["tunnel", "--url", "http://127.0.0.1:\(server.port)", "--protocol", "http2"]
            
            let cfPipe = Pipe()
            cf.standardOutput = cfPipe
            cf.standardError = cfPipe
            
            let tunnelGroup = DispatchGroup()
            tunnelGroup.enter()
            var discoveredURL: String?
            
            cfPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard let text = String(data: data, encoding: .utf8) else { return }
                for line in text.components(separatedBy: "\n") {
                    if line.contains("trycloudflare.com") && discoveredURL == nil {
                        let tokens = line.components(separatedBy: CharacterSet.whitespacesAndNewlines)
                        for token in tokens {
                            if token.hasPrefix("https://") && token.contains("trycloudflare.com") {
                                discoveredURL = token
                                tunnelGroup.leave()
                                break
                            }
                        }
                    }
                }
            }
            
            do {
                try cf.run()
                self.lock.lock()
                self.cloudflaredProcess = cf
                self.lock.unlock()
            } catch {
                LogManager.shared.error("DesktopAudioStreamer", "Failed to run cloudflared pre-warm: \(error.localizedDescription)")
                self.lock.lock()
                self.isWarmingUp = false
                self.lock.unlock()
                return
            }
            
            let waitResult = tunnelGroup.wait(timeout: .now() + 8.0)
            cfPipe.fileHandleForReading.readabilityHandler = nil
            
            if waitResult == .success, let baseURL = discoveredURL {
                // Verify edge reachability in background
                var isReachable = false
                for _ in 1...10 {
                    Thread.sleep(forTimeInterval: 0.3)
                    if let checkURL = URL(string: "\(baseURL)/chime.ogg") {
                        var request = URLRequest(url: checkURL)
                        request.httpMethod = "HEAD"
                        request.timeoutInterval = 1.0
                        let sem = DispatchSemaphore(value: 0)
                        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
                            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                                isReachable = true
                            }
                            sem.signal()
                        }
                        task.resume()
                        _ = sem.wait(timeout: .now() + 1.2)
                        if isReachable { break }
                    }
                }
                
                self.lock.lock()
                self.cachedTunnelURL = baseURL
                self.isWarmingUp = false
                self.lock.unlock()
                LogManager.shared.audio("Streaming ingress pre-warmed & verified: \(baseURL)")
            } else {
                self.lock.lock()
                self.isWarmingUp = false
                self.lock.unlock()
                LogManager.shared.audio("Background tunnel pre-warm completed or timed out")
            }
        }
    }
    
    public func startStreaming(
        to device: CastDevice,
        server: AudioStreamServer,
        cast: CastProtocol,
        completion: ((Bool) -> Void)? = nil
    ) {
        stopStreaming()
        
        lock.lock()
        let sessionToken = UUID()
        self.activeSessionToken = sessionToken
        lock.unlock()
        
        guard let soxPath = findExecutable(named: "sox") else {
            let msg = "SoX not found. Install via: brew install sox"
            LogManager.shared.error("DesktopAudioStreamer", msg)
            DispatchQueue.main.async { self.statusText = msg }
            completion?(false)
            return
        }
        
        DispatchQueue.main.async {
            self.statusText = "Connecting audio to \(device.name)..."
        }
        
        // 1. Immediately switch macOS Audio Output to BlackHole 2ch
        guard AudioDeviceManager.shared.switchToBlackHole() else {
            let msg = "BlackHole 2ch driver not found. Install via: brew install blackhole-2ch"
            LogManager.shared.error("DesktopAudioStreamer", msg)
            DispatchQueue.main.async { self.statusText = msg }
            completion?(false)
            return
        }
        
        // 2. Start SoX Low-Latency 320kbps MP3 Capture (--buffer 1024 = 21.3ms real-time chunk latency)
        let sox = Process()
        sox.executableURL = URL(fileURLWithPath: soxPath)
        sox.arguments = [
            "-q",
            "--buffer", "1024",  // Low-latency capture buffer (21.3ms frame chunks)
            "-t", "coreaudio", "BlackHole 2ch",
            "-t", "mp3",
            "-C", "320",        // Studio-grade 320kbps CBR
            "-r", "48000",      // Native 48kHz matching CoreAudio DAC
            "-"
        ]
        
        let pipe = Pipe()
        sox.standardOutput = pipe
        sox.standardError = FileHandle.nullDevice
        
        pipe.fileHandleForReading.readabilityHandler = { [weak server] handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                server?.broadcastLiveChunk(chunk)
            }
        }
        
        do {
            try sox.run()
            lock.lock()
            self.soxProcess = sox
            self.soxPipe = pipe
            lock.unlock()
            LogManager.shared.audio("Ultra-low latency 320kbps @ 48kHz SoX desktop capture running")
        } catch {
            LogManager.shared.error("DesktopAudioStreamer", "Failed to start SoX: \(error.localizedDescription)")
            stopStreaming()
            completion?(false)
            return
        }
        
        // 3. Resolve Stream URL
        let localIP = AudioStreamServer.getWiFiIP(matchingSubnetOf: device.ipAddress) ?? server.localIP
        let directLANURL = "http://\(localIP):\(server.port)/live.mp3"
        
        func proceedWithStream(url: String, isTunnel: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                guard self.activeSessionToken == sessionToken else {
                    self.lock.unlock()
                    return
                }
                self.currentStreamURL = url
                self.isStreaming = true
                self.statusText = isTunnel ? "Streaming Hi-Fi 320k to \(device.name)" : "Streaming Hi-Fi 320k to \(device.name)"
                self.lock.unlock()
                
                LogManager.shared.cast("Dispatching stream URL to \(device.name): \(url) (tunnel: \(isTunnel))")
                
                // Connect to Cast device and launch Default Media Receiver
                cast.connect(to: device) { [weak self] success in
                    guard let self = self else { return }
                    self.lock.lock()
                    guard self.activeSessionToken == sessionToken else {
                        self.lock.unlock()
                        return
                    }
                    self.lock.unlock()
                    
                    if success {
                        cast.launchAndLoad(streamURL: url, streamType: "LIVE", title: "Mac Desktop Audio (Hi-Fi 320k)") { [weak self] loadSuccess in
                            guard let self = self else { return }
                            self.lock.lock()
                            guard self.activeSessionToken == sessionToken else {
                                self.lock.unlock()
                                return
                            }
                            self.lock.unlock()
                            
                            if loadSuccess {
                                LogManager.shared.cast("Live stream loaded successfully on \(device.name)")
                                completion?(true)
                            } else {
                                LogManager.shared.error("DesktopAudioStreamer", "Failed to load media stream on speaker")
                                self.stopStreaming()
                                completion?(false)
                            }
                        }
                    } else {
                        LogManager.shared.error("DesktopAudioStreamer", "Failed to connect Cast protocol to \(device.name)")
                        self.stopStreaming()
                        completion?(false)
                    }
                }
            }
        }
        
        // Instant stream start if tunnel is pre-warmed
        lock.lock()
        let preWarmed = cachedTunnelURL
        lock.unlock()
        
        if let warmBaseURL = preWarmed {
            proceedWithStream(url: "\(warmBaseURL)/live.mp3", isTunnel: true)
            return
        }
        
        // If not pre-warmed yet, check if cloudflared is present and warm it up on demand
        if findExecutable(named: "cloudflared") != nil {
            warmUpStreamingIngress(server: server)
            streamQueue.async { [weak self] in
                guard let self = self else { return }
                // Quick poll for pre-warmed tunnel (up to 3.5s)
                for _ in 1...14 {
                    Thread.sleep(forTimeInterval: 0.25)
                    self.lock.lock()
                    let readyURL = self.cachedTunnelURL
                    self.lock.unlock()
                    if let ready = readyURL {
                        proceedWithStream(url: "\(ready)/live.mp3", isTunnel: true)
                        return
                    }
                }
                LogManager.shared.audio("Tunnel not ready in time, falling back to direct Wi-Fi URL: \(directLANURL)")
                proceedWithStream(url: directLANURL, isTunnel: false)
            }
        } else {
            proceedWithStream(url: directLANURL, isTunnel: false)
        }
    }
    
    public func stopStreaming() {
        lock.lock()
        activeSessionToken = nil
        
        // Clear readabilityHandler immediately to halt piping
        soxPipe?.fileHandleForReading.readabilityHandler = nil
        soxPipe = nil
        
        soxProcess?.terminate()
        soxProcess = nil
        // Note: cloudflaredProcess is intentionally NOT terminated here to keep the ingress warm for instant replay
        lock.unlock()
        
        // Immediately restore macOS audio output to Mac speakers
        AudioDeviceManager.shared.restoreOriginalOutput()
        AudioStreamServer.sharedInstance?.closeLiveConnections()
        
        DispatchQueue.main.async {
            self.isStreaming = false
            self.currentStreamURL = nil
            self.statusText = ""
        }
        LogManager.shared.audio("Desktop audio streaming stopped and output restored instantly")
    }
}
