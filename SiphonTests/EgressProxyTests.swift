//
//  EgressProxyTests.swift
//  SiphonTests
//

import XCTest
import Network
@testable import Siphon

final class EgressProxyTests: XCTestCase {
    func testConcurrentStartsShareOneListenerAndRestartAfterStop() async throws {
        let proxy = EgressProxyServer()
        async let first = proxy.start()
        async let second = proxy.start()
        let ports = try await [first, second]
        XCTAssertNotEqual(ports[0], 0)
        XCTAssertEqual(ports[0], ports[1], "Concurrent callers must share one listener")

        proxy.stop()
        let restarted = try await proxy.start()
        defer { proxy.stop() }
        XCTAssertNotEqual(restarted, 0)
    }

    func testProxyBlocksDirectLoopbackConnection() async throws {
        let proxy = EgressProxyServer()
        let proxyPort = try await proxy.start()
        defer { proxy.stop() }

        let response = try await sendThroughProxy(
            port: proxyPort,
            "CONNECT 127.0.0.1:\(proxyPort) HTTP/1.1\r\nHost: 127.0.0.1:\(proxyPort)\r\n\r\n"
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 403"), "Expected 403, got: \(response)")
    }

    func testProxyBlocksDirectPrivateIPConnection() async throws {
        let proxy = EgressProxyServer()
        let proxyPort = try await proxy.start()
        defer { proxy.stop() }

        let response = try await sendThroughProxy(
            port: proxyPort,
            "GET http://192.168.1.1/secret HTTP/1.1\r\nHost: 192.168.1.1\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 403"), "Expected 403, got: \(response)")
    }

