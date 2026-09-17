//
//  AppState.swift
//  Siphon
//

import Foundation
import Combine

@MainActor
public final class AppState: ObservableObject {
    @Published public var showAddDownloadSheet: Bool = false
    @Published public var selectedNavItem: NavigationItem = .home
    @Published public var urlToDownload: String = ""
    @Published public var rawCookiesToDownload: String? = nil
    
    public init() {}
}
