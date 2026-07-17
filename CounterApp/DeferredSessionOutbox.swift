import Foundation
import Network
import UIKit

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
    private let applicationIsActive: () -> Bool
    private let pathQueue = DispatchQueue(label: "VoiceSurvey.DeferredSessionOutbox.Path")
    private var isStarted = false
    private var isRunning = false
    private var pendingRunRequested = false
    private var activeSessionIds: Set<String> = []

    init(
        apiClient: DeferredSessionAPIClient,
        stageProcessor: DeferredSessionStageProcessing,
        sessionsRootProvider: @escaping () throws -> URL = defaultDeferredSessionsRoot,
        now: @escaping () -> Date = Date.init,
        jitterUnit: @escaping () -> Double = { Double.random(in: 0...1) },
        retryPolicy: DeferredSessionRetryPolicy = .standard,
        pathMonitor: NWPathMonitor? = NWPathMonitor(),
        applicationIsActive: @escaping () -> Bool = {
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
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard self?.applicationIsActive() == true else { return }
                _ = await self?.run(trigger: .pathSatisfied)
            }
        }
        pathMonitor?.start(queue: pathQueue)
        Task { [weak self] in
            _ = await self?.run(trigger: .launch)
        }
    }

    @objc private func applicationDidBecomeActive() {
        Task { [weak self] in
            _ = await self?.run(trigger: .foreground)
        }
    }

    @discardableResult
    func retryNow() async -> DeferredSessionOutboxSummary {
        await run(trigger: .manual)
    }

    @discardableResult
    func run(trigger: DeferredSessionOutboxTrigger) async -> DeferredSessionOutboxSummary {
        guard trigger == .manual || applicationIsActive() else {
            return DeferredSessionOutboxSummary()
        }
        guard !isRunning else {
            pendingRunRequested = true
            return DeferredSessionOutboxSummary(duplicateRunSuppressed: true)
        }
        isRunning = true
        defer {
            isRunning = false
            if pendingRunRequested {
                pendingRunRequested = false
                Task { [weak self] in
                    _ = await self?.run(trigger: .foreground)
                }
            }
        }

        var summary = DeferredSessionOutboxSummary()
        let directories: [URL]
        do {
            directories = try sessionDirectories()
        } catch {
            return summary
        }
        summary.scannedCount = directories.count

        for directoryURL in directories {
            guard var manifest = try? LocalSessionManifestStore.loadOrSynthesize(from: directoryURL) else {
                continue
            }
            if !FileManager.default.fileExists(atPath: LocalSessionManifestStore.url(in: directoryURL).path) {
                try? LocalSessionManifestStore.save(manifest, to: directoryURL)
            }
            guard manifest.audioStatus == .recordedLocally,
                  manifest.uploadStatus != .uploaded,
                  let audioFileName = manifest.audioFileName else { continue }
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

            if !isFinalPackageReady(manifest, in: directoryURL) {
                guard trigger.allowsInterviewProcessing else {
                    summary.deferredSessionIds.append(manifest.localSessionId)
                    continue
                }
                let outcome = await stageProcessor.resume(
                    sessionDirectoryURL: directoryURL,
                    audioURL: audioURL,
                    localeIdentifier: Locale.current.identifier
                )
                switch outcome {
                case .readyToUpload:
                    manifest = (try? LocalSessionManifestStore.load(from: directoryURL)) ?? manifest
                case .failed(_, let category, _):
                    if category != .audioUnavailable {
                        scheduleExistingProcessingFailure(in: directoryURL)
                    }
                    summary.failedSessionIds.append(manifest.localSessionId)
                    continue
                case .deferred, .needsClarification, .analysisCompleted, .alreadyRunning:
                    summary.deferredSessionIds.append(manifest.localSessionId)
                    continue
                }
            }

            guard apiClient.deferredProcessingIsConfigured else {
                summary.deferredSessionIds.append(manifest.localSessionId)
                continue
            }
            do {
                try await uploadSession(in: directoryURL, audioURL: audioURL)
                summary.uploadedSessionIds.append(manifest.localSessionId)
            } catch {
                persistUploadFailure(error, in: directoryURL)
                summary.failedSessionIds.append(manifest.localSessionId)
            }
        }
        return summary
    }

    private func uploadSession(in directoryURL: URL, audioURL: URL) async throws {
        try verifyNonemptyReadableFile(audioURL, missingError: .missingAudio)
        let packageURL = directoryURL.appendingPathComponent("session.json")
        try verifyNonemptyReadableFile(packageURL, missingError: .missingPackage)

        var manifest = try LocalSessionManifestStore.load(from: directoryURL)
        try LocalSessionManifestStore.update(in: directoryURL, now: now()) { value in
            value.uploadStatus = .inProgress
            value.retry.lastAttemptAt = now().timeIntervalSince1970
            value.retry.lastError = nil
        }

        if manifest.cloudSessionId == nil || manifest.cloudRespondentId == nil {
            let identity = try await apiClient.createDeferredCloudSession(
                for: manifest,
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
            manifest = try LocalSessionManifestStore.load(from: directoryURL)
        }

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
