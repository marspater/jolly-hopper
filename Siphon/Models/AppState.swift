//
//  AppState.swift
//  Siphon
//

import Foundation
import Combine

public enum ExternalDownloadTargetPolicy {
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return false
        }

        if host == "localhost" ||
            host.hasSuffix(".localhost") ||
            host.hasSuffix(".local") ||
            host.hasSuffix(".localdomain") ||
            host.hasSuffix(".internal") ||
            host.hasSuffix(".lan") ||
            !host.contains(".") {
            return false
        }

        if let ipv4 = parseIPv4(host) {
            return isGloballyRoutableIPv4(ipv4)
        }

        if host.contains(":") {
            return isGloballyRoutableIPv6(host)
        }

        return true
    }

    private static func parseIPv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let value = UInt8(part) else {
                return nil
            }
            bytes.append(value)
        }
        return bytes
    }

    private static func isGloballyRoutableIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        let a = b[0], second = b[1]

        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(second) { return false }
        if a == 169 && second == 254 { return false }
        if a == 172 && (16...31).contains(second) { return false }
        if a == 192 && second == 168 { return false }
        if a == 198 && (second == 18 || second == 19) { return false }

        return true
    }

    private static func isGloballyRoutableIPv6(_ host: String) -> Bool {
        let value = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if value == "::" || value == "::1" { return false }
        if value.hasPrefix("fc") || value.hasPrefix("fd") { return false }
        if value.hasPrefix("fe8") || value.hasPrefix("fe9") ||
            value.hasPrefix("fea") || value.hasPrefix("feb") { return false }
        if value.hasPrefix("ff") { return false }
        if value.hasPrefix("2001:db8:") { return false }

        if value.hasPrefix("::ffff:"),
           let mapped = parseIPv4(String(value.dropFirst("::ffff:".count))) {
            return isGloballyRoutableIPv4(mapped)
        }

        return true
    }
}

public struct BrowserSessionCredentials: Equatable, Sendable {
    public let originScheme: String
    public let originHost: String
    public let rawCookies: String?
    public let rawUserAgent: String?

    public init(originScheme: String, originHost: String, rawCookies: String?, rawUserAgent: String?) {
        self.originScheme = originScheme
        self.originHost = originHost
        self.rawCookies = rawCookies
        self.rawUserAgent = rawUserAgent
    }
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var showAddDownloadSheet: Bool = false
    @Published public var selectedNavItem: NavigationItem = .home
    @Published public var urlToDownload: String = ""
    @Published public private(set) var rawCookiesToDownload: String? = nil
    @Published public private(set) var rawUserAgentToDownload: String? = nil
    @Published public private(set) var browserSessionOriginScheme: String? = nil
    @Published public private(set) var browserSessionOriginHost: String? = nil

    public init() {}

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
        rawUserAgent: String?
    ) {
        guard let scheme = targetURL.scheme?.lowercased(),
              let host = targetURL.host?.lowercased(),
              ["http", "https"].contains(scheme),
              rawCookies?.isEmpty == false || rawUserAgent?.isEmpty == false else {
            clearBrowserSession()
            return
        }

        rawCookiesToDownload = rawCookies?.isEmpty == false ? rawCookies : nil
        rawUserAgentToDownload = rawUserAgent?.isEmpty == false ? rawUserAgent : nil
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
            rawUserAgent: rawUserAgentToDownload
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
                rawUserAgent: rawUserAgentToDownload
            )
            : nil
        clearBrowserSession()
        return credentials
    }

    public func clearBrowserSession() {
        rawCookiesToDownload = nil
        rawUserAgentToDownload = nil
        browserSessionOriginScheme = nil
        browserSessionOriginHost = nil
    }
}
