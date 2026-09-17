//
//  DownloadHistoryStoreTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

@MainActor
final class DownloadHistoryStoreTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.history.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSaveAndLoadHistory() {
        let store = DownloadHistoryStore(userDefaults: testDefaults, historyKey: "test_history")
        let download = Download(url: "https://example.com/test", options: .default, title: "Test Video")
        var history: [HistoricDownload] = []

        store.addToHistory(download, history: &history)
        XCTAssertEqual(history.count, 1)

        let loaded = store.loadHistory()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.url, "https://example.com/test")
        XCTAssertEqual(loaded.first?.title, "Test Video")
    }

    func testAddToHistoryCapsAt500() {
        let store = DownloadHistoryStore(userDefaults: testDefaults, historyKey: "test_history")
        var history: [HistoricDownload] = []

        for i in 0..<505 {
            let dl = Download(url: "https://example.com/video/\(i)", options: .default, title: "Video \(i)")
            store.addToHistory(dl, history: &history, skipSave: true)
        }

        XCTAssertEqual(history.count, 500)
        XCTAssertEqual(history.first?.title, "Video 5")
        XCTAssertEqual(history.last?.title, "Video 504")
    }

    func testCorruptedHistoryRepair() throws {
        let key = "test_history_corrupt"
        let store = DownloadHistoryStore(userDefaults: testDefaults, historyKey: key)

        let validDownload = Download(url: "https://example.com/valid", options: .default, title: "Valid")
        let validHistoric = HistoricDownload(download: validDownload)
        let validData = try JSONEncoder().encode(validHistoric)
        let validDict = try JSONSerialization.jsonObject(with: validData)

        let invalidDict: [String: Any] = ["invalid_key": "not a historic download"]

        let rawArray: [Any] = [validDict, invalidDict]
        let serialized = try JSONSerialization.data(withJSONObject: rawArray)
        testDefaults.set(serialized, forKey: key)

        let loaded = store.loadHistory()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Valid")
    }

    func testRestoreDownloadsDeduplication() {
        let dl1 = Download(url: "https://example.com/1", options: .default, title: "1")
        dl1.status = .completed
        let dl2 = Download(url: "https://example.com/2", options: .default, title: "2")
        dl2.status = .downloading // Should transition to .stopped

        let history = [HistoricDownload(download: dl1), HistoricDownload(download: dl2)]
        let existing = [Download(url: "https://example.com/existing", options: .default, title: "Existing")]

        let restored = DownloadHistoryStore.restoreDownloads(from: history, existingDownloads: existing)
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored[0].title, "Existing")
        XCTAssertEqual(restored[1].title, "2")
        XCTAssertEqual(restored[1].status, .stopped)
        XCTAssertEqual(restored[2].title, "1")
        XCTAssertEqual(restored[2].status, .completed)
    }

    func testClearHistory() {
        let store = DownloadHistoryStore(userDefaults: testDefaults, historyKey: "test_history")
        let dl = Download(url: "https://example.com/1", options: .default, title: "1")
        var history: [HistoricDownload] = []
        store.addToHistory(dl, history: &history)

        XCTAssertFalse(history.isEmpty)
        store.clearHistory(history: &history)
        XCTAssertTrue(history.isEmpty)

        let loaded = store.loadHistory()
        XCTAssertTrue(loaded.isEmpty)
    }
}
