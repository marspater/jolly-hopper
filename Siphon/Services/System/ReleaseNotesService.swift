//
//  ReleaseNotesService.swift
//  Siphon
//

import Foundation
import SwiftUI
import SiphonCore

struct ReleaseFeature: Identifiable, Sendable, Equatable {
    let id: UUID
    let icon: String
    let title: String
    let description: String

    init(id: UUID = UUID(), icon: String, title: String, description: String) {
        self.id = id
        self.icon = icon
        self.title = title
        self.description = description
    }
}

@MainActor
final class ReleaseNotesService {
    private let userDefaults: UserDefaults

    static let defaultFeatures: [ReleaseFeature] = [
        ReleaseFeature(
            icon: "network.badge.shield.half.filled",
            title: "Public-Network Boundary",
            description: "Downloads from browser links run through a local proxy that refuses private, loopback, and reserved destinations, including after redirects."
        ),
        ReleaseFeature(
            icon: "checkmark.seal.fill",
            title: "Signed Releases",
            description: "App updates must carry an Ed25519-signed release manifest; a release without one is refused instead of trusting its checksum alone."
        ),
        ReleaseFeature(
            icon: "checkmark.shield",
            title: "Pinned yt-dlp",
            description: "Siphon downloads a pinned, SHA-256-verified build of its yt-dlp fork, with DRM-format and byte-range download fixes."
        ),
        ReleaseFeature(
            icon: "macwindow",
            title: "Calmer Main Window",
            description: "The status strip only animates while downloading, downloads stay in arrival order, finished downloads no longer glow, and motion respects Reduce Motion."
        ),
        ReleaseFeature(
            icon: "textformat",
            title: "Geist Everywhere",
            description: "Every window, pop-up menu and button in Siphon uses Geist, with a new layered app icon in light, dark, and mono."
        )
    ]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func parseReleaseFeatures(from text: String) -> [ReleaseFeature] {
        var features: [ReleaseFeature] = []
        let lines = text.split(whereSeparator: \.isNewline)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("---") || trimmed.hasPrefix("===") {
                continue
            }

            var cleanLine = trimmed
            if cleanLine.hasPrefix("- ") || cleanLine.hasPrefix("* ") || cleanLine.hasPrefix("• ") {
                cleanLine = String(cleanLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }

            if let colonIndex = cleanLine.firstIndex(of: ":") {
                let rawTitle = String(cleanLine[..<colonIndex])
                let rawDesc = String(cleanLine[cleanLine.index(after: colonIndex)...])

                let cleanTitle = rawTitle.replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let cleanDesc = rawDesc.replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !cleanTitle.isEmpty && !cleanDesc.isEmpty else { continue }

                let icon = Self.icon(title: cleanTitle, description: cleanDesc)

                features.append(ReleaseFeature(icon: icon, title: cleanTitle, description: cleanDesc))
            }
        }

        return features.isEmpty ? Self.defaultFeatures : features
    }

    /// Most specific topic first. Release notes mention downloads almost everywhere, so
    /// the title decides when it can and the description is only a fallback.
    private static let iconRules: [(keywords: [String], icon: String)] = [
        (["proxy", "network", "boundary", "egress", "redirect"], "network.badge.shield.half.filled"),
        (["signed", "signature", "manifest", "update", "updater"], "checkmark.seal.fill"),
        (["pinned", "sha-256", "verified", "yt-dlp", "ffmpeg", "dependenc"], "checkmark.shield"),
        (["cookie", "privacy", "security", "sandbox", "credential", "keychain"], "shield.checkerboard"),
        (["font", "typography", "geist"], "textformat"),
        (["app icon", "icon composer", "rebrand", "logo"], "app.badge"),
        (["play", "pause", "resume", "playback"], "play.circle"),
        (["list", "order", "sort", "queue", "move up", "move down"], "list.bullet.rectangle"),
        (["menu bar", "menubar", "status bar"], "menubar.rectangle"),
        (["accessib", "voiceover", "contrast"], "accessibility"),
        (["window", "glass", "translucen", "material", "layout", "motion", "palette", "calm"], "macwindow"),
        (["speed", "faster", "performance", "anti-bot", "stream", "engine", "optim"], "bolt.fill"),
        (["fix", "crash", "bug", "stability"], "wrench.and.screwdriver")
    ]

