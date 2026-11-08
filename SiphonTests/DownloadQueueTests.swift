//
//  DownloadQueueTests.swift
//  SiphonTests
//

import XCTest
@testable import Siphon
@testable import SiphonCore

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

    func testDotTitlesFromDifferentVideosDoNotShareTheFallbackName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var options = DownloadOptions.default
        options.saveFolder = folder
        let queue = DownloadQueue(userDefaults: testDefaults)
        func planned(_ url: String, title: String = ".") -> String {
            queue.planUniqueOutputPath(for: Download(url: url, options: options, title: title)).resolvedBaseName
        }
        let first = planned("https://www.boyfriendtv.com/videos/1634352/-/")
        XCTAssertNotNil(YtdlpService.sanitizedFilenameOrNil(first))
        XCTAssertNotEqual(first, planned("https://www.boyfriendtv.com/videos/1734715/-/"))
        XCTAssertEqual(first, planned("https://www.boyfriendtv.com/es/videos/1634352/-/?tag=x"))
        XCTAssertNotEqual(planned("https://www.boyfriendtv.com/?id=1634352"), planned("https://www.boyfriendtv.com/?id=1734715"))
        XCTAssertNotEqual(planned("https://www.boyfriendtv.com/videos/1634352/2024/"), planned("https://www.boyfriendtv.com/videos/1734715/2024/"))
        XCTAssertEqual(first, planned("https://es.boyfriendtv.com/videos/1634352/-/"))
        XCTAssertNotEqual(planned("https://example.com/album/123/video/456"), planned("https://example.com/album/123/video/789"))
        XCTAssertNotEqual(planned("https://site-a.co.uk/videos/1/-/"), planned("https://site-b.co.uk/videos/1/-/"))
        XCTAssertEqual(planned("https://www.boyfriendtv.com/videos/1634352/-/", title: "Clip"), "Clip")
        XCTAssertEqual(planned("https://www.boyfriendtv.com/videos/1634352/-/", title: "download"), "download")
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

        var videoOptions = DownloadOptions.default
        videoOptions.fileType = .mp4
        for ext in YtdlpService.videoMediaExtensions {
            XCTAssertTrue(
                DownloadQueue.mediaFileCollides(baseName: "My Video", options: videoOptions, existingMediaFileKeys: ["my video.\(ext)"]),
                "An existing .\(ext) must block a video job of the same name"
            )
        }
    }
}
