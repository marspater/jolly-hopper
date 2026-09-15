import XCTest
@testable import Siphon

final class UserDefaultsKeysTests: XCTestCase {
    func testUserDefaultsKeysValues() {
        XCTAssertEqual(UserDefaultsKeys.showMenuBarIcon, "showMenuBarIcon")
        XCTAssertEqual(UserDefaultsKeys.showNotifications, "showNotifications")
        XCTAssertEqual(UserDefaultsKeys.customPresets, "customPresets")
        XCTAssertEqual(UserDefaultsKeys.defaultSaveFolder, "defaultSaveFolder")
        XCTAssertEqual(UserDefaultsKeys.lastSeenVersion, "lastSeenVersion_v3")
        XCTAssertEqual(UserDefaultsKeys.downloadHistory, "downloadHistory")
        XCTAssertEqual(UserDefaultsKeys.browserForCookies, "browserForCookies")
        XCTAssertEqual(UserDefaultsKeys.launchAtLogin, "launchAtLogin")
        XCTAssertEqual(UserDefaultsKeys.theme, "theme")
        XCTAssertEqual(UserDefaultsKeys.maxConcurrentDownloads, "maxConcurrentDownloads")
        XCTAssertEqual(UserDefaultsKeys.embedThumbnail, "embedThumbnail")
        XCTAssertEqual(UserDefaultsKeys.embedMetadata, "embedMetadata")
        XCTAssertEqual(UserDefaultsKeys.defaultFileType, "defaultFileType")
        XCTAssertEqual(UserDefaultsKeys.defaultVideoResolution, "defaultVideoResolution")
        XCTAssertEqual(UserDefaultsKeys.defaultVideoCodec, "defaultVideoCodec")
        XCTAssertEqual(UserDefaultsKeys.defaultAudioCodec, "defaultAudioCodec")
        XCTAssertEqual(UserDefaultsKeys.selectedPreset, "selectedPreset")
        XCTAssertEqual(UserDefaultsKeys.sponsorBlock, "sponsorBlock")
        XCTAssertEqual(UserDefaultsKeys.defaultAdditionalArguments, "defaultAdditionalArguments")
        XCTAssertEqual(UserDefaultsKeys.startInBackground, "startInBackground")
        XCTAssertEqual(UserDefaultsKeys.selectedCustomPresetId, "selectedCustomPresetId")
        XCTAssertEqual(UserDefaultsKeys.downloadSpeedLimit, "downloadSpeedLimit")
        XCTAssertEqual(UserDefaultsKeys.resolutionFallbackPolicy, "resolutionFallbackPolicy")
    }
}
