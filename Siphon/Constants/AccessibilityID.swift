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
    static let rowNewName = "row-new-name"
    static let rowRevealExisting = "row-reveal-existing"
    static let rowCancel = "row-cancel"
    static let rowRemove = "row-remove"
    static let rowMore = "row-more"
    static let existingFileOverwrite = "existing-file-overwrite"
    static let existingFileNewName = "existing-file-new-name"
    static let existingFileCancel = "existing-file-cancel"
    static let checkForUpdates = "check-for-updates"
    static let viewDebugLogs = "view-debug-logs"
    static let queueRecoveryRestore = "queue-recovery-restore"
    static let menuBarRow = "menu-bar-row"
    static let sidebarToggle = "sidebar-toggle"

    static func settingsTab(_ tab: PreferencesView.PreferenceTab) -> String { "settings-tab-\(tab)" }
    static func statusSegment(_ item: NavigationItem) -> String { "status-segment-\(item)" }
    static func sidebarItem(_ item: NavigationItem) -> String { "sidebar-\(item)" }
}
