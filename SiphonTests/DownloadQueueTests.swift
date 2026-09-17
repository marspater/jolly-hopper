//
//  DownloadQueueTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon

@MainActor
final class DownloadQueueTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DownloadQueueTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSlotReservationAndRelease() {
        testDefaults.set(2, forKey: UserDefaultsKeys.maxConcurrentDownloads)
        let queue = DownloadQueue(userDefaults: testDefaults)

        XCTAssertEqual(queue.maxConcurrentDownloads, 2)
        XCTAssertEqual(queue.availableSlots, 2)
        XCTAssertEqual(queue.activeSlotCount, 0)

        let id1 = UUID()
        let id2 = UUID()

        XCTAssertFalse(queue.isSlotReserved(for: id1))
        XCTAssertTrue(queue.reserveSlot(for: id1))
        XCTAssertTrue(queue.isSlotReserved(for: id1))
        XCTAssertEqual(queue.availableSlots, 1)

        XCTAssertTrue(queue.reserveSlot(for: id2))
        XCTAssertEqual(queue.availableSlots, 0)

        queue.releaseSlot(for: id1)
        XCTAssertFalse(queue.isSlotReserved(for: id1))
        XCTAssertEqual(queue.availableSlots, 1)

        queue.clearReservedSlots()
        XCTAssertEqual(queue.activeSlotCount, 0)
        XCTAssertEqual(queue.availableSlots, 2)
    }

    func testScheduleNextDownloadsRespectsLimit() {
        testDefaults.set(2, forKey: UserDefaultsKeys.maxConcurrentDownloads)
        let queue = DownloadQueue(userDefaults: testDefaults)

        let dl1 = Download(url: "https://example.com/1", options: .default)
        let dl2 = Download(url: "https://example.com/2", options: .default)
        let dl3 = Download(url: "https://example.com/3", options: .default)
        let all = [dl1, dl2, dl3]

        let scheduled = queue.scheduleNextDownloads(from: all)
        XCTAssertEqual(scheduled.count, 2)
        XCTAssertEqual(scheduled.map { $0.id }, [dl1.id, dl2.id])
        XCTAssertTrue(queue.isSlotReserved(for: dl1.id))
        XCTAssertTrue(queue.isSlotReserved(for: dl2.id))
        XCTAssertFalse(queue.isSlotReserved(for: dl3.id))

        // No more slots available
        let secondBatch = queue.scheduleNextDownloads(from: all)
        XCTAssertTrue(secondBatch.isEmpty)

        // dl1 begins downloading and later finishes, freeing its slot
        dl1.status = .downloading
        queue.releaseSlot(for: dl1.id)
        XCTAssertEqual(queue.availableSlots, 1)

        let thirdBatch = queue.scheduleNextDownloads(from: all)
        XCTAssertEqual(thirdBatch.count, 1)
        XCTAssertEqual(thirdBatch.first?.id, dl3.id)
        XCTAssertTrue(queue.isSlotReserved(for: dl3.id))
    }

    func testOutputPathPlanningAndReservation() {
        let queue = DownloadQueue(userDefaults: testDefaults)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dl1 = Download(url: "https://example.com/video1", options: .default)
        dl1.title = "Sample Video"
        dl1.options.saveFolder = tempDir

        let (name1, path1) = queue.planUniqueOutputPath(for: dl1)
        XCTAssertEqual(name1, "Sample Video")
        XCTAssertEqual(path1, tempDir.appendingPathComponent("Sample Video.mp4").path)

        // Reserve path1
        let (resName, resPath) = queue.reserveUniqueOutputPath(for: dl1)
        XCTAssertEqual(resName, "Sample Video")
        XCTAssertEqual(resPath, path1)
        XCTAssertTrue(queue.isPathReserved(path1))

        // Plan for a second download with same name
        let dl2 = Download(url: "https://example.com/video2", options: .default)
        dl2.title = "Sample Video"
        dl2.options.saveFolder = tempDir

        let (name2, path2) = queue.planUniqueOutputPath(for: dl2)
        XCTAssertEqual(name2, "Sample Video (1)")
        XCTAssertEqual(path2, tempDir.appendingPathComponent("Sample Video (1).mp4").path)

        queue.unreserveOutputPath(path1)
        XCTAssertFalse(queue.isPathReserved(path1))
    }

    func testReorderingHelpers() {
        let queue = DownloadQueue(userDefaults: testDefaults)
        let dl1 = Download(url: "https://example.com/1", options: .default)
        let dl2 = Download(url: "https://example.com/2", options: .default)
        let dl3 = Download(url: "https://example.com/3", options: .default)
        var downloads = [dl1, dl2, dl3]

        // Move up
        XCTAssertTrue(queue.moveUp(download: dl2, in: &downloads))
        XCTAssertEqual(downloads.map { $0.id }, [dl2.id, dl1.id, dl3.id])

        // Moving top item up should fail gracefully
        XCTAssertFalse(queue.moveUp(download: dl2, in: &downloads))

        // Move down
        XCTAssertTrue(queue.moveDown(download: dl2, in: &downloads))
        XCTAssertEqual(downloads.map { $0.id }, [dl1.id, dl2.id, dl3.id])

        // Move to bottom
        XCTAssertTrue(queue.moveToBottom(download: dl1, in: &downloads))
        XCTAssertEqual(downloads.map { $0.id }, [dl2.id, dl3.id, dl1.id])

        // Move to top
        XCTAssertTrue(queue.moveToTop(download: dl1, in: &downloads))
        XCTAssertEqual(downloads.map { $0.id }, [dl1.id, dl2.id, dl3.id])

        // IndexSet move
        queue.move(from: IndexSet(integer: 2), to: 0, in: &downloads)
        XCTAssertEqual(downloads.map { $0.id }, [dl3.id, dl1.id, dl2.id])
    }
}
