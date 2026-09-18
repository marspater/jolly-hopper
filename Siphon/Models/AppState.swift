//
//  AppState.swift
//  Siphon
//

import Foundation
import Combine

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

    public init() {}

    public static func normalizedBrowserCookieSource(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let browser = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set(SupportedBrowser.allCases.map(\.rawValue))
        return allowed.contains(browser) ? browser : nil
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

    public func clearBrowserSession() {
        rawCookiesToDownload = nil
        rawUserAgentToDownload = nil
        browserCookieSourceToDownload = nil
        browserSessionOriginScheme = nil
        browserSessionOriginHost = nil
    }
}
