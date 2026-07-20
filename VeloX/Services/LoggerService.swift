import Foundation
import SwiftUI

@MainActor
class LoggerService: ObservableObject {
    static let shared = LoggerService()
    
    @Published var logs: [String] = []
    private let logFileURL: URL
    private let maxLogEntries = 1000
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VeloX")
        
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.logFileURL = appSupport.appendingPathComponent("velox_debug.log")
        
        loadInitialLogs()
    }
    
    private func loadInitialLogs() {
        if let content = try? String(contentsOf: logFileURL, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            self.logs = Array(lines.suffix(maxLogEntries))
        }
    }
    
    func log(_ message: String, level: LogLevel = .info) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        
        let entry = "[\(timestamp)] [\(level.rawValue)] \(message)"
        
        logs.append(entry)
        if logs.count > maxLogEntries {
            logs.removeFirst(logs.count - maxLogEntries)
        }
        
        appendToLogFile(entry + "\n")
    }
    
    private func appendToLogFile(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                try? fileHandle.close()
            }
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
    }
    
    func clearLogs() {
        logs.removeAll()
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        log("Logs cleared", level: .info)
    }
    
    func exportLogs() -> URL {
        return logFileURL
    }
    
    enum LogLevel: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case command = "CMD"
    }
}
