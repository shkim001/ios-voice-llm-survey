import Foundation
import Network
import UIKit

extension Notification.Name {
    static let deferredSessionWorkDiscovered = Notification.Name("VoiceSurvey.DeferredSessionWorkDiscovered")
}

private func defaultDeferredSessionsRoot() throws -> URL {
    let documents = try FileManager.default.url(
        for: .documentDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    return documents.appendingPathComponent("SurveySessions", isDirectory: true)
}

enum DeferredSessionOutboxTrigger: Equatable {
    case launch
    case foreground
    case pathSatisfied
    case sessionReady
    case manual

    var bypassesBackoff: Bool {
        self == .manual
    }

    var allowsInterviewProcessing: Bool {
        self == .manual
    }
}

struct DeferredSessionRetryPolicy {
    let baseDelay: TimeInterval
    let maximumDelay: TimeInterval
    let jitterFraction: Double

    static let standard = DeferredSessionRetryPolicy(
        baseDelay: 30,
        maximumDelay: 2 * 60 * 60,
        jitterFraction: 0.2
    )

    func delay(forRetryCount retryCount: Int, jitterUnit: Double) -> TimeInterval {
        let exponent = max(0, min(retryCount - 1, 20))
        let unjittered = min(maximumDelay, baseDelay * pow(2, Double(exponent)))
        let normalized = min(1, max(0, jitterUnit))
        let multiplier = 1 + ((normalized * 2) - 1) * jitterFraction
        return min(maximumDelay, max(0, unjittered * multiplier))
    }
}

struct DeferredCloudSessionIdentity: Equatable {
    let respondentId: String
    let sessionId: String
}

struct DeferredPackageUploadReceipt: Equatable {
    let sessionId: String
    let respondentId: String
    let packageDirectory: String
    let jsonPath: String
    let audioPath: String?
    let jsonFileSizeBytes: Int
    let audioFileSizeBytes: Int?
    let jsonSHA256: String
    let audioSHA256: String?
}

struct DeferredProcessingJobReceipt: Equatable {
    let sessionId: String
    let respondentId: String
    let status: String
    let revision: Int
    let resultAvailable: Bool
}

protocol DeferredSessionAPIClient {
    var deferredProcessingIsConfigured: Bool { get }

    func createDeferredCloudSession(
        for manifest: LocalSessionManifest,
        appVersion: String?,
        locale: String?
    ) async throws -> DeferredCloudSessionIdentity

    func uploadDeferredPackage(
        sessionId: String,
        sessionJSONURL: URL,
        audioURL: URL,
        localSessionId: String
    ) async throws -> DeferredPackageUploadReceipt

    func uploadDeferredProcessingInput(
        sessionId: String,
        inputManifestURL: URL,
        audioURL: URL,
        localSessionId: String
    ) async throws -> DeferredProcessingJobReceipt

    func fetchDeferredProcessingJob(sessionId: String) async throws -> DeferredProcessingJobReceipt

    func fetchDeferredProcessingResult(sessionId: String) async throws -> Data

    func retryDeferredProcessingJob(sessionId: String) async throws -> DeferredProcessingJobReceipt
}

extension SurveyAPIClient: DeferredSessionAPIClient {
    var deferredProcessingIsConfigured: Bool { isConfigured() }

    func createDeferredCloudSession(
        for manifest: LocalSessionManifest,
        appVersion: String?,
        locale: String?
    ) async throws -> DeferredCloudSessionIdentity {
        let response = try await createSession(
            questionnaireId: manifest.questionnaireId,
            questionnaireVersion: manifest.questionnaireVersion ?? "1",
            appVersion: appVersion,
            locale: locale,
            localSessionId: manifest.localSessionId
        )
        return DeferredCloudSessionIdentity(
            respondentId: response.respondentId,
            sessionId: response.sessionId
        )
    }

    func uploadDeferredPackage(
        sessionId: String,
        sessionJSONURL: URL,
        audioURL: URL,
        localSessionId: String
    ) async throws -> DeferredPackageUploadReceipt {
        let response = try await uploadSessionPackage(
            sessionId: sessionId,
            sessionJSONURL: sessionJSONURL,
            audioURL: audioURL,
            localSessionId: localSessionId
        )
        return DeferredPackageUploadReceipt(
            sessionId: response.sessionId,
            respondentId: response.respondentId,
            packageDirectory: response.packageDir,
            jsonPath: response.jsonPath,
            audioPath: response.audioPath,
            jsonFileSizeBytes: response.jsonFileSizeBytes,
            audioFileSizeBytes: response.audioFileSizeBytes,
            jsonSHA256: response.jsonSha256,
            audioSHA256: response.audioSha256
        )
    }

    func uploadDeferredProcessingInput(
        sessionId: String,
        inputManifestURL: URL,
        audioURL: URL,
        localSessionId: String
    ) async throws -> DeferredProcessingJobReceipt {
        let response = try await uploadProcessingInput(
            sessionId: sessionId,
            inputManifestURL: inputManifestURL,
            audioURL: audioURL,
            localSessionId: localSessionId
        )
        return DeferredProcessingJobReceipt(
            sessionId: response.sessionId,
            respondentId: response.respondentId,
            status: response.status,
            revision: response.revision,
            resultAvailable: response.resultAvailable
        )
    }

    func fetchDeferredProcessingJob(sessionId: String) async throws -> DeferredProcessingJobReceipt {
        let response = try await fetchProcessingJob(sessionId: sessionId)
        return DeferredProcessingJobReceipt(
            sessionId: response.sessionId,
            respondentId: response.respondentId,
            status: response.status,
            revision: response.revision,
            resultAvailable: response.resultAvailable
        )
    }

    func fetchDeferredProcessingResult(sessionId: String) async throws -> Data {
        try await fetchProcessingResult(sessionId: sessionId)
    }

    func retryDeferredProcessingJob(sessionId: String) async throws -> DeferredProcessingJobReceipt {
        let response = try await retryProcessingJob(sessionId: sessionId)
        return DeferredProcessingJobReceipt(
            sessionId: response.sessionId,
            respondentId: response.respondentId,
            status: response.status,
            revision: response.revision,
            resultAvailable: response.resultAvailable
        )
    }
}

extension DeferredSessionAPIClient {
    func uploadDeferredProcessingInput(
        sessionId: String,
        inputManifestURL: URL,
        audioURL: URL,
        localSessionId: String
    ) async throws -> DeferredProcessingJobReceipt {
        throw DeferredSessionOutboxError.serverProcessingUnavailable
    }

    func fetchDeferredProcessingJob(sessionId: String) async throws -> DeferredProcessingJobReceipt {
        throw DeferredSessionOutboxError.serverProcessingUnavailable
    }

    func fetchDeferredProcessingResult(sessionId: String) async throws -> Data {
        throw DeferredSessionOutboxError.serverProcessingUnavailable
    }

    func retryDeferredProcessingJob(sessionId: String) async throws -> DeferredProcessingJobReceipt {
        throw DeferredSessionOutboxError.serverProcessingUnavailable
    }
}

@MainActor
protocol DeferredSessionStageProcessing {
    func resume(
        sessionDirectoryURL: URL,
        audioURL: URL,
        localeIdentifier: String
    ) async -> DurableProcessingOutcome
}

extension DurableInterviewProcessingCoordinator: DeferredSessionStageProcessing {}

struct DeferredSessionOutboxSummary: Equatable {
    var scannedCount = 0
    var attemptedCount = 0
    var uploadedSessionIds: [String] = []
    var deferredSessionIds: [String] = []
    var failedSessionIds: [String] = []
    var duplicateRunSuppressed = false
}

enum DeferredSessionOutboxError: LocalizedError {
    case invalidCloudIdentity
    case invalidUploadReceipt
    case missingAudio
    case missingPackage
    case serverProcessingUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidCloudIdentity:
            return "The Survey API returned invalid cloud session identifiers."
        case .invalidUploadReceipt:
            return "The Survey API upload response did not verify the JSON and audio package."
        case .missingAudio:
            return "The original audio file is missing, unreadable, or empty."
        case .missingPackage:
            return "The finalized session.json package is missing or empty."
        case .serverProcessingUnavailable:
            return "The Survey API does not support server-side interview processing."
        }
    }
}

