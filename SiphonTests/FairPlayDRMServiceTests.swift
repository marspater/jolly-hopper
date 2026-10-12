import AVFoundation
import XCTest
@testable import Siphon

@MainActor
final class FairPlayDRMServiceTests: XCTestCase {
    private let configuration = DRMConfiguration(
        certificateURL: URL(string: "https://cert.example/app.der")!,
        licenseServerURL: URL(string: "https://license.example/key")!,
        contentIDsByKeyURI: ["skd://first": "first-id", "skd://second": "second-id"]
    )

    func testConcurrentRequestsAndRenewalEachReceiveOneResponse() async throws {
        let started = expectation(description: "Both license exchanges started")
        started.expectedFulfillmentCount = 2
        let license = ControlledLicenseClient(started: started)
        let service = FairPlayDRMService(configuration: configuration, certificateProvider: CertificateStub(),
                                        licenseClient: license) { _ in XCTFail("Valid mocked exchange must not fail") }
        defer { service.stop() }
        let first = KeyRequestStub(identifier: "skd://first", spc: Data([1]))
        let second = KeyRequestStub(identifier: "skd://second", spc: Data([2]))
        let firstWork = try XCTUnwrap(service.handleFairPlayRequest(first))
        let secondWork = try XCTUnwrap(service.handleFairPlayRequest(second))
        XCTAssertNil(service.handleFairPlayRequest(first), "Duplicate delivery must not start another exchange")
        await fulfillment(of: [started], timeout: 5)
        await license.finishAll(with: .success(Data([3])))
        await firstWork.value
        await secondWork.value
        XCTAssertEqual(first.responses.count, 1)
        XCTAssertEqual(second.responses.count, 1)
        XCTAssertEqual(try first.responses[0].get(), Data([3]))
        XCTAssertEqual(first.certificates, [Data([9])])
        XCTAssertEqual(first.contentIDs, ["first-id"])

        // Renewal is a new AVContentKeyRequest object with the same key identifier.
        let renewal = KeyRequestStub(identifier: "skd://first")
        let renewalWork = try XCTUnwrap(service.handleFairPlayRequest(renewal))
        await renewalWork.value
        XCTAssertEqual(renewal.responses.count, 1)
        let contentIDs = await license.contentIDs
        XCTAssertEqual(contentIDs.count, 3)
        XCTAssertEqual(Set(contentIDs), ["first-id", "second-id"])
        service.stop()
        XCTAssertEqual(first.responses.count, 1, "Teardown must not respond again to a completed key")
    }

    func testStopCancelsPendingRequestAndDiscardsLateCKC() async throws {
        let started = expectation(description: "License exchange started")
        let license = ControlledLicenseClient(started: started)
        var failures: [PlaybackError] = []
        let service = FairPlayDRMService(configuration: configuration, certificateProvider: CertificateStub(),
                                        licenseClient: license) { failures.append($0) }
        let request = KeyRequestStub(identifier: "skd://first")
        let work = try XCTUnwrap(service.handleFairPlayRequest(request))
        await fulfillment(of: [started], timeout: 5)
        service.stop()
        service.stop()
        XCTAssertEqual(request.responses.count, 1)
        if case .failure(let error) = request.responses[0] { XCTAssertTrue(error is CancellationError) }
        else { XCTFail("Stopped request must fail") }
        await license.finishAll(with: .success(Data([1])))
        await work.value
        XCTAssertEqual(request.responses.count, 1, "Late CKC must not cause a second terminal response")
        XCTAssertTrue(failures.isEmpty)
        let late = KeyRequestStub(identifier: "skd://second")
        XCTAssertNil(service.handleFairPlayRequest(late))
        XCTAssertEqual(late.responses.count, 1)
    }

    func testConcurrentLicenseDenialsFailSessionOnceAndCancelOtherKeys() async throws {
        let started = expectation(description: "Both exchanges started")
        started.expectedFulfillmentCount = 2
        let license = ControlledLicenseClient(started: started)
        var failures: [PlaybackError] = []
        let service = FairPlayDRMService(configuration: configuration, certificateProvider: CertificateStub(),
                                        licenseClient: license) { failures.append($0) }
        let first = KeyRequestStub(identifier: "skd://first")
        let second = KeyRequestStub(identifier: "skd://second")
        let firstWork = try XCTUnwrap(service.handleFairPlayRequest(first))
        let secondWork = try XCTUnwrap(service.handleFairPlayRequest(second))
        await fulfillment(of: [started], timeout: 5)
        await license.finishAll(with: .failure(.httpStatus(403)))
        await firstWork.value
        await secondWork.value
        XCTAssertEqual(failures, [.httpStatus(403)])
        XCTAssertEqual(first.responses.count, 1)
        XCTAssertEqual(second.responses.count, 1)
        XCTAssertNil(service.handleFairPlayRequest(first))
    }

