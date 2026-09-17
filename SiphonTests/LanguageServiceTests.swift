import XCTest
@testable import Siphon

final class LanguageServiceTests: XCTestCase {

    func testLanguageEnumProperties() {
        let lang = Language.english
        XCTAssertEqual(lang.rawValue, "en")
        XCTAssertEqual(lang.id, "en")
        XCTAssertEqual(lang.displayName, "English")
        XCTAssertEqual(Language.allCases, [.english])
    }

    @MainActor
    func testLanguageServiceSharedAndInitialization() {
        let shared = LanguageService.shared
        XCTAssertNotNil(shared)

        let instance = LanguageService()
        XCTAssertNotNil(instance)
        XCTAssertEqual(instance.selectedLanguage, .english)
    }

    @MainActor
    func testSelectedLanguageMutation() {
        let service = LanguageService()
        XCTAssertEqual(service.selectedLanguage, .english)

        service.selectedLanguage = .english
        XCTAssertEqual(service.selectedLanguage, .english)
    }

    func testLocalizationLookupExistingKeys() {
        let service = MainActor.assumeIsolated { LanguageService() }

        XCTAssertEqual(service.s("legal_disclaimer"), "Legal Disclaimer")
        XCTAssertEqual(service.s("about_app"), "About Siphon")
        XCTAssertEqual(service.s("couldnt_download"), "Couldn't download")
        XCTAssertEqual(service.s("youtube_auth_required"), "YouTube requires authentication")
        XCTAssertEqual(service.s("home"), "Home")
        XCTAssertEqual(service.s("downloading"), "Downloading")
        XCTAssertEqual(service.s("queued"), "Queued")
        XCTAssertEqual(service.s("completed"), "Completed")
        XCTAssertEqual(service.s("settings"), "Settings")
    }

    func testLocalizationLookupFallbackForMissingKeys() {
        let service = MainActor.assumeIsolated { LanguageService() }

        XCTAssertEqual(service.s("custom_missing_key"), "Custom Missing Key")
        XCTAssertEqual(service.s("untranslated_feature_flag"), "Untranslated Feature Flag")
        XCTAssertEqual(service.s("simple"), "Simple")
        XCTAssertEqual(service.s("another_test_label_key"), "Another Test Label Key")
    }
}
