import XCTest
@testable import SiphonCore

/// Run through the Performance test plan only.
final class SiphonPerformanceTests: XCTestCase {
    private let metrics: [XCTMetric] = [XCTClockMetric(), XCTMemoryMetric()]

    func testFormatRankingOverLargeMediaInfo() {
        let formats = (0..<2_000).map {
            MediaFormat(formatId: "\($0)", ext: "mp4", resolution: "\(144 + $0 % 2_000)p", fps: Double($0 % 60), tbr: Double($0))
        }
        let info = MediaInfo(id: "x", title: "Large", formats: formats)
        measure(metrics: metrics) {
            _ = info.resolveSelectedFormats(options: .default)
        }
    }

    func testLogSanitizationOfLargeBuffer() {
        let line = "GET https://example.com/a?token=abc Authorization: Bearer abc cookie: a=b\n"
        let buffer = String(repeating: line, count: 20_000)
        measure(metrics: metrics) {
            _ = LogSanitizer.sanitizeLogContentForExport(LogSanitizer.sanitizeDiagnosticText(buffer))
        }
    }
}
