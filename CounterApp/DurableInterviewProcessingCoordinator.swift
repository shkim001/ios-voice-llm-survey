import Foundation
import AVFoundation
import Network
import Speech

enum DurableProcessingStage: String, Equatable {
    case transcription
    case analysis
    case clarification
    case upload
}

enum DurableProcessingErrorCategory: String, Equatable {
    case audioUnavailable = "audio_unavailable"
    case speechPermission = "speech_permission"
    case speechUnavailable = "speech_unavailable"
    case onDeviceSpeechUnavailable = "on_device_speech_unavailable"
    case speechRecognition = "speech_recognition"
    case timeout
    case transcriptPersistence = "transcript_persistence"
    case transcriptUnavailable = "transcript_unavailable"
    case questionnaireUnavailable = "questionnaire_unavailable"
    case llmConfiguration = "llm_configuration"
    case llmUnavailable = "llm_unavailable"
    case invalidResponse = "invalid_response"
    case persistence
    case unknown
}

struct SpeechRecognitionCapabilities: Equatable {
    let supportsOnDeviceRecognition: Bool
    let serviceIsAvailable: Bool
    let authorizationStatus: SFSpeechRecognizerAuthorizationStatus
}

protocol InterviewSpeechTranscribing {
    func capabilities(localeIdentifier: String) -> SpeechRecognitionCapabilities
    func transcribe(
        audioURL: URL,
        localeIdentifier: String,
        requiresOnDeviceRecognition: Bool
    ) async throws -> String
}

protocol InterviewLLMAnalyzing {
    func analyze(transcript: String, questions: [Question]) async throws -> [MatchedQuestion]
}

protocol ProcessingConnectivityProviding {
    var networkIsAvailable: Bool { get }
}

protocol TranscriptPersisting {
    func save(_ transcript: String, in sessionDirectoryURL: URL) throws -> URL
    func load(from transcriptURL: URL) throws -> String
}

protocol InterviewAudioValidating {
    func validate(audioURL: URL) throws
}

struct PlayableInterviewAudioValidator: InterviewAudioValidating {
    func validate(audioURL: URL) throws {
        let values = try audioURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey])
        guard values.isRegularFile == true,
              values.isReadable != false,
              (values.fileSize ?? 0) > 0 else {
            throw DurableProcessingError.audioUnavailable
        }

        do {
            let file = try AVAudioFile(forReading: audioURL)
            guard file.length > 0, file.processingFormat.sampleRate > 0 else {
                throw DurableProcessingError.audioUnavailable
            }
        } catch {
            throw DurableProcessingError.audioUnavailable
        }
    }
}

enum DurableProcessingOutcome {
    case needsClarification(transcript: String, matchedQuestions: [MatchedQuestion])
    case analysisCompleted(transcript: String, matchedQuestions: [MatchedQuestion])
    case readyToUpload
    case deferred(stage: DurableProcessingStage, category: DurableProcessingErrorCategory, message: String)
    case failed(stage: DurableProcessingStage, category: DurableProcessingErrorCategory, message: String)
    case alreadyRunning
}

struct FileTranscriptStore: TranscriptPersisting {
    static let fileName = "transcript.txt"

    func save(_ transcript: String, in sessionDirectoryURL: URL) throws -> URL {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let data = normalized.data(using: .utf8) else {
            throw DurableProcessingError.emptyTranscript
        }
        let url = sessionDirectoryURL.appendingPathComponent(Self.fileName)
        try data.write(to: url, options: [.atomic])
        _ = try load(from: url)
        return url
    }

    func load(from transcriptURL: URL) throws -> String {
        let text = try String(contentsOf: transcriptURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DurableProcessingError.emptyTranscript }
        return text
    }
}

enum DurableProcessingError: LocalizedError {
    case audioUnavailable
    case speechPermission
    case speechUnavailable
    case onDeviceSpeechUnavailable
    case emptyTranscript
    case questionnaireUnavailable

    var errorDescription: String? {
        switch self {
        case .audioUnavailable:
            return "The saved audio is missing or is not a valid playable recording. It remains available in Audio Files for review or deletion."
        case .speechPermission:
            return "Speech recognition permission is not available."
        case .speechUnavailable:
            return "Apple Speech recognition is currently unavailable."
        case .onDeviceSpeechUnavailable:
            return "This device and locale do not currently support on-device transcription."
        case .emptyTranscript:
            return "Speech recognition returned an empty transcript."
        case .questionnaireUnavailable:
            return "The saved questionnaire snapshot is unavailable."
        }
    }
}

