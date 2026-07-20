import Foundation
import Testing
@testable import CounterApp

@MainActor
struct DeferredSessionOutboxTests {
    @Test func startingOutboxDiscoversWorkWithoutProcessingIt() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let api = MockDeferredAPI(uploadResults: [.success(validReceipt())])
        let outbox = makeOutbox(root: fixture.root, api: api, clock: MutableClock(500))

        outbox.start()
        await Task.yield()

        #expect(api.createCallCount == 0)
        #expect(api.uploadCallCount == 0)
        #expect(try LocalSessionManifestStore.load(from: fixture.directory).uploadStatus == .pending)
    }

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

    @Test func automaticAndManualTriggersSubmitServerProcessingWithoutLocalSpeechOrLLM() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("session.json"))
        try LocalSessionManifestStore.update(in: fixture.directory) { manifest in
            manifest.transcriptionStatus = .pending
            manifest.analysisStatus = .pending
            manifest.clarificationStatus = .pending
            manifest.uploadStatus = .notReady
        }
        let processor = CountingStageProcessor()
        let outbox = DeferredSessionOutbox(
            apiClient: MockDeferredAPI(uploadResults: []),
            stageProcessor: processor,
            sessionsRootProvider: { fixture.root },
            now: { Date(timeIntervalSince1970: 9_000) },
            jitterUnit: { 0.5 },
            pathMonitor: nil,
            applicationIsActive: { true }
        )

        let launch = await outbox.run(trigger: .launch)
        #expect(launch.uploadedSessionIds == [fixture.localSessionId])
        #expect(processor.callCount == 0)
        #expect(try LocalSessionManifestStore.load(from: fixture.directory).serverProcessingStatus == .queued)

        let manual = await outbox.retryNow()
        #expect(manual.deferredSessionIds == [fixture.localSessionId])
        #expect(processor.callCount == 0)
    }

    @Test func legacyCompletedPackageRemainsUploadableWithoutLocalReprocessing() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("Legacy tail transcript".utf8).write(
            to: fixture.directory.appendingPathComponent("transcript.txt"),
            options: [.atomic]
        )
        try LocalSessionManifestStore.update(in: fixture.directory) { manifest in
            manifest.transcriptionPipelineVersion = 0
            manifest.transcriptFileName = "transcript.txt"
            manifest.transcription = "Legacy tail transcript"
        }
        let processor = CountingStageProcessor()
        let api = MockDeferredAPI(uploadResults: [.success(validReceipt())])
        let outbox = DeferredSessionOutbox(
            apiClient: api,
            stageProcessor: processor,
            sessionsRootProvider: { fixture.root },
            now: { Date(timeIntervalSince1970: 9_500) },
            jitterUnit: { 0.5 },
            pathMonitor: nil,
            applicationIsActive: { true }
        )

        let result = await outbox.retryNow(localSessionId: fixture.localSessionId)

        #expect(result.uploadedSessionIds == [fixture.localSessionId])
        #expect(processor.callCount == 0)
        #expect(api.uploadCallCount == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("session.json").path))
        #expect(try LocalSessionManifestStore.load(from: fixture.directory).uploadStatus == .uploaded)
    }

    @Test func inactiveAppDoesNotStartAutomaticOutboxWork() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let api = MockDeferredAPI(uploadResults: [.success(validReceipt())])
        let outbox = DeferredSessionOutbox(
            apiClient: api,
            stageProcessor: NoopStageProcessor(),
            sessionsRootProvider: { fixture.root },
            now: { Date(timeIntervalSince1970: 10_000) },
            jitterUnit: { 0.5 },
            pathMonitor: nil,
            applicationIsActive: { false }
        )

        let backgroundResult = await outbox.run(trigger: .pathSatisfied)

        #expect(backgroundResult.attemptedCount == 0)
        #expect(api.uploadCallCount == 0)
    }

    @Test func retryNowTargetsOnlyRequestedLocalSession() async throws {
        let first = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: first.root) }
        let secondDirectory = first.root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try Data([0x01]).write(to: secondDirectory.appendingPathComponent("recording.m4a"))
        try Data("{}".utf8).write(to: secondDirectory.appendingPathComponent("session.json"))
        var second = LocalSessionManifest(localSessionId: "second", audioFileName: "recording.m4a")
        second.audioStatus = .recordedLocally
        second.transcriptionStatus = .completed
        second.transcriptionPipelineVersion = LocalSessionManifest.currentTranscriptionPipelineVersion
        second.analysisStatus = .completed
        second.clarificationStatus = .completed
        second.uploadStatus = .pending
        try LocalSessionManifestStore.save(second, to: secondDirectory)

        let api = MockDeferredAPI(uploadResults: [.success(validReceipt())])
        let outbox = makeOutbox(root: first.root, api: api, clock: MutableClock(11_000))

        let result = await outbox.retryNow(localSessionId: first.localSessionId)

        #expect(result.uploadedSessionIds == [first.localSessionId])
        #expect(api.uploadCallCount == 1)
        #expect(try LocalSessionManifestStore.load(from: secondDirectory).uploadStatus == .pending)
    }

    @Test func retryNowProcessesSelectedSessionsSequentially() async throws {
        let first = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: first.root) }
        let secondDirectory = first.root.appendingPathComponent("second", isDirectory: true)
        let thirdDirectory = first.root.appendingPathComponent("third", isDirectory: true)
        try makeReadySession(id: "second", directory: secondDirectory)
        try makeReadySession(id: "third", directory: thirdDirectory)

        let api = MockDeferredAPI(uploadResults: [
            .success(validReceipt()),
            .success(validReceipt())
        ])
        let outbox = makeOutbox(root: first.root, api: api, clock: MutableClock(12_000))

        let result = await outbox.retryNow(localSessionIds: [first.localSessionId, "second"])

        #expect(result.attemptedCount == 2)
        #expect(Set(result.uploadedSessionIds) == Set([first.localSessionId, "second"]))
        #expect(api.uploadCallCount == 2)
        #expect(try LocalSessionManifestStore.load(from: thirdDirectory).uploadStatus == .pending)
    }

    @Test func batchRetrySubmitsRawAudioForServerProcessing() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("session.json"))
        try LocalSessionManifestStore.update(in: fixture.directory) { manifest in
            manifest.transcriptionStatus = .pending
            manifest.transcriptionPipelineVersion = 0
            manifest.transcriptFileName = nil
            manifest.transcription = nil
            manifest.analysisStatus = .pending
            manifest.matchedQuestions = []
            manifest.clarificationStatus = .pending
            manifest.uploadStatus = .notReady
        }
        let processor = CompletingStageProcessor()
        let api = MockDeferredAPI(uploadResults: [.success(validReceipt())])
        let outbox = DeferredSessionOutbox(
            apiClient: api,
            stageProcessor: processor,
            sessionsRootProvider: { fixture.root },
            now: { Date(timeIntervalSince1970: 12_500) },
            jitterUnit: { 0.5 },
            pathMonitor: nil,
            applicationIsActive: { true }
        )

        let result = await outbox.retryNow(localSessionId: fixture.localSessionId)

        #expect(result.uploadedSessionIds == [fixture.localSessionId])
        #expect(processor.callCount == 0)
        #expect(api.uploadCallCount == 0)
        #expect(api.processingUploadCallCount == 1)
        #expect(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("processing_input.json").path
        ))
        let manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.serverProcessingStatus == .queued)
        #expect(manifest.analysisStatus == .pending)
        #expect(manifest.uploadStatus == .uploaded)
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    @Test func completedServerResultIsSavedAtomicallyAndUpdatesManifest() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("session.json"))
        try LocalSessionManifestStore.update(in: fixture.directory) { manifest in
            manifest.transcriptionStatus = .pending
            manifest.analysisStatus = .pending
            manifest.clarificationStatus = .pending
            manifest.uploadStatus = .notReady
        }
        let resultJSON = """
        {
          "local_session_id": "\(fixture.localSessionId)",
          "transcription": "Server transcript",
          "matched_questions": [
            {
              "matched_question_id": 1,
              "matched_question": "Are there seats?",
              "extracted_answer": "Yes",
              "confidence": "high",
              "clarification_needed": false
            }
          ]
        }
        """.data(using: .utf8)!
        let api = MockDeferredAPI(
            uploadResults: [],
            processingStatus: "completed",
            processingResultData: resultJSON
        )
        let outbox = makeOutbox(root: fixture.root, api: api, clock: MutableClock(13_000))

        let result = await outbox.run(trigger: .sessionReady)

        #expect(result.uploadedSessionIds == [fixture.localSessionId])
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("session.json")) == resultJSON)
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("transcript.txt"), encoding: .utf8) == "Server transcript")
        let manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.serverProcessingStatus == .completed)
        #expect(manifest.transcription == "Server transcript")
        #expect(manifest.matchedQuestions.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    @Test func needsReviewServerStatusBecomesDashboardClarificationState() async throws {
        let fixture = try makeReadyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("session.json"))
        try LocalSessionManifestStore.update(in: fixture.directory) { manifest in
            manifest.transcriptionStatus = .pending
            manifest.analysisStatus = .pending
            manifest.clarificationStatus = .pending
            manifest.uploadStatus = .notReady
        }
        let api = MockDeferredAPI(uploadResults: [], processingStatus: "needs_review")
        let outbox = makeOutbox(root: fixture.root, api: api, clock: MutableClock(14_000))

        _ = await outbox.run(trigger: .sessionReady)

        let manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.serverProcessingStatus == .needsReview)
        #expect(LocalSessionStatusSummary.derive(from: manifest, hasFinalPackage: false).primary == "Clarification required")
        #expect(FileManager.default.fileExists(atPath: fixture.audioURL.path))
    }

    private func makeReadySession(id: String, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0x01]).write(to: directory.appendingPathComponent("recording.m4a"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("session.json"))
        var manifest = LocalSessionManifest(localSessionId: id, audioFileName: "recording.m4a")
        manifest.audioStatus = .recordedLocally
        manifest.transcriptionStatus = .completed
        manifest.transcriptionPipelineVersion = LocalSessionManifest.currentTranscriptionPipelineVersion
        manifest.analysisStatus = .completed
        manifest.clarificationStatus = .completed
        manifest.uploadStatus = .pending
        try LocalSessionManifestStore.save(manifest, to: directory)
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
            pathMonitor: nil,
            applicationIsActive: { true }
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
        manifest.transcriptionPipelineVersion = LocalSessionManifest.currentTranscriptionPipelineVersion
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

@MainActor
private final class CountingStageProcessor: DeferredSessionStageProcessing {
    private(set) var callCount = 0

    func resume(
        sessionDirectoryURL: URL,
        audioURL: URL,
        localeIdentifier: String
    ) async -> DurableProcessingOutcome {
        callCount += 1
        return .deferred(stage: .transcription, category: .speechUnavailable, message: "Deferred")
    }
}

@MainActor
private final class CompletingStageProcessor: DeferredSessionStageProcessing {
    static let transcript = "Complete recovered interview with every recorded answer."
    private(set) var callCount = 0

    func resume(
        sessionDirectoryURL: URL,
        audioURL: URL,
        localeIdentifier: String
    ) async -> DurableProcessingOutcome {
        callCount += 1
        return .analysisCompleted(
            transcript: Self.transcript,
            matchedQuestions: [
                MatchedQuestion(
                    matchedQuestionId: 1,
                    matchedQuestion: "Is the area comfortable?",
                    extractedAnswer: "Yes",
                    confidence: "high",
                    clarificationNeeded: false
                )
            ]
        )
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
    private let processingStatus: String
    private let processingResultData: Data?
    private(set) var createCallCount = 0
    private(set) var uploadCallCount = 0
    private(set) var processingUploadCallCount = 0
    private(set) var processingFetchCallCount = 0
    private(set) var acceptedLocalSessionIds: Set<String> = []
    private(set) var createdIdentityByLocalSessionId: [String: DeferredCloudSessionIdentity] = [:]
    private(set) var uploadedCloudSessionIds: [String] = []

    init(
        uploadResults: [Result<DeferredPackageUploadReceipt, Error>],
        uploadDelayNanoseconds: UInt64 = 0,
        acceptedBeforeFailure: Bool = false,
        loseFirstCreationResponse: Bool = false,
        processingStatus: String = "queued",
        processingResultData: Data? = nil
    ) {
        self.uploadResults = uploadResults
        self.uploadDelayNanoseconds = uploadDelayNanoseconds
        self.acceptedBeforeFailure = acceptedBeforeFailure
        self.loseFirstCreationResponse = loseFirstCreationResponse
        self.processingStatus = processingStatus
        self.processingResultData = processingResultData
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

    func uploadDeferredProcessingInput(
        sessionId: String,
        inputManifestURL: URL,
        audioURL: URL,
        localSessionId: String
    ) async throws -> DeferredProcessingJobReceipt {
        processingUploadCallCount += 1
        acceptedLocalSessionIds.insert(localSessionId)
        uploadedCloudSessionIds.append(sessionId)
        return DeferredProcessingJobReceipt(
            sessionId: sessionId,
            respondentId: Self.respondentId,
            status: processingStatus,
            revision: 1,
            resultAvailable: processingStatus == "completed"
        )
    }

    func fetchDeferredProcessingJob(sessionId: String) async throws -> DeferredProcessingJobReceipt {
        processingFetchCallCount += 1
        return DeferredProcessingJobReceipt(
            sessionId: sessionId,
            respondentId: Self.respondentId,
            status: processingStatus,
            revision: 1,
            resultAvailable: processingStatus == "completed"
        )
    }

    func fetchDeferredProcessingResult(sessionId: String) async throws -> Data {
        guard let processingResultData else { throw URLError(.resourceUnavailable) }
        return processingResultData
    }
}
