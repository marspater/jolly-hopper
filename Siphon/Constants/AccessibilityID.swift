/// Stable identifiers for UI tests. Labels are user-facing and change with copy edits.
enum AccessibilityID {
    static let heroURLField = "hero-url-field"
    static let heroSubmit = "hero-submit"
    static let addDownloadURLField = "add-download-url-field"
    static let addDownloadSubmit = "add-download-submit"
    static let queueRowTitle = "queue-row-title"
    static let rowPause = "row-pause"
    static let rowResume = "row-resume"
    static let rowRetry = "row-retry"
    static let rowOverwrite = "row-overwrite"
    static let checkForUpdates = "check-for-updates"
    static let queueRecoveryRestore = "queue-recovery-restore"
    static let menuBarRow = "menu-bar-row"

    static func statusSegment(_ item: NavigationItem) -> String { "status-segment-\(item)" }
}