final class SystemConnectivityStatus: ProcessingConnectivityProviding {
    static let shared = SystemConnectivityStatus()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "VoiceSurvey.NetworkPathHint")
    private let lock = NSLock()
    private var available: Bool

    private init() {
        available = monitor.currentPath.status == .satisfied
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.lock()
            self?.available = path.status == .satisfied
            self?.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    var networkIsAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return available
    }
}

final class AppleSpeechTranscriber: InterviewSpeechTranscribing {
    func capabilities(localeIdentifier: String) -> SpeechRecognitionCapabilities {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        return SpeechRecognitionCapabilities(
            supportsOnDeviceRecognition: recognizer?.supportsOnDeviceRecognition ?? false,
            serviceIsAvailable: recognizer?.isAvailable ?? false,
            authorizationStatus: SFSpeechRecognizer.authorizationStatus()
        )
    }

    func transcribe(
        audioURL: URL,
        localeIdentifier: String,
        requiresOnDeviceRecognition: Bool
    ) async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw DurableProcessingError.speechPermission
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw DurableProcessingError.speechUnavailable
        }
        if requiresOnDeviceRecognition {
            guard recognizer.supportsOnDeviceRecognition else {
                throw DurableProcessingError.onDeviceSpeechUnavailable
            }
        } else if !recognizer.isAvailable {
            throw DurableProcessingError.speechUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition

        return try await withCheckedThrowingContinuation { continuation in
            let gate = SpeechContinuationGate(continuation: continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    gate.resume(with: .failure(error))
                    return
                }
                if let result, result.isFinal {
                    let transcript = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if transcript.isEmpty {
                        gate.resume(with: .failure(DurableProcessingError.emptyTranscript))
                    } else {
                        gate.resume(with: .success(transcript))
                    }
                }
            }
            gate.attach(recognitionTask: task)
            gate.scheduleTimeout(after: 120)
        }
    }
}

private final class SpeechContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timeoutWorkItem: DispatchWorkItem?

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<String, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let recognitionTask = self.recognitionTask
        self.recognitionTask = nil
        let timeoutWorkItem = self.timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()
        timeoutWorkItem?.cancel()
        recognitionTask?.cancel()
        continuation.resume(with: result)
    }

    func attach(recognitionTask: SFSpeechRecognitionTask) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            recognitionTask.cancel()
            return
        }
        self.recognitionTask = recognitionTask
        lock.unlock()
    }

    func scheduleTimeout(after seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.resume(with: .failure(URLError(.timedOut)))
        }
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        timeoutWorkItem = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
    }
}

struct LiveLLMAnalyzer: InterviewLLMAnalyzing {
    func analyze(transcript: String, questions: [Question]) async throws -> [MatchedQuestion] {
        try await LLMService.shared.analyzeTranscription(transcript, questions: questions)
    }
}

@MainActor
final class DurableInterviewProcessingCoordinator {
    static let shared = DurableInterviewProcessingCoordinator(
        speech: AppleSpeechTranscriber(),
        llm: LiveLLMAnalyzer(),
        connectivity: SystemConnectivityStatus.shared,
        transcriptStore: FileTranscriptStore(),
        audioValidator: PlayableInterviewAudioValidator()
    )

    private let speech: InterviewSpeechTranscribing
    private let llm: InterviewLLMAnalyzing
    private let connectivity: ProcessingConnectivityProviding
    private let transcriptStore: TranscriptPersisting
    private let audioValidator: InterviewAudioValidating
    private var activeSessionIds: Set<String> = []

    init(
        speech: InterviewSpeechTranscribing,
        llm: InterviewLLMAnalyzing,
        connectivity: ProcessingConnectivityProviding,
        transcriptStore: TranscriptPersisting,
        audioValidator: InterviewAudioValidating = PlayableInterviewAudioValidator()
    ) {
        self.speech = speech
        self.llm = llm
        self.connectivity = connectivity
        self.transcriptStore = transcriptStore
        self.audioValidator = audioValidator
    }

