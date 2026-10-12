//
//  EgressProxyServer.swift
//  Siphon
//

import Foundation
import Network

/// The egress proxy of the boundary-enforced job the current task works for.
/// Site resolvers deep in YtdlpService launch their own yt-dlp runs, URLSession
/// requests and WebKit sessions; binding the proxy here covers all of them
/// without threading a parameter through each one.
enum EgressBoundary {
    @TaskLocal static var proxyURL: String?

    /// `args` with the bound proxy added when they launch yt-dlp without one.
    static func applying(to args: [String]) -> [String] {
        guard let proxyURL,
              let executable = args.first,
              URL(fileURLWithPath: executable).lastPathComponent.hasPrefix("yt-dlp"),
              !args.contains(where: { $0 == "--proxy" || $0.hasPrefix("--proxy=") }) else {
            return args
        }
        return [executable, "--proxy", proxyURL] + args.dropFirst()
    }

    /// The session for resolver requests: through the bound proxy, else shared.
    static var session: URLSession {
        guard let endpoint = proxyEndpoint else { return .shared }
        return sessionLock.withLock {
            if let cached = sessions[endpoint.port] { return cached }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: endpoint.host,
                kCFNetworkProxiesHTTPPort as String: endpoint.port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: endpoint.host,
                kCFNetworkProxiesHTTPSPort as String: endpoint.port
            ]
            let session = URLSession(configuration: configuration)
            sessions[endpoint.port] = session
            return session
        }
    }

    /// WebKit proxy settings for a website data store: the bound proxy, or none.
    static var webKitProxyConfigurations: [ProxyConfiguration] {
        guard let endpoint = proxyEndpoint,
              let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else { return [] }
        return [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(endpoint.host), port: port))]
    }

    private static var proxyEndpoint: (host: String, port: Int)? {
        guard let proxyURL, let url = URL(string: proxyURL), let host = url.host, let port = url.port else { return nil }
        return (host, port)
    }

    private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var sessions: [Int: URLSession] = [:]
}

/// A localhost-bound forward/tunneling proxy that enforces the public network boundary
/// at connection time for external deep-link downloads.
///
/// It intercepts every connection and every redirect, validating that the destination host
/// and its resolved IP addresses are globally routable. Any private, loopback, link-local,
/// or reserved destination is rejected with HTTP 403 Forbidden.
public final class EgressProxyServer: @unchecked Sendable {
    public static let shared = EgressProxyServer()

    public typealias TargetValidator = @Sendable (_ host: String, _ port: Int) -> Bool
    public typealias AddressResolver = @Sendable (_ host: String) -> [String]

    private let queue = DispatchQueue(label: "com.marspater.siphon.egress-proxy", attributes: .concurrent)
    private let targetValidator: TargetValidator
    private let addressResolver: AddressResolver
    private let lock = NSLock()

    private(set) var listener: NWListener?
    private var startTask: Task<UInt16, Error>?
    public private(set) var port: UInt16 = 0

    public init(targetValidator: TargetValidator? = nil, addressResolver: AddressResolver? = nil) {
        self.targetValidator = targetValidator ?? { host, port in
            ExternalDownloadTargetPolicy.isAllowedTarget(host: host, port: port)
        }
        self.addressResolver = addressResolver ?? Self.resolveNumericAddresses
    }

    /// Starts the proxy listener on a random ephemeral port bound strictly to 127.0.0.1.
    /// Concurrent callers share one startup; readiness is awaited, never blocked on,
    /// so main-actor callers stay responsive while Network.framework brings it up.
    @discardableResult
    public func start() async throws -> UInt16 {
        let task: Task<UInt16, Error> = lock.withLock {
            if let startTask {
                // A listener that dies after startup never recovers; replace it
                // rather than hand out its dead port.
                switch listener?.state {
                case .failed?, .cancelled?:
                    listener?.cancel()
                    listener = nil
                    port = 0
                    Task { @MainActor in
                        LoggerService.shared.log("Egress proxy listener stopped after startup; restarting it", level: .warning)
                    }
                default:
                    return startTask
                }
            }
            let task = Task { try await self.startListener() }
            startTask = task
            return task
        }
        do {
            return try await task.value
        } catch {
            lock.withLock {
                if startTask == task { startTask = nil }
            }
            throw error
        }
    }

    private func startListener() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        let newListener = try NWListener(using: params)
        newListener.newConnectionHandler = { [weak self] clientConn in
            self?.handleClientConnection(clientConn)
        }

