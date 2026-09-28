//
//  AppState.swift
//  Siphon
//

import Foundation
import Combine
import Darwin

public enum ExternalDownloadTargetPolicy {
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.user == nil,
              url.password == nil,
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty else {
            return false
        }

        var host = rawHost
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else { return false }

        if host == "localhost" ||
            host.hasSuffix(".localhost") ||
            host.hasSuffix(".local") ||
            host.hasSuffix(".localdomain") ||
            host.hasSuffix(".internal") ||
            host.hasSuffix(".lan") {
            return false
        }

        // inet_aton-style IPv4 shorthand, octal and hexadecimal forms can resolve
        // even when a strict dotted-quad parser rejects them. Refuse those forms
        // before allowing a hostname through to yt-dlp.
        if looksLikeLegacyIPv4Literal(host) {
            return false
        }

        if let ipv4 = parseIPv4(host) {
            return isGloballyRoutableIPv4(ipv4)
        }

        // Check IPv6 literals before the dot requirement so that bracket-
        // stripped hosts like "2606:4700::" are not rejected by !contains(".").
        if host.contains(":") {
            return isGloballyRoutableIPv6(host)
        }

        // Single-label hostnames (no dot) are local/intranet names.
        guard host.contains(".") else { return false }

        // Hostname passed static checks. Resolve DNS and verify every
        // returned address is globally routable to prevent SSRF via
        // domains that resolve to private/reserved IP ranges.
        return resolveAndValidateHost(host)
    }

    public static func isAllowedTarget(host: String, port: Int? = nil) -> Bool {
        var cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.hasPrefix("[") && cleanHost.hasSuffix("]") {
            cleanHost = String(cleanHost.dropFirst().dropLast())
        }
        guard !cleanHost.isEmpty else { return false }
        let hostForURL = cleanHost.contains(":") ? "[\(cleanHost)]" : cleanHost
        let portStr = port.map { ":\($0)" } ?? ""
        guard let url = URL(string: "https://\(hostForURL)\(portStr)") else { return false }
        return isAllowed(url)
    }

    private static func looksLikeLegacyIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }) else {
            return false
        }

        var sawNonCanonicalComponent = parts.count != 4
        for part in parts {
            let lower = part.lowercased()
            if lower.hasPrefix("0x") {
                let suffix = lower.dropFirst(2)
                guard !suffix.isEmpty, suffix.allSatisfy(\.isHexDigit) else { return false }
                sawNonCanonicalComponent = true
                continue
            }

            if part.count > 1, part.first == "0" {
                guard part.allSatisfy({ ("0"..."7").contains(String($0)) }) else {
                    return false
                }
                sawNonCanonicalComponent = true
                continue
            }

            guard part.allSatisfy(\.isNumber) else { return false }
        }

        return sawNonCanonicalComponent
    }

    private static func parseIPv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let value = UInt8(String(part)) else {
                return nil
            }
            bytes.append(value)
        }
        return bytes
    }

    private static func isGloballyRoutableIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        let a = b[0]
        let second = b[1]

        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(second) { return false }
        if a == 169 && second == 254 { return false }
        if a == 172 && (16...31).contains(second) { return false }
        if a == 192 && second == 168 { return false }
        if a == 198 && (second == 18 || second == 19) { return false }
        // IETF protocol assignments, documentation (TEST-NET-1/2/3), 6to4 relay anycast.
        if a == 192 && second == 0 && (b[2] == 0 || b[2] == 2) { return false }
        if a == 198 && second == 51 && b[2] == 100 { return false }
        if a == 203 && second == 0 && b[2] == 113 { return false }
        if a == 192 && second == 88 && b[2] == 99 { return false }

        return true
    }

    private static func isGloballyRoutableIPv6(_ host: String) -> Bool {
        var value = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if let zoneIndex = value.firstIndex(of: "%") {
            value = String(value[..<zoneIndex])
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        let parsed = value.withCString { cString in
            bytes.withUnsafeMutableBytes { buffer in
                inet_pton(AF_INET6, cString, buffer.baseAddress)
            }
        }
        guard parsed == 1 else { return false }
        return isGloballyRoutableIPv6Bytes(bytes)
    }

    /// Resolve all A/AAAA records for `host` and reject if **any** resolved
    /// address falls into a private or reserved range, such as a public
    /// hostname that resolves to 127.0.0.1 or 169.254.169.254.
    ///
    /// This is an admission check, not a connection-time boundary: yt-dlp
    /// resolves the host again and follows redirects on its own, so DNS
    /// rebinding or a redirect to a private address is not prevented here.
    private static func resolveAndValidateHost(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICSERV

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "443", &hints, &result)
        defer { if let result { freeaddrinfo(result) } }

        // Resolution failure → reject. Do not allow unresolvable hostnames
        // through, since yt-dlp may resolve them differently.
        guard status == 0, result != nil else { return false }

        var current = result
        var checkedAtLeastOne = false
        while let info = current {
            let family = info.pointee.ai_family
            switch family {
            case AF_INET:
                guard let addr = info.pointee.ai_addr else { return false }
                let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let raw = sin.sin_addr.s_addr  // network byte order
                let b: [UInt8] = [
                    UInt8(raw & 0xFF),
                    UInt8((raw >> 8) & 0xFF),
                    UInt8((raw >> 16) & 0xFF),
                    UInt8((raw >> 24) & 0xFF)
                ]
                guard isGloballyRoutableIPv4(b) else { return false }
                checkedAtLeastOne = true

            case AF_INET6:
                guard let addr = info.pointee.ai_addr else { return false }
                let sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                let bytes = withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
                guard isGloballyRoutableIPv6Bytes(bytes) else { return false }
                checkedAtLeastOne = true

            default:
                break
            }
            current = info.pointee.ai_next
        }

        // Reject if no address records were found at all.
        return checkedAtLeastOne
    }

    /// Check raw IPv6 bytes (16 bytes) against private/reserved ranges.
    /// Factored out of `isGloballyRoutableIPv6` to share with DNS resolution.
    private static func isGloballyRoutableIPv6Bytes(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }

        let firstTenZero = bytes[0..<10].allSatisfy { $0 == 0 }
        if firstTenZero, bytes[10] == 0xff, bytes[11] == 0xff {
            return isGloballyRoutableIPv4(Array(bytes[12..<16]))
        }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            return isGloballyRoutableIPv4(Array(bytes[12..<16]))
        }

        // Translation prefixes carry an IPv4 address that a gateway or relay
        // connects to, so they inherit IPv4 routing rules.
        if bytes[0..<4] == [0x00, 0x64, 0xff, 0x9b] {
            if bytes[4..<12].allSatisfy({ $0 == 0 }) {
                return isGloballyRoutableIPv4(Array(bytes[12..<16])) // NAT64 64:ff9b::/96
            }
            if bytes[4] == 0x00, bytes[5] == 0x01 { return false } // local-use NAT64 64:ff9b:1::/48
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            return isGloballyRoutableIPv4(Array(bytes[2..<6])) // 6to4 2002::/16
        }
        if bytes[0..<4] == [0x20, 0x01, 0x00, 0x00] { return false } // Teredo 2001::/32

        // Unique-local, link-local, deprecated site-local, multicast, and the
        // documentation prefix are never valid external deep-link targets.
        if (bytes[0] & 0xfe) == 0xfc { return false } // fc00::/7
        if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return false } // fe80::/10
        if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0xc0 { return false } // fec0::/10
        if bytes[0] == 0xff { return false } // ff00::/8
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 {
            return false // 2001:db8::/32
        }

        return true
    }
}