    func testProxyBlocksRedirectToLoopback() async throws {
        let privateServer = MockHTTPServer()
        let privatePort = try privateServer.start { _ in
            (200, ["Content-Type": "text/plain"], Data("SECRET LEAKED".utf8))
        }
        defer { privateServer.stop() }

        let publicServer = MockHTTPServer()
        let publicPort = try publicServer.start { requestPath in
            if requestPath == "/redirect" {
                return (302, ["Location": "http://127.0.0.1:\(privatePort)/secret"], Data())
            }
            return (404, [:], Data())
        }
        defer { publicServer.stop() }

        // Treat the "public" mock as allowed; everything else uses the real policy.
        let proxy = EgressProxyServer(targetValidator: { host, port in
            if port == Int(publicPort) { return true }
            return ExternalDownloadTargetPolicy.isAllowedTarget(host: host, port: port)
        })
        let proxyPort = try await proxy.start()
        defer { proxy.stop() }

        let first = try await sendThroughProxy(
            port: proxyPort,
            "GET http://127.0.0.1:\(publicPort)/redirect HTTP/1.1\r\nHost: 127.0.0.1:\(publicPort)\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(first.hasPrefix("HTTP/1.1 302"), "Expected the redirect to pass through, got: \(first)")

        // Following the redirect through the proxy must be refused.
        let second = try await sendThroughProxy(
            port: proxyPort,
            "GET http://127.0.0.1:\(privatePort)/secret HTTP/1.1\r\nHost: 127.0.0.1:\(privatePort)\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(second.hasPrefix("HTTP/1.1 403"), "Expected 403, got: \(second)")
        XCTAssertFalse(second.contains("SECRET LEAKED"))

        XCTAssertEqual(privateServer.hitCount, 0, "Private loopback server must have received 0 requests")
        XCTAssertEqual(publicServer.hitCount, 1, "Public server must have received the initial request")
    }

    func testProxyChecksResolvedAddressesNotJustTheName() async throws {
        let server = MockHTTPServer()
        let serverPort = try server.start { _ in (200, [:], Data("REACHED".utf8)) }
        defer { server.stop() }

        // The name passes but none of its addresses do: the proxy must judge
        // (and connect to) what the name resolves to, not the name alone.
        let proxy = EgressProxyServer(targetValidator: { host, _ in host == "localhost" })
        let proxyPort = try await proxy.start()
        defer { proxy.stop() }

        let response = try await sendThroughProxy(
            port: proxyPort,
            "GET http://localhost:\(serverPort)/ HTTP/1.1\r\nHost: localhost:\(serverPort)\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 403"), "Expected 403, got: \(response)")
        XCTAssertEqual(server.hitCount, 0)
    }

    func testProxyFallsBackToNextResolvedAddress() async throws {
        // The mock listens on 127.0.0.1 only. A fixed resolver puts ::1 (which
        // refuses) first, so the request only succeeds through the fallback.
        let server = MockHTTPServer()
        let serverPort = try server.start { _ in (200, [:], Data("REACHED".utf8)) }
        defer { server.stop() }

        let proxy = EgressProxyServer(
            targetValidator: { _, port in port == Int(serverPort) },
            addressResolver: { _ in ["::1", "127.0.0.1"] }
        )
        let proxyPort = try await proxy.start()
        defer { proxy.stop() }

        let response = try await sendThroughProxy(
            port: proxyPort,
            "GET http://mock.example:\(serverPort)/ HTTP/1.1\r\nHost: mock.example:\(serverPort)\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), "Expected 200, got: \(response)")
        XCTAssertEqual(server.hitCount, 1)
    }

    func testProxyForwardsPercentEncodedPathUnchanged() async throws {
        let receivedPath = LockedValue<String?>(nil)
        let server = MockHTTPServer()
        let serverPort = try server.start { path in
            receivedPath.set(path)
            return (200, [:], Data("OK".utf8))
        }
        defer { server.stop() }

        let proxy = EgressProxyServer(targetValidator: { _, port in port == Int(serverPort) })
        let proxyPort = try await proxy.start()
        defer { proxy.stop() }

        let response = try await sendThroughProxy(
            port: proxyPort,
            "GET http://127.0.0.1:\(serverPort)/a%20b%2Fc?x=%26 HTTP/1.1\r\nHost: 127.0.0.1:\(serverPort)\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), "Expected 200, got: \(response)")
        XCTAssertEqual(receivedPath.get(), "/a%20b%2Fc?x=%26")
    }

    func testProxyForwardsOneRequestPerUpstreamConnection() async throws {
        let server = MockHTTPServer()
        let serverPort = try server.start { _ in (200, [:], Data("OK".utf8)) }
        defer { server.stop() }

        let proxy = EgressProxyServer(targetValidator: { _, port in port == Int(serverPort) })
        let proxyPort = try await proxy.start()
        defer { proxy.stop() }

        let response = try await sendThroughProxy(
            port: proxyPort,
            "GET http://127.0.0.1:\(serverPort)/ HTTP/1.1\r\nHost: 127.0.0.1:\(serverPort)\r\n" +
            "Connection: keep-alive\r\nProxy-Connection: keep-alive\r\nKeep-Alive: timeout=5\r\n" +
            "Proxy-Authorization: Basic c2VjcmV0\r\nX-Kept: yes\r\n\r\n"
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), "Expected 200, got: \(response)")

        let headerLines = server.lastRequestText.components(separatedBy: "\r\n").map { $0.lowercased() }
        XCTAssertEqual(headerLines.filter { $0.hasPrefix("connection:") }, ["connection: close"])
        XCTAssertFalse(headerLines.contains { $0.hasPrefix("proxy-connection:") || $0.hasPrefix("keep-alive:") || $0.hasPrefix("proxy-authorization:") })
        XCTAssertTrue(headerLines.contains("x-kept: yes"), "End-to-end headers must still reach the server")
    }

    func testBoundaryProxyIsAddedOnlyToUnproxiedYtdlpRuns() {
        let ytdlp = ["/Library/Siphon/yt-dlp", "--dump-json", "--", "https://example.com/v"]
        XCTAssertEqual(EgressBoundary.applying(to: ytdlp), ytdlp, "Unbound tasks run unchanged")

        EgressBoundary.$proxyURL.withValue("http://127.0.0.1:4321") {
            XCTAssertEqual(
                EgressBoundary.applying(to: ytdlp),
                ["/Library/Siphon/yt-dlp", "--proxy", "http://127.0.0.1:4321", "--dump-json", "--", "https://example.com/v"]
            )
            let ffmpeg = ["/Library/Siphon/ffmpeg", "-i", "in.mp4", "out.mp4"]
            XCTAssertEqual(EgressBoundary.applying(to: ffmpeg), ffmpeg, "Only yt-dlp talks to the network")
            let proxied = ["/Library/Siphon/yt-dlp", "--proxy", "http://127.0.0.1:1", "--", "https://example.com/v"]
            XCTAssertEqual(EgressBoundary.applying(to: proxied), proxied)
            XCTAssertFalse(EgressBoundary.session === URLSession.shared)
            XCTAssertEqual(EgressBoundary.webKitProxyConfigurations.count, 1)
        }
        XCTAssertTrue(EgressBoundary.session === URLSession.shared)
        XCTAssertTrue(EgressBoundary.webKitProxyConfigurations.isEmpty)
    }

    @MainActor
    func testWebKitStoresNeverShareAProxyAcrossEgressRoutes() {
        let service = YtdlpService()
        let proxyURL = "http://127.0.0.1:4321"
        let proxied = EgressBoundary.$proxyURL.withValue(proxyURL) { service.boyfriendTVWebDataStore }
        // A direct job starting while the boundary job's page is still loading.
        let direct = service.boyfriendTVWebDataStore

        XCTAssertFalse(direct === proxied)
        XCTAssertTrue(direct.proxyConfigurations.isEmpty)
        XCTAssertEqual(proxied.proxyConfigurations.count, 1, "The direct job must not clear the boundary proxy")
        XCTAssertTrue(EgressBoundary.$proxyURL.withValue(proxyURL) { service.boyfriendTVWebDataStore } === proxied)
    }

    func testRunnerAddsBoundaryProxyToResolverYtdlpRuns() async throws {
        // A stand-in yt-dlp that prints its arguments.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boundary_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("yt-dlp")
        try "#!/bin/sh\necho \"$@\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let output = try await EgressBoundary.$proxyURL.withValue("http://127.0.0.1:4321") {
            try await DefaultYtdlpProcessRunner().runCommand([script.path, "--dump-pages", "--", "https://example.com/v"])
        }
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "--proxy http://127.0.0.1:4321 --dump-pages -- https://example.com/v")
    }

