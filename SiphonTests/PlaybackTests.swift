import AVFoundation
import Foundation
import Synchronization
import XCTest
@testable import Siphon

final class PlaybackTests: XCTestCase {
    func testSourceValidationAndNativeRouting() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Self.waveData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try PlaybackSourceResolver.validate(.localFile(url))
        XCTAssertTrue(PlaybackSourceResolver.prefersNativePlayer(url))
        XCTAssertFalse(PlaybackSourceResolver.prefersNativePlayer(url.deletingPathExtension().appendingPathExtension("mkv")))
        XCTAssertThrowsError(try PlaybackSourceResolver.validate(.localFile(url.appendingPathExtension("missing"))))
        XCTAssertThrowsError(try PlaybackSourceResolver.validate(.localFile(FileManager.default.temporaryDirectory)))
        XCTAssertThrowsError(try PlaybackSourceResolver.validate(.offlineHLS(packageURL: url, licenseReference: "test"))) {
            XCTAssertEqual($0 as? PlaybackError, .offlineUnsupported)
        }
        XCTAssertThrowsError(try PlaybackSourceResolver.validate(.hls(manifestURL: URL(string: "http://media.example/live.m3u8")!, drm: nil)))
        XCTAssertThrowsError(try PlaybackSourceResolver.validate(.hls(manifestURL: URL(string: "https://user:secret@media.example/live.m3u8")!, drm: nil)))
    }

    @MainActor
    func testLocalPlayerLoadsReplacesAndStops() async throws {
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Self.waveData().write(to: firstURL)
        defer { try? FileManager.default.removeItem(at: firstURL) }
        let service = PlaybackService()
        defer { service.stop() }
        try await service.load(.localFile(firstURL))
        let player = try XCTUnwrap(service.player)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { service.state == .ready || service.state == .failed }
        }, object: nil)
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(service.state, .ready, service.errorMessage ?? "")
        service.seek(to: -.infinity)
        service.seek(to: .nan)
        service.pause()
        try await service.load(.localFile(firstURL))
        XCTAssertFalse(service.player === player)
        XCTAssertNil(player.currentItem, "Replacement must detach the previous item")
        service.stop()
        XCTAssertNil(service.player)
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.errorMessage)
        service.stop()
    }

    @MainActor
    func testLiveClearHLSLoadsPlaysAndSeeks() async throws {
        guard ProcessInfo.processInfo.environment["SIPHON_RUN_PLAYBACK_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set SIPHON_RUN_PLAYBACK_LIVE_TESTS=1 to exercise Apple's public clear-HLS fixture.")
        }
        let service = PlaybackService()
        defer { service.stop() }
        let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!
        try await service.load(.hls(manifestURL: url, drm: nil))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { service.state == .ready || service.state == .failed }
        }, object: nil)
        await fulfillment(of: [ready], timeout: 45)
        XCTAssertEqual(service.state, .ready, service.errorMessage ?? "")
        guard service.state == .ready else { return }
        service.player?.isMuted = true
        service.play()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { service.player?.currentTime().seconds ?? 0 > 0.25 || service.state == .failed }
        }, object: nil)
        await fulfillment(of: [playing], timeout: 30)
        XCTAssertEqual(service.state, .playing, service.errorMessage ?? "")
        service.seek(to: 20)
        let sought = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { service.player?.currentTime().seconds ?? 0 >= 19 || service.state == .failed }
        }, object: nil)
        await fulfillment(of: [sought], timeout: 30)
        XCTAssertGreaterThanOrEqual(service.player?.currentTime().seconds ?? 0, 19)
        XCTAssertNotEqual(service.state, .failed, service.errorMessage ?? "")
        service.pause()
        XCTAssertEqual(service.state, .paused)
    }

    @MainActor
    func testInvalidLoadFailsAndCanRecover() async throws {
        let service = PlaybackService()
        do {
            try await service.load(.localFile(URL(fileURLWithPath: "/nonexistent/" + UUID().uuidString)))
            XCTFail("Missing media must fail")
        } catch {
            XCTAssertEqual(error as? PlaybackError, .invalidSource)
        }
        XCTAssertEqual(service.state, .failed)
        XCTAssertNotNil(service.errorMessage)
        service.stop()
        XCTAssertEqual(service.state, .idle)
    }

    func testStreamDescriptorResolvesClearAndExplicitFairPlay() throws {
        let clear = Data(#"{"version":1,"manifestURL":"https://media.example/master.m3u8","protection":"clear"}"#.utf8)
        guard case .hls(let clearURL, let clearDRM) = try PlaybackSourceDescriptor.decode(clear) else {
            return XCTFail("Clear stream must resolve to HLS")
        }
        XCTAssertEqual(clearURL.host, "media.example")
        XCTAssertNil(clearDRM)
        let fairPlay = Data(#"{"version":1,"manifestURL":"https://media.example/master.m3u8","protection":"fairplay","certificateURL":"https://cert.example/app.der","licenseServerURL":"https://license.example/key","licenseFormat":"raw-spc-ckc","contentIDsByKeyURI":{"skd://asset":"asset-id"}}"#.utf8)
        guard case .hls(_, let drm) = try PlaybackSourceDescriptor.decode(fairPlay) else {
            return XCTFail("Configured FairPlay must resolve to HLS")
        }
        let configuration = try XCTUnwrap(drm)
        XCTAssertNil(configuration.authorization, "Credentials must be entered separately and remain ephemeral")
        XCTAssertEqual(try configuration.contentID(for: "skd://asset"), "asset-id")
    }

    func testDescriptorRejectsSecretsUnknownFormatsAndUnsupportedDRM() {
        let fixtures = [
            (#"{"version":2,"manifestURL":"https://media.example/master.m3u8","protection":"clear"}"#, PlaybackError.invalidDescriptor),
            (#"{"version":1,"manifestURL":"https://media.example/master.m3u8","protection":"widevine"}"#, .unsupportedProtection),
            (#"{"version":1,"manifestURL":"https://media.example/master.m3u8","protection":"playready"}"#, .unsupportedProtection),
            (#"{"version":1,"manifestURL":"http://media.example/master.m3u8","protection":"clear"}"#, .invalidDescriptor),
            (#"{"version":1,"manifestURL":"https://media.example/master.m3u8","protection":"clear","authorization":"test-only"}"#, .invalidDescriptor),
            (#"{"version":1,"manifestURL":"https://media.example/master.m3u8","protection":"clear","cookies":"test-only"}"#, .invalidDescriptor),
            (#"{"version":1,"manifestURL":"https://media.example/master.m3u8","protection":"clear","certificateURL":"https://cert.example/app.der"}"#, .invalidDescriptor),
            (#"{"version":1,"manifestURL":"https://media.example/master.m3u8","protection":"fairplay","certificateURL":"https://cert.example/app.der","licenseServerURL":"https://license.example/key","licenseFormat":"json","contentIDsByKeyURI":{"skd://asset":"asset-id"}}"#, .invalidDescriptor),
            (#"{"version":1,"manifestURL":"https://media.example/master.m3u8","protection":"fairplay","certificateURL":"https://cert.example/app.der","licenseServerURL":"https://license.example/key","licenseFormat":"raw-spc-ckc","contentIDsByKeyURI":{}}"#, .invalidDescriptor),
            ("not JSON", .invalidDescriptor)
        ]
        for (json, expected) in fixtures {
            XCTAssertThrowsError(try PlaybackSourceDescriptor.decode(Data(json.utf8))) {
                XCTAssertEqual($0 as? PlaybackError, expected)
            }
        }
        XCTAssertThrowsError(try PlaybackSourceDescriptor.decode(Data(repeating: 0, count: 65537))) {
            XCTAssertEqual($0 as? PlaybackError, .responseTooLarge)
        }
    }

    func testStreamDescriptorFileReadIsBoundedAndRejectsRemoteFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"version":1,"manifestURL":"https://media.example/master.m3u8","protection":"clear"}"#.utf8).write(to: file)
        guard case .hls = try PlaybackSourceDescriptor.read(from: file) else { return XCTFail("Expected HLS") }
        try Data(repeating: 0, count: 65537).write(to: file)
        XCTAssertThrowsError(try PlaybackSourceDescriptor.read(from: file)) {
            XCTAssertEqual($0 as? PlaybackError, .responseTooLarge)
        }
        XCTAssertThrowsError(try PlaybackSourceDescriptor.read(from: URL(string: "https://media.example/config.json")!))
    }

    func testFairPlayConfigurationRequiresExplicitKeyMapping() throws {
        let config = DRMConfiguration(certificateURL: URL(string: "https://cert.example/app.der")!,
                                      licenseServerURL: URL(string: "https://license.example/key")!,
                                      contentIDsByKeyURI: ["skd://first": "first-id", "skd://second": "second-id"])
        try config.validate()
        XCTAssertEqual(try config.contentID(for: "skd://first"), "first-id")
        XCTAssertEqual(try config.contentID(for: URL(string: "skd://second")!), "second-id")
        XCTAssertThrowsError(try config.contentID(for: "skd://unconfigured"))
        var malformed = config
        malformed.authorization = "Bearer token\r\nInjected: value"
        XCTAssertThrowsError(try malformed.validate())
    }

    func testPlaylistRewritesEveryNetworkReferenceAndRetainsAuthorizedSKD() throws {
        let input = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,URI="audio/main.m3u8"
        #EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery",URI="skd://asset"
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6,
        segment.ts?signature=test
        """
        var urls: [URL] = []
        let output = try HLSPlaybackGateway.rewritePlaylist(Data(input.utf8), baseURL: URL(string: "https://media.example/path/live.m3u8")!,
                                                          fairPlayKeys: ["skd://asset"]) { url in
            urls.append(url)
            return URL(string: "http://127.0.0.1:1234/" + String(urls.count))!
        }
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://media.example/path/audio/main.m3u8", "https://media.example/path/init.mp4", "https://media.example/path/segment.ts?signature=test"])
        XCTAssertTrue(text.contains("skd://asset"))
        XCTAssertFalse(text.contains("segment.ts"))
        XCTAssertFalse(text.contains("https://"))
    }

    func testPlaylistRejectsUnconfiguredOrUnsupportedProtectionAndEscapingReferences() {
        let fixtures = [
            "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT=\"com.apple.streamingkeydelivery\",URI=\"skd://unknown\"",
            "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT=\"other.drm\",URI=\"https://keys.example/key\"",
            "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"https://keys.example/key\"",
            "#EXTM3U\nhttp://media.example/segment.ts",
            "#EXTM3U\nfile:///private/segment.ts",
            "#EXTM3U\n#EXT-X-CONTENT-STEERING:SERVER-URI=\"https://steering.example/config\"",
            "#EXTM3U\n#EXT-X-DATERANGE:X-ASSET-LIST=\"https://ads.example/list.json\"",
            "#EXTM3U\nhttps://media.example/{$unresolved}.ts",
            "<html>invalid manifest</html>",
            "\u{FEFF}#EXTM3U\nhttps://media.example/segment.ts",
            "\n#EXTM3U\nhttps://media.example/segment.ts"
        ]
        for input in fixtures {
            XCTAssertThrowsError(try HLSPlaybackGateway.rewritePlaylist(Data(input.utf8), baseURL: URL(string: "https://media.example/live.m3u8")!, fairPlayKeys: []) { $0 })
        }
    }

    func testByteRangesUseRewrittenBodyLength() throws {
        let body = Data("0123456789".utf8)
        let result = try HLSPlaybackGateway.slice(body, range: "bytes=3-6")
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "3456")
        XCTAssertEqual(result.contentRange, "bytes 3-6/10")
        XCTAssertEqual(try HLSPlaybackGateway.slice(body, range: "bytes=8-").data, Data("89".utf8))
        XCTAssertThrowsError(try HLSPlaybackGateway.slice(body, range: "bytes=10-11"))
        XCTAssertThrowsError(try HLSPlaybackGateway.slice(body, range: "bytes=5-4"))
    }

    func testLicenseRedirectsCannotChangeOriginOrDowngrade() {
        let origin = URL(string: "https://license.example/key")!
        XCTAssertTrue(PlaybackRedirectPolicy.allows(URL(string: "https://license.example/renew")!, from: origin))
        for target in ["https://other.example/key", "https://license.example:8443/key", "http://license.example/key", "https://user:pass@license.example/key"] {
            XCTAssertFalse(PlaybackRedirectPolicy.allows(URL(string: target)!, from: origin))
        }
    }

    func testLoopbackGatewayRewritesAndServesRangesThenStops() async throws {
        let manifest = Data("#EXTM3U\n#EXTINF:1,\nsegment.ts\n".utf8)
        let (client, endpoint) = stub(status: 200, data: manifest, contentType: "application/vnd.apple.mpegurl")
        defer { client.invalidate() }
        let segmentURL = endpoint.deletingLastPathComponent().appendingPathComponent("segment.ts")
        PlaybackStubProtocol.responses.withLock {
            $0[segmentURL.absoluteString] = .init(status: 200, data: Data("0123456789".utf8), contentType: "video/mp2t")
        }
        defer { PlaybackStubProtocol.responses.withLock { _ = $0.removeValue(forKey: segmentURL.absoluteString) } }
        let gateway = HLSPlaybackGateway(client: client)
        let localURL = try await gateway.start(manifestURL: endpoint)
        do {
            _ = try await gateway.start(manifestURL: endpoint)
            XCTFail("Repeated startup must not orphan a listener")
        } catch { XCTAssertEqual(error as? PlaybackError, .invalidSource) }
        let localSession = URLSession(configuration: .ephemeral)
        defer { localSession.invalidateAndCancel() }
        let (playlist, response) = try await localSession.data(from: localURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(decoding: playlist, as: UTF8.self)
        let route = try XCTUnwrap(text.components(separatedBy: "\n").first(where: { $0.hasPrefix("http://127.0.0.1:") }))
        var request = URLRequest(url: try XCTUnwrap(URL(string: route)))
        request.setValue("bytes=3-6", forHTTPHeaderField: "Range")
        let (segment, segmentResponse) = try await localSession.data(for: request)
        XCTAssertEqual(segment, Data("3456".utf8))
        XCTAssertEqual((segmentResponse as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual((segmentResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 3-6/10")
        await gateway.stop()
        do {
            _ = try await localSession.data(from: localURL)
            XCTFail("Stopped gateway must close its listener")
        } catch { }
    }

    func testCancelledGatewayStartupReturnsWithoutWaitingForReadiness() async throws {
        let (client, endpoint) = stub(status: 200, data: Data("#EXTM3U".utf8))
        defer { client.invalidate() }
        let gateway = HLSPlaybackGateway(client: client)
        let task = Task { try await gateway.start(manifestURL: endpoint) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled startup must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        await gateway.stop()
    }

    func testGatewayRejectsMalformedExtensionlessManifest() async throws {
        let (client, endpoint) = stub(status: 200, data: Data("<html>not HLS</html>".utf8), contentType: "text/html")
        defer { client.invalidate() }
        let gateway = HLSPlaybackGateway(client: client)
        let localURL = try await gateway.start(manifestURL: endpoint)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: localURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
        XCTAssertTrue(data.isEmpty)
        await gateway.stop()
    }

    func testProductionTransportBlocksLoopbackUpstream() async throws {
        let client = try await PlaybackHTTPClient.make()
        defer { client.invalidate() }
        let gateway = HLSPlaybackGateway(client: client)
        let localURL = try await gateway.start(manifestURL: URL(string: "https://127.0.0.1/private.m3u8")!)
        let localSession = URLSession(configuration: .ephemeral)
        defer { localSession.invalidateAndCancel() }
        let (body, response) = try await localSession.data(from: localURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
        XCTAssertTrue(body.isEmpty)
        await gateway.stop()
    }

    func testRawLicenseExchangeAndCertificateRetrieval() async throws {
        let (client, endpoint) = stub(status: 200, data: Data([1, 2, 3]))
        defer { client.invalidate() }
        let provider = TrustedCertificateProvider(endpoint: endpoint, httpClient: client)
        let certificate = try await provider.fetchApplicationDrmCertificate()
        XCTAssertEqual(certificate, Data([1, 2, 3]))
        let license = LicenseClient(endpoint: endpoint, authorization: "Bearer test-only", httpClient: client)
        let ckc = try await license.requestCKC(spcData: Data([4, 5]), contentID: "test-id")
        XCTAssertEqual(ckc, certificate)
        let request = try XCTUnwrap(PlaybackStubProtocol.requests.withLock { $0[endpoint.absoluteString] })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.httpBody, Data([4, 5]))
    }

    func testLicenseDenialEmptyAndWrongContentTypeFail() async {
        for (status, data, type, expected) in [
            (403, Data([1]), "application/octet-stream", PlaybackError.httpStatus(403)),
            (401, Data([1]), "application/octet-stream", PlaybackError.httpStatus(401)),
            (200, Data(), "application/octet-stream", PlaybackError.invalidLicenseResponse),
            (200, Data("not-a-key".utf8), "text/html", PlaybackError.invalidLicenseResponse)
        ] {
            let (client, endpoint) = stub(status: status, data: data, contentType: type)
            defer { client.invalidate() }
            do {
                _ = try await LicenseClient(endpoint: endpoint, authorization: nil, httpClient: client).requestCKC(spcData: Data([1]), contentID: "test")
                XCTFail("Invalid license response must fail")
            } catch { XCTAssertEqual(error as? PlaybackError, expected) }
        }
    }

    func testBoundedResponseAndEmptyCertificate() async {
        let (client, endpoint) = stub(status: 200, data: Data([1, 2, 3]))
        defer { client.invalidate() }
        do {
            _ = try await client.fetch(URLRequest(url: endpoint), limit: 2, sameOriginOnly: true)
            XCTFail("Oversized response must fail")
        } catch { XCTAssertEqual(error as? PlaybackError, .responseTooLarge) }
        let (empty, emptyEndpoint) = stub(status: 200, data: Data())
        defer { empty.invalidate() }
        do {
            _ = try await TrustedCertificateProvider(endpoint: emptyEndpoint, httpClient: empty).fetchApplicationDrmCertificate()
            XCTFail("Empty certificate must fail")
        } catch { XCTAssertEqual(error as? PlaybackError, .invalidCertificate) }
    }

    func testCallbackCancellationBeforeAndAfterInstallationIgnoresLateResults() async {
        let early = PlaybackContinuation<Data>()
        early.resolve(.failure(CancellationError()))
        do {
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(early.install(continuation))
            }
            XCTFail("Cancelled bridge must fail")
        } catch { XCTAssertTrue(error is CancellationError) }

        let late = PlaybackContinuation<Data>()
        do {
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(late.install(continuation))
                late.resolve(.failure(CancellationError()))
                late.resolve(.success(Data([1])))
            }
            XCTFail("First terminal result must win")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func stub(status: Int, data: Data, contentType: String = "application/octet-stream") -> (PlaybackHTTPClient, URL) {
        let url = URL(string: "https://license.example/" + UUID().uuidString)!
        PlaybackStubProtocol.responses.withLock { $0[url.absoluteString] = .init(status: status, data: data, contentType: contentType) }
        addTeardownBlock {
            PlaybackStubProtocol.responses.withLock { _ = $0.removeValue(forKey: url.absoluteString) }
            PlaybackStubProtocol.requests.withLock { _ = $0.removeValue(forKey: url.absoluteString) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaybackStubProtocol.self]
        return (PlaybackHTTPClient(session: URLSession(configuration: configuration)), url)
    }

    private static func waveData() -> Data {
        var data = Data("RIFF".utf8)
        func word<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        let samples: UInt32 = 8000
        word(UInt32(36) + samples * 2)
        data.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(8000)); word(UInt32(16000)); word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8))
        word(samples * 2)
        data.append(Data(repeating: 0, count: Int(samples * 2)))
        return data
    }
}

private final class PlaybackStubProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable { let status: Int; let data: Data; let contentType: String }
    static let responses = Mutex<[String: Response]>([:])
    static let requests = Mutex<[String: URLRequest]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "license.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = Self.responses.withLock({ $0[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var captured = request
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.requests.withLock { $0[url.absoluteString] = captured }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil,
                                   headerFields: ["Content-Type": response.contentType])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