public struct BrowserSessionCredentials: Equatable, Sendable {
    public let originScheme: String
    public let originHost: String
    public let rawCookies: String?
    public let rawUserAgent: String?
    public let browserCookieSource: String?

    public init(
        originScheme: String,
        originHost: String,
        rawCookies: String?,
        rawUserAgent: String?,
        browserCookieSource: String?
    ) {
        self.originScheme = originScheme
        self.originHost = originHost
        self.rawCookies = rawCookies
        self.rawUserAgent = rawUserAgent
        self.browserCookieSource = browserCookieSource
    }
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var showAddDownloadSheet: Bool = false
    @Published public var selectedNavItem: NavigationItem = .home
    @Published public var urlToDownload: String = ""
    @Published public private(set) var rawCookiesToDownload: String? = nil
    @Published public private(set) var rawUserAgentToDownload: String? = nil
    @Published public private(set) var browserCookieSourceToDownload: String? = nil
    @Published public private(set) var browserSessionOriginScheme: String? = nil
    @Published public private(set) var browserSessionOriginHost: String? = nil
    @Published public private(set) var externalTargetURL: String? = nil

    @Published var ytdlpVersion: String?
    @Published var showWhatsNew: Bool = false
    @Published var whatsNewFeatures: [ReleaseFeature] = []
    @Published var ytdlpUpdateMessage: YtdlpUpdateMessage?
    @Published var isUpdatingYtdlp: Bool = false
    @Published var ytdlpUpdateProgress: Double = 0

