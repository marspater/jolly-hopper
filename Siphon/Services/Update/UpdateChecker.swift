//
//  UpdateChecker.swift
//  Siphon
//

import Foundation
import AppKit

@MainActor
public final class UpdateChecker: ObservableObject {
    @Published public var isChecking: Bool = false
    @Published public var hasUpdate: Bool = false
    @Published public var latestVersion: String?
    @Published public var showUpToDateMessage: Bool = false
    @Published public var isDownloading: Bool = false
    @Published public var updateProgress: Double = 0
    @Published public var isInstalling: Bool = false
    @Published public var needsRestart: Bool = false
    @Published public var updateError: String?
    @Published public var releasePageURL: URL? = URL(string: "https://github.com/marspater/jolly-hopper/releases/latest")

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "5.5.0"
    }

    private let repoOwner = "marspater"
    private let repoName = "jolly-hopper"
    private var downloadURL: URL?
    private var downloadAssetName: String?
    private var expectedChecksum: String?
    private var checksumURL: URL?
    public private(set) var manifestURL: URL?
    public private(set) var manifestSigURL: URL?
    public var requireSignedManifest: Bool
    private var updateOperationID: UUID?

    private let downloader: UpdateDownloader
    private let installer = UpdateInstaller()
    private let manifestVerifier: UpdateManifestVerifier
    private let fetchManifestData: @Sendable (URL) async throws -> Data

    struct ReleaseCandidate: Sendable {
        let version: String
        let assetName: String
        let downloadURL: URL?
        let checksum: String?
        let checksumURL: URL?
        let manifestURL: URL?
        let signatureURL: URL?
        let requiresSignature: Bool
    }

    var releaseCandidate: ReleaseCandidate {
        ReleaseCandidate(version: latestVersion ?? "", assetName: downloadAssetName ?? "",
                         downloadURL: downloadURL, checksum: expectedChecksum, checksumURL: checksumURL,
                         manifestURL: manifestURL, signatureURL: manifestSigURL,
                         requiresSignature: requireSignedManifest || Self.releaseRequiresSignedManifest(latestVersion))
    }

    public init(
        downloader: UpdateDownloader = UpdateDownloader(),
        manifestVerifier: UpdateManifestVerifier = UpdateManifestVerifier(),
        requireSignedManifest: Bool = false,
        fetchManifestData: @escaping @Sendable (URL) async throws -> Data = { try await UpdateDownloader.fetchData(from: $0) }
    ) {
        self.downloader = downloader
        self.manifestVerifier = manifestVerifier
        self.requireSignedManifest = requireSignedManifest
        self.fetchManifestData = fetchManifestData
    }

    /// The last release published without a signed manifest. Every newer release
    /// must carry one; otherwise leaving the manifest out of a release would skip
    /// signature verification entirely. Sign releases with
    /// `scripts/sign-release-manifest.swift`.
    nonisolated static let lastUnsignedRelease = "5.4.5"

    nonisolated static func releaseRequiresSignedManifest(_ version: String?) -> Bool {
        guard let version, !version.isEmpty else { return true }
        return version.compare(lastUnsignedRelease, options: .numeric) == .orderedDescending
    }

    /// The release's installer archive. Release assets follow one contract,
    /// `Siphon-<tag>[-<arch>].dmg|zip`; any other archive (symbols, helpers) is ignored.
    nonisolated static func installerAsset(in assets: [[String: Any]], tag: String) -> [String: Any]? {
        #if arch(arm64)
        let archSuffixes = ["-arm64", "-aarch64", "-universal", ""]
        #else
        let archSuffixes = ["-x86_64", "-intel", "-universal", ""]
        #endif
        let lowerTag = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanTag = lowerTag.hasPrefix("v") ? String(lowerTag.dropFirst()) : lowerTag
        var accepted: [String] = []
        for arch in archSuffixes {
            for ext in ["dmg", "zip"] {
                for prefix in [cleanTag, "v" + cleanTag] {
                    accepted.append("siphon-\(prefix)\(arch).\(ext)")
                }
            }
        }
        let byName = Dictionary(
            assets.compactMap { asset in (asset["name"] as? String).map { ($0.lowercased(), asset) } },
            uniquingKeysWith: { first, _ in first }
        )
        return accepted.lazy.compactMap { byName[$0] }.first
    }

    nonisolated static func parseGitHubAssetSHA256(_ digest: String?) -> String? {
        guard let digest = digest?.trimmingCharacters(in: .whitespacesAndNewlines),
              digest.lowercased().hasPrefix("sha256:") else {
            return nil
        }
        let hash = String(digest.dropFirst("sha256:".count)).lowercased()
        guard hash.count == 64,
              hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return nil
        }
        return hash
    }

    public func checkForUpdates(manual: Bool = false) async {
        guard !isChecking, updateOperationID == nil, !needsRestart else { return }
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            let message = "Could not construct the GitHub releases URL."
            LoggerService.shared.log(message, level: .error)
            if manual {
                NotificationService.shared.sendAppUpdateNotification(title: "Update Check Failed", body: message)
            }
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Siphon-App/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                throw NSError(domain: "UpdateChecker", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "GitHub returned HTTP \(httpResponse.statusCode)"])
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  !tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(
                    domain: "UpdateChecker",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "GitHub returned a malformed release response."]
                )
            }

            let trimmedTag = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTag = (trimmedTag.hasPrefix("v") || trimmedTag.hasPrefix("V"))
                ? String(trimmedTag.dropFirst())
                : trimmedTag
            latestVersion = cleanTag
            hasUpdate = cleanTag.compare(currentVersion, options: .numeric) == .orderedDescending

            if let htmlUrlStr = json["html_url"] as? String, let htmlUrl = URL(string: htmlUrlStr) {
                releasePageURL = htmlUrl
            }

            downloadURL = nil
            downloadAssetName = nil
            expectedChecksum = nil
            checksumURL = nil
            manifestURL = nil
            manifestSigURL = nil

            if let assets = json["assets"] as? [[String: Any]],
               let dlpAsset = Self.installerAsset(in: assets, tag: trimmedTag),
               let downloadUrlStr = dlpAsset["browser_download_url"] as? String {
                downloadURL = URL(string: downloadUrlStr)
                let assetName = (dlpAsset["name"] as? String) ?? ""
                downloadAssetName = assetName
                expectedChecksum = Self.parseGitHubAssetSHA256(dlpAsset["digest"] as? String)

                let lowerAssetName = assetName.lowercased()
                if let sumAsset = assets.first(where: {
                    let name = ($0["name"] as? String)?.lowercased() ?? ""
                    return name == "\(lowerAssetName).sha256" ||
                           name == "\(lowerAssetName).sha256.txt" ||
                           name == "\(lowerAssetName).sha256sum" ||
                           name == "sha256sums.txt" ||
                           name == "checksums.txt" ||
                           name == "sha256sum.txt" ||
                           name == "checksums.sha256"
                }), let sumUrlStr = sumAsset["browser_download_url"] as? String {
                    checksumURL = URL(string: sumUrlStr)
                }

                if let manifestAsset = assets.first(where: {
                    let name = ($0["name"] as? String)?.lowercased() ?? ""
                    return name == "release-manifest.json" ||
                           name == "manifest.json" ||
                           name == "release_manifest.json"
                }), let mUrlStr = manifestAsset["browser_download_url"] as? String {
                    manifestURL = URL(string: mUrlStr)
                }

                if let sigAsset = assets.first(where: {
                    let name = ($0["name"] as? String)?.lowercased() ?? ""
                    return name == "release-manifest.json.sig" ||
                           name == "manifest.json.sig" ||
                           name == "release-manifest.sig" ||
                           name == "manifest.sig" ||
                           name == "release_manifest.json.sig"
                }), let sUrlStr = sigAsset["browser_download_url"] as? String {
                    manifestSigURL = URL(string: sUrlStr)
                }
            }

            if !hasUpdate {
                    showUpToDateMessage = true
                    if manual {
                        NotificationService.shared.sendAppUpdateNotification(
                            title: "Siphon is Up to Date",
                            body: "Version \(currentVersion) is the latest version available."
                        )
                    }
                    Task { @MainActor [weak self] in
                        do {
                            try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                        } catch is CancellationError {
                            return
                        } catch {
                            LoggerService.shared.log("Unexpected update-message timer failure: \(error.localizedDescription)", level: .warning)
                            return
                        }
                        self?.showUpToDateMessage = false
                    }
            } else if manual {
                NotificationService.shared.sendAppUpdateNotification(
                    title: "Update Available",
                    body: "Siphon v\(cleanTag) is now available."
                )
            }
        } catch is CancellationError {
            LoggerService.shared.log("App update check was cancelled.", level: .debug)
        } catch {
            LoggerService.shared.log("Failed to check for app updates: \(error.localizedDescription)", level: .warning)
            if latestVersion == nil {
                latestVersion = currentVersion
            }
            hasUpdate = false
            if manual {
                NotificationService.shared.sendAppUpdateNotification(
                    title: "Update Check Failed",
                    body: error.localizedDescription
                )
            }
        }
    }

    public func downloadAndInstallUpdate() async {
        guard updateOperationID == nil, !isChecking, !needsRestart else { return }
        let candidate = releaseCandidate
        let operationID = UUID()
        updateOperationID = operationID
        defer {
            if updateOperationID == operationID {
                updateOperationID = nil
            }
        }

        guard let url = candidate.downloadURL, UpdateDownloader.isTrustedGitHubURL(url) else {
            if let pageURL = releasePageURL {
                NSWorkspace.shared.open(pageURL)
            }
            return
        }

        guard let verifiedChecksum = await verifyUpdateChecksum(candidate: candidate, operationID: operationID) else {
            return
        }

        guard updateOperationID == operationID else { return }

        await performUpdateDownloadAndInstall(url: url, verifiedChecksum: verifiedChecksum,
                                              expectedVersion: candidate.version, operationID: operationID)
    }

    private func verifyUpdateChecksum(candidate: ReleaseCandidate, operationID: UUID) async -> String? {
        var verifiedChecksum = candidate.checksum

        if candidate.manifestURL != nil || candidate.signatureURL != nil || candidate.requiresSignature {
            guard let manifest = await verifySignedReleaseManifest(candidate: candidate, operationID: operationID, existingChecksum: verifiedChecksum) else {
                return nil
            }
            return manifest
        }

        if let checksumURL = candidate.checksumURL {
            guard let published = await fetchAndVerifyChecksumManifest(url: checksumURL, candidate: candidate, operationID: operationID, existingChecksum: verifiedChecksum) else {
                return nil
            }
            verifiedChecksum = published
        }

        guard let finalChecksum = verifiedChecksum, !finalChecksum.isEmpty else {
            let message = "The selected GitHub release asset has no verifiable SHA-256 digest."
            updateError = UpdateDownloadError.checksumUnavailable(message).localizedDescription
            LoggerService.shared.log("Refusing app update without a pinned SHA-256 digest.", level: .error)
            return nil
        }
        return finalChecksum
    }

    private func verifySignedReleaseManifest(candidate: ReleaseCandidate, operationID: UUID, existingChecksum: String?) async -> String? {
        guard let mURL = candidate.manifestURL, let sURL = candidate.signatureURL else {
            let message = "A signed release manifest and signature are required to verify this update."
            updateError = UpdateDownloadError.checksumUnavailable(message).localizedDescription
            LoggerService.shared.log(message, level: .error)
            return nil
        }
        guard UpdateDownloader.isTrustedGitHubURL(mURL) && UpdateDownloader.isTrustedGitHubURL(sURL) else {
            updateError = UpdateDownloadError.invalidURL.localizedDescription
            LoggerService.shared.log("Refusing untrusted manifest URL for app update.", level: .error)
            return nil
        }
        do {
            let manifestData = try await fetchManifestData(mURL)
            let signatureData = try await fetchManifestData(sURL)
            guard updateOperationID == operationID else { return nil }

            let manifestChecksum = try manifestVerifier.verify(
                manifestData: manifestData,
                signatureData: signatureData,
                expectedVersion: candidate.version,
                targetAssetName: candidate.assetName
            )
            guard updateOperationID == operationID else { return nil }

            if let current = existingChecksum, current.lowercased() != manifestChecksum.lowercased() {
                let message = "GitHub asset digest does not match the signed release manifest."
                updateError = UpdateDownloadError.checksumUnavailable(message).localizedDescription
                LoggerService.shared.log(message, level: .error)
                return nil
            }
            return manifestChecksum
        } catch is CancellationError {
            return nil
        } catch {
            guard updateOperationID == operationID else { return nil }
            updateError = error.localizedDescription
            LoggerService.shared.log("Signed manifest verification failed: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    private func fetchAndVerifyChecksumManifest(url: URL, candidate: ReleaseCandidate, operationID: UUID, existingChecksum: String?) async -> String? {
        guard UpdateDownloader.isTrustedGitHubURL(url) else {
            updateError = UpdateDownloadError.invalidURL.localizedDescription
            LoggerService.shared.log("Refusing untrusted checksum URL for app update.", level: .error)
            return nil
        }
        do {
            let manifestChecksum = try await UpdateDownloader.fetchExpectedChecksum(
                from: url,
                targetAssetName: candidate.assetName
            )
            guard updateOperationID == operationID else { return nil }
            if let apiChecksum = existingChecksum, apiChecksum.lowercased() != manifestChecksum.lowercased() {
                let message = "GitHub asset digest does not match the published checksum manifest."
                updateError = UpdateDownloadError.checksumUnavailable(message).localizedDescription
                LoggerService.shared.log(message, level: .error)
                return nil
            }
            return manifestChecksum
        } catch is CancellationError {
            return nil
        } catch {
            guard updateOperationID == operationID else { return nil }
            updateError = error.localizedDescription
            LoggerService.shared.log("Update checksum verification could not be prepared: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    private func performUpdateDownloadAndInstall(
        url: URL,
        verifiedChecksum: String,
        expectedVersion: String,
        operationID: UUID
    ) async {
        isDownloading = true
        updateProgress = 0
        updateError = nil

        do {
            let downloadedPkgURL = try await downloader.download(from: url) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard self?.updateOperationID == operationID else { return }
                    self?.updateProgress = progress
                }
            }

            guard updateOperationID == operationID else {
                cleanupCancelledPackage(downloadedPkgURL)
                return
            }

            isDownloading = false
            isInstalling = true

            try await installer.install(
                packageURL: downloadedPkgURL,
                expectedChecksum: verifiedChecksum,
                expectedTeamID: nil,
                allowAdHoc: true,
                expectedVersion: expectedVersion
            )

            isInstalling = false
            needsRestart = true
            LoggerService.shared.log("Update installed successfully.", level: .info)
        } catch {
            handleInstallFailure(error, operationID: operationID)
        }
    }

    private func cleanupCancelledPackage(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            LoggerService.shared.log("Failed to remove cancelled update package: \(error.localizedDescription)", level: .warning)
        }
    }

    private func handleInstallFailure(_ error: Error, operationID: UUID) {
        guard updateOperationID == operationID else { return }
        isDownloading = false
        isInstalling = false
        updateProgress = 0
        switch error {
        case UpdateDownloadError.downloadCancelled:
            updateError = nil
            LoggerService.shared.log("App update download was cancelled.", level: .info)
        case is CancellationError:
            downloader.cancel()
            updateError = nil
            LoggerService.shared.log("App update task was cancelled.", level: .info)
        default:
            updateError = error.localizedDescription
            LoggerService.shared.log("Update download or install failed: \(error.localizedDescription)", level: .error)
        }
    }

    @preconcurrency
    public func restartApp(prepare: @MainActor () -> Void) {
        UpdateInstaller.restartApp(prepare: prepare)
    }

    /// Test seam: seeds what `checkForUpdates` would discover. Internal (not
    /// `#if DEBUG`) so `@testable` Release test runs in CI can reach it too.
    func configureUpdateSources(
        downloadURL: URL?,
        downloadAssetName: String?,
        expectedChecksum: String? = nil,
        checksumURL: URL? = nil,
        manifestURL: URL? = nil,
        manifestSigURL: URL? = nil,
        latestVersion: String? = nil
    ) {
        self.downloadURL = downloadURL
        self.downloadAssetName = downloadAssetName
        self.expectedChecksum = expectedChecksum
        self.checksumURL = checksumURL
        self.manifestURL = manifestURL
        self.manifestSigURL = manifestSigURL
        if let latestVersion {
            self.latestVersion = latestVersion
        }
    }

    // MARK: - Compatibility & Static Verification Helpers

    nonisolated public static func isTrustedGitHubURL(_ url: URL) -> Bool {
        UpdateDownloader.isTrustedGitHubURL(url)
    }

    nonisolated public static func computeSHA256(for fileURL: URL) -> String? {
        try? UpdateVerifier.computeSHA256(for: fileURL)
    }
}
