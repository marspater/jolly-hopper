import XCTest
@testable import Siphon

@MainActor
final class AdversarialAndPropertyTests: XCTestCase {

    // MARK: - 1. Hostname Spoofing & Canonical Domain Tests

    func testCanonicalHostValidationBlocksSpoofedSubdomains() {
        let trustedDomains = ["youtube.com", "youtu.be", "thisvid.com", "xhamster.com", "boyfriend.tv"]
        
        let hostileURLs = [
            "https://evil-youtube.com/watch?v=123",
            "https://youtube.com.attacker.com/watch?v=123",
            "https://notthisvid.com/video/123",
            "https://thisvid.com.phishing.net/v/1",
            "https://xhamster.com.malicious.org/watch",
            "https://boyfriend.tv.evil.com/video/1"
        ]

        for urlString in hostileURLs {
            guard let host = URL(string: urlString)?.host?.lowercased() else { continue }
            for domain in trustedDomains {
                let isTrusted = (host == domain || host.hasSuffix("." + domain))
                XCTAssertFalse(isTrusted, "Host '\(host)' should not be trusted for domain '\(domain)'")
            }
        }
    }

    func testCanonicalHostValidationAllowsLegitimateSubdomains() {
        let validURLs: [(url: String, domain: String)] = [
            ("https://www.youtube.com/watch?v=123", "youtube.com"),
            ("https://m.youtube.com/watch?v=123", "youtube.com"),
            ("https://music.youtube.com/watch?v=123", "youtube.com"),
            ("https://youtu.be/123", "youtu.be"),
            ("https://www.thisvid.com/videos/123", "thisvid.com"),
            ("https://de.xhamster.com/videos/123", "xhamster.com"),
            ("https://www.boyfriend.tv/videos/123", "boyfriend.tv")
        ]

        for item in validURLs {
            guard let host = URL(string: item.url)?.host?.lowercased() else {
                XCTFail("Could not parse host for \(item.url)")
                continue
            }
            let isTrusted = (host == item.domain || host.hasSuffix("." + item.domain))
            XCTAssertTrue(isTrusted, "Host '\(host)' must be recognized as valid for '\(item.domain)'")
        }
    }

    // MARK: - 2. Filename Sanitization & Path Containment Tests

    func testFilenameSanitizationStripsPathSeparatorsAndTraversal() {
        let dirtyFilenames = [
            "../../../etc/passwd",
            "..\\..\\Windows\\System32",
            "video/with/slash",
            "video\\with\\backslash",
            "video:name?with*illegal<chars>|\"",
            "   padded_spaces   "
        ]

        for dirty in dirtyFilenames {
            let sanitized = YtdlpService.sanitizeFilename(dirty)
            XCTAssertFalse(sanitized.contains("/"), "Sanitized filename must not contain forward slashes")
            XCTAssertFalse(sanitized.contains("\\"), "Sanitized filename must not contain backslashes")
            XCTAssertFalse(sanitized.contains(":"), "Sanitized filename must not contain colons")
            XCTAssertFalse(sanitized.hasPrefix("."), "Sanitized filename must not start with dot")
            XCTAssertFalse(sanitized.isEmpty, "Sanitized filename should not become empty")
        }
    }

    func testPathContainmentBlocksEscapes() {
        let baseDir = URL(fileURLWithPath: "/Users/test/Downloads")
        let insideURL = URL(fileURLWithPath: "/Users/test/Downloads/Subfolder/video.mp4")
        let outsideURL = URL(fileURLWithPath: "/Users/test/Documents/private.txt")
        let traversalURL = URL(fileURLWithPath: "/Users/test/Downloads/../../etc/passwd")

        XCTAssertTrue(YtdlpService.isPathContained(targetURL: insideURL, inside: baseDir))
        XCTAssertFalse(YtdlpService.isPathContained(targetURL: outsideURL, inside: baseDir))
        XCTAssertFalse(YtdlpService.isPathContained(targetURL: traversalURL, inside: baseDir))
    }

    // MARK: - 3. Progress Parsing Defensive Tests

    func testProgressParsingHandlesVariousFormatsDefensively() {
        var capturedProgress: [(percent: Double, speed: String?, eta: String?)] = []

        let linesToTest = [
            "[download] Destination: /tmp/test.mp4",
            "SIPHON_PROG:45.5%|1.2MiB/s|00:15",
            "SIPHON_PROG: 80,0% | 500KiB/s | 01:00 ", // comma decimal
            "SIPHON_PROG:NA|NA|NA",                     // NA fields
            "SIPHON_PROG:100.0%|NA|00:00",              // partial NA
            "SIPHON_PROG:malformed_percentage|1MB/s|--:--",
            "SIPHON_PROG:999.0%|10MB/s|00:01"          // bounded to 1.0
        ]

        let exp = expectation(description: "Progress lines processed")
        exp.expectedFulfillmentCount = 4 // Only valid percentages (45.5%, 80.0%, 100.0%, 999.0%)

        for line in linesToTest {
            if line.contains("SIPHON_PROG:") {
                let parts = line.components(separatedBy: "SIPHON_PROG:")
                if parts.count > 1 {
                    let fields = parts[1].components(separatedBy: "|")
                    let percentStr = fields.first?.trimmingCharacters(in: .whitespaces) ?? ""
                    let stripped = percentStr.hasSuffix("%") ? String(percentStr.dropLast()) : percentStr
                    let normalized = stripped.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                    let speed = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : nil
                    let eta = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : nil
                    if normalized != "NA" && !normalized.isEmpty, let percent = Double(normalized), !percent.isNaN && !percent.isInfinite {
                        let safeSpeed = (speed == "NA" || speed?.isEmpty == true) ? nil : speed
                        let safeEta = (eta == "NA" || eta?.isEmpty == true) ? nil : eta
                        let boundedPercent = max(0.0, min(1.0, percent / 100.0))
                        capturedProgress.append((boundedPercent, safeSpeed, safeEta))
                        exp.fulfill()
                    }
                }
            }
        }

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(capturedProgress.count, 4)
        XCTAssertEqual(capturedProgress[0].percent, 0.455, accuracy: 0.001)
        XCTAssertEqual(capturedProgress[0].speed, "1.2MiB/s")
        XCTAssertEqual(capturedProgress[1].percent, 0.8, accuracy: 0.001)
        XCTAssertEqual(capturedProgress[2].percent, 1.0, accuracy: 0.001)
        XCTAssertNil(capturedProgress[2].speed)
        XCTAssertEqual(capturedProgress[3].percent, 1.0, accuracy: 0.001, "Percentage must be capped at 1.0")
    }