    func resume(
        sessionDirectoryURL: URL,
        audioURL: URL,
        localeIdentifier: String = "en-US"
    ) async -> DurableProcessingOutcome {
        let initialManifest: LocalSessionManifest
        do {
            initialManifest = try LocalSessionManifestStore.load(from: sessionDirectoryURL)
        } catch {
            return .failed(stage: .transcription, category: .persistence, message: error.localizedDescription)
        }

        let localSessionId = initialManifest.localSessionId
        guard !activeSessionIds.contains(localSessionId) else { return .alreadyRunning }
        activeSessionIds.insert(localSessionId)
        defer { activeSessionIds.remove(localSessionId) }

        do {
            try audioValidator.validate(audioURL: audioURL)
        } catch {
            let message = DurableProcessingError.audioUnavailable.localizedDescription
            try? LocalSessionManifestStore.update(in: sessionDirectoryURL) { value in
                value.audioStatus = .failed
                value.transcriptionStatus = .failed
                value.transcriptionErrorCategory = DurableProcessingErrorCategory.audioUnavailable.rawValue
                value.retry.lastError = message
                value.retry.lastAttemptAt = Date().timeIntervalSince1970
                value.retry.nextRetryAt = nil
            }
            return .failed(stage: .transcription, category: .audioUnavailable, message: message)
        }

        do {
            var manifest = try LocalSessionManifestStore.load(from: sessionDirectoryURL)
            if manifest.analysisStatus == .completed, !manifest.matchedQuestions.isEmpty {
                let transcript = try durableTranscript(for: manifest, in: sessionDirectoryURL)
                if manifest.clarificationStatus == .pending {
                    return .needsClarification(transcript: transcript, matchedQuestions: manifest.matchedQuestions)
                }
                if manifest.clarificationStatus == .completed,
                   FileManager.default.fileExists(atPath: sessionDirectoryURL.appendingPathComponent("session.json").path) {
                    return .readyToUpload
                }
                return .analysisCompleted(transcript: transcript, matchedQuestions: manifest.matchedQuestions)
            }

            if manifest.transcriptionStatus == .completed {
                _ = try durableTranscript(for: manifest, in: sessionDirectoryURL)
            } else {
                let capabilities = speech.capabilities(localeIdentifier: localeIdentifier)
                if capabilities.authorizationStatus != .authorized {
                    throw StageFailure(
                        stage: .transcription,
                        category: .speechPermission,
                        message: DurableProcessingError.speechPermission.localizedDescription
                    )
                }
                let offline = !connectivity.networkIsAvailable
                if offline && !capabilities.supportsOnDeviceRecognition {
                    let message = DurableProcessingError.onDeviceSpeechUnavailable.localizedDescription
                    try LocalSessionManifestStore.update(in: sessionDirectoryURL) { value in
                        value.transcriptionStatus = .pending
                        value.transcriptionErrorCategory = DurableProcessingErrorCategory.onDeviceSpeechUnavailable.rawValue
                        value.retry.lastError = message
                    }
                    return .deferred(
                        stage: .transcription,
                        category: .onDeviceSpeechUnavailable,
                        message: message
                    )
                }

                try LocalSessionManifestStore.update(in: sessionDirectoryURL) { value in
                    value.transcriptionStatus = .inProgress
                    value.transcriptionErrorCategory = nil
                    value.retry.lastAttemptAt = Date().timeIntervalSince1970
                    value.retry.lastError = nil
                }
                let recognized: String
                do {
                    recognized = try await speech.transcribe(
                        audioURL: audioURL,
                        localeIdentifier: localeIdentifier,
                        requiresOnDeviceRecognition: offline && capabilities.supportsOnDeviceRecognition
                    )
                } catch {
                    throw StageFailure(
                        stage: .transcription,
                        category: classifySpeechError(error),
                        message: error.localizedDescription
                    )
                }

                let transcriptURL: URL
                do {
                    transcriptURL = try transcriptStore.save(recognized, in: sessionDirectoryURL)
                    try LocalSessionManifestStore.update(in: sessionDirectoryURL) { value in
                        value.transcriptionStatus = .completed
                        value.transcriptFileName = transcriptURL.lastPathComponent
                        value.transcription = recognized
                        value.transcriptionErrorCategory = nil
                        value.retry = LocalSessionRetryMetadata()
                    }
                } catch {
                    throw StageFailure(
                        stage: .transcription,
                        category: .transcriptPersistence,
                        message: error.localizedDescription
                    )
                }
                _ = try transcriptStore.load(from: transcriptURL)
            }

            manifest = try LocalSessionManifestStore.load(from: sessionDirectoryURL)
            guard let questions = manifest.questionnaireSnapshot?.questions, !questions.isEmpty else {
                throw StageFailure(
                    stage: .analysis,
                    category: .questionnaireUnavailable,
                    message: DurableProcessingError.questionnaireUnavailable.localizedDescription
                )
            }

            try LocalSessionManifestStore.update(in: sessionDirectoryURL) { value in
                value.analysisStatus = .inProgress
                value.analysisErrorCategory = nil
                value.retry.lastAttemptAt = Date().timeIntervalSince1970
                value.retry.lastError = nil
            }
            let transcriptManifest = try LocalSessionManifestStore.load(from: sessionDirectoryURL)
            let persistedTranscript = try transcriptStore.load(
                from: sessionDirectoryURL.appendingPathComponent(
                    transcriptManifest.transcriptFileName ?? FileTranscriptStore.fileName
                )
            )
            let matches: [MatchedQuestion]
            do {
                matches = try await llm.analyze(transcript: persistedTranscript, questions: questions)
            } catch {
                throw StageFailure(
                    stage: .analysis,
                    category: classifyLLMError(error),
                    message: error.localizedDescription
                )
            }
            let needsClarification = matches.contains {
                $0.manuallyClarified != true
                    && ($0.clarificationNeeded
                        || $0.confidence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "high")
            }
            try LocalSessionManifestStore.update(in: sessionDirectoryURL) { value in
                value.analysisStatus = .completed
                value.matchedQuestions = matches
                value.analysisErrorCategory = nil
                value.clarificationStatus = needsClarification ? .pending : .notRequired
                value.retry = LocalSessionRetryMetadata()
            }
            return needsClarification
                ? .needsClarification(transcript: persistedTranscript, matchedQuestions: matches)
                : .analysisCompleted(transcript: persistedTranscript, matchedQuestions: matches)
        } catch let failure as StageFailure {
            persistFailure(failure, in: sessionDirectoryURL)
            return .failed(stage: failure.stage, category: failure.category, message: failure.message)
        } catch {
            let failure = StageFailure(stage: .analysis, category: .persistence, message: error.localizedDescription)
            persistFailure(failure, in: sessionDirectoryURL)
            return .failed(stage: failure.stage, category: failure.category, message: failure.message)
        }
    }

