import Foundation
import os.log

public final class LogManager: @unchecked Sendable {
    public static let shared = LogManager()
    
    private let logFileURL: URL
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.gpsurya.NestCast.logger", qos: .utility)
    private let dateFormatter: DateFormatter
    private let osLogger = Logger(subsystem: "com.gpsurya.NestCast", category: "App")
    
    private init() {
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        let logsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.logFileURL = logsDir.appendingPathComponent("NestCast.log")
        
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        
        self.fileHandle = try? FileHandle(forWritingTo: logFileURL)
        self.fileHandle?.seekToEndOfFile()
        
        log(level: "INFO", category: "Core", message: "=== NestCast Session Started ===")
    }
    
    public func log(level: String = "INFO", category: String = "App", message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] [\(category)] \(message)\n"
        
        queue.async { [weak self] in
            guard let self = self else { return }
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
