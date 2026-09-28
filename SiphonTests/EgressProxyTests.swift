//
//  EgressProxyTests.swift
//  SiphonTests
//

import XCTest
import Network
@testable import Siphon

final class EgressProxyTests: XCTestCase {
    func testProxyBlocksDirectLoopbackConnection() async throws {
        let proxy = EgressProxyServer()
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPPort: proxyPort
        ]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let url = URL(string: "http://127.0.0.1:\(proxyPort)/test")!
        do {
            let (_, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse {
                XCTAssertEqual(http.statusCode, 403)
            } else {
                XCTFail("Expected 403 Forbidden, got \(response)")
            }
        } catch {
            XCTAssertTrue(true)
        }
    }

    func testProxyBlocksDirectPrivateIPConnection() async throws {
        let proxy = EgressProxyServer()
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPPort: proxyPort
        ]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let url = URL(string: "http://192.168.1.1/secret")!
        do {
            let (_, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse {
                XCTAssertEqual(http.statusCode, 403)
            } else {
                XCTFail("Expected 403 Forbidden, got \(response)")
            }
        } catch {
            XCTAssertTrue(true)
        }
    }

    func testProxyBlocksRedirectToLoopback() async throws {
        let privateServer = MockHTTPServer()
        let privatePort = try privateServer.start { _ in
            XCTFail("Private server must not be contacted!")
            return (200, ["Content-Type": "text/plain"], Data("SECRET LEAKED".utf8))
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

        let proxy = EgressProxyServer(targetValidator: { host, port in
            if port == Int(publicPort) { return true }
            return ExternalDownloadTargetPolicy.isAllowedTarget(host: host, port: port)
        })
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPPort: proxyPort
        ]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let targetURL = URL(string: "http://127.0.0.1:\(publicPort)/redirect")!
        do {
            let (data, response) = try await session.data(from: targetURL)
            let body = String(data: data, encoding: .utf8) ?? ""
            XCTAssertFalse(body.contains("SECRET LEAKED"), "Proxy must have prevented reaching the loopback secret")
            if let http = response as? HTTPURLResponse {
                XCTAssertEqual(http.statusCode, 403, "Redirect to loopback must return 403 Forbidden")
            }
        } catch {
            XCTAssertTrue(true)
        }

        XCTAssertEqual(privateServer.hitCount, 0, "Private loopback server must have received 0 requests")
        XCTAssertGreaterThanOrEqual(publicServer.hitCount, 1, "Public server must have received the initial request")
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
}

private final class MockHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.marspater.siphon.mock-http")
    private(set) var hitCount: Int = 0
    private let lock = NSLock()

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

                self.lock.lock()
                self.hitCount += 1
                self.lock.unlock()

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
