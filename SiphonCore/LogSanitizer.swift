import Foundation

/// Redaction applied in front of every log sink.
public enum LogSanitizer {
    // Bolt Performance Optimization: Pre-compile regular expressions to eliminate
    // regex compilation and allocation overhead on every log, diagnostic text, and log export call.
    private static let urlRegex = try? NSRegularExpression(pattern: #"(?:https?|socks[45]a?h?)://[^\s"'<>]+"#, options: [])
    private static let redactionRegexes: [(NSRegularExpression, String)] = [
        (#"(?i)bearer\s+[A-Za-z0-9\-_\.]+"#, "Bearer <REDACTED>"),
        (#"(?i)authorization:\s*[^\r\n]+"#, "Authorization: <REDACTED>"),
        (#"(?i)cookie:\s*[^\r\n]+"#, "Cookie: <REDACTED>"),
        (#"(?i)set-cookie:\s*[^\r\n]+"#, "Set-Cookie: <REDACTED>"),
        (#"(?i)(x-[a-z0-9\-]*api-key|x-[a-z0-9\-]*token|x-[a-z0-9\-]*auth[a-z0-9\-]*):\s*[^\r\n]+"#, "$1: <REDACTED>"),
        (#"(?i)(token|api_key|password|pass|secret|auth|signature|sig|access_token|session|sessionid|sess|jwt|key|apikey|private_key|client_secret|pcode|oauth_token)=([^\s&"'<>]+)"#, "$1=<REDACTED>"),
        (#"(?i)(["'])(token|api_key|password|pass|secret|auth|signature|sig|access_token|session|sessionid|sess|jwt|key|apikey|private_key|client_secret|pcode|oauth_token)\1\s*:\s*(["'])(?:\\.|(?!\3)[^\\])*\3"#, "$1$2$1: $3<REDACTED>$3")
    ].compactMap { pattern, replacement in
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        return (regex, replacement)
    }

    private static let exportAuthRegex = try? NSRegularExpression(pattern: "(?i)(Authorization:\\s*)[^\\r\\n]+", options: [])
    private static let exportCookieHeaderRegex = try? NSRegularExpression(pattern: "(?i)((?:set-)?cookie:\\s*)[^\r\n]+", options: [])
    private static let exportKeyHeaderRegex = try? NSRegularExpression(pattern: "(?i)((?:x-[a-z0-9\\-]*api-key|x-[a-z0-9\\-]*token|x-[a-z0-9\\-]*auth[a-z0-9\\-]*):\\s*)[^\\s\\r\\n]+", options: [])
    private static let exportSecretQueryRegex = try? NSRegularExpression(pattern: "(?i)([?&](?:token|auth|key|api_key|password|pass|secret|sig|signature|access_token|session|sessionid|sess|jwt|apikey|private_key|client_secret|pcode|oauth_token)=)[^&\\s\\r\\n]+", options: [])
    private static let exportHomeDirRegex = try? NSRegularExpression(pattern: #"[/\\]Users[/\\]([a-zA-Z0-9._-]+)[/\\]"#, options: []) // NOSONAR

    // Bolt Performance Optimization: Move sensitive option flag dictionaries to static, lazy storage
    // to avoid per-call dictionary initialization overhead whenever command execution lines are sanitized for logging.
    private static let sensitiveValueFlags: [String: String] = [
        "--cookies": "\"<COOKIE_FILE>\"",
        "--cookies-from-browser": "\"<BROWSER>\"",
        "-b": "\"<BROWSER>\"",
        "--add-header": "\"<REDACTED_HEADER>\"",
        "--add-headers": "\"<REDACTED_HEADER>\"",
        "--header": "\"<REDACTED_HEADER>\"",
        "--http-header": "\"<REDACTED_HEADER>\"",
        "-H": "\"<REDACTED_HEADER>\"",
        "--username": "\"<USERNAME>\"",
        "-u": "\"<USERNAME>\"",
        "--password": "\"<PASSWORD>\"",
        "-p": "\"<PASSWORD>\"",
        "--video-password": "\"<PASSWORD>\"",
        "--ap-username": "\"<USERNAME>\"",
        "--ap-password": "\"<PASSWORD>\"",
        "--twofactor": "\"<2FACTOR>\"",
        "-2": "\"<2FACTOR>\"",
        "--token": "\"<TOKEN>\"",
        "--login-with-token": "\"<TOKEN>\"",
        "--api-key": "\"<API_KEY>\"",
        "--client-certificate-password": "\"<PASSWORD>\"",
        "--client-certificate": "\"<CLIENT_CERT_REDACTED>\"",
        "--client-certificate-key": "\"<CLIENT_KEY_REDACTED>\"",
        "--client-certificate-key-password": "\"<PASSWORD>\"",
        "--proxy": "\"<PROXY_REDACTED>\"",
        "--geo-verification-proxy": "\"<PROXY_REDACTED>\"",
        "--proxy-user": "\"<USERNAME>\"",
        "--proxy-password": "\"<PASSWORD>\"",
        "--user": "\"<USERNAME>\"",
        "--ffmpeg-location": "\"<LOCATION_REDACTED>\"",
        "--netrc-cmd": "\"<COMMAND_REDACTED>\"",
        "--netrc-location": "\"<LOCATION_REDACTED>\"",
        "--config-location": "\"<LOCATION_REDACTED>\"",
        "--config-locations": "\"<LOCATION_REDACTED>\"",
        "--exec": "\"<EXEC_REDACTED>\"",
        "--exec-before-download": "\"<EXEC_REDACTED>\"",
        "--extractor-args": "\"<ARGS_REDACTED>\"",
        "--postprocessor-args": "\"<ARGS_REDACTED>\"",
        "--downloader-args": "\"<ARGS_REDACTED>\"",
        "--external-downloader-args": "\"<ARGS_REDACTED>\""
    ]

    private static let shortSensitiveFlags: [String: String] = [
        "-p": "\"<PASSWORD>\"",
        "-u": "\"<USERNAME>\"",
        "-2": "\"<2FACTOR>\"",
        "-b": "\"<BROWSER>\"",
        "-H": "\"<REDACTED_HEADER>\""
    ]

    public static func sanitizeURLForLog(_ urlString: String) -> String {
        // Unparseable (e.g. a URL sliced out of a longer argument): still drop
        // the query and fragment, which carry tokens and signatures.
        guard let url = URL(string: urlString) else { return String(urlString.prefix { $0 != "?" && $0 != "#" }) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        components?.user = nil
        components?.password = nil
        return components?.string ?? "\(url.scheme ?? "https")://\(url.host ?? "unknown")"
    }

    private static func sanitizedArgument(_ arg: String) -> String {
        redactedAttachedShortFlag(arg) ?? redactedInlineFlag(arg) ?? sanitizedURLArgument(arg)
            ?? (arg.contains(" ") ? "\"\(arg)\"" : arg)
    }

    /// Attached short option syntax, for example -pPassword, -uUser or -2Code.
    private static func redactedAttachedShortFlag(_ arg: String) -> String? {
        for (shortFlag, placeholder) in Self.shortSensitiveFlags
        where arg.hasPrefix(shortFlag) && arg.count > 2 && !arg.hasPrefix(shortFlag + "=") {
            return "\(shortFlag)\(placeholder)"
        }
        return nil
    }

    /// --flag=value syntax.
    private static func redactedInlineFlag(_ arg: String) -> String? {
        for (flag, placeholder) in Self.sensitiveValueFlags where arg.hasPrefix(flag + "=") {
            return "\(flag)=\(placeholder)"
        }
        return nil
    }

    /// URLs, including quoted URLs and flag-prefixed URLs such as --url=https://...
    private static func sanitizedURLArgument(_ arg: String) -> String? {
        let schemes = ["http://", "https://", "socks4://", "socks4a://", "socks5://", "socks5h://"]
        guard let schemeRange = schemes.compactMap({ arg.range(of: $0, options: .caseInsensitive) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let prefix = String(arg[..<schemeRange.lowerBound])
        let rawURL = String(arg[schemeRange.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let full = prefix + sanitizeURLForLog(rawURL)
        return full.contains(" ") || arg.hasPrefix("\"") || arg.hasPrefix("'") ? "\"\(full)\"" : full
    }

    public static func sanitizeCommandForLog(_ args: [String]) -> String {
        var sanitizedArgs: [String] = []
        var skipNextForRedaction: String?

        for arg in args {
            if let redactionPlaceholder = skipNextForRedaction {
                sanitizedArgs.append(redactionPlaceholder)
                skipNextForRedaction = nil
            } else if let placeholder = Self.sensitiveValueFlags[arg] {
                sanitizedArgs.append(arg)
                skipNextForRedaction = placeholder
            } else {
                sanitizedArgs.append(sanitizedArgument(arg))
            }
        }

        if let pending = skipNextForRedaction {
            sanitizedArgs.append(pending)
        }

        return sanitizedArgs.joined(separator: " ")
    }

    public static func extractTailLines(from data: Data, maxEntries: Int, discardFirstLine: Bool = false) -> [String] {
        guard !data.isEmpty, maxEntries > 0 else { return [] }
        var lineStarts: [Int] = discardFirstLine ? [] : [data.startIndex]
        for byteIndex in data.indices {
            if data[byteIndex] == 0x0A && byteIndex + 1 < data.endIndex {
                lineStarts.append(byteIndex + 1)
            }
        }

        let neededStarts = lineStarts.suffix(maxEntries + 1)
        var result: [String] = []
        result.reserveCapacity(min(maxEntries, neededStarts.count))

        for idx in neededStarts {
            let nextNewline = data[idx...].firstIndex(of: 0x0A) ?? data.endIndex
            if idx < nextNewline {
                let slice = data[idx..<nextNewline]
                let line = Substring(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    result.append(line)
                }
            }
        }
        return Array(result.suffix(maxEntries))
    }

    public static func sanitizeDiagnosticText(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        // Bolt Performance Optimization: Use Swift Range slicing (`String(result[swiftRange])`) and
        // native UTF-16 character counting (`result.utf16.count`) instead of bridging to `NSString`
        // (`(result as NSString).length` and `nsString.substring(with:)`).
        // This eliminates temporary Objective-C object allocations on every high-frequency log sanitization call.
        // 1. Sanitize URLs (strip query strings, fragments, credentials)
        if let urlRegex = Self.urlRegex {
            let matches = urlRegex.matches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count))
            for match in matches.reversed() {
                if let swiftRange = Range(match.range, in: result) {
                    let urlStr = String(result[swiftRange])
                    let sanitizedURL = sanitizeURLForLog(urlStr)
                    result.replaceSubrange(swiftRange, with: sanitizedURL)
                }
            }
        }

        // 2. Redact Bearer / API tokens and credentials using pre-compiled regexes
        for (regex, replacement) in Self.redactionRegexes {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: replacement)
        }

        return result
    }

    public static func sanitizeLogContentForExport(_ content: String) -> String {
        var sanitized = content

        // 1. Redact Bearer / Basic / Token authorization headers
        if let regex = Self.exportAuthRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "$1<REDACTED_AUTH>")
        }

        // 2. Redact cookie headers or cookie parameter lines
        if let regex = Self.exportCookieHeaderRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "$1<REDACTED_COOKIES>")
        }

        // 3. Redact custom API key or token headers (e.g. X-API-Key, X-Token)
        if let regex = Self.exportKeyHeaderRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "$1<REDACTED_KEY>")
        }

        // 4. Redact common query secrets in URLs
        if let regex = Self.exportSecretQueryRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "$1<REDACTED>")
        }

        // 4. Redact username from /Users/<username>/
        if let regex = Self.exportHomeDirRegex {
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: NSRange(location: 0, length: sanitized.utf16.count), withTemplate: "/Users/<USER>/")
        }

        return sanitized
    }
}
