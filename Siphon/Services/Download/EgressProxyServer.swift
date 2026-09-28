//
//  EgressProxyServer.swift
//  Siphon
//

import Foundation
import Network

/// A localhost-bound forward/tunneling proxy that enforces the public network boundary
/// at connection time for external deep-link downloads.
///
/// It intercepts every connection and every redirect, validating that the destination host
/// and its resolved IP addresses are globally routable. Any private, loopback, link-local,
/// or reserved destination is rejected with HTTP 403 Forbidden.
public final class EgressProxyServer: @unchecked Sendable {
    public static let shared = EgressProxyServer()

    public typealias TargetValidator = @Sendable (_ host: String, _ port: Int) -> Bool

    private let queue = DispatchQueue(label: "com.marspater.siphon.egress-proxy", attributes: .concurrent)
    private let targetValidator: TargetValidator
    private let lock = NSLock()

    private var listener: NWListener?
    private var isStarted = false
    public private(set) var port: UInt16 = 0

    public init(targetValidator: TargetValidator? = nil) {
        self.targetValidator = targetValidator ?? { host, port in
            ExternalDownloadTargetPolicy.isAllowedTarget(host: host, port: port)
        }
    }

    /// Starts the proxy listener on a random ephemeral port bound strictly to 127.0.0.1.
    @discardableResult
    public func start() throws -> UInt16 {
        lock.lock()
        if isStarted, port > 0 {
            let p = port
            lock.unlock()
            return p
        }
        lock.unlock()

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        let newListener = try NWListener(using: params)
        let readySemaphore = DispatchSemaphore(value: 0)
        let startupErrorBox = AtomicBox<Error?>(nil)

        newListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let assignedPort = newListener.port?.rawValue {
                    self?.lock.lock()
                    self?.port = assignedPort
                    self?.isStarted = true
                    self?.lock.unlock()
                }
                readySemaphore.signal()
            case .failed(let error):
                startupErrorBox.set(error)
                readySemaphore.signal()
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] clientConn in
            self?.handleClientConnection(clientConn)
        }

        newListener.start(queue: queue)

        let waitResult = readySemaphore.wait(timeout: .now() + 5.0)
        if waitResult == .timedOut {
            newListener.cancel()
            throw NSError(domain: "EgressProxyServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Proxy listener startup timed out"])
        }
        if let error = startupErrorBox.get() {
            newListener.cancel()
            throw error
        }

        lock.lock()
        self.listener = newListener
        let finalPort = self.port
        lock.unlock()

        return finalPort
    }

    public func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        isStarted = false
        port = 0
        lock.unlock()
    }

    private func handleClientConnection(_ client: NWConnection) {
        client.start(queue: queue)
        receiveInitialRequest(client: client, accumulatedData: Data())
    }

    private func receiveInitialRequest(client: NWConnection, accumulatedData: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] content, _, isComplete, error in
            guard let self = self else {
                client.cancel()
                return
            }

            if error != nil {
                client.cancel()
                return
            }

            var buffer = accumulatedData
            if let data = content, !data.isEmpty {
                buffer.append(data)
            }

            // Look for header boundary: \r\n\r\n or \n\n
            if let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
                let remainingData = buffer.subdata(in: headerEndRange.upperBound..<buffer.count)
                self.processRequest(client: client, headerData: headerData, remainingData: remainingData)
            } else if let headerEndRange = buffer.range(of: Data("\n\n".utf8)) {
                let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
                let remainingData = buffer.subdata(in: headerEndRange.upperBound..<buffer.count)
                self.processRequest(client: client, headerData: headerData, remainingData: remainingData)
            } else if isComplete || buffer.count > 32768 {
                self.sendResponse(client: client, status: "400 Bad Request", body: "Header too large\n", close: true)
            } else {
                self.receiveInitialRequest(client: client, accumulatedData: buffer)
            }
        }
    }

    private func processRequest(client: NWConnection, headerData: Data, remainingData: Data) {
        guard let headerString = String(data: headerData, encoding: .utf8) ?? String(data: headerData, encoding: .isoLatin1) else {
            sendResponse(client: client, status: "400 Bad Request", body: "Malformed header\n", close: true)
            return
        }

        let lines = headerString.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
        guard let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines), !firstLine.isEmpty else {
            sendResponse(client: client, status: "400 Bad Request", body: "Empty request\n", close: true)
            return
        }

        let parts = firstLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            sendResponse(client: client, status: "400 Bad Request", body: "Invalid request line\n", close: true)
            return
        }

        let method = parts[0].uppercased()
        let target = parts[1]

        if method == "CONNECT" {
            handleConnect(client: client, target: target, remainingData: remainingData)
        } else {
            handleForwardRequest(client: client, method: method, target: target, lines: lines, remainingData: remainingData)
        }
    }

    private func handleConnect(client: NWConnection, target: String, remainingData: Data) {
        guard let (host, port) = Self.parseHostAndPort(target, defaultPort: 443) else {
            sendResponse(client: client, status: "400 Bad Request", body: "Invalid CONNECT target\n", close: true)
            return
        }

        guard let addresses = approvedAddresses(host: host, port: port) else {
            Task { @MainActor in
                LoggerService.shared.log("Egress proxy blocked CONNECT target outside public network: \(host):\(port)", level: .warning)
            }
            sendResponse(client: client, status: "403 Forbidden", body: "Blocked: Private or reserved destination\n", close: true)
            return
        }

        connectUpstream(addresses: addresses[...], port: port) { [weak self] upstreamResult in
            guard let self = self else {
                client.cancel()
                return
            }

            switch upstreamResult {
            case .failure:
                self.sendResponse(client: client, status: "502 Bad Gateway", body: "Failed to connect to destination\n", close: true)
            case .success(let upstream):
                let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
                client.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] sendError in
                    guard let self = self, sendError == nil else {
                        client.cancel()
                        upstream.cancel()
                        return
                    }

                    if !remainingData.isEmpty {
                        upstream.send(content: remainingData, completion: .contentProcessed { _ in })
                    }

                    self.bridgeConnections(client: client, upstream: upstream)
                })
            }
        }
    }

    private func handleForwardRequest(client: NWConnection, method: String, target: String, lines: [String], remainingData: Data) {
        let host: String
        let port: Int
        let relativePath: String

        if let url = URL(string: target), let urlHost = url.host {
            host = urlHost
            port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
            // Keep the path as the client encoded it; URL.path would decode
            // %20/%2F and forward an invalid or different request line.
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let path = components?.percentEncodedPath ?? ""
            let query = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
            relativePath = (path.isEmpty ? "/" : path) + query
        } else {
            var hostHeaderValue: String?
            for line in lines.dropFirst() {
                if line.lowercased().hasPrefix("host:") {
                    hostHeaderValue = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            guard let hostVal = hostHeaderValue, let (h, p) = Self.parseHostAndPort(hostVal, defaultPort: 80) else {
                sendResponse(client: client, status: "400 Bad Request", body: "Missing Host header\n", close: true)
                return
            }
            host = h
            port = p
            relativePath = target
        }

        guard let addresses = approvedAddresses(host: host, port: port) else {
            Task { @MainActor in
                LoggerService.shared.log("Egress proxy blocked HTTP target outside public network: \(host):\(port)", level: .warning)
            }
            sendResponse(client: client, status: "403 Forbidden", body: "Blocked: Private or reserved destination\n", close: true)
            return
        }

        connectUpstream(addresses: addresses[...], port: port) { [weak self] upstreamResult in
            guard let self = self else {
                client.cancel()
                return
            }

            switch upstreamResult {
            case .failure:
                self.sendResponse(client: client, status: "502 Bad Gateway", body: "Failed to connect to destination\n", close: true)
            case .success(let upstream):
                var forwardedHeaders = "\(method) \(relativePath) HTTP/1.1\r\n"
                for line in lines.dropFirst() {
                    let lower = line.lowercased()
                    if lower.hasPrefix("proxy-connection:") {
                        forwardedHeaders += "Connection: close\r\n"
                    } else {
                        forwardedHeaders += "\(line)\r\n"
                    }
                }
                forwardedHeaders += "\r\n"

                var payload = Data(forwardedHeaders.utf8)
                payload.append(remainingData)

                upstream.send(content: payload, completion: .contentProcessed { [weak self] sendError in
                    guard let self = self, sendError == nil else {
                        client.cancel()
                        upstream.cancel()
                        return
                    }
                    self.bridgeConnections(client: client, upstream: upstream)
                })
            }
        }
    }

    /// Resolves `host` once and returns the numeric addresses to connect to, only
    /// when the name and every address it resolves to pass the validator.
    /// Connecting to those exact addresses, instead of letting NWConnection resolve
    /// the name again, closes the DNS-rebinding window between check and connect.
    private func approvedAddresses(host: String, port: Int) -> [String]? {
        guard targetValidator(host, port) else { return nil }
        let addresses = Self.resolveNumericAddresses(host)
        guard !addresses.isEmpty,
              addresses.allSatisfy({ targetValidator($0, port) }) else {
            return nil
        }
        return addresses
    }

    private static func resolveNumericAddresses(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var current = result
        while let info = current {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let addr = info.pointee.ai_addr,
               getnameinfo(addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
            current = info.pointee.ai_next
        }
        return addresses
    }

    private static let upstreamConnectTimeout: TimeInterval = 15

    /// Tries the validated addresses in resolver order, moving on when one fails,
    /// since pinning addresses gives up NWConnection's own Happy Eyeballs fallback.
    private func connectUpstream(addresses: ArraySlice<String>, port: Int, completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void) {
        guard let address = addresses.first else {
            completion(.failure(NSError(domain: "EgressProxyServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No address to connect to"])))
            return
        }
        connectUpstream(address: address, port: port) { [weak self] result in
            if case .failure = result, addresses.count > 1, let self {
                self.connectUpstream(addresses: addresses.dropFirst(), port: port, completion: completion)
            } else {
                completion(result)
            }
        }
    }

    private func connectUpstream(address: String, port: Int, completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            completion(.failure(NSError(domain: "EgressProxyServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])))
            return
        }

        let upstream = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: .tcp)
        let completedBox = AtomicBox<Bool>(false)
        let fail: @Sendable (Error) -> Void = { error in
            if completedBox.compareAndSet(expected: false, newValue: true) {
                upstream.cancel()
                completion(.failure(error))
            }
        }

        upstream.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if completedBox.compareAndSet(expected: false, newValue: true) {
                    completion(.success(upstream))
                }
            // .waiting means no usable path (refused, unreachable); NWConnection
            // would retry indefinitely and hold the client connection open.
            case .waiting(let err), .failed(let err):
                fail(err)
            case .cancelled:
                fail(NSError(domain: "EgressProxyServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection cancelled"]))
            default:
                break
            }
        }

        upstream.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.upstreamConnectTimeout) {
            fail(NSError(domain: "EgressProxyServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Upstream connect timed out"]))
        }
    }

    private func bridgeConnections(client: NWConnection, upstream: NWConnection) {
        pipe(from: client, to: upstream)
        pipe(from: upstream, to: client)
    }

    private func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else {
                source.cancel()
                destination.cancel()
                return
            }

            if let data = content, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError == nil && !isComplete && error == nil {
                        self.pipe(from: source, to: destination)
                    } else {
                        source.cancel()
                        destination.cancel()
                    }
                })
            } else {
                source.cancel()
                destination.cancel()
            }
        }
    }

    private func sendResponse(client: NWConnection, status: String, body: String, close: Bool) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        client.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            if close {
                client.cancel()
            }
        })
    }

    private static func parseHostAndPort(_ string: String, defaultPort: Int) -> (host: String, port: Int)? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[") {
            guard let closeIndex = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIndex])
            let after = trimmed[trimmed.index(after: closeIndex)...]
            if after.hasPrefix(":") {
                let portStr = String(after.dropFirst())
                guard let port = Int(portStr), (1...65535).contains(port) else { return nil }
                return (host, port)
            }
            return (host, defaultPort)
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            let host = String(parts[0])
            guard let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
            return (host, port)
        } else if parts.count == 1 {
            return (String(parts[0]), defaultPort)
        }
        return nil
    }
}

private final class AtomicBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: T) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func compareAndSet(expected: T, newValue: T) -> Bool where T: Equatable {
        lock.lock()
        defer { lock.unlock() }
        if value == expected {
            value = newValue
            return true
        }
        return false
    }
}

