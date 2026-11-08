#if DEBUG
import Foundation
import Testing
@testable import Siphon

@MainActor
struct PreviewFixturesTests {
    @Test func fixturesStayOffSharedSessionAndRealDefaults() {
        let domain = Bundle.main.bundleIdentifier ?? ""
        let before = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?

        let state = PreviewFixtures.appState()
        #expect(state.urlSession !== URLSession.shared)
        _ = PreviewFixtures.manager(downloads: PreviewFixtures.lifecycle.map(\.1))
        _ = PreviewFixtures.history
        _ = PreviewFixtures.mixedQueue
        _ = PreviewFixtures.updateChecker()
        _ = PreviewFixtures.logger()
        _ = PreviewFixtures.language()

        let after = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
        #expect(before == after)
    }
}
#endif
