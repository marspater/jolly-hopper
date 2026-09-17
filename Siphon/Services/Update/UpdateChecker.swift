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
    @Published public var updateError: String? = nil
    @Published public var releasePageURL: URL? = URL(string: "https://github.com/marspater/jolly-hopper/releases/latest")

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "5.2.0"
    }

    private let repoOwner = "marspater"
    private let repoName = "jolly-hopper"
    private var downloadURL: URL?
    private var downloadAssetName: String?
    private var expectedChecksum: String?
    private var checksumURL: URL?

    private let downloader = UpdateDownloader()
    private let installer = UpdateInstaller()

    public init() {}

    public func cancelUpdate() {
        downloader.cancel()
        downloadURL = nil
        downloadAssetName = nil
        expectedChecksum = nil
        checksumURL = nil
        isDownloading = false
        isInstalling = false
        updateProgress = 0
    }

    public func checkForUpdates(manual: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            isChecking = false
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
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String {

                let cleanTag = tagName.replacingOccurrences(of: "v", with: "")
                latestVersion = cleanTag
                hasUpdate = cleanTag.compare(currentVersion, options: .numeric) == .orderedDescending

                if let htmlUrlStr = json["html_url"] as? String, let htmlUrl = URL(string: htmlUrlStr) {
                    releasePageURL = htmlUrl
                }

                downloadURL = nil
                downloadAssetName = nil
                expectedChecksum = nil
                checksumURL = nil

                if let assets = json["assets"] as? [[String: Any]] {
                    #if arch(arm64)
                    let targetArch = "arm64"
                    let altArch = "aarch64"
                    let nonTargetArch = "x86_64"
                    #else
                    let targetArch = "x86_64"
                    let altArch = "intel"
                    let nonTargetArch = "arm64"
                    #endif

                    let sortedAssets = assets.sorted { a, b in
                        let nameA = (a["name"] as? String)?.lowercased() ?? ""
                        let nameB = (b["name"] as? String)?.lowercased() ?? ""

                        let aMatchesTarget = nameA.contains(targetArch) || nameA.contains(altArch) || nameA.contains("universal")
                        let bMatchesTarget = nameB.contains(targetArch) || nameB.contains(altArch) || nameB.contains("universal")
                        let aMatchesNonTarget = nameA.contains(nonTargetArch)
                        let bMatchesNonTarget = nameB.contains(nonTargetArch)

                        if aMatchesTarget && !bMatchesTarget { return true }
                        if !aMatchesTarget && bMatchesTarget { return false }
                        if !aMatchesNonTarget && bMatchesNonTarget { return true }
                        if aMatchesNonTarget && !bMatchesNonTarget { return false }

                        if nameA.hasSuffix(".dmg") && !nameB.hasSuffix(".dmg") { return true }
                        return false
                    }

                    if let dlpAsset = sortedAssets.first(where: {
                        let name = ($0["name"] as? String)?.lowercased() ?? ""
                        return name.hasSuffix(".dmg") || name.hasSuffix(".zip") || name.hasSuffix(".app.zip")
                    }), let downloadUrlStr = dlpAsset["browser_download_url"] as? String {
                        downloadURL = URL(string: downloadUrlStr)
                        let assetName = (dlpAsset["name"] as? String) ?? ""
                        downloadAssetName = assetName

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
                        try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                        self?.showUpToDateMessage = false
                    }
                } else if manual {
                    NotificationService.shared.sendAppUpdateNotification(
                        title: "Update Available",
                        body: "Siphon v\(cleanTag) is now available."
                    )
                }
            }
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
        isChecking = false
    }

    public func downloadAndInstallUpdate() async {
        guard let url = downloadURL, UpdateDownloader.isTrustedGitHubURL(url) else {
            if let pageURL = releasePageURL {
                NSWorkspace.shared.open(pageURL)
            }
            return
        }

        // 1. Fetch checksum in background if available
        if let cURL = checksumURL, UpdateDownloader.isTrustedGitHubURL(cURL) {
            expectedChecksum = await UpdateDownloader.fetchExpectedChecksum(
                from: cURL,
                targetAssetName: downloadAssetName ?? ""
            )
        }

        isDownloading = true
        updateProgress = 0
        updateError = nil

        do {
            let downloadedPkgURL = try await downloader.download(from: url) { [weak self] progress in
                Task { @MainActor in
                    self?.updateProgress = progress
                }
            }

            isDownloading = false
            isInstalling = true

            try await installer.install(
                packageURL: downloadedPkgURL,
                expectedChecksum: expectedChecksum,
                expectedTeamID: nil,
                allowAdHoc: true
            )

            isInstalling = false
            needsRestart = true
            LoggerService.shared.log("Update installed successfully.", level: .info)
        } catch {
            isDownloading = false
            isInstalling = false
            updateError = error.localizedDescription
            LoggerService.shared.log("Update download or install failed: \(error.localizedDescription)", level: .error)
        }
    }

    public func restartApp() {
        UpdateInstaller.restartApp()
    }

    // MARK: - Compatibility & Static Verification Helpers

    nonisolated public static func isTrustedGitHubURL(_ url: URL) -> Bool {
        UpdateDownloader.isTrustedGitHubURL(url)
    }

    nonisolated public static func computeSHA256(for fileURL: URL) -> String? {
        try? UpdateVerifier.computeSHA256(for: fileURL)
    }

    nonisolated public static func generateUpdateScript() -> String {
        return """
        (
            set -e
            STATUS_FILE="${6:-${STATUS_FILE:-}}"
            MOUNT_POINT=""
            report_failure() {
                if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
                    hdiutil unmount "$MOUNT_POINT" -quiet 2>/dev/null || true
                fi
                if [ -n "$STATUS_FILE" ]; then
                    echo '{"status":"FAILED"}' > "$STATUS_FILE"
                fi
            }
            report_success() {
                if [ -n "$STATUS_FILE" ]; then
                    echo '{"status":"SUCCESS"}' > "$STATUS_FILE"
                fi
            }
            trap report_failure ERR

            sleep 2
            
            PKG_PATH="${1:-${PKG_PATH:-}}"
            APP_PATH="${2:-${APP_PATH:-}}"
            WORK_DIR="${3:-${WORK_DIR:-}}"
            EXPECTED_BUNDLE_ID="${4:-${EXPECTED_BUNDLE_ID:-}}"
            EXPECTED_TEAM_ID="${5:-${EXPECTED_TEAM_ID:-}}"
            
            mkdir -p "$WORK_DIR"

            # Step 1: Unpack into staging directory
            if file "$PKG_PATH" | grep -q "Zip archive"; then
                /usr/bin/unzip -q "$PKG_PATH" -d "$WORK_DIR"
            else
                MOUNT_POINT="$WORK_DIR/mount"
                mkdir -p "$MOUNT_POINT"
                hdiutil mount "$PKG_PATH" -mountpoint "$MOUNT_POINT" -quiet -nobrowse || { report_failure; exit 1; }
            fi
            
            SEARCH_DIR="${MOUNT_POINT:-$WORK_DIR}"
            NEW_APP="$(find "$SEARCH_DIR" -maxdepth 2 -name "*.app" | head -n 1)"
            
            if [ -z "$NEW_APP" ] || [ ! -d "$NEW_APP" ] || [ -L "$NEW_APP" ]; then
                echo "No application bundle found in update payload"
                if [ -n "$MOUNT_POINT" ]; then
                    hdiutil unmount "$MOUNT_POINT" -quiet 2>/dev/null || true
                fi
                rm -rf "$WORK_DIR" "$PKG_PATH"
                report_failure
                exit 1
            fi
            
            # Step 2: Verify Code Signature Integrity & Team Identifier
            if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$NEW_APP" 2>/dev/null; then
                echo "Code signature verification failed on new app payload"
                if [ -n "$MOUNT_POINT" ]; then
                    hdiutil unmount "$MOUNT_POINT" -quiet 2>/dev/null || true
                fi
                rm -rf "$WORK_DIR" "$PKG_PATH"
                report_failure
                exit 1
            fi

            if [ -n "$EXPECTED_TEAM_ID" ]; then
                NEW_TEAM_ID="$(/usr/bin/codesign -d --verbose=2 "$NEW_APP" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}' || true)"
                if [ "$NEW_TEAM_ID" != "$EXPECTED_TEAM_ID" ]; then
                    echo "Team identifier mismatch: expected $EXPECTED_TEAM_ID, got $NEW_TEAM_ID"
                    if [ -n "$MOUNT_POINT" ]; then
                        hdiutil unmount "$MOUNT_POINT" -quiet 2>/dev/null || true
                    fi
                    rm -rf "$WORK_DIR" "$PKG_PATH"
                    report_failure
                    exit 1
                fi
            fi
            
            # Step 3: Verify Bundle Identifier matches
            NEW_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$NEW_APP/Contents/Info.plist" 2>/dev/null || true)"
            if [ -n "$EXPECTED_BUNDLE_ID" ] && [ "$NEW_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
                echo "Bundle identifier mismatch: expected $EXPECTED_BUNDLE_ID, got $NEW_BUNDLE_ID"
                if [ -n "$MOUNT_POINT" ]; then
                    hdiutil unmount "$MOUNT_POINT" -quiet 2>/dev/null || true
                fi
                rm -rf "$WORK_DIR" "$PKG_PATH"
                report_failure
                exit 1
            fi
            
            # Step 4: Atomic Swap with Backup and Rollback
            BACKUP_PATH="${APP_PATH}.backup.$$"
            
            # Move existing app to backup
            if ! mv "$APP_PATH" "$BACKUP_PATH"; then
                echo "Failed to create atomic backup of existing app bundle"
                if [ -n "$MOUNT_POINT" ]; then
                    hdiutil unmount "$MOUNT_POINT" -quiet 2>/dev/null || true
                fi
                rm -rf "$WORK_DIR" "$PKG_PATH"
                report_failure
                exit 1
            fi
            
            # Copy new app to target location
            if ditto "$NEW_APP" "$APP_PATH"; then
                # Verify that installed app is present and intact
                if [ -d "$APP_PATH" ] && /usr/bin/codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
                    # Success: remove backup and clean up staging
                    rm -rf "$BACKUP_PATH"
                    if [ -n "$MOUNT_POINT" ]; then
                        hdiutil unmount "$MOUNT_POINT" -quiet 2>/dev/null || true
                    fi
                    rm -rf "$WORK_DIR" "$PKG_PATH"
                    report_success
                    open "$APP_PATH"
                    exit 0
                else
                    # Verification of installed target failed -> rollback
                    rm -rf "$APP_PATH"
                    mv "$BACKUP_PATH" "$APP_PATH"
                    if [ -n "$MOUNT_POINT" ]; then
                        hdiutil unmount "$MOUNT_POINT" -quiet 2>/dev/null || true
                    fi
                    rm -rf "$WORK_DIR" "$PKG_PATH"
                    report_failure
                    exit 1
                fi
            else
                # Copy failed -> rollback
                mv "$BACKUP_PATH" "$APP_PATH"
                if [ -n "$MOUNT_POINT" ]; then
                    hdiutil unmount "$MOUNT_POINT" -quiet 2>/dev/null || true
                fi
                rm -rf "$WORK_DIR" "$PKG_PATH"
                report_failure
                exit 1
            fi
        )
        """
    }
}

