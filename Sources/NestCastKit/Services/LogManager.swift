import Foundation
import os.log

public final class LogManager: @unchecked Sendable {
    public static let shared = LogManager()
    
    private let logFileURL: URL
    private let oldLogFileURL: URL
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.gpsurya.NestCast.logger", qos: .utility)
    private let dateFormatter: DateFormatter
    private let maxLogSizeBytes: UInt64 = 2 * 1024 * 1024 // 2 MB log rotation threshold
    
    private init() {
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        let logsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.logFileURL = logsDir.appendingPathComponent("NestCast.log")
        self.oldLogFileURL = logsDir.appendingPathComponent("NestCast.log.old")
        
        openLogFile()
        log(level: "INFO", category: "Core", message: "=== NestCast Session Started ===")
    }
    
    private func openLogFile() {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        self.fileHandle = try? FileHandle(forWritingTo: logFileURL)
        self.fileHandle?.seekToEndOfFile()
    }
    
    public func sanitize(_ text: String) -> String {
        // Redact authentication tokens from logged URLs and headers
        var sanitized = text
        if let regex = try? NSRegularExpression(pattern: "token=[A-Za-z0-9_-]+", options: []) {
            let range = NSRange(location: 0, length: sanitized.utf16.count)
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "token=[REDACTED]")
        }
        return sanitized
    }
    
    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64, size >= maxLogSizeBytes else {
            return
        }
        
        try? fileHandle?.close()
        fileHandle = nil
        
        _ = try? FileManager.default.removeItem(at: oldLogFileURL)
        _ = try? FileManager.default.moveItem(at: logFileURL, to: oldLogFileURL)
        
        openLogFile()
        print("[\(dateFormatter.string(from: Date()))] [INFO] [Core] Log rotated to NestCast.log.old")
    }
    
    public func log(level: String = "INFO", category: String = "App", message: String) {
        let cleanMsg = sanitize(message)
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] [\(category)] \(cleanMsg)\n"
        
        queue.async { [weak self] in
            guard let self = self else { return }
            self.rotateIfNeeded()
            print(line, terminator: "")
            if let data = line.data(using: .utf8) {
                self.fileHandle?.write(data)
            }
        }
    }
    
    public func info(_ category: String, _ message: String) {
        log(level: "INFO", category: category, message: message)
    }
    
    public func debug(_ category: String, _ message: String) {
        log(level: "DEBUG", category: category, message: message)
    }
    
    public func error(_ category: String, _ message: String) {
        log(level: "ERROR", category: category, message: message)
    }
    
    public func cast(_ message: String) {
        log(level: "CAST", category: "Protocol", message: message)
    }
    
    public func audio(_ message: String) {
        log(level: "AUDIO", category: "Stream", message: message)
    }
    
    public func getLogFilePath() -> String {
        return logFileURL.path
    }
}
