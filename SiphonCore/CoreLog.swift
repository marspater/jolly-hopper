import Foundation
import os

public enum CoreLogLevel: Sendable {
    case info, warning, error
}

public typealias CoreLogSink = @Sendable (String, CoreLogLevel) -> Void

public enum CoreLog {
    /// Default sink for core code running without the app's logger.
    public static let unified: CoreLogSink = { message, level in
        let type: OSLogType = level == .error ? .error : level == .warning ? .default : .info
        // Public so Console and `log stream` show the text. It must stay sanitized: it can
        // still carry a host and path.
        Logger(subsystem: "com.marspater.siphon", category: "core")
            .log(level: type, "\(LogSanitizer.sanitizeDiagnosticText(message), privacy: .public)")
    }
}
