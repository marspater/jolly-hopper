import Foundation
import Network

/// AVPlayer has no public per-asset proxy API. Rewrite HLS references through this
/// loopback-only gateway; every upstream fetch uses the public-network proxy.
actor HLSPlaybackGateway {
    private let client: PlaybackHTTPClient
    private let fairPlayKeys: Set<String>
    private let onFailure: @Sendable (PlaybackError) -> Void
    private let queue = DispatchQueue(label: "com.marspater.siphon.playback-gateway")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var routes: [String: URL] = [:]
    private var paths: [URL: String] = [:]
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false
    private var manifestURL: URL?

    init(client: PlaybackHTTPClient, fairPlayKeys: Set<String> = [], onFailure: @escaping @Sendable (PlaybackError) -> Void = { _ in }) {
        self.client = client
        self.fairPlayKeys = fairPlayKeys
        self.onFailure = onFailure
    }

    func start(manifestURL: URL) async throws -> URL {
        guard listener == nil, !stopped else { throw PlaybackError.invalidSource }
        self.manifestURL = manifestURL
        try PlaybackHTTPClient.validateEndpoint(manifestURL)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let completed = PlaybackContinuation<UInt16>()
        let assignedPort: UInt16 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard completed.install(continuation) else { return }
                listener.stateUpdateHandler = { state in
                    let result: Result<UInt16, Error>
                    switch state {
                    case .ready:
                        if let port = listener.port { result = .success(port.rawValue) }
                        else { result = .failure(PlaybackError.networkFailed) }
                    case .failed: result = .failure(PlaybackError.networkFailed)
                    case .cancelled: result = .failure(CancellationError())
                    default: return
                    }
                    completed.resolve(result)
                }
                queue.asyncAfter(deadline: .now() + 5) {
                    completed.resolve(.failure(PlaybackError.networkFailed))
                }
                listener.start(queue: queue)
            }
        } onCancel: {
            completed.resolve(.failure(CancellationError()))
            listener.cancel()
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        port = assignedPort
        return try route(manifestURL)
    }

    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
        for task in requests.values { task.cancel() }
        for connection in connections.values { connection.cancel() }
        requests.removeAll()
        connections.removeAll()
        routes.removeAll()
        paths.removeAll()
    }

    deinit {
        listener?.cancel()
        for task in requests.values { task.cancel() }
        for connection in connections.values { connection.cancel() }
    }

    private func route(_ url: URL) throws -> URL {
        try PlaybackHTTPClient.validateEndpoint(url)
        let path: String
        if let existing = paths[url] { path = existing }
        else {
            guard routes.count < 100_000 else { throw PlaybackError.responseTooLarge }
            path = "/" + UUID().uuidString + (url.pathExtension.lowercased() == "m3u8" ? ".m3u8" : ".media")
            paths[url] = path
            routes[path] = url
        }
        return URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 4 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.finish(id) }
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + 60) {
            connection.cancel()
        }
        receive(connection, id: id, buffer: Data())
    }

    private func finish(_ id: UUID) {
        requests.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task {
                await self?.received(connection, id: id, buffer: buffer + (data ?? Data()), complete: complete, failed: error != nil)
            }
        }
    }

    private func received(_ connection: NWConnection, id: UUID, buffer: Data, complete: Bool, failed: Bool) {
        guard !stopped, !failed, buffer.count <= 16384 else { finish(id); return }
        if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
            requests[id] = Task { [weak self] in
                await self?.respond(connection, id: id, request: buffer)
            }
        } else if complete { finish(id) }
        else { receive(connection, id: id, buffer: buffer) }
    }

    private func respond(_ connection: NWConnection, id: UUID, request: Data) async {
        var admitted = false
        do {
            let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            guard first.count == 3, first[0] == "GET",
                  let url = routes[String(first[1])] else { throw PlaybackError.invalidSource }
            admitted = true
            let upstream = URLRequest(url: url)
            var requestedRange: String?
            if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
                let value = range.dropFirst(6).trimmingCharacters(in: .whitespaces)
                guard value.range(of: #"^bytes=[0-9]+-[0-9]*$"#, options: .regularExpression) != nil else {
                    throw PlaybackError.invalidSource
                }
                requestedRange = value
            }
            // ponytail: bounded segment buffering, stream responses if >64 MiB segments are required.
            let (data, response) = try await client.fetch(upstream, limit: 64 * 1024 * 1024, sameOriginOnly: false)
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            var body = data
            var contentType = response.mimeType ?? "application/octet-stream"
            // Reject HLS-like responses with leading junk/BOM instead of passing
            // unrewritten references to AVFoundation's more permissive parser.
            let isPlaylist = data.prefix(1024).range(of: Data("#EXTM3U".utf8)) != nil
            if isPlaylist {
                body = try Self.rewritePlaylist(data, baseURL: response.url ?? url, fairPlayKeys: fairPlayKeys) { try self.route($0) }
                contentType = "application/vnd.apple.mpegurl"
            } else if url == manifestURL || url.pathExtension.lowercased() == "m3u8" || contentType.lowercased().contains("mpegurl") {
                throw PlaybackError.invalidSource
            }
            var status = 200
            var contentRange: String?
            if let requestedRange {
                let sliced = try Self.slice(body, range: requestedRange)
                body = sliced.data
                contentRange = sliced.contentRange
                status = 206
            }
            var headers = "HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            if let range = contentRange {
                headers += "Content-Range: \(range)\r\n"
            }
            send(Data((headers + "\r\n").utf8) + body, to: connection, id: id)
        } catch {
            guard !stopped, !Task.isCancelled else { finish(id); return }
            // Generic failure only: upstream URLs and query credentials never enter logs/responses.
            if admitted { onFailure((error as? PlaybackError) ?? .networkFailed) }
            send(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection, id: id)
        }
    }

    private func send(_ data: Data, to connection: NWConnection, id: UUID) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { await self?.finish(id) }
        })
    }

    nonisolated static func slice(_ data: Data, range: String) throws -> (data: Data, contentRange: String) {
        let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int(bounds[0]), start >= 0, start < data.count else {
            throw PlaybackError.invalidSource
        }
        let end: Int
        if bounds[1].isEmpty { end = data.count - 1 }
        else {
            guard let requestedEnd = Int(bounds[1]), requestedEnd >= start else { throw PlaybackError.invalidSource }
            end = min(requestedEnd, data.count - 1)
        }
        return (data.subdata(in: start..<(end + 1)), "bytes \(start)-\(end)/\(data.count)")
    }

    nonisolated static func rewritePlaylist(
        _ data: Data, baseURL: URL, fairPlayKeys: Set<String>,
        localURL: (URL) throws -> URL
    ) throws -> Data {
        guard data.starts(with: Data("#EXTM3U".utf8)),
              let text = String(data: data, encoding: .utf8), !text.contains("{$") else {
            throw PlaybackError.invalidSource
        }
        let uriExpression = try NSRegularExpression(pattern: #"URI="([^"]*)""#)
        let referenceTags = ["#EXT-X-KEY:", "#EXT-X-SESSION-KEY:", "#EXT-X-MAP:", "#EXT-X-MEDIA:", "#EXT-X-I-FRAME-STREAM-INF:", "#EXT-X-PART:", "#EXT-X-PRELOAD-HINT:", "#EXT-X-RENDITION-REPORT:"]
        func rewritten(_ value: String) throws -> String {
            guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else { throw PlaybackError.invalidSource }
            if url.scheme?.lowercased() == "skd" {
                guard fairPlayKeys.contains(url.absoluteString) else { throw PlaybackError.unsupportedProtection }
                return value
            }
            try PlaybackHTTPClient.validateEndpoint(url)
            return try localURL(url).absoluteString
        }
        var result: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, !line.hasPrefix("#") {
                line = try rewritten(line)
            } else if line.hasPrefix("#EXT-X-DATERANGE:"), line.contains("X-ASSET-") {
                throw PlaybackError.unsupportedProtection
            } else if line.contains("URI=") {
                guard referenceTags.contains(where: { line.hasPrefix($0) }) else { throw PlaybackError.unsupportedProtection }
                let matches = uriExpression.matches(in: line, range: NSRange(line.startIndex..., in: line))
                guard !matches.isEmpty else { throw PlaybackError.invalidSource }
                if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                    if line.contains("KEYFORMAT="), !line.contains(#"KEYFORMAT="identity""#),
                       !line.contains(#"KEYFORMAT="com.apple.streamingkeydelivery""#) {
                        throw PlaybackError.unsupportedProtection
                    }
                    if line.contains("METHOD=SAMPLE-AES"), !line.contains(#"KEYFORMAT="com.apple.streamingkeydelivery""#) {
                        throw PlaybackError.unsupportedProtection
                    }
                }
                for match in matches.reversed() {
                    guard let range = Range(match.range(at: 1), in: line) else { throw PlaybackError.invalidSource }
                    let replacement = try rewritten(String(line[range]))
                    line.replaceSubrange(range, with: replacement)
                }
            }
            result.append(line)
        }
        return Data(result.joined(separator: "\n").utf8)
    }
}
