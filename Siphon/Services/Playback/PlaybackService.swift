import AVFoundation
import Combine
import Foundation

enum PlaybackState: Equatable {
    case idle, loading, ready, playing, paused, buffering, failed
}

@MainActor
final class PlaybackService: ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var player: AVPlayer?

    private var generation = UUID()
    private var setupTask: Task<Void, Error>?
    private var itemObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var drmService: FairPlayDRMService?
    private var httpClient: PlaybackHTTPClient?
    private var gateway: HLSPlaybackGateway?
    private var wantsPlayback = false
    private var hasStarted = false

    func load(_ source: PlaybackSource) async throws {
        stop()
        let current = generation
        state = .loading
        let task = Task { try await prepare(source, generation: current) }
        setupTask = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == current else { throw CancellationError() }
            setupTask = nil
        } catch {
            guard generation == current else { throw CancellationError() }
            if error is CancellationError || Task.isCancelled { stop(); throw CancellationError() }
            fail((error as? PlaybackError) ?? .playerFailed)
            throw error
        }
    }

    private func prepare(_ source: PlaybackSource, generation current: UUID) async throws {
        try PlaybackSourceResolver.validate(source)
        try Task.checkCancellation()
        let asset: AVURLAsset
        switch source {
        case .localFile(let url):
            // A local file cannot reference remote media or another local file.
            asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        case .hls(let url, let configuration):
            let client = try await PlaybackHTTPClient.make()
            guard generation == current else { client.invalidate(); throw CancellationError() }
            httpClient = client
            let gateway = HLSPlaybackGateway(client: client, fairPlayKeys: Set(configuration?.contentIDsByKeyURI.keys.map { $0 } ?? [])) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    self.fail(error)
                }
            }
            self.gateway = gateway
            let localURL = try await gateway.start(manifestURL: url)
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            asset = AVURLAsset(url: localURL, options: [
                AVURLAssetOverrideMIMETypeKey: "application/vnd.apple.mpegurl",
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidCrossSiteReference.rawValue
            ])
            if let configuration {
                let service = FairPlayDRMService(
                    configuration: configuration,
                    certificateProvider: TrustedCertificateProvider(endpoint: configuration.certificateURL, httpClient: client),
                    licenseClient: LicenseClient(endpoint: configuration.licenseServerURL, authorization: configuration.authorization, httpClient: client)
                ) { [weak self] error in
                    guard let self, self.generation == current else { return }
                    self.fail(error)
                }
                drmService = service
                service.attach(to: asset)
            }
        case .offlineHLS:
            throw PlaybackError.offlineUnsupported
        }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                switch item.status {
                case .readyToPlay:
                    if self.wantsPlayback { player.play() }
                    self.updateState()
                case .failed: self.fail(.playerFailed)
                default: break
                }
            }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.updateState()
            }
        }
        self.player = player
    }

    func play() {
        guard state != .idle, state != .failed else { return }
        wantsPlayback = true
        hasStarted = true
        player?.play()
        updateState()
    }

    func pause() {
        wantsPlayback = false
        player?.pause()
        updateState()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0, let item = player?.currentItem, item.status == .readyToPlay else { return }
        let duration = item.duration.seconds
        let target = duration.isFinite ? min(seconds, duration) : seconds
        player?.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600))
    }

    private func updateState() {
        guard state != .failed, let player, player.currentItem?.status == .readyToPlay else { return }
        switch player.timeControlStatus {
        case .playing: state = .playing
        case .waitingToPlayAtSpecifiedRate: state = .buffering
        case .paused: state = hasStarted ? .paused : .ready
        @unknown default: state = .ready
        }
    }

    private func fail(_ error: PlaybackError) {
        stop()
        state = .failed
        errorMessage = error.localizedDescription
        LoggerService.shared.log("Native playback failed: \(error.localizedDescription)", level: .warning)
    }

    func stop() {
        generation = UUID()
        setupTask?.cancel()
        setupTask = nil
        itemObservation?.invalidate()
        controlObservation?.invalidate()
        itemObservation = nil
        controlObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        drmService?.stop()
        drmService = nil
        httpClient?.invalidate()
        httpClient = nil
        if let gateway { Task { await gateway.stop() } }
        gateway = nil
        wantsPlayback = false
        hasStarted = false
        state = .idle
        errorMessage = nil
    }

    isolated deinit { stop() }
}
