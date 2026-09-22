import XCTest
@testable import Siphon

final class CustomPresetTests: XCTestCase {

    func testCustomPresetFullSerialization() throws {
        let originalPreset = CustomPreset(
            name: "Full Preset",
            videoCodec: .h264,
            audioCodec: .aac,
            videoResolution: .r1080p,
            fileType: .mp4,
            downloadSubtitles: true,
            subtitleLanguage: "en,es",
            subtitleFormat: .vtt,
            sponsorBlock: true,
            splitChapters: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(originalPreset)

        // Ensure "embedSubtitles" mapping works during encoding
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        XCTAssertNotNil(jsonObject)
        XCTAssertEqual(jsonObject?["embedSubtitles"] as? Bool, true)
        XCTAssertNil(jsonObject?["downloadSubtitles"])
        XCTAssertEqual(jsonObject?["videoCodec"] as? String, "h264")
        XCTAssertEqual(jsonObject?["audioCodec"] as? String, "aac")
        XCTAssertEqual(jsonObject?["videoResolution"] as? String, "r1080p")
        XCTAssertEqual(jsonObject?["fileType"] as? String, "MP4")

        let decoder = JSONDecoder()
        let decodedPreset = try decoder.decode(CustomPreset.self, from: data)

        XCTAssertEqual(originalPreset.id, decodedPreset.id)
        XCTAssertEqual(decodedPreset.name, "Full Preset")
        XCTAssertEqual(decodedPreset.videoCodec, .h264)
        XCTAssertEqual(decodedPreset.audioCodec, .aac)
        XCTAssertEqual(decodedPreset.videoResolution, .r1080p)
        XCTAssertEqual(decodedPreset.fileType, .mp4)
        XCTAssertEqual(decodedPreset.downloadSubtitles, true)
        XCTAssertEqual(decodedPreset.subtitleLanguage, "en,es")
        XCTAssertEqual(decodedPreset.subtitleFormat, .vtt)
        XCTAssertEqual(decodedPreset.sponsorBlock, true)
        XCTAssertEqual(decodedPreset.splitChapters, true)

        XCTAssertEqual(originalPreset, decodedPreset)
    }

    func testCustomPresetMinimalSerialization() throws {
        // Init with only required arguments, others should use defaults
        let originalPreset = CustomPreset(
            name: "Minimal Preset",
            videoCodec: .vp9,
            audioCodec: .opus,
            videoResolution: .r480p,
            fileType: .webm
        )

        let data = try JSONEncoder().encode(originalPreset)
        let decodedPreset = try JSONDecoder().decode(CustomPreset.self, from: data)

        XCTAssertEqual(decodedPreset.name, "Minimal Preset")
        XCTAssertEqual(decodedPreset.videoCodec, .vp9)
        XCTAssertEqual(decodedPreset.audioCodec, .opus)
        XCTAssertEqual(decodedPreset.videoResolution, .r480p)
        XCTAssertEqual(decodedPreset.fileType, .webm)

        // These are defaults from the init
        XCTAssertEqual(decodedPreset.downloadSubtitles, false)
        XCTAssertEqual(decodedPreset.subtitleLanguage, "")
        XCTAssertEqual(decodedPreset.subtitleFormat, .srt)
        XCTAssertEqual(decodedPreset.sponsorBlock, false)
        XCTAssertEqual(decodedPreset.splitChapters, false)

        XCTAssertEqual(originalPreset, decodedPreset)
    }

    func testCustomPresetLegacyDecoding() throws {
        // A JSON blob lacking many of the newer optional properties
        let jsonString = """
        {
            "id": "123e4567-e89b-12d3-a456-426614174000",
            "name": "Legacy JSON",
            "videoCodec": "av1",
            "audioCodec": "mp3",
            "videoResolution": "r720p",
            "fileType": "MKV"
        }
        """

        let data = jsonString.data(using: .utf8)!
        let decodedPreset = try JSONDecoder().decode(CustomPreset.self, from: data)

        XCTAssertEqual(decodedPreset.id.uuidString, "123E4567-E89B-12D3-A456-426614174000")
        XCTAssertEqual(decodedPreset.name, "Legacy JSON")
        XCTAssertEqual(decodedPreset.videoCodec, .av1)
        XCTAssertEqual(decodedPreset.audioCodec, .mp3)
        XCTAssertEqual(decodedPreset.videoResolution, .r720p)
        XCTAssertEqual(decodedPreset.fileType, .mkv)

        // Since the JSON string didn't contain the properties, they should decode to nil
        XCTAssertNil(decodedPreset.downloadSubtitles)
        XCTAssertNil(decodedPreset.subtitleLanguage)
        XCTAssertNil(decodedPreset.subtitleFormat)
        XCTAssertNil(decodedPreset.sponsorBlock)
        XCTAssertNil(decodedPreset.splitChapters)
    }

    func testCustomPresetLoadAllAndSaveAll() throws {
        // Save current user defaults state to restore after test
        let originalData = UserDefaults.standard.data(forKey: UserDefaultsKeys.customPresets)
        defer {
            if let originalData = originalData {
                UserDefaults.standard.set(originalData, forKey: UserDefaultsKeys.customPresets)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.customPresets)
            }
        }

        // Test loadAll when no presets exist
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.customPresets)
        XCTAssertTrue(CustomPreset.loadAll().isEmpty)

        // Test saveAll and loadAll round-trip
        let preset1 = CustomPreset(name: "Preset 1", videoCodec: .h264, audioCodec: .aac, videoResolution: .r1080p, fileType: .mp4)
        let preset2 = CustomPreset(name: "Preset 2", videoCodec: .h265, audioCodec: .opus, videoResolution: .r2160p, fileType: .mkv)
        let presets = [preset1, preset2]

        CustomPreset.saveAll(presets)
        let loaded = CustomPreset.loadAll()
        XCTAssertEqual(loaded, presets)

        // Test loadAll when invalid/corrupted data exists
        let corruptedData = "invalid json data".data(using: .utf8)!
        UserDefaults.standard.set(corruptedData, forKey: UserDefaultsKeys.customPresets)
        XCTAssertTrue(CustomPreset.loadAll().isEmpty)
    }

    func testCustomPresetConfigurationInitialization() throws {
        let config = CustomPresetConfiguration(
            name: "Configured Preset",
            videoCodec: .av1,
            audioCodec: .flac,
            videoResolution: .r1440p,
            fileType: .mkv,
            downloadSubtitles: true,
            subtitleLanguage: "fr",
            subtitleFormat: .vtt,
            sponsorBlock: true,
            splitChapters: true
        )
        let preset = CustomPreset(configuration: config)

        XCTAssertEqual(preset.name, "Configured Preset")
        XCTAssertEqual(preset.videoCodec, .av1)
        XCTAssertEqual(preset.audioCodec, .flac)
        XCTAssertEqual(preset.videoResolution, .r1440p)
        XCTAssertEqual(preset.fileType, .mkv)
        XCTAssertEqual(preset.downloadSubtitles, true)
        XCTAssertEqual(preset.subtitleLanguage, "fr")
        XCTAssertEqual(preset.subtitleFormat, .vtt)
        XCTAssertEqual(preset.sponsorBlock, true)
        XCTAssertEqual(preset.splitChapters, true)
    }
}
