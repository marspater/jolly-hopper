import AVFoundation
import Foundation
import Synchronization

/// A narrow seam for deterministic lifecycle tests; production uses AVContentKeyRequest.
protocol FairPlayKeyRequest: AnyObject, Sendable {
    var identifier: (any Sendable)? { get }
    func generateSPC(certificate: Data, contentID: String) async throws -> Data
    @MainActor func respond(ckc: Data)
    @MainActor func respond(error: Error)
}

/// Serializes terminal responses on MainActor; delegate callbacks only enqueue work.
@MainActor
final class FairPlayDRMService: NSObject, AVContentKeySessionDelegate {
    private let session = AVContentKeySession(keySystem: .fairPlayStreaming)
    private let configuration: DRMConfiguration
    private let certificateProvider: any FairPlayCertificateProviding
    private let licenseClient: any FairPlayLicenseProviding
    private let onFailure: @MainActor (PlaybackError) -> Void
    private var asset: AVURLAsset?
    private var handled: [ObjectIdentifier: any FairPlayKeyRequest] = [:]
    private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopped = false

    init(configuration: DRMConfiguration, certificateProvider: any FairPlayCertificateProviding,
         licenseClient: any FairPlayLicenseProviding, onFailure: @escaping @MainActor (PlaybackError) -> Void) {
        self.configuration = configuration
        self.certificateProvider = certificateProvider
        self.licenseClient = licenseClient
        self.onFailure = onFailure
        super.init()
        session.setDelegate(self, queue: .main)
    }

    func attach(to asset: AVURLAsset) {
        self.asset = asset
        session.addContentKeyRecipient(asset)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        session.setDelegate(nil, queue: nil)
        for (id, task) in pending {
            task.cancel()
            handled[id]?.respond(error: CancellationError())
        }
        pending.removeAll()
        if let asset { session.removeContentKeyRecipient(asset) }
        asset = nil
        session.expire()
    }

    nonisolated func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        Task { @MainActor in _ = self.handleFairPlayRequest(keyRequest) }
    }

    nonisolated func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        Task { @MainActor in _ = self.handleFairPlayRequest(keyRequest) }
    }

    nonisolated func contentKeySession(_ session: AVContentKeySession, contentKeyRequest: AVContentKeyRequest, didFailWithError err: Error) {
        Task { @MainActor in
            guard !self.stopped else { return }
            self.reportFailure(.keyRequestFailed)
        }
    }

    @discardableResult
    func handleFairPlayRequest(_ request: any FairPlayKeyRequest) -> Task<Void, Never>? {
        let id = ObjectIdentifier(request)
        guard handled[id] == nil else { return nil }
        handled[id] = request
        // ponytail: retain terminal identities for one session, prune if >1024 keys are required.
        guard !stopped, handled.count <= 1024, pending.count < 32 else {
            request.respond(error: stopped ? CancellationError() : PlaybackError.keyRequestFailed)
            if !stopped { reportFailure(.keyRequestFailed) }
            return nil
        }
        let task = Task {
            do {
                let contentID = try configuration.contentID(for: request.identifier)
                let certificate = try await certificateProvider.fetchApplicationDrmCertificate()
                guard !certificate.isEmpty else { throw PlaybackError.invalidCertificate }
                try Task.checkCancellation()
                let spc = try await request.generateSPC(certificate: certificate, contentID: contentID)
                try Task.checkCancellation()
                guard !spc.isEmpty, spc.count <= 1024 * 1024 else { throw PlaybackError.keyRequestFailed }
                let ckc = try await licenseClient.requestCKC(spcData: spc, contentID: contentID)
                try Task.checkCancellation()
                guard !ckc.isEmpty, ckc.count <= 1024 * 1024 else { throw PlaybackError.invalidLicenseResponse }
                guard pending.removeValue(forKey: id) != nil else { return }
                request.respond(ckc: ckc)
            } catch {
                guard pending.removeValue(forKey: id) != nil else { return }
                let failure = (error as? PlaybackError) ?? .keyRequestFailed
                request.respond(error: failure)
                reportFailure(failure)
            }
        }
        pending[id] = task
        return task
    }

    private func reportFailure(_ error: PlaybackError) {
        guard !stopped else { return }
        stop()
        onFailure(error)
    }

    isolated deinit { stop() }

    nonisolated fileprivate static func generateSPC(for request: AVContentKeyRequest, certificate: Data, contentID: String) async throws -> Data {
        let result = PlaybackContinuation<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard result.install(continuation) else { return }
                request.makeStreamingContentKeyRequestData(forApp: certificate, contentIdentifier: Data(contentID.utf8), options: nil) { data, error in
                    if let error { result.resolve(.failure(error)) }
                    else if let data, !data.isEmpty { result.resolve(.success(data)) }
                    else { result.resolve(.failure(PlaybackError.keyRequestFailed)) }
                }
            }
        } onCancel: {
            // AVFoundation has no SPC cancellation API; discard its late callback.
            result.resolve(.failure(CancellationError()))
        }
    }
}

extension AVContentKeyRequest: FairPlayKeyRequest {
    func generateSPC(certificate: Data, contentID: String) async throws -> Data {
        try await FairPlayDRMService.generateSPC(for: self, certificate: certificate, contentID: contentID)
    }

    @MainActor func respond(ckc: Data) {
        processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
    }

    @MainActor func respond(error: Error) { processContentKeyResponseError(error) }
}

/// Both Network.framework startup and SPC callbacks may race cancellation.
final class PlaybackContinuation<Value: Sendable>: Sendable {
    private let state = Mutex<(CheckedContinuation<Value, Error>?, Result<Value, Error>?)>((nil, nil))

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let result: Result<Value, Error>? = state.withLock { state in
            if let result = state.1 { return result }
            state.0 = continuation
            return nil
        }
        if let result { continuation.resume(with: result); return false }
        return true
    }

    func resolve(_ result: Result<Value, Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Value, Error>? in
            guard state.1 == nil else { return nil }
            state.1 = result
            let continuation = state.0
            state.0 = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