    @MainActor
    func testRemovingProxyArguments() {
        let args = ["--proxy", "http://evil:8080", "--keep-video", "--proxy=http://other:8080"]
        let cleaned = YtdlpService.removingProxyArguments(args)
        XCTAssertEqual(cleaned, ["--keep-video"])
    }

    func testExternalDownloadTargetPolicyIsAllowedTarget() {
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "127.0.0.1"))
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "localhost"))
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "10.0.0.1"))
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "192.168.1.1"))
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "169.254.169.254"))
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "::1"))
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "fe80::1"))
    }

    func testTranslationPrefixesInheritIPv4Rules() {
        // NAT64 and 6to4 carry the IPv4 address a gateway connects to.
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "64:ff9b::7f00:1"), "NAT64 of 127.0.0.1")
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "64:ff9b::a9fe:a9fe"), "NAT64 of 169.254.169.254")
        XCTAssertTrue(ExternalDownloadTargetPolicy.isAllowedTarget(host: "64:ff9b::808:808"), "NAT64 of 8.8.8.8")
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "64:ff9b:1::808:808"), "Local-use NAT64 maps to private IPv4")
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "2002:c0a8:101::1"), "6to4 of 192.168.1.1")
        XCTAssertTrue(ExternalDownloadTargetPolicy.isAllowedTarget(host: "2002:808:808::1"), "6to4 of 8.8.8.8")
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "2001:0:4136:e378::1"), "Teredo")
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "::ffff:10.0.0.1"))
        XCTAssertTrue(ExternalDownloadTargetPolicy.isAllowedTarget(host: "2606:4700:4700::1111"))
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "192.0.2.10"))
        XCTAssertFalse(ExternalDownloadTargetPolicy.isAllowedTarget(host: "192.0.0.170"))
        XCTAssertTrue(ExternalDownloadTargetPolicy.isAllowedTarget(host: "8.8.8.8"))
    }
}

/// Sends `request` straight to the proxy over a raw socket and returns the
/// whole response, so a test cannot pass unless the proxy itself answers.
private func sendThroughProxy(port: UInt16, _ request: String) async throws -> String {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    defer { connection.cancel() }
    let response = LockedValue(Data())
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
        let resumed = LockedValue(false)
        @Sendable func finish(_ error: Error?) {
            guard resumed.swap(true) == false else { return }
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: String(decoding: response.get(), as: UTF8.self))
            }
        }
        @Sendable func receiveAll() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let content { response.mutate { $0.append(content) } }
                if isComplete || error != nil {
                    finish(nil)
                } else {
                    receiveAll()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if let error { finish(error) } else { receiveAll() }
                })
            case .waiting(let error), .failed(let error):
                finish(error)
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
    func swap(_ newValue: T) -> T {
        lock.withLock {
            let old = value
            value = newValue
            return old
        }
    }
}

private final class MockHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.marspater.siphon.mock-http")
    private var hits: Int = 0
    private var lastRequest = ""
    private let lock = NSLock()

    var hitCount: Int { lock.withLock { hits } }
    var lastRequestText: String { lock.withLock { lastRequest } }

    func start(handler: @escaping @Sendable (String) -> (statusCode: Int, headers: [String: String], body: Data)) throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                guard let data = data, let text = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                let firstLine = text.components(separatedBy: "\r\n").first ?? ""
                let parts = firstLine.split(separator: " ")
                let path = parts.count > 1 ? String(parts[1]) : "/"

                self.lock.withLock {
                    self.hits += 1
                    self.lastRequest = text
                }

                let result = handler(path)
                var response = "HTTP/1.1 \(result.statusCode) OK\r\nContent-Length: \(result.body.count)\r\nConnection: close\r\n"
                for (k, v) in result.headers {
                    response += "\(k): \(v)\r\n"
                }
                response += "\r\n"
                var responseData = Data(response.utf8)
                responseData.append(result.body)
                connection.send(content: responseData, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        let semaphore = DispatchSemaphore(value: 0)
        final class PortBox: @unchecked Sendable {
            var value: UInt16 = 0
        }
        let portBox = PortBox()
        l.stateUpdateHandler = { state in
            if case .ready = state {
                portBox.value = l.port?.rawValue ?? 0
                semaphore.signal()
            }
        }
        l.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 5)
        self.listener = l
        return portBox.value
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
