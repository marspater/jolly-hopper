#if DEBUG
import Foundation
import Testing
import SiphonCore
@testable import Siphon

@MainActor
struct PreviewFixturesTests {
    @Test func canvasEnvironmentsCountAsPreviewHosts() {
        #expect(NotificationService.isPreviewHost(["XCODE_RUNNING_FOR_PREVIEWS": "1"]))
        #expect(NotificationService.isPreviewHost(["XCODE_RUNNING_FOR_PLAYGROUNDS": "1"]))
        #expect(!NotificationService.isPreviewHost([:]))
    }

    @Test func fixturesStayOffSharedSessionAndRealDefaults() {
        let domain = Bundle.main.bundleIdentifier ?? ""
        let before = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?

        let state = PreviewFixtures.appState()
        #expect(state.urlSession !== URLSession.shared)
        let manager = PreviewFixtures.manager(downloads: PreviewFixtures.lifecycle.map(\.1))
        #expect(manager.ytdlpService.updateYtdlpHandler != nil)
        _ = PreviewFixtures.history
        _ = PreviewFixtures.mixedQueue
        #expect(PreviewFixtures.playlistInfo.playlist != nil)
        #expect(!PreviewFixtures.features.isEmpty)
        _ = PreviewFixtures.updateChecker()
        _ = PreviewFixtures.logger()
        _ = PreviewFixtures.language()

        let after = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
        #expect(before == after)
    }
}
#endif
