import Foundation
import Testing
@testable import CounterApp

@MainActor
struct DeferredSessionOutboxTests {
    @Test func unreachableAPIThenManualOnlineRetryUploadsPersistedPackage() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let api = MockDeferredAPI(uploadResults: [
            .failure(URLError(.notConnectedToInternet)),
            .success(validReceipt())
        ])
        let clock = MutableClock(1_000)
        let outbox = makeOutbox(root: fixture.root, api: api, clock: clock)

        let offline = await outbox.run(trigger: .launch)
        #expect(offline.failedSessionIds == [fixture.localSessionId])
        var manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.uploadStatus == .failed)
        #expect(manifest.retry.retryCount == 1)
        #expect(manifest.retry.nextRetryAt == 1_030)

        let online = await outbox.retryNow()
        #expect(online.uploadedSessionIds == [fixture.localSessionId])
        manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.uploadStatus == .uploaded)
        #expect(manifest.retry.retryCount == 0)
        #expect(FileManager.default.fileExists(
            atPath: fixture.audioURL.deletingPathExtension().appendingPathExtension("json").path
        ))
    }

    @Test func satisfiedPathHintDoesNotOverrideActualAPIFailure() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let api = MockDeferredAPI(uploadResults: [.failure(URLError(.cannotConnectToHost))])
        let outbox = makeOutbox(root: fixture.root, api: api, clock: MutableClock(2_000))

        let summary = await outbox.run(trigger: .pathSatisfied)

        #expect(summary.failedSessionIds == [fixture.localSessionId])
        #expect(try LocalSessionManifestStore.load(from: fixture.directory).uploadStatus == .failed)
    }

    @Test func automaticRetryHonorsBackoffWhileManualRetryBypassesIt() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let api = MockDeferredAPI(uploadResults: [
            .failure(URLError(.timedOut)),
            .success(validReceipt())
        ])
        let clock = MutableClock(3_000)
        let outbox = makeOutbox(root: fixture.root, api: api, clock: clock)

        _ = await outbox.run(trigger: .launch)
        let tooSoon = await outbox.run(trigger: .foreground)
        #expect(tooSoon.attemptedCount == 0)
        #expect(tooSoon.deferredSessionIds == [fixture.localSessionId])
        #expect(api.uploadCallCount == 1)

        let manual = await outbox.retryNow()
        #expect(manual.uploadedSessionIds == [fixture.localSessionId])
        #expect(api.uploadCallCount == 2)
    }

    @Test func retryPolicyIsExponentialJitteredAndBounded() {
        let policy = DeferredSessionRetryPolicy.standard
        #expect(policy.delay(forRetryCount: 1, jitterUnit: 0.5) == 30)
        #expect(policy.delay(forRetryCount: 2, jitterUnit: 0.5) == 60)
        #expect(policy.delay(forRetryCount: 1, jitterUnit: 0) == 24)
        #expect(policy.delay(forRetryCount: 1, jitterUnit: 1) == 36)
        #expect(policy.delay(forRetryCount: 30, jitterUnit: 1) == 7_200)
    }

    @Test func concurrentOutboxRunsDoNotDuplicateUpload() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let api = MockDeferredAPI(
            uploadResults: [.success(validReceipt())],
            uploadDelayNanoseconds: 150_000_000
        )
        let outbox = makeOutbox(root: fixture.root, api: api, clock: MutableClock(4_000))

        async let first = outbox.run(trigger: .launch)
        try await Task.sleep(nanoseconds: 20_000_000)
        let duplicate = await outbox.run(trigger: .foreground)
        _ = await first
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(duplicate.duplicateRunSuppressed)
        #expect(api.uploadCallCount == 1)
    }

    @Test func uploadAcceptedButResponseLostRetriesSameCloudSessionSafely() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let api = MockDeferredAPI(
            uploadResults: [
                .failure(MockDeferredAPI.AcceptedButResponseLost()),
                .success(validReceipt())
            ],
            acceptedBeforeFailure: true
        )
        let clock = MutableClock(5_000)
        let firstOutbox = makeOutbox(root: fixture.root, api: api, clock: clock)

        _ = await firstOutbox.run(trigger: .launch)
        var manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.cloudSessionId == MockDeferredAPI.sessionId)
        #expect(manifest.uploadStatus == .failed)

        let recreatedOutbox = makeOutbox(root: fixture.root, api: api, clock: clock)
        let recovered = await recreatedOutbox.retryNow()
        #expect(recovered.uploadedSessionIds == [fixture.localSessionId])
        #expect(api.createCallCount == 1)
        #expect(api.uploadCallCount == 2)
        #expect(api.acceptedLocalSessionIds == [fixture.localSessionId])
        manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.uploadStatus == .uploaded)
    }

    @Test func lostCreationResponseUsesLocalSessionIdToRecoverSameIdentity() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let api = MockDeferredAPI(
            uploadResults: [.success(validReceipt())],
            loseFirstCreationResponse: true
        )
        let outbox = makeOutbox(root: fixture.root, api: api, clock: MutableClock(6_000))

        _ = await outbox.run(trigger: .launch)
        #expect(try LocalSessionManifestStore.load(from: fixture.directory).cloudSessionId == nil)
        let recovered = await outbox.retryNow()

        #expect(recovered.uploadedSessionIds == [fixture.localSessionId])
        #expect(api.createCallCount == 2)
        #expect(api.createdIdentityByLocalSessionId.count == 1)
        #expect(api.uploadedCloudSessionIds == [MockDeferredAPI.sessionId])
    }

    @Test func relaunchScansPendingFolderAndUploadedSessionIsNotRepeated() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let api = MockDeferredAPI(uploadResults: [.success(validReceipt())])
        let firstProcess = makeOutbox(root: fixture.root, api: api, clock: MutableClock(7_000))

        let launch = await firstProcess.run(trigger: .launch)
        #expect(launch.uploadedSessionIds == [fixture.localSessionId])

        let relaunchedProcess = makeOutbox(root: fixture.root, api: api, clock: MutableClock(8_000))
        let secondLaunch = await relaunchedProcess.run(trigger: .launch)
        #expect(secondLaunch.attemptedCount == 0)
        #expect(api.uploadCallCount == 1)
    }

    private func makeOutbox(
        root: URL,
        api: MockDeferredAPI,
        clock: MutableClock
    ) -> DeferredSessionOutbox {
        DeferredSessionOutbox(
            apiClient: api,
            stageProcessor: NoopStageProcessor(),
            sessionsRootProvider: { root },
            now: { clock.date },
            jitterUnit: { 0.5 },
            pathMonitor: nil
        )
    }

    private func makeReadyFixture() throws -> (
        root: URL,
        directory: URL,
        audioURL: URL,
        localSessionId: String
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeferredOutboxTests-\(UUID().uuidString)", isDirectory: true)
        let localSessionId = "local-\(UUID().uuidString)"
        let directory = root.appendingPathComponent(localSessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("recording.m4a")
        try Data([0x01, 0x02, 0x03]).write(to: audioURL, options: [.atomic])
        try Data("{\"local_session_id\":\"\(localSessionId)\"}".utf8).write(
            to: directory.appendingPathComponent("session.json"),
            options: [.atomic]
        )
        var manifest = LocalSessionManifest(
            localSessionId: localSessionId,
            audioFileName: audioURL.lastPathComponent
        )
        manifest.audioStatus = .recordedLocally
        manifest.transcriptionStatus = .completed
        manifest.analysisStatus = .completed
        manifest.clarificationStatus = .completed
        manifest.uploadStatus = .pending
        try LocalSessionManifestStore.save(manifest, to: directory)
        return (root, directory, audioURL, localSessionId)
    }

    private func validReceipt() -> DeferredPackageUploadReceipt {
        DeferredPackageUploadReceipt(
            sessionId: MockDeferredAPI.sessionId,
            respondentId: MockDeferredAPI.respondentId,
            packageDirectory: MockDeferredAPI.sessionId,
            jsonPath: "\(MockDeferredAPI.sessionId)/session.json",
            audioPath: "\(MockDeferredAPI.sessionId)/recording.m4a",
            jsonFileSizeBytes: 42,
            audioFileSizeBytes: 3,
            jsonSHA256: String(repeating: "a", count: 64),
            audioSHA256: String(repeating: "b", count: 64)
        )
    }
}