        let assignedPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = AtomicBox(false)
            let finish: @Sendable (Result<UInt16, Error>) -> Void = { result in
                guard resumed.compareAndSet(expected: false, newValue: true) else { return }
                if case .failure = result { newListener.cancel() }
                continuation.resume(with: result)
            }

            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = newListener.port?.rawValue {
                        finish(.success(port))
                    } else {
                        finish(.failure(NSError(domain: "EgressProxyServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Proxy listener has no port"])))
                    }
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CancellationError()))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + 5.0) {
                finish(.failure(NSError(domain: "EgressProxyServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Proxy listener startup timed out"])))
            }
            newListener.start(queue: queue)
        }

        // stop() cancels the start task under this lock, so checking here (not
        // before taking it) means a stop() that ran while the listener was coming
        // up is always seen, and one that runs later always finds it to cancel.
        let published = lock.withLock { () -> Bool in
            guard !Task.isCancelled else { return false }
            listener?.cancel()
            listener = newListener
            port = assignedPort
            return true
        }
        guard published else {
            newListener.cancel()
            throw CancellationError()
        }
        return assignedPort
    }

    public func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        startTask?.cancel()
        startTask = nil
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
            let boundaryRange = buffer.range(of: Data("\r\n\r\n".utf8)) ?? buffer.range(of: Data("\n\n".utf8))
            if let headerEndRange = boundaryRange {
                guard headerEndRange.lowerBound <= 32768 else {
                    self.sendResponse(client: client, status: "400 Bad Request", body: "Header too large\n", close: true)
                    return
                }
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

        // Bolt Performance Optimization: Use Substring views directly from split(whereSeparator: \.isNewline) and split(separator: " ") without calling .map(String.init) to eliminate per-line heap allocations for header strings on every proxy request.
        let lines = headerString.split(whereSeparator: \.isNewline)
        guard let rawFirstLine = lines.first else {
            sendResponse(client: client, status: "400 Bad Request", body: "Empty request\n", close: true)
            return
        }
        let firstLine = rawFirstLine.trimmingWhitespace()
        guard !firstLine.isEmpty else {
            sendResponse(client: client, status: "400 Bad Request", body: "Empty request\n", close: true)
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[2])),
              parts[0].allSatisfy({ Self.httpTokenCharacters.contains($0) }),
              parts[1].utf8.allSatisfy({ $0 > 32 && $0 != 127 }) else {
            sendResponse(client: client, status: "400 Bad Request", body: "Invalid request line\n", close: true)
            return
        }

        let method = parts[0].uppercased()
        let target = String(parts[1])

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
                self.handleConnectEstablished(client: client, upstream: upstream, remainingData: remainingData)
            }
        }
    }

    private func handleConnectEstablished(client: NWConnection, upstream: NWConnection, remainingData: Data) {
        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        client.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] sendError in
            guard let self = self, sendError == nil else {
                client.cancel()
                upstream.cancel()
                return
            }

            if !remainingData.isEmpty {
                upstream.send(content: remainingData, completion: .contentProcessed { _ in
                    // Remaining data buffered before connection established was forwarded; ignore send errors
                })
            }

            self.bridgeConnections(client: client, upstream: upstream)
        })
    }

    private func handleForwardRequest(client: NWConnection, method: String, target: String, lines: [Substring], remainingData: Data) {
        // Reject ambiguous/unsupported framing before opening any upstream.
        guard let request = Self.forwardRequestHeaders(lines) else {
            sendResponse(client: client, status: "400 Bad Request", body: "Invalid HTTP request framing\n", close: true)
            return
        }
        guard !request.hasTransferEncoding else {
            sendResponse(client: client, status: "501 Not Implemented", body: "Transfer-Encoding request bodies are unsupported\n", close: true)
            return
        }
        let host: String
        let port: Int
        let relativePath: String
        let authority: String

        if let url = URL(string: target), let urlHost = url.host {
            guard url.scheme?.lowercased() == "http", url.user == nil, url.password == nil, url.fragment == nil else {
                sendResponse(client: client, status: "400 Bad Request", body: "Use CONNECT for HTTPS\n", close: true)
                return
            }
            host = urlHost
            port = url.port ?? 80
            guard (1...65535).contains(port) else {
                sendResponse(client: client, status: "400 Bad Request", body: "Invalid port\n", close: true)
                return
            }
            authority = urlHost + (url.port.map { ":\($0)" } ?? "")
            // Keep the path as the client encoded it; URL.path would decode
            // %20/%2F and forward an invalid or different request line.
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let path = components?.percentEncodedPath ?? ""
            let query = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
            relativePath = (path.isEmpty ? "/" : path) + query
        } else {
            guard target.hasPrefix("/"), !target.hasPrefix("//") else {
                sendResponse(client: client, status: "400 Bad Request", body: "Invalid request target\n", close: true)
                return
            }
            var hostHeaderValue: Substring?
            for line in lines.dropFirst() {
                let trimmedLine = line.trimmingWhitespace()
                if let colon = trimmedLine.firstIndex(of: ":"),
                   trimmedLine[..<colon].caseInsensitiveCompare("host") == .orderedSame {
                    hostHeaderValue = trimmedLine[trimmedLine.index(after: colon)...].trimmingWhitespace()
                    break
                }
            }
            guard let hostVal = hostHeaderValue, let (h, p) = Self.parseHostAndPort(hostVal, defaultPort: 80) else {
                sendResponse(client: client, status: "400 Bad Request", body: "Missing Host header\n", close: true)
                return
            }
            host = h
            port = p
            authority = String(hostVal)
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
                // Canonicalize routing and framing fields; never reuse this
                // connection for a subsequent HTTP request.
                var forwardedHeaders = ""
                let estimatedCapacity = lines.reduce(0) { $0 + $1.count + 2 } + 64
                forwardedHeaders.reserveCapacity(estimatedCapacity)
                forwardedHeaders.append(method)
                forwardedHeaders.append(" ")
                forwardedHeaders.append(relativePath)
                forwardedHeaders.append(" HTTP/1.1\r\n")
                for line in request.forwardedLines {
                    forwardedHeaders.append(contentsOf: line)
                    forwardedHeaders.append("\r\n")
                }
                forwardedHeaders.append("Host: \(authority)\r\n")
                if request.hasContentLength {
                    forwardedHeaders.append("Content-Length: \(request.bodyLength)\r\n")
                }
                forwardedHeaders.append("Connection: close\r\n\r\n")

                let bufferedBody = remainingData.prefix(request.bodyLength)
                var payload = Data(forwardedHeaders.utf8)
                payload.append(bufferedBody)

                upstream.send(content: payload, completion: .contentProcessed { [weak self] sendError in
                    guard let self = self, sendError == nil else {
                        client.cancel()
                        upstream.cancel()
                        return
                    }
                    // Only the response is an unrestricted stream. Uploads
                    // stop exactly at Content-Length, even across TCP receives.
                    self.pipe(from: upstream, to: client, completion: {
                        client.cancel()
                        upstream.cancel()
                    })
                    self.forwardBody(client: client, upstream: upstream, remaining: request.bodyLength - bufferedBody.count)
                })
            }
        }
    }

    private func forwardBody(client: NWConnection, upstream: NWConnection, remaining: Int) {
        guard remaining > 0 else {
            upstream.send(content: nil, contentContext: .finalMessage, isComplete: true,
                          completion: .contentProcessed { error in
                if error != nil { client.cancel(); upstream.cancel() }
            })
            return
        }
        client.receive(minimumIncompleteLength: 1, maximumLength: min(65536, remaining)) { [weak self] content, _, isComplete, error in
            guard let self, error == nil, let content, !content.isEmpty else {
                client.cancel()
                upstream.cancel()
                return
            }
            let body = content.prefix(remaining)
            let left = remaining - body.count
            upstream.send(content: Data(body), completion: .contentProcessed { sendError in
                guard sendError == nil, !isComplete || left == 0 else {
                    client.cancel()
                    upstream.cancel()
                    return
                }
                self.forwardBody(client: client, upstream: upstream, remaining: left)
            })
        }
    }

    /// Resolves `host` once and returns the numeric addresses to connect to, only
    /// when the name and every address it resolves to pass the validator.
    /// Connecting to those exact addresses, instead of letting NWConnection resolve
    /// the name again, closes the DNS-rebinding window between check and connect.
    private func approvedAddresses(host: String, port: Int) -> [String]? {
        guard targetValidator(host, port) else { return nil }
        let addresses = addressResolver(host)
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

    /// Budget for the whole address walk, and for any single address in it.
    private static let upstreamConnectTimeout: TimeInterval = 15
    private static let perAddressConnectTimeout: TimeInterval = 5

    /// Tries the validated addresses in resolver order, moving on when one fails,
    /// since pinning addresses gives up NWConnection's own Happy Eyeballs fallback.
    /// One deadline bounds the whole walk, however many addresses DNS returned.
    private func connectUpstream(
        addresses: ArraySlice<String>,
        port: Int,
        deadline: DispatchTime = .now() + EgressProxyServer.upstreamConnectTimeout,
        completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void
    ) {
        guard let address = addresses.first, DispatchTime.now() < deadline else {
            completion(.failure(NSError(domain: "EgressProxyServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Upstream connect timed out"])))
            return
        }
        let attemptDeadline = min(deadline, .now() + Self.perAddressConnectTimeout)
        connectUpstream(address: address, port: port, deadline: attemptDeadline) { [weak self] result in
            if case .failure = result, addresses.count > 1, let self {
                self.connectUpstream(addresses: addresses.dropFirst(), port: port, deadline: deadline, completion: completion)
            } else {
                completion(result)
            }
        }
    }

    private func connectUpstream(address: String, port: Int, deadline: DispatchTime, completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void) {
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
        queue.asyncAfter(deadline: deadline) {
            fail(NSError(domain: "EgressProxyServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Upstream connect timed out"]))
        }
    }

    private func bridgeConnections(client: NWConnection, upstream: NWConnection) {
        let firstFinished = AtomicBox(false)
        let finish: @Sendable () -> Void = {
            if !firstFinished.compareAndSet(expected: false, newValue: true) {
                client.cancel()
                upstream.cancel()
            }
        }
        pipe(from: client, to: upstream, completion: finish)
        pipe(from: upstream, to: client, completion: finish)
    }

    /// EOF finishes only this direction after its final bytes have drained.
    private func pipe(from source: NWConnection, to destination: NWConnection, completion: @escaping @Sendable () -> Void) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self, error == nil else {
                source.cancel()
                destination.cancel()
                return
            }
            destination.send(content: content, contentContext: isComplete ? .finalMessage : .defaultMessage,
                             isComplete: true, completion: .contentProcessed { sendError in
                guard sendError == nil else {
                    source.cancel()
                    destination.cancel()
                    return
                }
                if isComplete {
                    completion()
                } else {
                    self.pipe(from: source, to: destination, completion: completion)
                }
            })
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

    private static let hopByHopHeaders: Set<String> = [
        "connection", "proxy-connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "trailers", "transfer-encoding", "upgrade"
    ]

    private static let httpTokenCharacters = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    private struct ForwardHeaders {
        let forwardedLines: [Substring]
        let bodyLength: Int
        let hasContentLength: Bool
        let hasTransferEncoding: Bool
    }

    private struct RequestHeader {
        let name: String
        let value: Substring
        let line: Substring

        init?(_ line: Substring) {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon]
            guard !name.isEmpty, name.allSatisfy({ httpTokenCharacters.contains($0) }) else { return nil }
            let value = line[line.index(after: colon)...].trimmingWhitespace()
            guard value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }) else { return nil }
            self.name = name.lowercased()
            self.value = value
            self.line = line
        }
    }

    private static func connectionHeaders(in headers: [RequestHeader]) -> Set<String>? {
        var nominated = Set<String>()
        for header in headers where header.name == "connection" {
            for part in header.value.split(separator: ",", omittingEmptySubsequences: false) {
                let token = part.trimmingWhitespace().lowercased()
                guard !token.isEmpty, token.allSatisfy({ httpTokenCharacters.contains($0) }) else { return nil }
                nominated.insert(token)
            }
        }
        return nominated
    }

    private static func forwardRequestHeaders(_ lines: [Substring]) -> ForwardHeaders? {
        let headers = lines.dropFirst().compactMap(RequestHeader.init)
        guard headers.count == lines.count - 1,
              let nominated = connectionHeaders(in: headers) else { return nil }
        // Routing/framing fields cannot safely be made hop-by-hop.
        guard nominated.isDisjoint(with: ["host", "content-length", "transfer-encoding"]),
              headers.filter({ $0.name == "host" }).count <= 1 else { return nil }
        let lengths = headers.filter { $0.name == "content-length" }
        guard lengths.count <= 1 else { return nil }
        var bodyLength = 0
        if let length = lengths.first?.value {
            guard !length.isEmpty, length.allSatisfy({ $0 >= "0" && $0 <= "9" }), let parsed = Int(length) else { return nil }
            bodyLength = parsed
        }
        let hasTransferEncoding = headers.contains { $0.name == "transfer-encoding" }
        guard !(hasTransferEncoding && !lengths.isEmpty) else { return nil }
        let forwarded = headers.filter {
            !hopByHopHeaders.contains($0.name) && !nominated.contains($0.name) &&
            $0.name != "host" && $0.name != "content-length"
        }.map(\.line)
        return ForwardHeaders(forwardedLines: forwarded, bodyLength: bodyLength,
                              hasContentLength: !lengths.isEmpty, hasTransferEncoding: hasTransferEncoding)
    }

    private static func parseHostAndPort(_ string: Substring, defaultPort: Int) -> (host: String, port: Int)? {
        let trimmed = string.trimmingWhitespace()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("[") {
            guard let closeIndex = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIndex])
            let after = trimmed[trimmed.index(after: closeIndex)...]
            if after.hasPrefix(":") {
                let portStr = after.dropFirst()
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

    private static func parseHostAndPort(_ string: String, defaultPort: Int) -> (host: String, port: Int)? {
        parseHostAndPort(Substring(string), defaultPort: defaultPort)
    }
}

private extension Substring {
    func trimmingWhitespace() -> Substring {
        var start = startIndex
        while start < endIndex && self[start].isWhitespace {
            start = index(after: start)
        }
        var end = endIndex
        while end > start {
            let prev = index(before: end)
            if self[prev].isWhitespace {
                end = prev
            } else {
                break
            }
        }
        return self[start..<end]
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

