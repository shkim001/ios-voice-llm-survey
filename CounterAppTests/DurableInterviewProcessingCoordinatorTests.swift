import Foundation
import Speech
import Testing
@testable import CounterApp

@MainActor
struct DurableInterviewProcessingCoordinatorTests {
    @Test func successfulTranscriptionIsPersistedBeforeLLMAnalysis() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let speech = FakeSpeech(result: .success("A durable transcript"))
        let llm = FakeLLM(result: .success([highConfidenceMatch()]))
        let coordinator = makeCoordinator(speech: speech, llm: llm, networkAvailable: true)

        let outcome = await coordinator.resume(
            sessionDirectoryURL: fixture.directory,
            audioURL: fixture.audioURL
        )

        guard case .analysisCompleted(let transcript, _) = outcome else {
            Issue.record("Expected completed analysis")
            return
        }
        #expect(transcript == "A durable transcript")
        #expect(llm.receivedTranscripts == ["A durable transcript"])
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("transcript.txt"), encoding: .utf8) == "A durable transcript")
        let manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.transcriptionStatus == .completed)
        #expect(manifest.transcriptFileName == "transcript.txt")
        #expect(manifest.analysisStatus == .completed)
    }

    @Test func speechFailureBecomesPendingRetryWithoutCallingLLM() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let speech = FakeSpeech(result: .failure(TestFailure.speech))
        let llm = FakeLLM(result: .success([highConfidenceMatch()]))
        let coordinator = makeCoordinator(speech: speech, llm: llm, networkAvailable: true)

        let outcome = await coordinator.resume(sessionDirectoryURL: fixture.directory, audioURL: fixture.audioURL)

        guard case .failed(let stage, _, _) = outcome else {
            Issue.record("Expected transcription failure")
            return
        }
        #expect(stage == .transcription)
        #expect(llm.callCount == 0)
        let manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.transcriptionStatus == .pendingRetry)
        #expect(manifest.transcriptionErrorCategory == DurableProcessingErrorCategory.speechRecognition.rawValue)
        #expect(manifest.retry.retryCount == 1)
        #expect(manifest.audioStatus == .recordedLocally)
    }

    @Test func invalidAudioIsMarkedTerminalAndNeverSentToSpeech() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let speech = FakeSpeech(result: .success("Must not run"))
        let llm = FakeLLM(result: .success([highConfidenceMatch()]))
        let coordinator = DurableInterviewProcessingCoordinator(
            speech: speech,
            llm: llm,
            connectivity: FixedConnectivity(networkIsAvailable: true),
            transcriptStore: FileTranscriptStore(),
            audioValidator: FailingAudioValidator()
        )

        let outcome = await coordinator.resume(
            sessionDirectoryURL: fixture.directory,
            audioURL: fixture.audioURL
        )

        guard case .failed(let stage, let category, _) = outcome else {
            Issue.record("Expected terminal audio validation failure")
            return
        }
        #expect(stage == .transcription)
        #expect(category == .audioUnavailable)
        #expect(speech.callCount == 0)
        #expect(llm.callCount == 0)
        let manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.audioStatus == .failed)
        #expect(manifest.transcriptionStatus == .failed)
        #expect(manifest.transcriptionErrorCategory == DurableProcessingErrorCategory.audioUnavailable.rawValue)
        #expect(manifest.retry.nextRetryAt == nil)
    }

    @Test func llmTimeoutRetainsTranscriptAndResumesWithoutRetranscribing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstSpeech = FakeSpeech(result: .success("Persist me first"))
        let firstLLM = FakeLLM(result: .failure(URLError(.timedOut)))
        let firstCoordinator = makeCoordinator(speech: firstSpeech, llm: firstLLM, networkAvailable: true)

        let firstOutcome = await firstCoordinator.resume(
            sessionDirectoryURL: fixture.directory,
            audioURL: fixture.audioURL
        )
        guard case .failed(let stage, let category, _) = firstOutcome else {
            Issue.record("Expected LLM timeout")
            return
        }
        #expect(stage == .analysis)
        #expect(category == .timeout)
        var manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.transcriptionStatus == .completed)
        #expect(manifest.analysisStatus == .pendingRetry)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("transcript.txt").path))

        let recreatedSpeech = FakeSpeech(result: .failure(TestFailure.speech))
        let recreatedLLM = FakeLLM(result: .success([highConfidenceMatch()]))
        let recreatedCoordinator = makeCoordinator(
            speech: recreatedSpeech,
            llm: recreatedLLM,
            networkAvailable: true
        )
        let resumedOutcome = await recreatedCoordinator.resume(
            sessionDirectoryURL: fixture.directory,
            audioURL: fixture.audioURL
        )

        guard case .analysisCompleted = resumedOutcome else {
            Issue.record("Expected resumed analysis completion")
            return
        }
        #expect(recreatedSpeech.callCount == 0)
        #expect(recreatedLLM.receivedTranscripts == ["Persist me first"])
        manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.analysisStatus == .completed)
        #expect(manifest.audioStatus == .recordedLocally)
    }

    @Test func offlineWithoutOnDeviceSpeechDefersSafely() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let speech = FakeSpeech(
            result: .success("Should not run"),
            supportsOnDevice: false
        )
        let llm = FakeLLM(result: .success([highConfidenceMatch()]))
        let coordinator = makeCoordinator(speech: speech, llm: llm, networkAvailable: false)

        let outcome = await coordinator.resume(sessionDirectoryURL: fixture.directory, audioURL: fixture.audioURL)

        guard case .deferred(let stage, let category, _) = outcome else {
            Issue.record("Expected deferred transcription")
            return
        }
        #expect(stage == .transcription)
        #expect(category == .onDeviceSpeechUnavailable)
        #expect(speech.callCount == 0)
        #expect(llm.callCount == 0)
        let manifest = try LocalSessionManifestStore.load(from: fixture.directory)
        #expect(manifest.transcriptionStatus == .pending)
        #expect(manifest.audioStatus == .recordedLocally)
    }

    @Test func offlineOnDeviceSpeechIsExplicitlyRequired() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let speech = FakeSpeech(result: .success("Offline transcript"), supportsOnDevice: true)
        let llm = FakeLLM(result: .success([highConfidenceMatch()]))
        let coordinator = makeCoordinator(speech: speech, llm: llm, networkAvailable: false)

        _ = await coordinator.resume(sessionDirectoryURL: fixture.directory, audioURL: fixture.audioURL)

        #expect(speech.requiresOnDeviceValues == [true])
    }

    @Test func duplicateConcurrentResumeIsSuppressedPerSession() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let speech = FakeSpeech(result: .success("Once"), delayNanoseconds: 150_000_000)
        let llm = FakeLLM(result: .success([highConfidenceMatch()]))
        let coordinator = makeCoordinator(speech: speech, llm: llm, networkAvailable: true)

        async let first = coordinator.resume(sessionDirectoryURL: fixture.directory, audioURL: fixture.audioURL)
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = await coordinator.resume(sessionDirectoryURL: fixture.directory, audioURL: fixture.audioURL)
        _ = await first

        guard case .alreadyRunning = second else {
            Issue.record("Expected duplicate processing suppression")
            return
        }
        #expect(speech.callCount == 1)
        #expect(llm.callCount == 1)
    }

    @Test func completedAnalysisResumesAtClarificationThenReadyToUpload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try "Saved transcript".write(
            to: fixture.directory.appendingPathComponent("transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        try LocalSessionManifestStore.update(in: fixture.directory) { manifest in
            manifest.transcriptionStatus = .completed
            manifest.transcriptFileName = "transcript.txt"
            manifest.transcription = "Saved transcript"
            manifest.analysisStatus = .completed
            manifest.matchedQuestions = [
                MatchedQuestion(
                    matchedQuestionId: 1,
                    matchedQuestion: "Is seating available?",
                    extractedAnswer: "Maybe",
                    confidence: "low",
                    clarificationNeeded: true
                )
            ]
            manifest.clarificationStatus = .pending
        }
        let speech = FakeSpeech(result: .failure(TestFailure.speech))
        let llm = FakeLLM(result: .failure(TestFailure.speech))
        let coordinator = makeCoordinator(speech: speech, llm: llm, networkAvailable: true)

        let clarificationOutcome = await coordinator.resume(
            sessionDirectoryURL: fixture.directory,
            audioURL: fixture.audioURL
        )
        guard case .needsClarification = clarificationOutcome else {
            Issue.record("Expected clarification resumption")
            return
        }
        #expect(speech.callCount == 0)
        #expect(llm.callCount == 0)

        try Data("{}".utf8).write(
            to: fixture.directory.appendingPathComponent("session.json"),
            options: [.atomic]
        )
        try LocalSessionManifestStore.update(in: fixture.directory) { manifest in
            manifest.clarificationStatus = .completed
            manifest.uploadStatus = .pending
        }
        let uploadOutcome = await coordinator.resume(
            sessionDirectoryURL: fixture.directory,
            audioURL: fixture.audioURL
        )
        guard case .readyToUpload = uploadOutcome else {
            Issue.record("Expected ready-to-upload resumption")
            return
        }
    }

    private func makeCoordinator(
        speech: FakeSpeech,
        llm: FakeLLM,
        networkAvailable: Bool
    ) -> DurableInterviewProcessingCoordinator {
        DurableInterviewProcessingCoordinator(
            speech: speech,
            llm: llm,
            connectivity: FixedConnectivity(networkIsAvailable: networkAvailable),
            transcriptStore: FileTranscriptStore(),
            audioValidator: AcceptingAudioValidator()
        )
    }

    private func makeFixture() throws -> (directory: URL, audioURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableProcessingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("recording.m4a")
        try Data([0x01, 0x02, 0x03]).write(to: audioURL)
        var manifest = LocalSessionManifest(
            localSessionId: UUID().uuidString,
            audioFileName: audioURL.lastPathComponent,
            questionnaireSnapshot: testQuestionnaire()
        )
        manifest.audioStatus = .recordedLocally
        try LocalSessionManifestStore.save(manifest, to: directory)
        return (directory, audioURL)
    }

    private func testQuestionnaire() -> Questionnaire {
        Questionnaire(
            id: "test",
            version: "1",
            title: "Test Questionnaire",
            description: "",
            status: "published",
            hash: "hash",
            questions: [
                Question(
                    id: 1,
                    question: "Is seating available?",
                    type: "yes-no",
                    followUp: nil,
                    keywords: ["seating"]
                )
            ]
        )
    }

    private func highConfidenceMatch() -> MatchedQuestion {
        MatchedQuestion(
            matchedQuestionId: 1,
            matchedQuestion: "Is seating available?",
            extractedAnswer: "Yes",
            confidence: "high",
            clarificationNeeded: false
        )
    }
}