    static func icon(title: String, description: String) -> String {
        func match(_ text: String) -> String? {
            // Keywords match at a word start, so "play" skips "display" and "order" skips "border".
            let normalized = " " + String(text.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : " " })
            if normalized.contains(" ui ") || normalized.hasSuffix(" ui") { return "macwindow" }
            return iconRules.first { $0.keywords.contains { normalized.contains(" " + $0) } }?.icon
        }
        return match(title) ?? match(description) ?? "sparkles"
    }

    func sanitizeReleaseNotes(_ text: String) -> String {
        var sanitized = text.replacingOccurrences(of: "\r\n", with: "\n")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized
    }

    func fetchReleaseNotesFromGitHub(version: String, session: URLSession = .shared) async -> (title: String, body: String)? {
        guard let url = URL(string: "https://api.github.com/repos/marspater/jolly-hopper/releases/tags/v\(version)") else {
            return nil
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Siphon-App/\(version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                LoggerService.shared.log("Release notes request returned a non-HTTP response.", level: .warning)
                return nil
            }
            guard httpResponse.statusCode == 200 else {
                LoggerService.shared.log("Release notes request failed with HTTP \(httpResponse.statusCode).", level: .warning)
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                LoggerService.shared.log("Release notes response could not be parsed as a JSON object.", level: .warning)
                return nil
            }

            guard let tagName = json["tag_name"] as? String else {
                LoggerService.shared.log("Release notes response did not contain a tag name.", level: .warning)
                return nil
            }
            let trimmedTag = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTag = trimmedTag.lowercased().hasPrefix("v") ? String(trimmedTag.dropFirst()) : trimmedTag
            if cleanTag.compare(version, options: .numeric) == .orderedAscending {
                return nil
            }

            let title = (json["name"] as? String) ?? "What's New in Siphon"
            var rawBody = (json["body"] as? String) ?? ""
            rawBody = sanitizeReleaseNotes(rawBody)

            if !rawBody.isEmpty {
                return (title: title, body: rawBody)
            }
        } catch is CancellationError {
            LoggerService.shared.log("Release notes request was cancelled.", level: .debug)
            return nil
        } catch {
            LoggerService.shared.log("Failed to fetch release notes: \(error.localizedDescription)", level: .warning)
            return nil
        }
        return nil
    }

    struct WhatsNewCheckResult {
        let shouldShow: Bool
        let features: [ReleaseFeature]
    }

    func checkAndFetchWhatsNew(appVersion: String, session: URLSession = .shared) async -> WhatsNewCheckResult? {
        let lastSeenVersion = userDefaults.string(forKey: UserDefaultsKeys.lastSeenVersion)
        let isFirstEverRun = (lastSeenVersion == nil || lastSeenVersion?.isEmpty == true || lastSeenVersion == "0.0.0")
        let isAppUpdated = (lastSeenVersion != nil && lastSeenVersion != appVersion && !isFirstEverRun)

        guard isFirstEverRun || isAppUpdated else {
            return nil
        }

        var features = Self.defaultFeatures

        if let releaseInfo = await fetchReleaseNotesFromGitHub(version: appVersion, session: session) {
            let parsed = parseReleaseFeatures(from: releaseInfo.body)
            if !parsed.isEmpty {
                features = parsed
            }
        }

        userDefaults.set(appVersion, forKey: UserDefaultsKeys.lastSeenVersion)
        return WhatsNewCheckResult(shouldShow: true, features: features)
    }
}