@MainActor
final class DeferredSessionOutbox: NSObject {
    static let shared = DeferredSessionOutbox(
        apiClient: SurveyAPIClient.shared,
        stageProcessor: DurableInterviewProcessingCoordinator.shared
    )

    private let apiClient: DeferredSessionAPIClient
    private let stageProcessor: DeferredSessionStageProcessing
    private let sessionsRootProvider: () throws -> URL
    private let now: () -> Date
    private let jitterUnit: () -> Double
    private let retryPolicy: DeferredSessionRetryPolicy
    private let pathMonitor: NWPathMonitor?
    private let applicationIsActive: @MainActor () -> Bool
    private let pathQueue = DispatchQueue(label: "VoiceSurvey.DeferredSessionOutbox.Path")
    private var isStarted = false
    private var isRunning = false
    private var activeSessionIds: Set<String> = []

    init(
        apiClient: DeferredSessionAPIClient,
        stageProcessor: DeferredSessionStageProcessing,
        sessionsRootProvider: @escaping () throws -> URL = defaultDeferredSessionsRoot,
        now: @escaping () -> Date = Date.init,
        jitterUnit: @escaping () -> Double = { Double.random(in: 0...1) },
        retryPolicy: DeferredSessionRetryPolicy = .standard,
        pathMonitor: NWPathMonitor? = NWPathMonitor(),
        applicationIsActive: @escaping @MainActor () -> Bool = {
            UIApplication.shared.applicationState == .active
        }
    ) {
        self.apiClient = apiClient
        self.stageProcessor = stageProcessor
        self.sessionsRootProvider = sessionsRootProvider
        self.now = now
        self.jitterUnit = jitterUnit
        self.retryPolicy = retryPolicy
        self.pathMonitor = pathMonitor
        self.applicationIsActive = applicationIsActive
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard self?.applicationIsActive() == true else { return }
                self?.announcePendingWorkIfNeeded()
            }
        }
        pathMonitor?.start(queue: pathQueue)
        announcePendingWorkIfNeeded()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        announcePendingWorkIfNeeded()
    }

    @discardableResult
    func retryNow() async -> DeferredSessionOutboxSummary {
        await run(trigger: .manual)
    }

    @discardableResult
    func retryNow(localSessionId: String) async -> DeferredSessionOutboxSummary {
        await run(trigger: .manual, localSessionId: localSessionId)
    }

    @discardableResult
    func retryNow(localSessionIds: Set<String>) async -> DeferredSessionOutboxSummary {
        guard !localSessionIds.isEmpty else { return DeferredSessionOutboxSummary() }
        return await run(trigger: .manual, requestedLocalSessionIds: localSessionIds)
    }

    @discardableResult
    func run(
        trigger: DeferredSessionOutboxTrigger,
        localSessionId requestedLocalSessionId: String? = nil
    ) async -> DeferredSessionOutboxSummary {
        await run(
            trigger: trigger,
            requestedLocalSessionIds: requestedLocalSessionId.map { Set([$0]) }
        )
    }

    private func run(
        trigger: DeferredSessionOutboxTrigger,
        requestedLocalSessionIds: Set<String>?
    ) async -> DeferredSessionOutboxSummary {
        guard trigger == .manual || applicationIsActive() else {
            return DeferredSessionOutboxSummary()
        }
        guard !isRunning else {
            return DeferredSessionOutboxSummary(duplicateRunSuppressed: true)
        }
        isRunning = true
        defer { isRunning = false }

        var summary = DeferredSessionOutboxSummary()
        let directories: [URL]
        do {
            directories = try sessionDirectories()
        } catch {
            return summary
        }
        summary.scannedCount = directories.count

        for directoryURL in directories {
            guard let manifest = try? LocalSessionManifestStore.loadOrSynthesize(from: directoryURL) else {
                continue
            }
            if let requestedLocalSessionIds,
               !requestedLocalSessionIds.contains(manifest.localSessionId) {
                continue
            }
            if !FileManager.default.fileExists(atPath: LocalSessionManifestStore.url(in: directoryURL).path) {
                try? LocalSessionManifestStore.save(manifest, to: directoryURL)
            }
            guard manifest.audioStatus == .recordedLocally,
                  let audioFileName = manifest.audioFileName else { continue }
            let localResultExists = FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent("session.json").path
            )
            if manifest.serverProcessingStatus == .completed && localResultExists {
                continue
            }
            if manifest.serverProcessingStatus == .notSubmitted,
               manifest.uploadStatus == .uploaded,
               localResultExists {
                continue
            }
            guard trigger.bypassesBackoff || isDue(manifest) else {
                summary.deferredSessionIds.append(manifest.localSessionId)
                continue
            }
            guard !activeSessionIds.contains(manifest.localSessionId) else {
                summary.deferredSessionIds.append(manifest.localSessionId)
                continue
            }

            activeSessionIds.insert(manifest.localSessionId)
            defer { activeSessionIds.remove(manifest.localSessionId) }
            summary.attemptedCount += 1
            let audioURL = directoryURL.appendingPathComponent(audioFileName)

            guard apiClient.deferredProcessingIsConfigured else {
                summary.deferredSessionIds.append(manifest.localSessionId)
                continue
            }
            do {
                if manifest.serverProcessingStatus != .notSubmitted {
                    if trigger == .manual,
                       manifest.serverProcessingStatus == .failedRetryable
                        || manifest.serverProcessingStatus == .failedTerminal,
                       let cloudSessionId = manifest.cloudSessionId {
                        let retried = try await apiClient.retryDeferredProcessingJob(
                            sessionId: cloudSessionId
                        )
                        guard let retriedStatus = LocalSessionServerProcessingStatus(rawValue: retried.status) else {
                            throw DeferredSessionOutboxError.invalidUploadReceipt
                        }
                        try LocalSessionManifestStore.update(in: directoryURL, now: now()) { value in
                            value.serverProcessingStatus = retriedStatus
                            value.serverProcessingRevision = retried.revision
                            value.retry = LocalSessionRetryMetadata()
                        }
                        summary.deferredSessionIds.append(manifest.localSessionId)
                        continue
                    }
                    let completed = try await synchronizeServerProcessing(
                        manifest: manifest,
                        in: directoryURL
                    )
                    if completed {
                        summary.uploadedSessionIds.append(manifest.localSessionId)
                    } else {
                        summary.deferredSessionIds.append(manifest.localSessionId)
                    }
                } else if isFinalPackageReady(manifest, in: directoryURL) {
                    try await uploadLegacyFinalPackage(in: directoryURL, audioURL: audioURL)
                    summary.uploadedSessionIds.append(manifest.localSessionId)
                } else {
                    try await submitServerProcessing(in: directoryURL, audioURL: audioURL)
                    summary.uploadedSessionIds.append(manifest.localSessionId)
                }
            } catch {
                persistUploadFailure(error, in: directoryURL)
                summary.failedSessionIds.append(manifest.localSessionId)
            }
        }
        return summary
    }

    private func announcePendingWorkIfNeeded() {
        guard pendingSessionCount() > 0 else { return }
        NotificationCenter.default.post(name: .deferredSessionWorkDiscovered, object: self)
    }

    private func pendingSessionCount() -> Int {
        guard let directories = try? sessionDirectories() else { return 0 }
        return directories.reduce(into: 0) { count, directoryURL in
            guard let manifest = try? LocalSessionManifestStore.loadOrSynthesize(from: directoryURL),
                  manifest.audioStatus == .recordedLocally,
                  (manifest.serverProcessingStatus != .completed || manifest.uploadStatus != .uploaded),
                  manifest.audioFileName != nil else { return }
            count += 1
        }
    }

    private func ensureCloudIdentity(
        for manifest: LocalSessionManifest,
        in directoryURL: URL
    ) async throws -> LocalSessionManifest {
        var current = manifest
        if current.cloudSessionId == nil || current.cloudRespondentId == nil {
            let identity = try await apiClient.createDeferredCloudSession(
                for: current,
                appVersion: appVersionString(),
                locale: Locale.current.identifier
            )
            guard !identity.sessionId.isEmpty, !identity.respondentId.isEmpty else {
                throw DeferredSessionOutboxError.invalidCloudIdentity
            }
            try LocalSessionManifestStore.update(in: directoryURL, now: now()) { value in
                value.cloudRespondentId = identity.respondentId
                value.cloudSessionId = identity.sessionId
            }
            current = try LocalSessionManifestStore.load(from: directoryURL)
        }
        return current
    }

    private func uploadLegacyFinalPackage(in directoryURL: URL, audioURL: URL) async throws {
        try verifyNonemptyReadableFile(audioURL, missingError: .missingAudio)
        let packageURL = directoryURL.appendingPathComponent("session.json")
        try verifyNonemptyReadableFile(packageURL, missingError: .missingPackage)

        var manifest = try LocalSessionManifestStore.load(from: directoryURL)
        try LocalSessionManifestStore.update(in: directoryURL, now: now()) { value in
            value.uploadStatus = .inProgress
            value.retry.lastAttemptAt = now().timeIntervalSince1970
            value.retry.lastError = nil
        }

        manifest = try await ensureCloudIdentity(for: manifest, in: directoryURL)

        guard let cloudSessionId = manifest.cloudSessionId,
              let cloudRespondentId = manifest.cloudRespondentId else {
            throw DeferredSessionOutboxError.invalidCloudIdentity
        }
        let receipt = try await apiClient.uploadDeferredPackage(
            sessionId: cloudSessionId,
            sessionJSONURL: packageURL,
            audioURL: audioURL,
            localSessionId: manifest.localSessionId
        )
        guard receipt.sessionId == cloudSessionId,
              receipt.respondentId == cloudRespondentId,
              !receipt.packageDirectory.isEmpty,
              !receipt.jsonPath.isEmpty,
              receipt.jsonFileSizeBytes > 0,
              !receipt.jsonSHA256.isEmpty,
              receipt.audioPath?.isEmpty == false,
              (receipt.audioFileSizeBytes ?? 0) > 0,
              receipt.audioSHA256?.isEmpty == false else {
            throw DeferredSessionOutboxError.invalidUploadReceipt
        }

        try markCompatibilitySidecarUploaded(audioURL: audioURL, receipt: receipt)
        try LocalSessionManifestStore.update(in: directoryURL, now: now()) { value in
            value.uploadStatus = .uploaded
            value.retry = LocalSessionRetryMetadata()
        }
    }

    private func submitServerProcessing(in directoryURL: URL, audioURL: URL) async throws {
        try verifyNonemptyReadableFile(audioURL, missingError: .missingAudio)
        var manifest = try LocalSessionManifestStore.load(from: directoryURL)
        try LocalSessionManifestStore.update(in: directoryURL, now: now()) { value in
            value.uploadStatus = .inProgress
            value.retry.lastAttemptAt = now().timeIntervalSince1970
            value.retry.lastError = nil
        }
        manifest = try await ensureCloudIdentity(for: manifest, in: directoryURL)
        guard let cloudSessionId = manifest.cloudSessionId,
              let cloudRespondentId = manifest.cloudRespondentId else {
            throw DeferredSessionOutboxError.invalidCloudIdentity
        }
        let inputURL = try processingInputURL(for: manifest, in: directoryURL)
        let receipt = try await apiClient.uploadDeferredProcessingInput(
            sessionId: cloudSessionId,
            inputManifestURL: inputURL,
            audioURL: audioURL,
            localSessionId: manifest.localSessionId
        )
        guard receipt.sessionId == cloudSessionId,
              receipt.respondentId == cloudRespondentId,
              let status = LocalSessionServerProcessingStatus(rawValue: receipt.status) else {
            throw DeferredSessionOutboxError.invalidUploadReceipt
        }
        try LocalSessionManifestStore.update(in: directoryURL, now: now()) { value in
            value.uploadStatus = .uploaded
            value.serverProcessingStatus = status
            value.serverProcessingRevision = receipt.revision
            value.transcriptionStatus = status == .transcribing ? .inProgress : .pending
            value.analysisStatus = status == .analyzing ? .inProgress : .pending
            value.clarificationStatus = status == .completed ? .notRequired : .pending
            value.retry = LocalSessionRetryMetadata()
        }
        if receipt.resultAvailable || status == .completed {
            _ = try await synchronizeServerProcessing(
                manifest: try LocalSessionManifestStore.load(from: directoryURL),
                in: directoryURL
            )
        }
    }

    private func processingInputURL(
        for manifest: LocalSessionManifest,
        in directoryURL: URL
    ) throws -> URL {
        let fileName = manifest.processingInputFileName ?? "processing_input.json"
        let url = directoryURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try verifyNonemptyReadableFile(url, missingError: .missingPackage)
            return url
        }
        var input = manifest
        input.schemaVersion = LocalSessionManifest.currentSchemaVersion
        input.transcriptionStatus = .pending
        input.transcriptionPipelineVersion = 0
        input.transcriptFileName = nil
        input.transcription = nil
        input.transcriptionErrorCategory = nil
        input.analysisStatus = .pending
        input.matchedQuestions = []
        input.analysisErrorCategory = nil
        input.clarificationStatus = .pending
        input.uploadStatus = .notReady
        input.serverProcessingStatus = .notSubmitted
        input.serverProcessingRevision = nil
        input.processingInputFileName = nil
        input.retry = LocalSessionRetryMetadata()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(input).write(to: url, options: [.atomic])
        try LocalSessionManifestStore.update(in: directoryURL, now: now()) { value in
            value.processingInputFileName = fileName
        }
        return url
    }

    private struct ServerProcessingResult: Decodable {
        let transcription: String
        let matchedQuestions: [MatchedQuestion]

        enum CodingKeys: String, CodingKey {
            case transcription
            case matchedQuestions = "matched_questions"
        }
    }

    private func synchronizeServerProcessing(
        manifest: LocalSessionManifest,
        in directoryURL: URL
    ) async throws -> Bool {
        guard let cloudSessionId = manifest.cloudSessionId else {
            throw DeferredSessionOutboxError.invalidCloudIdentity
        }
        let receipt = try await apiClient.fetchDeferredProcessingJob(sessionId: cloudSessionId)
        guard receipt.sessionId == cloudSessionId,
              let status = LocalSessionServerProcessingStatus(rawValue: receipt.status) else {
            throw DeferredSessionOutboxError.invalidUploadReceipt
        }
        if status == .completed || receipt.resultAvailable {
            let resultData = try await apiClient.fetchDeferredProcessingResult(sessionId: cloudSessionId)
            let result = try JSONDecoder().decode(ServerProcessingResult.self, from: resultData)
            try resultData.write(
                to: directoryURL.appendingPathComponent("session.json"),
                options: [.atomic]
            )
            try Data(result.transcription.utf8).write(
                to: directoryURL.appendingPathComponent(FileTranscriptStore.fileName),
                options: [.atomic]
            )
            try LocalSessionManifestStore.update(in: directoryURL, now: now()) { value in
                value.serverProcessingStatus = .completed
                value.serverProcessingRevision = receipt.revision
                value.transcriptionStatus = .completed
                value.transcriptionPipelineVersion = LocalSessionManifest.currentTranscriptionPipelineVersion
                value.transcriptFileName = FileTranscriptStore.fileName
                value.transcription = result.transcription
                value.analysisStatus = .completed
                value.matchedQuestions = result.matchedQuestions
                value.clarificationStatus = .completed
                value.uploadStatus = .uploaded
                value.retry = LocalSessionRetryMetadata()
            }
            return true
        }
        try LocalSessionManifestStore.update(in: directoryURL, now: now()) { value in
            value.serverProcessingStatus = status
            value.serverProcessingRevision = receipt.revision
            value.uploadStatus = .uploaded
            value.transcriptionStatus = status == .transcribing ? .inProgress : value.transcriptionStatus
            value.analysisStatus = status == .analyzing ? .inProgress : value.analysisStatus
            value.clarificationStatus = status == .needsReview ? .pending : value.clarificationStatus
            value.retry.lastError = status == .failedTerminal ? "Server processing failed; review and retry." : nil
        }
        return false
    }

    private func persistUploadFailure(_ error: Error, in directoryURL: URL) {
        let attemptDate = now()
        try? LocalSessionManifestStore.update(in: directoryURL, now: attemptDate) { value in
            let retryCount = value.retry.retryCount + 1
            value.uploadStatus = .failed
            value.retry.retryCount = retryCount
            value.retry.lastAttemptAt = attemptDate.timeIntervalSince1970
            value.retry.nextRetryAt = attemptDate.addingTimeInterval(
                retryPolicy.delay(forRetryCount: retryCount, jitterUnit: jitterUnit())
            ).timeIntervalSince1970
            value.retry.lastError = error.localizedDescription
        }
    }

    private func scheduleExistingProcessingFailure(in directoryURL: URL) {
        let attemptDate = now()
        try? LocalSessionManifestStore.update(in: directoryURL, now: attemptDate) { value in
            let retryCount = max(1, value.retry.retryCount)
            value.retry.lastAttemptAt = value.retry.lastAttemptAt ?? attemptDate.timeIntervalSince1970
            value.retry.nextRetryAt = attemptDate.addingTimeInterval(
                retryPolicy.delay(forRetryCount: retryCount, jitterUnit: jitterUnit())
            ).timeIntervalSince1970
        }
    }

    private func isDue(_ manifest: LocalSessionManifest) -> Bool {
        guard let nextRetryAt = manifest.retry.nextRetryAt else { return true }
        return nextRetryAt <= now().timeIntervalSince1970
    }

    private func isFinalPackageReady(_ manifest: LocalSessionManifest, in directoryURL: URL) -> Bool {
        let processingComplete = manifest.transcriptionStatus == .completed
            && manifest.analysisStatus == .completed
            && (manifest.clarificationStatus == .completed || manifest.clarificationStatus == .notRequired)
        return processingComplete
            && FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("session.json").path)
    }

    private func sessionDirectories() throws -> [URL] {
        let root = try sessionsRootProvider()
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func verifyNonemptyReadableFile(
        _ url: URL,
        missingError: DeferredSessionOutboxError
    ) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isReadable != false,
              (values.fileSize ?? 0) > 0 else { throw missingError }
        let handle = try FileHandle(forReadingFrom: url)
        try handle.close()
    }

    private func markCompatibilitySidecarUploaded(
        audioURL: URL,
        receipt: DeferredPackageUploadReceipt
    ) throws {
        let sidecarURL = audioURL.deletingPathExtension().appendingPathExtension("json")
        var metadata: [String: Any] = [:]
        if let data = try? Data(contentsOf: sidecarURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            metadata = existing
        }
        metadata["session_package_uploaded_at_epoch"] = now().timeIntervalSince1970
        metadata["server_package_dir"] = receipt.packageDirectory
        metadata["server_session_json_path"] = receipt.jsonPath
        metadata["server_session_json_sha256"] = receipt.jsonSHA256
        metadata["server_audio_path"] = receipt.audioPath
        metadata["server_audio_sha256"] = receipt.audioSHA256
        metadata["server_audio_file_size_bytes"] = receipt.audioFileSizeBytes
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: sidecarURL, options: [.atomic])
    }

    private func appVersionString() -> String? {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let short, let build { return "\(short) (\(build))" }
        return short ?? build
    }

}