    func testUnmappedKeyAndEmptyCertificateDoNotReachLicenseServer() async throws {
        for (identifier, certificate, expected) in [
            ("skd://unknown", Data([9]), PlaybackError.unsupportedProtection),
            ("skd://first", Data(), PlaybackError.invalidCertificate)
        ] {
            let license = ControlledLicenseClient(result: .success(Data([1])))
            var failures: [PlaybackError] = []
            let service = FairPlayDRMService(configuration: configuration,
                                            certificateProvider: CertificateStub(data: certificate),
                                            licenseClient: license) { failures.append($0) }
            let request = KeyRequestStub(identifier: identifier)
            let work = try XCTUnwrap(service.handleFairPlayRequest(request))
            await work.value
            XCTAssertEqual(failures, [expected])
            XCTAssertEqual(request.responses.count, 1)
            let calls = await license.contentIDs
            XCTAssertTrue(calls.isEmpty)
            XCTAssertTrue(request.certificates.isEmpty)
        }
    }

    func testEmptySPCAndInvalidCKCFailPredictably() async throws {
        for (spc, ckc, expected) in [
            (Data(), Data([1]), PlaybackError.keyRequestFailed),
            (Data([1]), Data(), PlaybackError.invalidLicenseResponse),
            (Data([1]), Data(repeating: 0, count: 1024 * 1024 + 1), PlaybackError.invalidLicenseResponse)
        ] {
            let license = ControlledLicenseClient(result: .success(ckc))
            var failures: [PlaybackError] = []
            let service = FairPlayDRMService(configuration: configuration, certificateProvider: CertificateStub(),
                                            licenseClient: license) { failures.append($0) }
            let request = KeyRequestStub(identifier: "skd://first", spc: spc)
            let work = try XCTUnwrap(service.handleFairPlayRequest(request))
            await work.value
            XCTAssertEqual(failures, [expected])
            XCTAssertEqual(request.responses.count, 1)
        }
    }

    func testSPCFailureNeverStartsLicenseExchange() async throws {
        let license = ControlledLicenseClient(result: .success(Data([1])))
        var failures: [PlaybackError] = []
        let service = FairPlayDRMService(configuration: configuration, certificateProvider: CertificateStub(),
                                        licenseClient: license) { failures.append($0) }
        let request = KeyRequestStub(identifier: "skd://first", spcError: .keyRequestFailed)
        let work = try XCTUnwrap(service.handleFairPlayRequest(request))
        await work.value
        XCTAssertEqual(failures, [.keyRequestFailed])
        let calls = await license.contentIDs
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(request.responses.count, 1)
    }
}

private struct CertificateStub: FairPlayCertificateProviding {
    var data = Data([9])
    func fetchApplicationDrmCertificate() async throws -> Data { data }
}

@MainActor
private final class KeyRequestStub: FairPlayKeyRequest {
    nonisolated let identifier: (any Sendable)?
    let spc: Data
    let spcError: PlaybackError?
    private(set) var responses: [Result<Data, Error>] = []
    private(set) var certificates: [Data] = []
    private(set) var contentIDs: [String] = []

    init(identifier: String, spc: Data = Data([1]), spcError: PlaybackError? = nil) {
        self.identifier = identifier
        self.spc = spc
        self.spcError = spcError
    }

    func generateSPC(certificate: Data, contentID: String) async throws -> Data {
        certificates.append(certificate)
        contentIDs.append(contentID)
        if let spcError { throw spcError }
        return spc
    }

    func respond(ckc: Data) { responses.append(.success(ckc)) }
    func respond(error: Error) { responses.append(.failure(error)) }
}

/// Deliberately ignores task cancellation so the service must discard a late response.
private actor ControlledLicenseClient: FairPlayLicenseProviding {
    let started: XCTestExpectation?
    private var result: Result<Data, PlaybackError>?
    private var waiting: [CheckedContinuation<Data, Error>] = []
    private(set) var contentIDs: [String] = []

    init(started: XCTestExpectation? = nil, result: Result<Data, PlaybackError>? = nil) {
        self.started = started
        self.result = result
    }

    func requestCKC(spcData: Data, contentID: String) async throws -> Data {
        contentIDs.append(contentID)
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            started?.fulfill()
        }
    }

    func finishAll(with result: Result<Data, PlaybackError>) {
        self.result = result
        let continuations = waiting
        waiting.removeAll()
        for continuation in continuations {
            switch result {
            case .success(let data): continuation.resume(returning: data)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }
}
