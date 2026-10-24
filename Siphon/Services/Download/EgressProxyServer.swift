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
    @TaskLocal static var ytdlpExecutablePath: String?

    /// `args` with the bound proxy added when they launch yt-dlp without one.
    static func applying(to args: [String], downloaderPath: String? = nil) -> [String] {
        guard let proxyURL,
              let executable = args.first,
              (executable == (downloaderPath ?? ytdlpExecutablePath) || URL(fileURLWithPath: executable).lastPathComponent.hasPrefix("yt-dlp")),
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
            let session = URLSession(configuration: configuration,
                                     delegate: ProxyCredentialDelegate(credential: endpoint.credential), delegateQueue: nil)
            // ponytail: cap cached routes at eight; retired sessions finish in-flight work.
            if sessions.count >= 8, let retiredPort = sessions.keys.first {
                sessions.removeValue(forKey: retiredPort)?.finishTasksAndInvalidate()
            }
            sessions[endpoint.port] = session
            return session
        }
    }

    /// `Proxy-Authorization` for a plain-HTTP request through `session`'s proxy.
    /// URLSession answers the proxy's 407 only for CONNECT (HTTPS), and a
    /// session-wide header would also travel inside every HTTPS tunnel to the site.
    /// Read from the session itself: a request may run after the binding that
    /// created the session has ended.
    static func proxyAuthorization(for session: URLSession) -> String? {
        guard let credential = (session.delegate as? ProxyCredentialDelegate)?.credential,
              let user = credential.user, let password = credential.password else { return nil }
        return "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    static func retireSession(for port: UInt16) {
        let retired = sessionLock.withLock { sessions.removeValue(forKey: Int(port)) }
        retired?.finishTasksAndInvalidate()
    }

    /// WebKit proxy settings for a website data store: the bound proxy, or none.
    static var webKitProxyConfigurations: [ProxyConfiguration] {
        guard let endpoint = proxyEndpoint,
              let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else { return [] }
        let configuration = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(endpoint.host), port: port))
        if let user = endpoint.credential?.user, let password = endpoint.credential?.password {
            configuration.applyCredential(username: user, password: password)
        }
        return [configuration]
    }

    private struct ProxyEndpoint {
        let host: String
        let port: Int
        let credential: URLCredential?
    }

    private static var proxyEndpoint: ProxyEndpoint? {
        guard let proxyURL, let url = URL(string: proxyURL), let host = url.host, let port = url.port else { return nil }
        let credential = url.user.flatMap { user in
            url.password.map { URLCredential(user: user.removingPercentEncoding ?? user,
                                              password: $0.removingPercentEncoding ?? $0, persistence: .none) }
        }
        return ProxyEndpoint(host: host, port: port, credential: credential)
    }

    /// Moves a credentialed `--proxy` into a 0600 yt-dlp config file in the
    /// private session directory, so the secret is not in yt-dlp's argv, which
    /// other local processes can read. The caller removes the file afterwards.
    static func movingProxyCredentialToConfig(_ args: [String]) throws -> (args: [String], configFile: URL?) {
        guard let index = args.firstIndex(of: "--proxy"), index + 1 < args.count,
              URL(string: args[index + 1])?.password != nil else { return (args, nil) }
        guard let directory = CookieManager.getSecureTempCookiesDirectory() else {
            throw YtdlpError.downloadFailed("Could not prepare the egress proxy configuration.")
        }
        let file = directory.appendingPathComponent("siphon_proxy_\(UUID().uuidString).conf")
        guard FileManager.default.createFile(atPath: file.path, contents: Data("--proxy \(args[index + 1])\n".utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw YtdlpError.downloadFailed("Could not prepare the egress proxy configuration.")
        }
        var routed = args
        routed.replaceSubrange(index...index + 1, with: ["--config-locations", file.path])
        return (routed, file)
    }

    private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var sessions: [Int: URLSession] = [:]
}

/// Answers the egress proxy's 407 on CONNECT with its per-launch credential. A
/// task's own delegate that does not handle challenges falls back to this one.
private final class ProxyCredentialDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let credential: URLCredential?

    init(credential: URLCredential?) {
        self.credential = credential
    }

    func urlSession(
        _ _: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.isProxy(), challenge.previousFailureCount == 0, let credential else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, credential)
    }
}

/// A localhost-bound forward/tunneling proxy that enforces the public network boundary
/// at connection time for external deep-link downloads.
///
/// It intercepts every connection and every redirect, validating that the destination host
/// and its resolved IP addresses are globally routable. Any private, loopback, link-local,
/// or reserved destination is rejected with HTTP 403 Forbidden.
public final class EgressProxyServer: @unchecked Sendable {
    /// Any local process can reach 127.0.0.1. The shared proxy requires a
    /// per-launch secret, so another app cannot route traffic through Siphon
    /// (and around a per-app firewall rule).
    public static let shared = EgressProxyServer(credential: UUID().uuidString.lowercased())
    static let credentialUser = "siphon"

