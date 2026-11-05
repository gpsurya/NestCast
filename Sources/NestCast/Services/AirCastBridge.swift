import Foundation

@MainActor
public class AirCastBridge: ObservableObject {
    @Published public var isRunning: Bool = false
    @Published public var statusMessage: String = "Bridge Inactive"
    @Published public var logLines: [String] = []
    
    private var process: Process?
    private var pipe: Pipe?
    
    public init() {}
    
    public func startBridge() {
        guard !isRunning else { return }
        
        let binaryPath = findAircastBinary()
        guard let path = binaryPath, FileManager.default.isExecutableFile(atPath: path) else {
            statusMessage = "Helper binary not found"
            return
        }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["-Z"] // Non-interactive mode
        
        let outputPipe = Pipe()
        proc.standardOutput = outputPipe
        proc.standardError = outputPipe
        
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor [weak self] in
                    let lines = str.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    self?.logLines.append(contentsOf: lines)
                    if (self?.logLines.count ?? 0) > 100 {
                        self?.logLines.removeFirst(50)
                    }
                }
            }
        }
        
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.statusMessage = "Bridge stopped"
                self?.process = nil
            }
        }
        
        do {
            try proc.run()
            self.process = proc
            self.isRunning = true
            self.statusMessage = "Bridge Active (AirPlay targets published)"
        } catch {
            self.statusMessage = "Failed to launch bridge: \(error.localizedDescription)"
        }
    }
    
    public func stopBridge() {
        process?.terminate()
        process = nil
        isRunning = false
        statusMessage = "Bridge stopped"
    }
    
    private func findAircastBinary() -> String? {
        // 1. App Bundle Resources
        if let bundlePath = Bundle.main.path(forResource: "aircast", ofType: nil) {
            return bundlePath
        }
        // 2. Relative Resources path during development
        let devPath = "/Users/suryaprakashpalanisamy/NestCast/Resources/aircast"
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        // 3. System fallback
        let tempPath = "/tmp/airconnect/aircast-macos-arm64-static"
        if FileManager.default.fileExists(atPath: tempPath) {
            return tempPath
        }
        return nil
    }
}
