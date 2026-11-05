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
    private var soxErrPipe: Pipe?
    private var cloudflaredProcess: Process?
    private var activeSessionToken: String?
    private var cachedTunnelURL: String?
    private var isWarmingUp: Bool = false
    private var hasReceivedFirstAudioChunk: Bool = false
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
    
    /// Pre-warms the zero-trust streaming ingress tunnel only when explicitly needed or requested
    public func warmUpStreamingIngress(server: AudioStreamServer, completion: ((String?) -> Void)? = nil) {
        lock.lock()
        if let existing = cachedTunnelURL {
            lock.unlock()
            completion?(existing)
            return
        }
        guard !isWarmingUp else {
            lock.unlock()
            return
        }
        guard let cfPath = findExecutable(named: "cloudflared") else {
            lock.unlock()
            completion?(nil)
            return
        }
        isWarmingUp = true
        lock.unlock()
        
        streamQueue.async { [weak self] in
            guard let self = self else { return }
            LogManager.shared.audio("Initializing zero-trust fallback ingress tunnel on port \(server.port)...")
            
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
                LogManager.shared.error("DesktopAudioStreamer", "Failed to run cloudflared fallback: \(error.localizedDescription)")
                self.lock.lock()
                self.isWarmingUp = false
                self.lock.unlock()
                completion?(nil)
                return
            }
            
            let waitResult = tunnelGroup.wait(timeout: .now() + 8.0)
            cfPipe.fileHandleForReading.readabilityHandler = nil
            
            if waitResult == .success, let baseURL = discoveredURL {
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
                LogManager.shared.audio("Zero-trust fallback tunnel verified: \(baseURL)")
                completion?(baseURL)
            } else {
                self.lock.lock()
                self.isWarmingUp = false
                self.lock.unlock()
                LogManager.shared.audio("Fallback tunnel unavailable or timed out")
                completion?(nil)
            }
        }
    }
    
    public func startStreaming(
        to device: CastDevice,
        server: AudioStreamServer,
        cast: CastProtocol,
        forceTunnelFallback: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        stopStreaming()
        
        lock.lock()
        let sessionToken = UUID().uuidString
        self.activeSessionToken = sessionToken
        self.hasReceivedFirstAudioChunk = false
        lock.unlock()
        
        // Register token with local HTTP streaming server
        server.activeSessionToken = sessionToken
        
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
        
        // 2. Start SoX High-Definition 320kbps MP3 Capture with Low-Latency Buffer (--buffer 1024)
        let sox = Process()
        sox.executableURL = URL(fileURLWithPath: soxPath)
        sox.arguments = [
            "-q",
            "--buffer", "1024",  // Low-latency capture buffer (~21.3ms frame chunks)
            "-t", "coreaudio", "BlackHole 2ch",
            "-t", "mp3",
            "-C", "320",        // Studio-grade 320kbps CBR
            "-r", "48000",      // Native 48kHz matching CoreAudio DAC
            "-"
        ]
        
        let pipe = Pipe()
        let errPipe = Pipe()
        sox.standardOutput = pipe
        sox.standardError = errPipe
        
        var soxStderrData = Data()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let errChunk = handle.availableData
            if !errChunk.isEmpty {
                soxStderrData.append(errChunk)
            }
        }
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak server] handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                self?.lock.lock()
                self?.hasReceivedFirstAudioChunk = true
                self?.lock.unlock()
                server?.broadcastLiveChunk(chunk)
            }
        }
        
        sox.terminationHandler = { [weak self] proc in
            let exitCode = proc.terminationStatus
            if exitCode != 0 {
                let errString = String(data: soxStderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                LogManager.shared.error("DesktopAudioStreamer", "SoX terminated with code \(exitCode): \(errString)")
                DispatchQueue.main.async {
                    self?.statusText = "Audio capture engine stopped (\(exitCode))"
                    self?.stopStreaming()
                }
            }
        }
        
        do {
            try sox.run()
            lock.lock()
            self.soxProcess = sox
            self.soxPipe = pipe
            self.soxErrPipe = errPipe
            lock.unlock()
            LogManager.shared.audio("320kbps @ 48kHz SoX desktop capture running")
        } catch {
            LogManager.shared.error("DesktopAudioStreamer", "Failed to start SoX: \(error.localizedDescription)")
            stopStreaming()
            completion?(false)
            return
        }
        
        // 3. First-chunk watchdog timer (3.5s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let received = self.hasReceivedFirstAudioChunk
            let stillStreaming = self.isStreaming || self.activeSessionToken == sessionToken
            self.lock.unlock()
            
            if stillStreaming && !received {
                LogManager.shared.error("DesktopAudioStreamer", "Watchdog: No audio chunks received from BlackHole within 3.5s")
                self.statusText = "No audio received from audio driver"
                self.stopStreaming()
                completion?(false)
            }
        }
        
        // 4. Resolve Stream URL: DIRECT WI-FI LAN IS ALWAYS THE PRIMARY DEFAULT
        let localIP = AudioStreamServer.getWiFiIP(matchingSubnetOf: device.ipAddress) ?? server.localIP
        let directLANURL = "http://\(localIP):\(server.port)/live.mp3?token=\(sessionToken)"
        
        func dispatchToSpeaker(url: String, isTunnel: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                guard self.activeSessionToken == sessionToken else {
                    self.lock.unlock()
                    return
                }
                self.currentStreamURL = url
                self.isStreaming = true
                self.statusText = isTunnel ? "Streaming Hi-Fi 320k (Tunnel Fallback) to \(device.name)" : "Streaming Hi-Fi 320k to \(device.name)"
                self.lock.unlock()
                
                LogManager.shared.cast("Dispatching stream URL to \(device.name): \(url) (tunnel: \(isTunnel))")
                
                cast.connect(to: device) { [weak self] success in
                    guard let self = self else { return }
                    self.lock.lock()
                    guard self.activeSessionToken == sessionToken else {
                        self.lock.unlock()
                        return
                    }
                    self.lock.unlock()
                    
                    if success {
                        cast.launchAndLoad(streamURL: url, streamType: "LIVE", title: "Mac Desktop Audio") { [weak self] loadSuccess in
                            guard let self = self else { return }
                            self.lock.lock()
                            guard self.activeSessionToken == sessionToken else {
                                self.lock.unlock()
                                return
                            }
                            self.lock.unlock()
                            
                            if loadSuccess {
                                LogManager.shared.cast("Live stream playing successfully on \(device.name)")
                                completion?(true)
                            } else {
                                // If direct LAN failed and we haven't tried tunnel fallback yet, diagnose and attempt fallback
                                if !isTunnel && self.findExecutable(named: "cloudflared") != nil {
                                    LogManager.shared.audio("Direct LAN load failed (possibly corporate firewall/packet filter). Attempting zero-trust fallback...")
                                    self.warmUpStreamingIngress(server: server) { tunnelURL in
                                        guard let tURL = tunnelURL else {
                                            LogManager.shared.error("DesktopAudioStreamer", "Tunnel fallback unavailable. Stopping stream.")
                                            self.stopStreaming()
                                            completion?(false)
                                            return
                                        }
                                        let secureTunnelURL = "\(tURL)/live.mp3?token=\(sessionToken)"
                                        dispatchToSpeaker(url: secureTunnelURL, isTunnel: true)
                                    }
                                } else {
                                    LogManager.shared.error("DesktopAudioStreamer", "Failed to load media stream on speaker")
                                    self.stopStreaming()
                                    completion?(false)
                                }
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
        
        if forceTunnelFallback {
            warmUpStreamingIngress(server: server) { tunnelURL in
                if let tURL = tunnelURL {
                    dispatchToSpeaker(url: "\(tURL)/live.mp3?token=\(sessionToken)", isTunnel: true)
                } else {
                    dispatchToSpeaker(url: directLANURL, isTunnel: false)
                }
            }
        } else {
            // Direct LAN first!
            dispatchToSpeaker(url: directLANURL, isTunnel: false)
        }
    }
    
    public func stopStreaming() {
        lock.lock()
        activeSessionToken = nil
        hasReceivedFirstAudioChunk = false
        
        soxPipe?.fileHandleForReading.readabilityHandler = nil
        soxPipe = nil
        
        soxErrPipe?.fileHandleForReading.readabilityHandler = nil
        soxErrPipe = nil
        
        soxProcess?.terminationHandler = nil
        soxProcess?.terminate()
        soxProcess = nil
        lock.unlock()
        
        // Immediately restore macOS audio output to Mac speakers
        AudioDeviceManager.shared.restoreOriginalOutput()
        AudioStreamServer.sharedInstance?.closeLiveConnections()
        AudioStreamServer.sharedInstance?.activeSessionToken = nil
        
        DispatchQueue.main.async {
            self.isStreaming = false
            self.currentStreamURL = nil
            self.statusText = ""
        }
        LogManager.shared.audio("Desktop audio streaming stopped and output restored")
    }
}
