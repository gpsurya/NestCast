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
    private let streamQueue = DispatchQueue(label: "com.gpsurya.NestCast.desktopAudioStreamer", qos: .userInitiated)
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
        stopStreaming()
    }
    
    @objc private func handleAppWillTerminate() {
        stopStreaming()
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
            self.statusText = "Redirecting Mac audio to BlackHole..."
        }
        
        // 1. Redirect macOS Default Audio Output to BlackHole 2ch
        guard AudioDeviceManager.shared.switchToBlackHole() else {
            let msg = "BlackHole 2ch driver not found. Install via: brew install blackhole-2ch"
            LogManager.shared.error("DesktopAudioStreamer", msg)
            DispatchQueue.main.async { self.statusText = msg }
            completion?(false)
            return
        }
        
        // 2. Start SoX High-Definition 320kbps MP3 Capture (Native 48kHz, Zero Resampling)
        let sox = Process()
        sox.executableURL = URL(fileURLWithPath: soxPath)
        sox.arguments = [
            "-q",
            "-t", "coreaudio", "BlackHole 2ch",
            "-t", "mp3",
            "-C", "320",      // Studio-grade 320kbps CBR (Superior to Bluetooth SBC/AAC)
            "-r", "48000",    // Native 48kHz matching CoreAudio DAC (Zero resampling artifacts)
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
            LogManager.shared.audio("High-Definition 320kbps @ 48kHz SoX desktop capture running")
        } catch {
            LogManager.shared.error("DesktopAudioStreamer", "Failed to start SoX: \(error.localizedDescription)")
            stopStreaming()
            completion?(false)
            return
        }
        
        // 3. Resolve Stream URL (Tunnel if available for zero-trust/corporate firewalls, else Direct LAN)
        let localIP = AudioStreamServer.getWiFiIP(matchingSubnetOf: device.ipAddress) ?? server.localIP
        let directLANURL = "http://\(localIP):\(server.port)/live.mp3"
        let cfPath = findExecutable(named: "cloudflared")
        
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
                self.statusText = isTunnel ? "Streaming Hi-Fi 320k (Firewall Safe) to \(device.name)" : "Streaming Hi-Fi 320k to \(device.name)"
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
        
        if let cfPath = cfPath {
            DispatchQueue.main.async {
                self.statusText = "Establishing secure audio stream..."
            }
            let cf = Process()
            cf.executableURL = URL(fileURLWithPath: cfPath)
            cf.arguments = ["tunnel", "--url", "http://127.0.0.1:\(server.port)"]
            
            let cfPipe = Pipe()
            cf.standardOutput = cfPipe
            cf.standardError = cfPipe
            
            let tunnelGroup = DispatchGroup()
            tunnelGroup.enter()
            var discoveredTunnelURL: String?
            
            cfPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard let text = String(data: data, encoding: .utf8) else { return }
                for line in text.components(separatedBy: "\n") {
                    if line.contains("trycloudflare.com") && discoveredTunnelURL == nil {
                        let tokens = line.components(separatedBy: CharacterSet.whitespacesAndNewlines)
                        for token in tokens {
                            if token.hasPrefix("https://") && token.contains("trycloudflare.com") {
                                discoveredTunnelURL = token
                                LogManager.shared.audio("Cloudflared tunnel established: \(token)")
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
                LogManager.shared.error("DesktopAudioStreamer", "Failed to run cloudflared: \(error.localizedDescription)")
            }
            
            streamQueue.async { [weak self] in
                guard self != nil else { return }
                let waitResult = tunnelGroup.wait(timeout: .now() + 8.0)
                cfPipe.fileHandleForReading.readabilityHandler = nil
                
                if waitResult == .success, let baseURL = discoveredTunnelURL {
                    let liveURL = "\(baseURL)/live.mp3"
                    proceedWithStream(url: liveURL, isTunnel: true)
                } else {
                    LogManager.shared.audio("Tunnel timed out or unavailable, falling back to Direct LAN: \(directLANURL)")
                    proceedWithStream(url: directLANURL, isTunnel: false)
                }
            }
        } else {
            LogManager.shared.cast("Direct Wi-Fi audio stream URL for \(device.name): \(directLANURL)")
            proceedWithStream(url: directLANURL, isTunnel: false)
        }
    }
    
    public func stopStreaming() {
        lock.lock()
        activeSessionToken = nil
        
        // Clear readabilityHandler to prevent kernel file descriptor leaks
        soxPipe?.fileHandleForReading.readabilityHandler = nil
        soxPipe = nil
        
        soxProcess?.terminate()
        soxProcess = nil
        
        cloudflaredProcess?.terminate()
        cloudflaredProcess = nil
        lock.unlock()
        
        AudioDeviceManager.shared.restoreOriginalOutput()
        AudioStreamServer.sharedInstance?.closeLiveConnections()
        
        DispatchQueue.main.async {
            self.isStreaming = false
            self.currentStreamURL = nil
            self.statusText = ""
        }
        LogManager.shared.audio("Desktop audio streaming stopped and output restored")
    }
}