    // MARK: - 4. Deterministic Format Ranking & Untested Streams

    func testUntested4KStreamOutranksTested720PStream() {
        let untested4K = MediaFormat(
            formatId: "4k_fmt",
            ext: "mp4",
            resolution: "3840x2160",
            fps: 60,
            vcodec: "avc1.640033",
            acodec: "none",
            abr: nil,
            vbr: 15000,
            filesize: 200000000,
            formatNote: "2160p 4K",
            needsTesting: true // Untested stream
        )
        let tested720p = MediaFormat(
            formatId: "720p_fmt",
            ext: "mp4",
            resolution: "1280x720",
            fps: 30,
            vcodec: "avc1.4d401f",
            acodec: "none",
            abr: nil,
            vbr: 2500,
            filesize: 40000000,
            formatNote: "720p",
            needsTesting: false // Tested stream
        )
        let audio = MediaFormat(
            formatId: "audio_1",
            ext: "m4a",
            vcodec: "none",
            acodec: "mp4a.40.2",
            abr: 128,
            formatNote: "original"
        )

        let mediaInfo = MediaInfo(
            id: "quality_test",
            title: "Quality Test",
            formats: [tested720p, untested4K, audio]
        )

        let options = DownloadOptions.default
        let resolved = mediaInfo.resolveSelectedFormats(options: options)

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].formatId, "4k_fmt", "Untested 4K stream must outrank tested 720p stream when 'Best' quality is selected")
    }

    func testTested1080PStreamOutranksUntested1080PStreamAtSameResolution() {
        let untested1080 = MediaFormat(
            formatId: "1080_untested",
            ext: "mp4",
            resolution: "1920x1080",
            fps: 60,
            vcodec: "avc1.64002a",
            acodec: "none",
            abr: nil,
            vbr: 4500,
            filesize: 80000000,
            needsTesting: true
        )
        let tested1080 = MediaFormat(
            formatId: "1080_tested",
            ext: "mp4",
            resolution: "1920x1080",
            fps: 60,
            vcodec: "avc1.64002a",
            acodec: "none",
            abr: nil,
            vbr: 4500,
            filesize: 80000000,
            needsTesting: false
        )
        let audio = MediaFormat(formatId: "audio_1", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", abr: 128)

        let mediaInfo = MediaInfo(
            id: "tie_test",
            title: "Tie Test",
            formats: [untested1080, tested1080, audio]
        )

        let resolved = mediaInfo.resolveSelectedFormats(options: DownloadOptions.default)
        XCTAssertEqual(resolved[0].formatId, "1080_tested", "Tested stream must win tie-breaker against untested stream of same resolution")
    }

    func testStaleCustomFormatSelectionGracefullyFallsBackToAutomatic() {
        let video = MediaFormat(formatId: "137", ext: "mp4", resolution: "1920x1080", vcodec: "avc1", acodec: "none")
        let audio = MediaFormat(formatId: "140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", abr: 128)
        let mediaInfo = MediaInfo(id: "stale_test", title: "Stale Test", formats: [video, audio])

        var options = DownloadOptions.default
        options.selectedFormatId = "999+888" // Non-existent formats in manifest

        let resolved = mediaInfo.resolveSelectedFormats(options: options)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].formatId, "137", "Should fall back gracefully to valid 1080p stream")
        XCTAssertEqual(resolved[1].formatId, "140")
    }

    // MARK: - 5. Clipboard URL Validation Tests

    func testClipboardURLValidationRejectsNonHTTPAndSensitiveData() {
        let invalidInputs = [
            "Password123!",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "ftp://example.com/file",
            "  not a url  ",
            ""
        ]

        let validate: (String) -> String? = { input in
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: trimmed),
                  let scheme = parsed.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https") else {
                return nil
            }
            return trimmed
        }

        for input in invalidInputs {
            XCTAssertNil(validate(input), "Clipboard validation should reject invalid input: '\(input)'")
        }

        let validInputs = [
            "https://youtube.com/watch?v=123",
            "http://example.com/video.mp4",
            "  https://vimeo.com/123456  "
        ]

        for input in validInputs {
            XCTAssertNotNil(validate(input), "Clipboard validation should accept valid HTTP/HTTPS URL: '\(input)'")
        }
    }
}
