//
//  ReleaseNotesService.swift
//  Siphon
//

import Foundation
import SwiftUI

struct ReleaseFeature: Identifiable, Sendable, Equatable {
    let id: UUID
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    init(id: UUID = UUID(), icon: String, iconColor: Color, title: String, description: String) {
        self.id = id
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.description = description
    }
}

@MainActor
final class ReleaseNotesService {
    private let userDefaults: UserDefaults

    static let defaultFeatures: [ReleaseFeature] = [
        ReleaseFeature(
            icon: "arrow.clockwise.icloud.fill",
            iconColor: .orange,
            title: "Durable Queue Recovery",
            description: "Interrupted download jobs are atomically persisted across state changes, offering one-click queue restoration after unexpected crashes."
        ),
        ReleaseFeature(
            icon: "lock.shield.fill",
            iconColor: .green,
            title: "Secure Browser Handoff",
            description: "Browser extensions no longer put raw cookies in custom URLs; browser identity is validated and scoped to the target origin."
        ),
        ReleaseFeature(
            icon: "arrow.triangle.2.circlepath.circle.fill",
            iconColor: .blue,
            title: "Reliable Pause & Resume",
            description: "Per-download scratch directories preserve resumable partial data while cancellation keeps executor ownership until teardown completes."
        ),
        ReleaseFeature(
            icon: "checkmark.seal.fill",
            iconColor: .purple,
            title: "Hardened Update Pipeline",
            description: "Pinned release digests, rollback safety, stale-operation protection, and download/update exclusion keep dependency replacement deterministic."
        ),
        ReleaseFeature(
            icon: "network.badge.shield.half.filled",
            iconColor: .cyan,
            title: "Protected-Site Recovery",
            description: "Expanded protected-site and browser-session handling preserves the correct browser and transport identity."
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

                let lower = cleanTitle.lowercased() + " " + cleanDesc.lowercased()
                let icon: String
                let color: Color
                if lower.contains("font") || lower.contains("typography") || lower.contains("rebrand") || lower.contains("geist") {
                    icon = "textformat"
                    color = .purple
                } else if lower.contains("glass") || lower.contains("translucen") || lower.contains("material") || lower.contains("ui") || lower.contains("layout") {
                    icon = "macwindow"
                    color = .cyan
                } else if lower.contains("anti-bot") || lower.contains("stream") || lower.contains("engine") || lower.contains("download") || lower.contains("speed") {
                    icon = "bolt.fill"
                    color = .blue
                } else if lower.contains("menu bar") || lower.contains("status bar") || lower.contains("menubar") {
                    icon = "menubar.rectangle"
                    color = .indigo
                } else if lower.contains("security") || lower.contains("cookie") || lower.contains("privacy") || lower.contains("sandbox") {
                    icon = "shield.checkerboard"
                    color = .green
                } else if lower.contains("accessib") || lower.contains("voiceover") || lower.contains("tooltip") || lower.contains("optim") {
                    icon = "accessibility"
                    color = .orange
                } else {
                    icon = "sparkles"
                    color = .blue
                }

                features.append(ReleaseFeature(icon: icon, iconColor: color, title: cleanTitle, description: cleanDesc))
            }
        }

        return features.isEmpty ? Self.defaultFeatures : features
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
            let cleanTag = tagName.replacingOccurrences(of: "v", with: "")
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
        let title: String
        let features: [ReleaseFeature]
    }

    func checkAndFetchWhatsNew(appVersion: String, languageService: LanguageService?, session: URLSession = .shared) async -> WhatsNewCheckResult? {
        let lastSeenVersion = userDefaults.string(forKey: UserDefaultsKeys.lastSeenVersion)
        let isFirstEverRun = (lastSeenVersion == nil || lastSeenVersion?.isEmpty == true || lastSeenVersion == "0.0.0")
        let isAppUpdated = (lastSeenVersion != nil && lastSeenVersion != appVersion && !isFirstEverRun)

        guard isFirstEverRun || isAppUpdated else {
            return nil
        }

        let title = languageService?.s("whats_new_title") ?? "What's New in Siphon"
        var features = Self.defaultFeatures

        if let releaseInfo = await fetchReleaseNotesFromGitHub(version: appVersion, session: session) {
            let parsed = parseReleaseFeatures(from: releaseInfo.body)
            if !parsed.isEmpty {
                features = parsed
            }
        }

        userDefaults.set(appVersion, forKey: UserDefaultsKeys.lastSeenVersion)
        return WhatsNewCheckResult(shouldShow: true, title: title, features: features)
    }
}
