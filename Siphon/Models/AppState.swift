//
//  AppState.swift
//  Siphon
//

import Foundation
import Combine

public struct BrowserSessionCredentials: Equatable, Sendable {
    public let originHost: String
    public let rawCookies: String?
    public let rawUserAgent: String?

    public init(originHost: String, rawCookies: String?, rawUserAgent: String?) {
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
    @Published public private(set) var browserSessionOriginHost: String? = nil

    public init() {}

    private static func normalizedHost(for urlString: String) -> String? {
        URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?
            .lowercased()
    }

    public func setBrowserSession(
        for targetURL: URL,
        rawCookies: String?,
        rawUserAgent: String?
    ) {
        guard let host = targetURL.host?.lowercased(),
              rawCookies?.isEmpty == false || rawUserAgent?.isEmpty == false else {
            clearBrowserSession()
            return
        }

        rawCookiesToDownload = rawCookies?.isEmpty == false ? rawCookies : nil
        rawUserAgentToDownload = rawUserAgent?.isEmpty == false ? rawUserAgent : nil
        browserSessionOriginHost = host
    }

    public func browserSession(for urlString: String) -> BrowserSessionCredentials? {
        guard let originHost = browserSessionOriginHost,
              let targetHost = Self.normalizedHost(for: urlString),
              targetHost == originHost else {
            return nil
        }

        return BrowserSessionCredentials(
            originHost: originHost,
            rawCookies: rawCookiesToDownload,
            rawUserAgent: rawUserAgentToDownload
        )
    }

    public func clearBrowserSessionIfHostChanged(to urlString: String) {
        guard browserSessionOriginHost != nil else { return }
        guard let targetHost = Self.normalizedHost(for: urlString),
              targetHost == browserSessionOriginHost else {
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
        guard let originHost = browserSessionOriginHost, !urls.isEmpty else {
            clearBrowserSession()
            return nil
        }
        let allMatch = urls.allSatisfy { Self.normalizedHost(for: $0) == originHost }
        let credentials = allMatch
            ? BrowserSessionCredentials(
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
        browserSessionOriginHost = nil
    }
}
