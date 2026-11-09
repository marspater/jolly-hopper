import Foundation

public enum UserDefaultsKeys {
    public static let showMenuBarIcon = "showMenuBarIcon"
    public static let showNotifications = "showNotifications"
    public static let customPresets = "customPresets"
    public static let defaultSaveFolder = "defaultSaveFolder"
    public static let lastSeenVersion = "lastSeenVersion_v3"
    public static let downloadHistory = "downloadHistory"
    public static let browserForCookies = "browserForCookies"
    public static let launchAtLogin = "launchAtLogin"
    public static let theme = "theme"
    public static let maxConcurrentDownloads = "maxConcurrentDownloads"
    public static let embedThumbnail = "embedThumbnail"
    public static let embedMetadata = "embedMetadata"
    public static let defaultFileType = "defaultFileType"
    public static let defaultVideoResolution = "defaultVideoResolution"
    public static let defaultVideoCodec = "defaultVideoCodec"
    public static let defaultAudioCodec = "defaultAudioCodec"
    public static let selectedPreset = "selectedPreset"
    public static let sponsorBlock = "sponsorBlock"
    public static let defaultAdditionalArguments = "defaultAdditionalArguments"
    public static let startInBackground = "startInBackground"
    public static let selectedCustomPresetId = "selectedCustomPresetId"
    public static let downloadSpeedLimit = "downloadSpeedLimit"
    public static let resolutionFallbackPolicy = "resolutionFallbackPolicy"
    public static let customYtdlpPath = "customYtdlpPath"
}

public extension UserDefaults {
    /// Observable mirror of `UserDefaultsKeys.maxConcurrentDownloads`. KVO
    /// matches the property name to the key, so the two must stay equal.
    @objc dynamic var maxConcurrentDownloads: Int {
        integer(forKey: UserDefaultsKeys.maxConcurrentDownloads)
    }
}