@MainActor
private final class MutableClock {
    var date: Date

    init(_ timestamp: TimeInterval) {
        date = Date(timeIntervalSince1970: timestamp)
    }
}

@MainActor
private struct NoopStageProcessor: DeferredSessionStageProcessing {
    func resume(
        sessionDirectoryURL: URL,
        audioURL: URL,
        localeIdentifier: String
    ) async -> DurableProcessingOutcome {
        .readyToUpload
    }
}

private final class MockDeferredAPI: DeferredSessionAPIClient {
    struct AcceptedButResponseLost: LocalizedError {
        var errorDescription: String? { "The response was lost after the server accepted the package." }
    }

    static let respondentId = "11111111-1111-1111-1111-111111111111"
    static let sessionId = "22222222-2222-2222-2222-222222222222"

    let deferredProcessingIsConfigured = true
    private var uploadResults: [Result<DeferredPackageUploadReceipt, Error>]
    private let uploadDelayNanoseconds: UInt64
    private let acceptedBeforeFailure: Bool
    private var loseFirstCreationResponse: Bool
    private(set) var createCallCount = 0
    private(set) var uploadCallCount = 0
    private(set) var acceptedLocalSessionIds: Set<String> = []
    private(set) var createdIdentityByLocalSessionId: [String: DeferredCloudSessionIdentity] = [:]
    private(set) var uploadedCloudSessionIds: [String] = []

    init(
        uploadResults: [Result<DeferredPackageUploadReceipt, Error>],
        uploadDelayNanoseconds: UInt64 = 0,
        acceptedBeforeFailure: Bool = false,
        loseFirstCreationResponse: Bool = false
    ) {
        self.uploadResults = uploadResults
        self.uploadDelayNanoseconds = uploadDelayNanoseconds
        self.acceptedBeforeFailure = acceptedBeforeFailure
        self.loseFirstCreationResponse = loseFirstCreationResponse
    }

    func createDeferredCloudSession(
        for manifest: LocalSessionManifest,
        appVersion: String?,
        locale: String?
    ) async throws -> DeferredCloudSessionIdentity {
        createCallCount += 1
        let identity = createdIdentityByLocalSessionId[manifest.localSessionId]
            ?? DeferredCloudSessionIdentity(respondentId: Self.respondentId, sessionId: Self.sessionId)
        createdIdentityByLocalSessionId[manifest.localSessionId] = identity
        if loseFirstCreationResponse {
            loseFirstCreationResponse = false
            throw URLError(.networkConnectionLost)
        }
        return identity
    }

    func uploadDeferredPackage(
        sessionId: String,
        sessionJSONURL: URL,
        audioURL: URL,
        localSessionId: String
    ) async throws -> DeferredPackageUploadReceipt {
        uploadCallCount += 1
        uploadedCloudSessionIds.append(sessionId)
        if uploadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: uploadDelayNanoseconds)
        }
        guard !uploadResults.isEmpty else { throw URLError(.badServerResponse) }
        let result = uploadResults.removeFirst()
        if acceptedBeforeFailure || (try? result.get()) != nil {
            acceptedLocalSessionIds.insert(localSessionId)
        }
        return try result.get()
    }
}