    public typealias TargetValidator = @Sendable (_ host: String, _ port: Int) -> Bool
    public typealias AddressResolver = @Sendable (_ host: String) -> [String]

    private let queue = DispatchQueue(label: "com.marspater.siphon.egress-proxy", attributes: .concurrent)
    private let targetValidator: TargetValidator
    private let addressResolver: AddressResolver
    /// Expected `Proxy-Authorization` value; nil accepts every local client.
    private let expectedAuthorization: String?
    private let credential: String?
    private let lock = NSLock()

    private(set) var listener: NWListener?
    private var startTask: Task<UInt16, Error>?
    public private(set) var port: UInt16 = 0

    public init(targetValidator: TargetValidator? = nil, addressResolver: AddressResolver? = nil, credential: String? = nil) {
        self.credential = credential
        self.expectedAuthorization = credential.map {
            "Basic " + Data("\(Self.credentialUser):\($0)".utf8).base64EncodedString()
        }
        self.targetValidator = targetValidator ?? { host, port in
            ExternalDownloadTargetPolicy.isAllowedTarget(host: host, port: port, resolveDNS: false)
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
                    EgressBoundary.retireSession(for: port)
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

    /// The URL clients use for this proxy on `port`, credential included.
    public func proxyURL(port: UInt16) -> String {
        guard let credential else { return "http://127.0.0.1:\(port)" }
        return "http://\(Self.credentialUser):\(credential)@127.0.0.1:\(port)"
    }

    public func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        startTask?.cancel()
        startTask = nil
        let retiredPort = port
        port = 0
        lock.unlock()
        EgressBoundary.retireSession(for: retiredPort)
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

        let normalizedHeaders = headerString.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalizedHeaders.unicodeScalars.allSatisfy({ $0.value == 10 || !CharacterSet.newlines.contains($0) }) else {
            sendResponse(client: client, status: "400 Bad Request", body: "Invalid header newline\n", close: true)
            return
        }
        let lines = normalizedHeaders.split(separator: "\n", omittingEmptySubsequences: false)
        guard let rawFirstLine = lines.first else {
            sendResponse(client: client, status: "400 Bad Request", body: "Empty request\n", close: true)
            return
        }
        let firstLine = rawFirstLine.trimmingWhitespace()
        guard !firstLine.isEmpty else {
            sendResponse(client: client, status: "400 Bad Request", body: "Empty request\n", close: true)
            return
        }

        guard let request = Self.requestLine(firstLine) else {
            sendResponse(client: client, status: "400 Bad Request", body: "Invalid request line\n", close: true)
            return
        }

        guard isAuthorized(lines) else {
            sendResponse(client: client, status: "407 Proxy Authentication Required", body: "Proxy credential required\n",
                         close: true, extraHeaders: "Proxy-Authenticate: Basic realm=\"Siphon\"\r\n")
            return
        }

        if request.method == "CONNECT" {
            handleConnect(client: client, target: request.target, remainingData: remainingData)
        } else {
            handleForwardRequest(client: client, method: request.method, target: request.target, lines: lines, remainingData: remainingData)
        }
    }

    /// Method and target of a valid `METHOD target HTTP/1.x` request line.
    private static func requestLine(_ line: Substring) -> (method: String, target: String)? {
        let parts = line.split(separator: " ")
        guard parts.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[2])),
              parts[0].allSatisfy({ httpTokenCharacters.contains($0) }),
              parts[1].utf8.allSatisfy({ $0 > 32 && $0 != 127 }) else { return nil }
        return (parts[0].uppercased(), String(parts[1]))
    }

    /// True when no credential is required or a header carries the expected one.
    private func isAuthorized(_ lines: [Substring]) -> Bool {
        guard let expectedAuthorization else { return true }
        return lines.dropFirst().contains { line in
            guard let header = RequestHeader(line), header.name == "proxy-authorization" else { return false }
            return header.value == expectedAuthorization
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

    private struct ForwardTarget {
        let host: String
        let port: Int
        let relativePath: String
        let authority: String
    }

    private struct ForwardRequestRejection: Error {
        let status: String
        let body: String

        init(_ body: String, status: String = "400 Bad Request") {
            self.status = status
            self.body = body + "\n"
        }
    }

    private func handleForwardRequest(client: NWConnection, method: String, target: String, lines: [Substring], remainingData: Data) {
        do {
            let request = try Self.validatedForwardHeaders(lines)
            let destination = try Self.parseForwardTarget(target, lines: lines)
            let addresses = try authorizeForwardTarget(destination)
            let bufferedBody = remainingData.prefix(request.bodyLength)
            let payload = Self.forwardPayload(method: method, target: destination, request: request, body: bufferedBody)
            let remainingBodyLength = request.bodyLength - bufferedBody.count

            connectUpstream(addresses: addresses[...], port: destination.port) { [weak self] upstreamResult in
                guard let self else { client.cancel(); return }
                switch upstreamResult {
                case .failure:
                    self.sendResponse(client: client, status: "502 Bad Gateway", body: "Failed to connect to destination\n", close: true)
                case .success(let upstream):
                    self.sendForwardPayload(client: client, upstream: upstream, payload: payload, remainingBodyLength: remainingBodyLength)
                }
            }
        } catch {
            sendResponse(client: client, status: error.status, body: error.body, close: true)
        }
    }

    private static func validatedForwardHeaders(_ lines: [Substring]) throws(ForwardRequestRejection) -> ForwardHeaders {
        guard let request = forwardRequestHeaders(lines) else {
            throw ForwardRequestRejection("Invalid HTTP request framing")
        }
        guard !request.hasTransferEncoding else {
            throw ForwardRequestRejection("Transfer-Encoding request bodies are unsupported", status: "501 Not Implemented")
        }
        return request
    }

    private static func parseForwardTarget(_ target: String, lines: [Substring]) throws(ForwardRequestRejection) -> ForwardTarget {
        if let url = URL(string: target), let host = url.host {
            return try absoluteForwardTarget(url, host: host)
        }
        guard target.hasPrefix("/"), !target.hasPrefix("//") else {
            throw ForwardRequestRejection("Invalid request target")
        }
        return try originForwardTarget(target, lines: lines)
    }

    private static func absoluteForwardTarget(_ url: URL, host: String) throws(ForwardRequestRejection) -> ForwardTarget {
        guard url.scheme?.lowercased() == "http", url.user == nil, url.password == nil, url.fragment == nil else {
            throw ForwardRequestRejection("Use CONNECT for HTTPS")
        }
        let port = url.port ?? 80
        guard (1...65535).contains(port) else { throw ForwardRequestRejection("Invalid port") }
        // URL.path would decode %20/%2F and change the wire request target.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? ""
        let query = components?.percentEncodedQuery.map { "?\($0)" } ?? ""
        return ForwardTarget(host: host, port: port, relativePath: (path.isEmpty ? "/" : path) + query, // NOSONAR
                             authority: forwardAuthority(host: host, port: url.port))
    }

    /// `URL.host` drops IPv6 brackets; a Host header needs them back.
    static func forwardAuthority(host: String, port: Int?) -> String {
        (host.contains(":") ? "[\(host)]" : host) + (port.map { ":\($0)" } ?? "")
    }

    private static func originForwardTarget(_ target: String, lines: [Substring]) throws(ForwardRequestRejection) -> ForwardTarget {
        for line in lines.dropFirst() {
            guard let header = RequestHeader(line), header.name == "host" else { continue }
            guard let endpoint = parseHostAndPort(header.value, defaultPort: 80) else { break }
            return ForwardTarget(host: endpoint.host, port: endpoint.port, relativePath: target, authority: String(header.value))
        }
        throw ForwardRequestRejection("Missing Host header")
    }

    private func authorizeForwardTarget(_ target: ForwardTarget) throws(ForwardRequestRejection) -> [String] {
        guard let addresses = approvedAddresses(host: target.host, port: target.port) else {
            Task { @MainActor in
                LoggerService.shared.log("Egress proxy blocked HTTP target outside public network: \(target.host):\(target.port)", level: .warning)
            }
            throw ForwardRequestRejection("Blocked: Private or reserved destination", status: "403 Forbidden")
        }
        return addresses
    }

    private static func forwardPayload(method: String, target: ForwardTarget, request: ForwardHeaders, body: Data) -> Data {
        // Canonicalize routing/framing fields; serialize exactly one request.
        var headers = ""
        headers.reserveCapacity(request.forwardedLines.reduce(0) { $0 + $1.count + 2 } + 64)
        headers.append("\(method) \(target.relativePath) HTTP/1.1\r\n")
        for line in request.forwardedLines {
            headers.append(contentsOf: line)
            headers.append("\r\n")
        }
        headers.append("Host: \(target.authority)\r\n")
        if request.hasContentLength { headers.append("Content-Length: \(request.bodyLength)\r\n") }
        headers.append("Connection: close\r\n\r\n")
        var payload = Data(headers.utf8)
        payload.append(body)
        return payload
    }

    private func sendForwardPayload(client: NWConnection, upstream: NWConnection, payload: Data, remainingBodyLength: Int) {
        upstream.send(content: payload, completion: .contentProcessed { [weak self] sendError in
            guard let self, sendError == nil else { client.cancel(); upstream.cancel(); return }
            // Response bytes stream freely; request bytes stop at Content-Length.
            self.pipe(from: upstream, to: client, completion: { client.cancel(); upstream.cancel() })
            self.forwardBody(client: client, upstream: upstream, remaining: remainingBodyLength)
        })
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
    func approvedAddresses(host: String, port: Int) -> [String]? {
        guard targetValidator(host, port) else { return nil }
        let addresses = addressResolver(host)
        guard !addresses.isEmpty,
              addresses.allSatisfy({ (IPv4Address($0) != nil || IPv6Address($0) != nil) && targetValidator($0, port) }) else {
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

    /// Delay before the next address joins the race (RFC 8305 recommends 250 ms).
    static let connectionAttemptDelay: TimeInterval = 0.25

    /// Races the validated addresses, Happy Eyeballs style, since pinning
    /// addresses gives up NWConnection's own fallback: families alternate, each
    /// next address starts 250 ms later or as soon as the previous one fails,
    /// and the first to connect wins. A silently dropping IPv6 path then costs
    /// 250 ms per connection instead of a 5 s timeout. One deadline bounds the
    /// whole race, however many addresses DNS returned.
    private func connectUpstream(
        addresses: ArraySlice<String>,
        port: Int,
        deadline: DispatchTime = .now() + EgressProxyServer.upstreamConnectTimeout,
        completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void
    ) {
        let ordered = Self.interleavedByFamily(Array(addresses))
        let timedOut = NSError(domain: "EgressProxyServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Upstream connect timed out"])
        guard !ordered.isEmpty else {
            completion(.failure(timedOut))
            return
        }
        let race = UpstreamRace(attempts: ordered.count, completion: completion)

        @Sendable func attempt(_ index: Int) {
            guard index < ordered.count, !race.isFinished else { return }
            guard DispatchTime.now() < deadline else {
                for _ in index..<ordered.count { race.fail(timedOut) }
                return
            }
            let startedNext = AtomicBox(false)
            let startNext: @Sendable () -> Void = {
                if startedNext.compareAndSet(expected: false, newValue: true) { attempt(index + 1) }
            }
            queue.asyncAfter(deadline: .now() + Self.connectionAttemptDelay, execute: startNext)
            let attemptDeadline = min(deadline, .now() + Self.perAddressConnectTimeout)
            connectUpstream(address: ordered[index], port: port, deadline: attemptDeadline) { result in
                switch result {
                case .success(let connection):
                    if !race.win(connection) { connection.cancel() }
                case .failure(let error):
                    startNext()
                    race.fail(error)
                }
            }
        }
        attempt(0)
    }

    /// Alternates address families, starting with the resolver's first choice
    /// and keeping its order within each family.
    static func interleavedByFamily(_ addresses: [String], preferIPv4: Bool = (!NetworkEnvironmentService.shared.supportsIPv6 || NetworkEnvironmentService.shared.isVPNActive)) -> [String] {
        guard let first = addresses.first else { return [] }
        let hasV4 = addresses.contains { IPv4Address($0) != nil }
        let preferV6 = !preferIPv4 && (IPv6Address(first) != nil || !hasV4)
        let preferred = addresses.filter { (IPv6Address($0) != nil) == preferV6 }
        let other = addresses.filter { (IPv6Address($0) != nil) != preferV6 }
        var result: [String] = []
        for index in 0..<max(preferred.count, other.count) {
            if index < preferred.count { result.append(preferred[index]) }
            if index < other.count { result.append(other[index]) }
        }
        return result
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

    private func sendResponse(client: NWConnection, status: String, body: String, close: Bool, extraHeaders: String = "") {
        let response = "HTTP/1.1 \(status)\r\n\(extraHeaders)Content-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
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

/// One upstream connect race: the first connection wins; the race fails only
/// after every attempt has failed.
private final class UpstreamRace: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var remaining: Int
    private let completion: @Sendable (Result<NWConnection, Error>) -> Void

    init(attempts: Int, completion: @escaping @Sendable (Result<NWConnection, Error>) -> Void) {
        self.remaining = attempts
        self.completion = completion
    }

    var isFinished: Bool { lock.withLock { finished } }

    /// Returns false when another attempt already won; the caller cancels its connection.
    func win(_ connection: NWConnection) -> Bool {
        let won = lock.withLock { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        if won { completion(.success(connection)) }
        return won
    }

    func fail(_ error: Error) {
        let lost = lock.withLock { () -> Bool in
            remaining -= 1
            guard !finished, remaining == 0 else { return false }
            finished = true
            return true
        }
        if lost { completion(.failure(error)) }
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
