//
//  NavigationItem.swift
//  Siphon
//

import Foundation

public enum NavigationItem: String, CaseIterable, Identifiable, Sendable {
    case home
    case downloading
    case queued
    case completed
    case failed
    
    public var id: String { rawValue }
    
    func title(lang: LanguageService) -> String {
        switch self {
        case .home: return lang.s("home")
        case .downloading: return lang.s("downloading")
        case .queued: return lang.s("queued")
        case .completed: return lang.s("completed")
        case .failed: return lang.s("failed")
        }
    }
    
    public var icon: String {
        switch self {
        case .home: return "house.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .queued: return "clock.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
}
