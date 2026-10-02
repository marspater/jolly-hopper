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

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "DownloadQueueTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        testDefaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
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

    func testCollisionPlanningComparesOnlyExtensionsTheJobCanProduce() {
        let queue = DownloadQueue(userDefaults: testDefaults)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("Song.mp3").path, contents: Data())
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("clip.WEBM").path, contents: Data())

        func plannedName(_ title: String, _ fileType: MediaFileType) -> String {
            var options = DownloadOptions.default
            options.saveFolder = tempDir
            options.fileType = fileType
            return queue.planUniqueOutputPath(for: Download(url: "https://example.com/v", options: options, title: title)).resolvedBaseName
        }

        XCTAssertEqual(plannedName("Song", .mp4), "Song", "An audio file must not block a video of the same name")
        XCTAssertEqual(plannedName("Song", .flac), "Song", "Audio is converted to its exact extension")
        XCTAssertEqual(plannedName("song", .mp3), "song (1)", "Same file, case-only difference")
        XCTAssertEqual(plannedName("Clip", .mp4), "Clip (1)", "Unmerged video can keep the source container")
        XCTAssertEqual(plannedName("Clip", .m4a), "Clip", "A video file must not block audio of the same name")

        // Reveal in Finder for a `.fileExists` row selects the file that collided.
        func colliding(_ baseName: String, _ fileType: MediaFileType) -> String? {
            var options = DownloadOptions.default
            options.fileType = fileType
            return DownloadQueue.collidingMediaFile(baseName: baseName, options: options, in: tempDir)?.lastPathComponent
        }
        XCTAssertEqual(colliding("Clip", .mp4), "clip.WEBM")
        XCTAssertEqual(colliding("song", .mp3), "Song.mp3")
        XCTAssertNil(colliding("Song", .mp4))
    }

    func testOutputReservationsAreCaseInsensitiveAndUnicodeCanonicalized() {
        let queue = DownloadQueue(userDefaults: testDefaults)
        let upper = "/tmp/Siphon/Video Name.mp4"
        let lower = "/tmp/siphon/video name.mp4"

        queue.reserveOutputPath(upper)

        XCTAssertTrue(
            queue.isPathReserved(lower),
            "A case-only path variant must collide on normal macOS volumes"
        )
        XCTAssertEqual(
            DownloadQueue.reservationKey(for: "/tmp/Siphon/Café.mp4"),
            DownloadQueue.reservationKey(for: "/tmp/siphon/Cafe\u{301}.mp4"),
            "Canonical Unicode variants must reserve the same output path"
        )

        queue.unreserveOutputPath(lower)
        XCTAssertFalse(queue.isPathReserved(upper))
    }

    func testForceOverwritePreservesExactFilenameWithoutIncrementing() throws {
        let queue = DownloadQueue(userDefaults: testDefaults)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let existingFilePath = tempDir.appendingPathComponent("Sample Video.mp4")
        try "existing file".write(to: existingFilePath, atomically: true, encoding: .utf8)

        let dl = Download(url: "https://example.com/video", options: .default)
        dl.title = "Sample Video"
        dl.options.saveFolder = tempDir
        dl.options.forceOverwrite = true

        let (name, path) = queue.planUniqueOutputPath(for: dl)
        XCTAssertEqual(name, "Sample Video", "forceOverwrite must preserve the original filename")
        XCTAssertEqual(path, existingFilePath.path, "forceOverwrite must target the existing file path")
    }

    func testReservationsBlockOtherVideoContainersOfTheSameName() throws {
        let queue = DownloadQueue(userDefaults: testDefaults)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        func plannedName(_ title: String, _ fileType: MediaFileType, videoCodec: VideoCodec? = nil, forceOverwrite: Bool = false) -> String {
            var options = DownloadOptions.default
            options.saveFolder = tempDir
            options.fileType = fileType
            options.videoCodec = videoCodec
            options.forceOverwrite = forceOverwrite
            return queue.planUniqueOutputPath(for: Download(url: "https://example.com/v", options: options, title: title)).resolvedBaseName
        }

        // Another active video job holds Movie.mp4. Unmerged output keeps the
        // source container, so both jobs could still finish as Movie.webm.
        queue.reserveOutputPath(tempDir.appendingPathComponent("Movie.mp4").path)
        XCTAssertEqual(plannedName("Movie", .mkv), "Movie (1)")
        XCTAssertEqual(plannedName("Movie", .webm), "Movie (1)")
        XCTAssertEqual(plannedName("Movie", .mp4, videoCodec: .vp9), "Movie (1)", "Predicted mkv must still see the mp4 reservation")
        XCTAssertEqual(plannedName("Movie", .mkv, forceOverwrite: true), "Movie (1)", "Overwrite must not take a name another active job holds")
        XCTAssertEqual(plannedName("Movie", .mp3), "Movie", "A video reservation must not block audio")

        queue.reserveOutputPath(tempDir.appendingPathComponent("Song.mp3").path)
        XCTAssertEqual(plannedName("Song", .mp4), "Song", "An audio reservation must not block video")
        XCTAssertEqual(plannedName("Song", .mp3), "Song (1)")
        XCTAssertEqual(plannedName("Song", .flac), "Song", "Audio reservations stay exact-extension")
    }

    func testForceOverwriteTargetsOwnNameAndNeverClobbersRenamedFiles() throws {
        let queue = DownloadQueue(userDefaults: testDefaults)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        for name in ["Movie.mkv", "Movie.webm"] {
            FileManager.default.createFile(atPath: tempDir.appendingPathComponent(name).path, contents: Data())
        }

        var options = DownloadOptions.default
        options.saveFolder = tempDir
        options.fileType = .mp4
        options.forceOverwrite = true
        let download = Download(url: "https://example.com/movie", options: options, title: "Movie")

        // Overwrite keeps the original name even with several existing
        // containers; yt-dlp replaces only the file it writes.
        let (name, path) = queue.planUniqueOutputPath(for: download)
        XCTAssertEqual(name, "Movie")
        XCTAssertEqual(path, tempDir.appendingPathComponent("Movie.mp4").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Movie.mkv").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Movie.webm").path))

        // Another active job holds the original name. The bumped name must be
        // free on disk, or --force-overwrites would delete "Movie (1).mp4".
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("Movie (1).mp4").path, contents: Data())
        queue.reserveOutputPath(tempDir.appendingPathComponent("Movie.mp4").path)
        XCTAssertEqual(queue.planUniqueOutputPath(for: download).resolvedBaseName, "Movie (2)")
        XCTAssertEqual(queue.planUniqueOutputPath(for: download, forceIncrement: true).resolvedBaseName, "Movie (2)")
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

    func testReorderingSkipsDownloadsHiddenFromQueueTab() {
        let queue = DownloadQueue(userDefaults: testDefaults)
        let queuedA = Download(url: "https://example.com/a", options: .default)
        let active = Download(url: "https://example.com/active", options: .default)
        let finished = Download(url: "https://example.com/finished", options: .default)
        let pausedB = Download(url: "https://example.com/b", options: .default)
        let failed = Download(url: "https://example.com/failed", options: .default)
        active.status = .downloading
        finished.status = .completed
        pausedB.status = .paused
        failed.status = .failed
        var downloads = [queuedA, active, finished, pausedB, failed]

        // Visible order is [queuedA, pausedB]; Up/Down swap the visible neighbours.
        XCTAssertFalse(queue.canMoveUp(download: queuedA, in: downloads))
        XCTAssertTrue(queue.canMoveDown(download: queuedA, in: downloads))
        XCTAssertTrue(queue.canMoveUp(download: pausedB, in: downloads))
        XCTAssertFalse(queue.canMoveDown(download: pausedB, in: downloads))

        XCTAssertTrue(queue.moveDown(download: queuedA, in: &downloads))
        XCTAssertEqual(downloads.map(\.id), [pausedB.id, active.id, finished.id, queuedA.id, failed.id])
        XCTAssertEqual(downloads.filter(DownloadQueue.isQueueTabMember).map(\.id), [pausedB.id, queuedA.id])

        // Last visible row cannot move down past a hidden failed download.
        XCTAssertFalse(queue.moveDown(download: queuedA, in: &downloads))

        XCTAssertTrue(queue.moveUp(download: queuedA, in: &downloads))
        XCTAssertEqual(downloads.map(\.id), [queuedA.id, active.id, finished.id, pausedB.id, failed.id])

        // First visible row cannot move up.
        XCTAssertFalse(queue.moveUp(download: queuedA, in: &downloads))
    }
}