    var urlSession: URLSession = .shared
    private let releaseNotesService = ReleaseNotesService()
    private let dependencyCoordinator = DependencyUpdateCoordinator()

    public init() {
        dependencyCoordinator.$isUpdating
            .receive(on: RunLoop.main)
            .assign(to: &$isUpdatingYtdlp)
        dependencyCoordinator.$updateProgress
            .receive(on: RunLoop.main)
            .assign(to: &$ytdlpUpdateProgress)
        dependencyCoordinator.$version
            .receive(on: RunLoop.main)
            .assign(to: &$ytdlpVersion)
        dependencyCoordinator.$updateMessage
            .receive(on: RunLoop.main)
            .assign(to: &$ytdlpUpdateMessage)
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "5.4.5"
    }

    func initializeApplicationServices(
        ytdlpService: YtdlpService,
        languageService: LanguageService,
        skipBinarySetup: Bool = false
    ) async {
        dependencyCoordinator.bind(to: ytdlpService)
        await dependencyCoordinator.initialize(service: ytdlpService, skipBinarySetup: skipBinarySetup)
        // Do not rely on the RunLoop-delivered Combine mirror for values that
        // callers expect to be current when this async operation returns.
        ytdlpVersion = dependencyCoordinator.version
        await checkAndFetchWhatsNew(languageService: languageService)
    }

    func checkAndFetchWhatsNew(languageService: LanguageService) async {
        if let result = await releaseNotesService.checkAndFetchWhatsNew(
            appVersion: appVersion,
            languageService: languageService,
            session: urlSession
        ) {
            whatsNewFeatures = result.features
            showWhatsNew = result.shouldShow
        }
    }

    func updateYtdlp(
        using ytdlpService: YtdlpService,
        activeExecutionCount: Int,
        languageService: LanguageService? = nil
    ) async {
        let lang = languageService ?? .shared
        guard activeExecutionCount == 0 else {
            ytdlpUpdateMessage = YtdlpUpdateMessage(
                title: lang.s("ytdlp_update_unavailable_title"),
                message: lang.s("ytdlp_update_unavailable_message")
            )
            return
        }

        dependencyCoordinator.bind(to: ytdlpService)
        await dependencyCoordinator.updateYtdlp(service: ytdlpService, languageService: lang)
        ytdlpVersion = dependencyCoordinator.version
        ytdlpUpdateMessage = dependencyCoordinator.updateMessage
    }

    public static func normalizedBrowserCookieSource(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let browser = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if browser == "helium" { return "chromium-based" }
        return SupportedBrowser.allowedRawValues.contains(browser) ? browser : nil
    }