private enum TestFailure: LocalizedError {
    case speech

    var errorDescription: String? { "Synthetic speech failure" }
}

private final class FakeSpeech: InterviewSpeechTranscribing {
    private let result: Result<String, Error>
    private let supportsOnDevice: Bool
    private let delayNanoseconds: UInt64
    private(set) var callCount = 0
    private(set) var requiresOnDeviceValues: [Bool] = []

    init(
        result: Result<String, Error>,
        supportsOnDevice: Bool = true,
        delayNanoseconds: UInt64 = 0
    ) {
        self.result = result
        self.supportsOnDevice = supportsOnDevice
        self.delayNanoseconds = delayNanoseconds
    }

    func capabilities(localeIdentifier: String) -> SpeechRecognitionCapabilities {
        SpeechRecognitionCapabilities(
            supportsOnDeviceRecognition: supportsOnDevice,
            serviceIsAvailable: true,
            authorizationStatus: .authorized
        )
    }

    func transcribe(
        audioURL: URL,
        localeIdentifier: String,
        requiresOnDeviceRecognition: Bool
    ) async throws -> String {
        callCount += 1
        requiresOnDeviceValues.append(requiresOnDeviceRecognition)
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return try result.get()
    }
}

private final class FakeLLM: InterviewLLMAnalyzing {
    private let result: Result<[MatchedQuestion], Error>
    private(set) var receivedTranscripts: [String] = []
    var callCount: Int { receivedTranscripts.count }

    init(result: Result<[MatchedQuestion], Error>) {
        self.result = result
    }

    func analyze(transcript: String, questions: [Question]) async throws -> [MatchedQuestion] {
        receivedTranscripts.append(transcript)
        return try result.get()
    }
}

private struct FixedConnectivity: ProcessingConnectivityProviding {
    let networkIsAvailable: Bool
}

private struct AcceptingAudioValidator: InterviewAudioValidating {
    func validate(audioURL: URL) throws {}
}

private struct FailingAudioValidator: InterviewAudioValidating {
    func validate(audioURL: URL) throws {
        throw DurableProcessingError.audioUnavailable
    }
}
