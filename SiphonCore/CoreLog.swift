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
        // Private: sanitized text can still carry a host and path that identify user activity.
        Logger(subsystem: "com.marspater.siphon", category: "core")
            .log(level: type, "\(LogSanitizer.sanitizeDiagnosticText(message), privacy: .private)")
    }
}