    private static func normalizedOrigin(for urlString: String) -> (scheme: String, host: String)? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }
        return (scheme, host)
    }

    public func setBrowserSession(
        for targetURL: URL,
        rawCookies: String?,
        rawUserAgent: String?,
        browserCookieSource: String? = nil
    ) {
        let normalizedBrowser = Self.normalizedBrowserCookieSource(browserCookieSource)
        guard let scheme = targetURL.scheme?.lowercased(),
              let host = targetURL.host?.lowercased(),
              ["http", "https"].contains(scheme),
              rawCookies?.isEmpty == false ||
                rawUserAgent?.isEmpty == false ||
                normalizedBrowser != nil else {
            clearBrowserSession()
            return
        }

        rawCookiesToDownload = rawCookies?.isEmpty == false ? rawCookies : nil
        rawUserAgentToDownload = rawUserAgent?.isEmpty == false ? rawUserAgent : nil
        browserCookieSourceToDownload = normalizedBrowser
        browserSessionOriginScheme = scheme
        browserSessionOriginHost = host
    }

    public func browserSession(for urlString: String) -> BrowserSessionCredentials? {
        guard let originScheme = browserSessionOriginScheme,
              let originHost = browserSessionOriginHost,
              let target = Self.normalizedOrigin(for: urlString),
              target.scheme == originScheme,
              target.host == originHost else {
            return nil
        }

        return BrowserSessionCredentials(
            originScheme: originScheme,
            originHost: originHost,
            rawCookies: rawCookiesToDownload,
            rawUserAgent: rawUserAgentToDownload,
            browserCookieSource: browserCookieSourceToDownload
        )
    }

    public func clearBrowserSessionIfOriginChanged(to urlString: String) {
        guard browserSessionOriginHost != nil else { return }
        guard let target = Self.normalizedOrigin(for: urlString),
              target.scheme == browserSessionOriginScheme,
              target.host == browserSessionOriginHost else {
            clearBrowserSession()
            return
        }
    }

    public func consumeBrowserSession(for urlString: String) -> BrowserSessionCredentials? {
        let credentials = browserSession(for: urlString)
        clearBrowserSession()
        return credentials
    }

    public func consumeBrowserSession(for urls: [String]) -> BrowserSessionCredentials? {
        guard let originScheme = browserSessionOriginScheme,
              let originHost = browserSessionOriginHost,
              !urls.isEmpty else {
            clearBrowserSession()
            return nil
        }
        let allMatch = urls.allSatisfy {
            guard let target = Self.normalizedOrigin(for: $0) else { return false }
            return target.scheme == originScheme && target.host == originHost
        }
        let credentials = allMatch
            ? BrowserSessionCredentials(
                originScheme: originScheme,
                originHost: originHost,
                rawCookies: rawCookiesToDownload,
                rawUserAgent: rawUserAgentToDownload,
                browserCookieSource: browserCookieSourceToDownload
            )
            : nil
        clearBrowserSession()
        return credentials
    }

    public func setExternalTarget(_ urlString: String) {
        externalTargetURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func consumeExternalTarget(for urlString: String) -> Bool {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let target = externalTargetURL, target == clean {
            externalTargetURL = nil
            return true
        }
        return false
    }

    public func consumeExternalTarget(for urls: [String]) -> Bool {
        let cleanUrls = Set(urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if let target = externalTargetURL, cleanUrls.contains(target) {
            externalTargetURL = nil
            return true
        }
        return false
    }

    /// Clears browser credentials only. The external-target marker is security
    /// provenance, not a credential: it must outlive credential clears, or a URL
    /// that arrived by deep link could download without the egress proxy.
    public func clearBrowserSession() {
        rawCookiesToDownload = nil
        rawUserAgentToDownload = nil
        browserCookieSourceToDownload = nil
        browserSessionOriginScheme = nil
        browserSessionOriginHost = nil
    }

    public func clearExternalTarget() {
        externalTargetURL = nil
    }

    /// Opens a job's URL in the Add Download window again. A job that came from
    /// a deep link keeps its external-target marker, so the new download (and
    /// its preview) stays behind the egress proxy.
    func reopenInAddSheet(_ download: Download) {
        if download.options.enforcePublicNetworkBoundary {
            setExternalTarget(download.url)
        }
        urlToDownload = download.url
        showAddDownloadSheet = true
    }
}