    private func durableTranscript(for manifest: LocalSessionManifest, in directoryURL: URL) throws -> String {
        let fileName = manifest.transcriptFileName ?? FileTranscriptStore.fileName
        let url = directoryURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            return try transcriptStore.load(from: url)
        }
        if let legacyTranscript = manifest.transcription,
           !legacyTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let savedURL = try transcriptStore.save(legacyTranscript, in: directoryURL)
            try LocalSessionManifestStore.update(in: directoryURL) { value in
                value.transcriptFileName = savedURL.lastPathComponent
                value.transcriptionStatus = .completed
            }
            return try transcriptStore.load(from: savedURL)
        }
        throw StageFailure(
            stage: .transcription,
            category: .transcriptUnavailable,
            message: "The persisted transcript file is unavailable."
        )
    }

    private func persistFailure(_ failure: StageFailure, in directoryURL: URL) {
        let attemptDate = Date()
        try? LocalSessionManifestStore.update(in: directoryURL, now: attemptDate) { value in
            switch failure.stage {
            case .transcription:
                value.transcriptionStatus = .pendingRetry
                value.transcriptionErrorCategory = failure.category.rawValue
            case .analysis:
                value.analysisStatus = .pendingRetry
                value.analysisErrorCategory = failure.category.rawValue
            case .clarification, .upload:
                break
            }
            let retryCount = value.retry.retryCount + 1
            value.retry.retryCount = retryCount
            value.retry.lastAttemptAt = attemptDate.timeIntervalSince1970
            value.retry.nextRetryAt = attemptDate.addingTimeInterval(
                DeferredSessionRetryPolicy.standard.delay(
                    forRetryCount: retryCount,
                    jitterUnit: Double.random(in: 0...1)
                )
            ).timeIntervalSince1970
            value.retry.lastError = failure.message
        }
    }

    private func classifySpeechError(_ error: Error) -> DurableProcessingErrorCategory {
        if let durable = error as? DurableProcessingError {
            switch durable {
            case .speechPermission: return .speechPermission
            case .speechUnavailable: return .speechUnavailable
            case .onDeviceSpeechUnavailable: return .onDeviceSpeechUnavailable
            case .emptyTranscript: return .speechRecognition
            default: return .speechRecognition
            }
        }
        if (error as? URLError)?.code == .timedOut { return .timeout }
        return .speechRecognition
    }

    private func classifyLLMError(_ error: Error) -> DurableProcessingErrorCategory {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timeout : .llmUnavailable
        }
        let nsError = error as NSError
        if nsError.domain == "LLMService", nsError.code == -1 { return .llmConfiguration }
        let message = error.localizedDescription.lowercased()
        if message.contains("json") || message.contains("decode") || message.contains("response format") {
            return .invalidResponse
        }
        return .llmUnavailable
    }
}

private struct StageFailure: Error {
    let stage: DurableProcessingStage
    let category: DurableProcessingErrorCategory
    let message: String
}
