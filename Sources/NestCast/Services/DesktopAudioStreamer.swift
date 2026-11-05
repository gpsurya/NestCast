import Foundation
import CoreAudio
import AppKit

public final class DesktopAudioStreamer: ObservableObject, @unchecked Sendable {
    public static let shared = DesktopAudioStreamer()
    
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var publicStreamURL: String? = nil
    @Published public private(set) var statusText: String = ""
    
    private var soxProcess: Process?
    private var cloudflaredProcess: Process?
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
        
        guard let soxPath = findExecutable(named: "sox") else {
            let msg = "SoX not installed. Please install via: brew install sox"
            LogManager.shared.error("DesktopAudioStreamer", msg)
            DispatchQueue.main.async { self.statusText = msg }
            completion?(false)
            return
        }
        
        guard let cfPath = findExecutable(named: "cloudflared") else {
            let msg = "cloudflared not installed. Please install via: brew install cloudflared"
            LogManager.shared.error("DesktopAudioStreamer", msg)
            DispatchQueue.main.async { self.statusText = msg }
            completion?(false)
            return
        }
        
        DispatchQueue.main.async {
            self.statusText = "Redirecting Mac audio to BlackHole..."
        }
        
        // 1. Switch Default Audio Output
        guard AudioDeviceManager.shared.switchToBlackHole() else {
            let msg = "Failed to switch audio output to BlackHole 2ch"
            LogManager.shared.error("DesktopAudioStreamer", msg)
            DispatchQueue.main.async { self.statusText = msg }
            completion?(false)
            return
        }
        
        // 2. Start SoX Capture to MP3
        let sox = Process()
        sox.executableURL = URL(fileURLWithPath: soxPath)
        sox.arguments = [
            "-q",
            "-t", "coreaudio", "BlackHole 2ch",
            "-t", "mp3",
            "-C", "192",
            "-r", "44100",
            "-"
        ]
        
        let soxPipe = Pipe()
        sox.standardOutput = soxPipe
        sox.standardError = FileHandle.nullDevice
        
        soxPipe.fileHandleForReading.readabilityHandler = { [weak server] handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                server?.broadcastLiveChunk(chunk)
            }
        }
        
        do {
            try sox.run()
            self.lock.lock()
            self.soxProcess = sox
            self.lock.unlock()
            LogManager.shared.audio("SoX live desktop audio capture running")
        } catch {
            LogManager.shared.error("DesktopAudioStreamer", "Failed to start SoX: \(error.localizedDescription)")
            stopStreaming()
            completion?(false)
            return
        }
        
        // 3. Launch cloudflared tunnel
        DispatchQueue.main.async {
            self.statusText = "Establishing secure streaming tunnel..."
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
            stopStreaming()
            completion?(false)
            return
        }
        
        // 4. Await tunnel ready on streamQueue
        streamQueue.async { [weak self] in
            guard let self = self else { return }
            let waitResult = tunnelGroup.wait(timeout: .now() + 12.0)
            
            guard waitResult == .success, let baseURL = discoveredTunnelURL else {
                LogManager.shared.error("DesktopAudioStreamer", "Timed out waiting for cloudflared tunnel URL")
                self.stopStreaming()
                DispatchQueue.main.async {
                    self.statusText = "Streaming tunnel timed out"
                    completion?(false)
                }
                return
            }
            
            let liveURL = "\(baseURL)/live.mp3"
            LogManager.shared.cast("Dispatching live audio stream URL to \(device.name): \(liveURL)")
            
            DispatchQueue.main.async {
                self.publicStreamURL = liveURL
                self.isStreaming = true
                self.statusText = "Streaming Mac audio live to \(device.name)"
                
                // Connect and launch Default Media Receiver
                cast.connect(to: device) { success in
                    if success {
                        cast.launchAndLoad(streamURL: liveURL, streamType: "LIVE") { loadSuccess in
                            if loadSuccess {
                                LogManager.shared.cast("Live stream loaded successfully on \(device.name)")
                                completion?(true)
                            } else {
                                LogManager.shared.error("DesktopAudioStreamer", "Failed to load live media on speaker")
                                self.stopStreaming()
                                completion?(false)
                            }
                        }
                    } else {
                        LogManager.shared.error("DesktopAudioStreamer", "Failed to connect Cast session")
                        self.stopStreaming()
                        completion?(false)
                    }
                }
            }
        }
    }
    
    public func stopStreaming() {
        lock.lock()
        defer { lock.unlock() }
        
        soxProcess?.terminate()
        soxProcess = nil
        
        cloudflaredProcess?.terminate()
        cloudflaredProcess = nil
        
        AudioDeviceManager.shared.restoreOriginalOutput()
        AudioStreamServer.sharedInstance?.closeLiveConnections()
        
        DispatchQueue.main.async {
            self.isStreaming = false
            self.publicStreamURL = nil
            self.statusText = ""
        }
        LogManager.shared.audio("Desktop audio streaming stopped and output restored")
    }
}
