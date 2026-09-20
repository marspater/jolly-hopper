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

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test.history.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        testDefaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
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

    func testHistoryStripsSecretsFromLogsAndAdvancedArguments() {
        var options = DownloadOptions.default
        options.additionalArguments = "--add-header Authorization:Bearer super_secret --proxy https://user:pass@example.com"
        options.rawCookies = "session=secret"
        options.rawUserAgent = "FixtureBrowser/1.0"

        let download = Download(
            url: "https://example.com/video",
            options: options,
            title: "Sensitive"
        )
        download.log = "failed https://cdn.example.com/master.m3u8?token=secret_token&expires=999"
        download.errorMessage = "request token=another_secret"

        let historic = HistoricDownload(download: download)

        XCTAssertNil(historic.options.rawCookies)
        XCTAssertNil(historic.options.rawUserAgent)
        XCTAssertNil(historic.options.additionalArguments)
        XCTAssertFalse(historic.log.contains("secret_token"))
        XCTAssertFalse(historic.log.contains("expires=999"))
        XCTAssertFalse(historic.errorMessage?.contains("another_secret") == true)
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

    func testRestoreDownloadsCleansesFetchingPlaceholder() {
        let dl = Download(url: "https://www.boyfriendtv.com/videos/999/amazing-clip", options: .default, title: "Custom")
        var historic = HistoricDownload(download: dl)
        historic.title = "___FETCHING___" // simulate legacy corrupted history entry

        let restored = DownloadHistoryStore.restoreDownloads(from: [historic], existingDownloads: [])
        XCTAssertEqual(restored.count, 1)
        XCTAssertNotEqual(restored.first?.title, "___FETCHING___")
        XCTAssertEqual(restored.first?.title, "Amazing Clip")
    }
    func testPausedHistoryPreservesOwnedScratchDirectoryAndCreationDate() throws {
        let store = DownloadHistoryStore(userDefaults: testDefaults, historyKey: "test_history")
        let scratch = ScratchDirectoryPolicy.makeURL()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let createdAt = Date(timeIntervalSince1970: 1_700_000_123)
        let download = Download(
            url: "https://example.com/paused",
            options: .default,
            title: "Paused",
            createdAt: createdAt
        )
        download.status = .paused
        download.progress = 0.51
        download.scratchDirectory = scratch

        var history: [HistoricDownload] = []
        store.addToHistory(download, history: &history)
        let loaded = store.loadHistory()
        let restored = try XCTUnwrap(
            DownloadHistoryStore.restoreDownloads(from: loaded, existingDownloads: []).first
        )

        XCTAssertEqual(restored.status, .paused)
        XCTAssertEqual(restored.createdAt, createdAt)
        XCTAssertEqual(restored.progress, 0.51)
        XCTAssertEqual(restored.scratchDirectory?.standardizedFileURL.path, scratch.standardizedFileURL.path)
    }

    func testHistoryDoesNotPersistUnownedScratchDirectory() {
        let download = Download(url: "https://example.com/paused", options: .default)
        let unowned = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("siphon_scratch_tampered", isDirectory: true)
        download.status = .paused
        download.scratchDirectory = unowned

        let historic = HistoricDownload(download: download)
        XCTAssertNil(historic.scratchDirectoryPath)
    }

}

