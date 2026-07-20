import Foundation

protocol LocalSessionDefaultingStatus: Codable, RawRepresentable where RawValue == String {
    static var decodingFallback: Self { get }
}

extension LocalSessionDefaultingStatus {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? ""
        self = Self(rawValue: rawValue) ?? Self.decodingFallback
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum LocalSessionAudioStatus: String, LocalSessionDefaultingStatus {
    case preparing
    case recording
    case recordedLocally = "recorded_locally"
    case failed

    static let decodingFallback: Self = .preparing
}

enum LocalSessionLocationStatus: String, LocalSessionDefaultingStatus {
    case pending
    case acquiring
    case available
    case permissionDenied = "permission_denied"
    case timedOut = "timed_out"
    case lowAccuracy = "low_accuracy"
    case unavailable

    static let decodingFallback: Self = .pending
}

enum LocalSessionLocationSource: String, LocalSessionDefaultingStatus {
    case deviceGPS = "device_gps"
    case placeSearch = "place_search"
    case savedSurveyLocation = "saved_survey_location"
    case none

    static let decodingFallback: Self = .none
}

enum LocalSessionLocationQuality: String, LocalSessionDefaultingStatus {
    case high
    case acceptable
    case low
    case unknown

    static let decodingFallback: Self = .unknown
}

struct LocalSessionPlaceSnapshot: Codable, Equatable {
    var displayLabel: String
    var formattedAddress: String?
    var latitude: Double?
    var longitude: Double?

    enum CodingKeys: String, CodingKey {
        case displayLabel = "display_label"
        case formattedAddress = "formatted_address"
        case latitude
        case longitude
    }
}

struct LocalSessionCoordinateSnapshot: Codable, Equatable {
    var latitude: Double?
    var longitude: Double?

    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
    }

    init(latitude: Double? = nil, longitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
    }
}

enum LocalSessionTranscriptionStatus: String, LocalSessionDefaultingStatus {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    case pendingRetry = "pending_retry"

    static let decodingFallback: Self = .pending
}

enum LocalSessionAnalysisStatus: String, LocalSessionDefaultingStatus {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    case pendingRetry = "pending_retry"

    static let decodingFallback: Self = .pending
}

enum LocalSessionClarificationStatus: String, LocalSessionDefaultingStatus {
    case notRequired = "not_required"
    case pending
    case completed

    static let decodingFallback: Self = .pending
}

enum LocalSessionUploadStatus: String, LocalSessionDefaultingStatus {
    case notReady = "not_ready"
    case pending
    case inProgress = "in_progress"
    case uploaded
    case failed

    static let decodingFallback: Self = .notReady
}

enum LocalSessionServerProcessingStatus: String, LocalSessionDefaultingStatus {
    case notSubmitted = "not_submitted"
    case queued
    case transcribing
    case analyzing
    case needsReview = "needs_review"
    case completed
    case failedRetryable = "failed_retryable"
    case failedTerminal = "failed_terminal"

    static let decodingFallback: Self = .notSubmitted
}

struct LocalSessionRetryMetadata: Codable {
    var retryCount: Int
    var lastError: String?
    var lastAttemptAt: TimeInterval?
    var nextRetryAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case retryCount = "retry_count"
        case lastError = "last_error"
        case lastAttemptAt = "last_attempt_at"
        case nextRetryAt = "next_retry_at"
    }

    init(
        retryCount: Int = 0,
        lastError: String? = nil,
        lastAttemptAt: TimeInterval? = nil,
        nextRetryAt: TimeInterval? = nil
    ) {
        self.retryCount = retryCount
        self.lastError = lastError
        self.lastAttemptAt = lastAttemptAt
        self.nextRetryAt = nextRetryAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastAttemptAt = try container.decodeIfPresent(TimeInterval.self, forKey: .lastAttemptAt)
        nextRetryAt = try container.decodeIfPresent(TimeInterval.self, forKey: .nextRetryAt)
    }
}

struct LocalSessionManifest: Codable {
    static let currentSchemaVersion = 7
    static let currentTranscriptionPipelineVersion = 2

    var schemaVersion: Int
    var localSessionId: String
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var recordingStartedAt: TimeInterval?
    var recordingStoppedAt: TimeInterval?
    var audioFileName: String?
    var audioStatus: LocalSessionAudioStatus
    var interviewerSnapshot: InterviewerProfile?
    var respondentSnapshot: RespondentInfo?
    var questionnaireId: String?
    var questionnaireVersion: String?
    var questionnaireHash: String?
    var questionnaireSnapshot: Questionnaire?
    var locationInfo: SessionLocationInfo?
    var locationStatus: LocalSessionLocationStatus
    var locationSource: LocalSessionLocationSource
    var locationQuality: LocalSessionLocationQuality
    var locationHorizontalAccuracyM: Double?
    var locationCoordinates: LocalSessionCoordinateSnapshot
    var locationLabel: String?
    var locationPoint: TrajectoryPoint?
    var placeSnapshot: LocalSessionPlaceSnapshot?
    var trajectoryPoints: [TrajectoryPoint]
    var interviewerCheckedOptionCodesByQuestionId: [String: [String]]
    var transcriptionStatus: LocalSessionTranscriptionStatus
    var transcriptionPipelineVersion: Int
    var transcriptFileName: String?
    var transcription: String?
    var transcriptionErrorCategory: String?
    var analysisStatus: LocalSessionAnalysisStatus
    var matchedQuestions: [MatchedQuestion]
    var analysisErrorCategory: String?
    var clarificationStatus: LocalSessionClarificationStatus
    var uploadStatus: LocalSessionUploadStatus
    var serverProcessingStatus: LocalSessionServerProcessingStatus
    var serverProcessingRevision: Int?
    var processingInputFileName: String?
    var cloudRespondentId: String?
    var cloudSessionId: String?
    var retry: LocalSessionRetryMetadata

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case localSessionId = "local_session_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case recordingStartedAt = "recording_started_at"
        case recordingStoppedAt = "recording_stopped_at"
        case audioFileName = "audio_file_name"
        case audioStatus = "audio_status"
        case interviewerSnapshot = "interviewer_snapshot"
        case respondentSnapshot = "respondent_snapshot"
        case questionnaireId = "questionnaire_id"
        case questionnaireVersion = "questionnaire_version"
        case questionnaireHash = "questionnaire_hash"
        case questionnaireSnapshot = "questionnaire_snapshot"
        case locationInfo = "location_info"
        case locationStatus = "location_status"
        case locationSource = "location_source"
        case locationQuality = "location_quality"
        case locationHorizontalAccuracyM = "location_horizontal_accuracy_m"
        case locationCoordinates = "location_coordinates"
        case locationLabel = "location_label"
        case locationPoint = "location_point"
        case placeSnapshot = "place_snapshot"
        case trajectoryPoints = "trajectory_points"
        case interviewerCheckedOptionCodesByQuestionId = "interviewer_checked_option_codes_by_question_id"
        case transcriptionStatus = "transcription_status"
        case transcriptionPipelineVersion = "transcription_pipeline_version"
        case transcriptFileName = "transcript_file_name"
        case transcription
        case transcriptionErrorCategory = "transcription_error_category"
        case analysisStatus = "analysis_status"
        case matchedQuestions = "matched_questions"
        case analysisErrorCategory = "analysis_error_category"
        case clarificationStatus = "clarification_status"
        case uploadStatus = "upload_status"
        case serverProcessingStatus = "server_processing_status"
        case serverProcessingRevision = "server_processing_revision"
        case processingInputFileName = "processing_input_file_name"
        case cloudRespondentId = "cloud_respondent_id"
        case cloudSessionId = "cloud_session_id"
        case retry
    }

    init(
        localSessionId: String,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        audioFileName: String? = nil,
        interviewerSnapshot: InterviewerProfile? = nil,
        respondentSnapshot: RespondentInfo? = nil,
        questionnaireSnapshot: Questionnaire? = nil,
        locationInfo: SessionLocationInfo? = nil,
        locationStatus: LocalSessionLocationStatus = .pending,
        locationSource: LocalSessionLocationSource = .none,
        locationQuality: LocalSessionLocationQuality = .unknown,
        locationHorizontalAccuracyM: Double? = nil,
        locationCoordinates: LocalSessionCoordinateSnapshot = LocalSessionCoordinateSnapshot(),
        locationLabel: String? = nil,
        locationPoint: TrajectoryPoint? = nil,
        placeSnapshot: LocalSessionPlaceSnapshot? = nil,
        trajectoryPoints: [TrajectoryPoint] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.localSessionId = localSessionId
        self.createdAt = createdAt
        updatedAt = createdAt
        recordingStartedAt = nil
        recordingStoppedAt = nil
        self.audioFileName = audioFileName
        audioStatus = .preparing
        self.interviewerSnapshot = interviewerSnapshot
        self.respondentSnapshot = respondentSnapshot
        questionnaireId = questionnaireSnapshot?.id
        questionnaireVersion = questionnaireSnapshot?.version
        questionnaireHash = questionnaireSnapshot?.hash
        self.questionnaireSnapshot = questionnaireSnapshot
        self.locationInfo = locationInfo
        self.locationStatus = locationStatus
        self.locationSource = locationSource
        self.locationQuality = locationQuality
        self.locationHorizontalAccuracyM = locationHorizontalAccuracyM
        self.locationCoordinates = locationCoordinates
        self.locationLabel = locationLabel
        self.locationPoint = locationPoint
        self.placeSnapshot = placeSnapshot
        self.trajectoryPoints = trajectoryPoints
        interviewerCheckedOptionCodesByQuestionId = [:]
        transcriptionStatus = .pending
        transcriptionPipelineVersion = 0
        transcriptFileName = nil
        transcription = nil
        transcriptionErrorCategory = nil
        analysisStatus = .pending
        matchedQuestions = []
        analysisErrorCategory = nil
        clarificationStatus = .pending
        uploadStatus = .notReady
        serverProcessingStatus = .notSubmitted
        serverProcessingRevision = nil
        processingInputFileName = nil
        cloudRespondentId = nil
        cloudSessionId = nil
        retry = LocalSessionRetryMetadata()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        localSessionId = try container.decodeIfPresent(String.self, forKey: .localSessionId) ?? ""
        createdAt = try container.decodeIfPresent(TimeInterval.self, forKey: .createdAt) ?? 0
        updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? createdAt
        recordingStartedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .recordingStartedAt)
        recordingStoppedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .recordingStoppedAt)
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        audioStatus = try container.decodeIfPresent(LocalSessionAudioStatus.self, forKey: .audioStatus)
            ?? (audioFileName == nil ? .preparing : .recordedLocally)
        interviewerSnapshot = try container.decodeIfPresent(InterviewerProfile.self, forKey: .interviewerSnapshot)
        respondentSnapshot = try container.decodeIfPresent(RespondentInfo.self, forKey: .respondentSnapshot)
        questionnaireId = try container.decodeIfPresent(String.self, forKey: .questionnaireId)
        questionnaireVersion = try container.decodeIfPresent(String.self, forKey: .questionnaireVersion)
        questionnaireHash = try container.decodeIfPresent(String.self, forKey: .questionnaireHash)
        questionnaireSnapshot = try container.decodeIfPresent(Questionnaire.self, forKey: .questionnaireSnapshot)
        questionnaireId = questionnaireId ?? questionnaireSnapshot?.id
        questionnaireVersion = questionnaireVersion ?? questionnaireSnapshot?.version
        questionnaireHash = questionnaireHash ?? questionnaireSnapshot?.hash
        locationInfo = try container.decodeIfPresent(SessionLocationInfo.self, forKey: .locationInfo)
        locationStatus = try container.decodeIfPresent(LocalSessionLocationStatus.self, forKey: .locationStatus) ?? .pending
        locationSource = try container.decodeIfPresent(LocalSessionLocationSource.self, forKey: .locationSource) ?? .none
        locationQuality = try container.decodeIfPresent(LocalSessionLocationQuality.self, forKey: .locationQuality) ?? .unknown
        locationHorizontalAccuracyM = try container.decodeIfPresent(Double.self, forKey: .locationHorizontalAccuracyM)
        locationCoordinates = try container.decodeIfPresent(
            LocalSessionCoordinateSnapshot.self,
            forKey: .locationCoordinates
        ) ?? LocalSessionCoordinateSnapshot()
        locationLabel = try container.decodeIfPresent(String.self, forKey: .locationLabel)
        locationPoint = try container.decodeIfPresent(TrajectoryPoint.self, forKey: .locationPoint)
        placeSnapshot = try container.decodeIfPresent(LocalSessionPlaceSnapshot.self, forKey: .placeSnapshot)
        if locationHorizontalAccuracyM == nil {
            locationHorizontalAccuracyM = locationPoint?.accuracyM
        }
        if locationCoordinates.latitude == nil, locationCoordinates.longitude == nil {
            locationCoordinates = LocalSessionCoordinateSnapshot(
                latitude: placeSnapshot?.latitude ?? locationPoint?.lat,
                longitude: placeSnapshot?.longitude ?? locationPoint?.lon
            )
        }
        trajectoryPoints = try container.decodeIfPresent([TrajectoryPoint].self, forKey: .trajectoryPoints) ?? []
        interviewerCheckedOptionCodesByQuestionId = try container.decodeIfPresent(
            [String: [String]].self,
            forKey: .interviewerCheckedOptionCodesByQuestionId
        ) ?? [:]
        transcriptionStatus = try container.decodeIfPresent(
            LocalSessionTranscriptionStatus.self,
            forKey: .transcriptionStatus
        ) ?? .pending
        transcriptionPipelineVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .transcriptionPipelineVersion
        ) ?? 0
        transcriptFileName = try container.decodeIfPresent(String.self, forKey: .transcriptFileName)
        transcription = try container.decodeIfPresent(String.self, forKey: .transcription)
        transcriptionErrorCategory = try container.decodeIfPresent(String.self, forKey: .transcriptionErrorCategory)
        analysisStatus = try container.decodeIfPresent(LocalSessionAnalysisStatus.self, forKey: .analysisStatus) ?? .pending
        matchedQuestions = try container.decodeIfPresent([MatchedQuestion].self, forKey: .matchedQuestions) ?? []
        analysisErrorCategory = try container.decodeIfPresent(String.self, forKey: .analysisErrorCategory)
        clarificationStatus = try container.decodeIfPresent(
            LocalSessionClarificationStatus.self,
            forKey: .clarificationStatus
        ) ?? .pending
        uploadStatus = try container.decodeIfPresent(LocalSessionUploadStatus.self, forKey: .uploadStatus) ?? .notReady
        serverProcessingStatus = try container.decodeIfPresent(
            LocalSessionServerProcessingStatus.self,
            forKey: .serverProcessingStatus
        ) ?? .notSubmitted
        serverProcessingRevision = try container.decodeIfPresent(Int.self, forKey: .serverProcessingRevision)
        processingInputFileName = try container.decodeIfPresent(String.self, forKey: .processingInputFileName)
        cloudRespondentId = try container.decodeIfPresent(String.self, forKey: .cloudRespondentId)
        cloudSessionId = try container.decodeIfPresent(String.self, forKey: .cloudSessionId)
        retry = try container.decodeIfPresent(LocalSessionRetryMetadata.self, forKey: .retry) ?? LocalSessionRetryMetadata()
    }

}

struct LocalSessionStatusSummary: Equatable {
    let primary: String
    let messages: [String]
    let recordingIsSafeLocally: Bool
    let canRetryNow: Bool
    let retryScheduledAt: TimeInterval?

    static func derive(from manifest: LocalSessionManifest, hasFinalPackage: Bool) -> Self {
        var messages: [String] = []
        let recordingIsSafeLocally = manifest.audioStatus == .recordedLocally
        if recordingIsSafeLocally {
            messages.append("Recording saved locally")
        }

        switch (manifest.locationSource, manifest.locationStatus, manifest.locationQuality) {
        case (.savedSurveyLocation, _, _):
            messages.append("Fixed survey location")
        case (.placeSearch, _, _):
            messages.append("Address selected manually")
        case (.deviceGPS, .lowAccuracy, _), (.deviceGPS, _, .low):
            messages.append("Low-accuracy GPS")
        case (.none, _, _) where manifest.locationInfo?.mode == SurveyLocationMode.none:
            messages.append("Location intentionally disabled")
        case (.none, _, _) where recordingIsSafeLocally:
            messages.append("Location missing")
        default:
            break
        }

        let primary: String
        let retryableStage: Bool
        if manifest.serverProcessingStatus == .completed
            || (manifest.uploadStatus == .uploaded && hasFinalPackage) {
            primary = "Uploaded"
            retryableStage = false
        } else if manifest.serverProcessingStatus == .needsReview {
            primary = "Clarification required"
            messages.append("Server analysis needs interviewer review")
            retryableStage = true
        } else if manifest.serverProcessingStatus == .failedTerminal {
            primary = "Failed — action required"
            messages.append("Server processing failed")
            retryableStage = true
        } else if manifest.serverProcessingStatus == .failedRetryable {
            primary = "Waiting for server retry"
            messages.append("Server processing will retry")
            retryableStage = true
        } else if manifest.serverProcessingStatus == .queued {
            primary = "Queued on server"
            retryableStage = true
        } else if manifest.serverProcessingStatus == .transcribing {
            primary = "Transcribing on server"
            retryableStage = false
        } else if manifest.serverProcessingStatus == .analyzing {
            primary = "Analyzing on server"
            retryableStage = false
        } else if manifest.audioStatus != .recordedLocally {
            primary = "Failed — action required"
            if manifest.audioStatus == .preparing || manifest.audioStatus == .recording {
                messages.append("Recording was not finalized")
            }
            retryableStage = false
        } else if manifest.transcriptionStatus != .completed {
            let failed = manifest.transcriptionStatus == .failed || manifest.transcriptionStatus == .pendingRetry
            primary = failed ? "Failed — action required" : "Waiting for transcription"
            if failed { messages.append("Waiting for transcription") }
            retryableStage = manifest.transcriptionStatus != .inProgress
        } else if manifest.analysisStatus != .completed {
            let failed = manifest.analysisStatus == .failed || manifest.analysisStatus == .pendingRetry
            primary = failed ? "Failed — action required" : "Waiting for AI analysis"
            if failed { messages.append("Waiting for AI analysis") }
            retryableStage = manifest.analysisStatus != .inProgress
        } else if manifest.clarificationStatus == .pending {
            primary = "Clarification required"
            retryableStage = true
        } else if hasFinalPackage {
            if manifest.uploadStatus == .failed {
                primary = "Failed — action required"
                messages.append("Waiting for upload")
            } else {
                primary = "Waiting for upload"
            }
            retryableStage = manifest.uploadStatus != .inProgress
        } else {
            primary = "Failed — action required"
            messages.append("Final package missing")
            retryableStage = true
        }

        if !messages.contains(primary) {
            messages.append(primary)
        }
        if manifest.retry.nextRetryAt != nil, manifest.uploadStatus != .uploaded {
            messages.append("Retry scheduled")
        }

        return Self(
            primary: primary,
            messages: messages,
            recordingIsSafeLocally: recordingIsSafeLocally,
            canRetryNow: recordingIsSafeLocally && retryableStage,
            retryScheduledAt: manifest.retry.nextRetryAt
        )
    }
}

enum LocalSessionRetentionState {
    case emptyMetadataOnly
    case protected
    case uploaded
}

enum LocalSessionManifestStore {
    static let fileName = "session_state.json"

    static func url(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(fileName)
    }

    static func load(from directoryURL: URL) throws -> LocalSessionManifest {
        let data = try Data(contentsOf: url(in: directoryURL))
        var manifest = try JSONDecoder().decode(LocalSessionManifest.self, from: data)
        if manifest.localSessionId.isEmpty {
            manifest.localSessionId = directoryURL.lastPathComponent
        }
        return manifest
    }

    static func save(_ manifest: LocalSessionManifest, to directoryURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(to: url(in: directoryURL), options: [.atomic])
    }

    private static func standardAgeRangeLabel(for age: Int) -> String? {
        switch age {
        case ..<18:
            return "Under 18"
        case 18...24:
            return "18-24"
        case 25...34:
            return "25-34"
        case 35...44:
            return "35-44"
        case 45...54:
            return "45-54"
        case 55...64:
            return "55-64"
        default:
            return "65+"
        }
    }

    static func update(
        in directoryURL: URL,
        now: Date = Date(),
        _ mutate: (inout LocalSessionManifest) -> Void
    ) throws {
        var manifest = try load(from: directoryURL)
        mutate(&manifest)
        manifest.updatedAt = now.timeIntervalSince1970
        try save(manifest, to: directoryURL)
    }

    static func resolveFixedLocationForRetry(
        in directoryURL: URL,
        candidate: SurveyLocationAddressCandidate,
        confirmedName: String? = nil,
        now: Date = Date()
    ) throws {
        let manifest = try load(from: directoryURL)
        guard let current = manifest.locationInfo,
              current.needsCoordinateResolutionOnRetry else { return }
        let resolved = current.resolved(with: candidate, confirmedName: confirmedName)

        try update(in: directoryURL, now: now) { value in
            value.locationInfo = resolved
            value.locationStatus = .available
            value.locationSource = .savedSurveyLocation
            value.locationQuality = .unknown
            value.locationHorizontalAccuracyM = nil
            value.locationCoordinates = LocalSessionCoordinateSnapshot(
                latitude: candidate.latitude,
                longitude: candidate.longitude
            )
            value.locationLabel = resolved.locationName
            value.locationPoint = nil
            value.placeSnapshot = LocalSessionPlaceSnapshot(
                displayLabel: resolved.locationName ?? candidate.name ?? candidate.formattedAddress,
                formattedAddress: candidate.formattedAddress,
                latitude: candidate.latitude,
                longitude: candidate.longitude
            )
            value.trajectoryPoints = []
            if value.uploadStatus != .uploaded {
                value.uploadStatus = .notReady
            }
            if value.serverProcessingStatus == .notSubmitted {
                value.processingInputFileName = nil
            }
        }

        // session.json is derived from the manifest. Removing an older address-only
        // package ensures the retry pipeline rebuilds it with the confirmed point.
        let packageURL = directoryURL.appendingPathComponent("session.json")
        if FileManager.default.fileExists(atPath: packageURL.path) {
            try FileManager.default.removeItem(at: packageURL)
        }
        let processingInputURL = directoryURL.appendingPathComponent("processing_input.json")
        if FileManager.default.fileExists(atPath: processingInputURL.path) {
            try FileManager.default.removeItem(at: processingInputURL)
        }
    }

    static func resetDerivedProcessingForRetranscription(
        in directoryURL: URL,
        now: Date = Date()
    ) throws {
        let manifest = try load(from: directoryURL)
        guard manifest.audioStatus == .recordedLocally,
              let audioFileName = manifest.audioFileName else {
            throw DurableProcessingError.audioUnavailable
        }
        let audioURL = directoryURL.appendingPathComponent(audioFileName)
        let values = try audioURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isReadable != false,
              (values.fileSize ?? 0) > 0 else {
            throw DurableProcessingError.audioUnavailable
        }

        // Reset the authoritative manifest first. If file cleanup is interrupted,
        // the next coordinator run still knows it must regenerate every derived
        // artifact from the preserved original audio.
        try update(in: directoryURL, now: now) { value in
            value.transcriptionStatus = .pending
            value.transcriptionPipelineVersion = 0
            value.transcriptFileName = nil
            value.transcription = nil
            value.transcriptionErrorCategory = nil
            value.analysisStatus = .pending
            value.matchedQuestions = []
            value.analysisErrorCategory = nil
            value.clarificationStatus = .pending
            value.uploadStatus = .notReady
            value.serverProcessingStatus = .notSubmitted
            value.serverProcessingRevision = nil
            value.processingInputFileName = nil
            value.retry = LocalSessionRetryMetadata()
        }

        let derivedURLs = [
            directoryURL.appendingPathComponent(FileTranscriptStore.fileName),
            directoryURL.appendingPathComponent("session.json"),
            directoryURL.appendingPathComponent("processing_input.json")
        ]
        for url in derivedURLs where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    static func prepareForUserRetry(
        in directoryURL: URL,
        now: Date = Date()
    ) throws -> Bool {
        let manifest = try load(from: directoryURL)
        let hasHumanClarification = manifest.matchedQuestions.contains {
            $0.manuallyClarified == true
        }
        let needsCurrentTranscription = manifest.audioStatus == .recordedLocally
            && manifest.uploadStatus != .uploaded
            && manifest.transcriptionStatus == .completed
            && manifest.transcriptionPipelineVersion < LocalSessionManifest.currentTranscriptionPipelineVersion
            && !hasHumanClarification
        guard needsCurrentTranscription else { return false }

        try resetDerivedProcessingForRetranscription(in: directoryURL, now: now)
        return true
    }

    static func remove(from directoryURL: URL) throws {
        let manifestURL = url(in: directoryURL)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            try FileManager.default.removeItem(at: manifestURL)
        }
    }

    static func loadOrSynthesize(from directoryURL: URL) throws -> LocalSessionManifest {
        if FileManager.default.fileExists(atPath: url(in: directoryURL).path) {
            return try load(from: directoryURL)
        }
        return try synthesizeLegacyManifest(from: directoryURL)
    }

    static func retentionState(for directoryURL: URL) -> LocalSessionRetentionState {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let audioFiles = files.filter { $0.pathExtension.lowercased() == "m4a" }
        let hasSessionPackage = files.contains { $0.lastPathComponent == "session.json" }
        let hasManifest = files.contains { $0.lastPathComponent == fileName }

        if audioFiles.isEmpty && !hasSessionPackage {
            return .emptyMetadataOnly
        }

        if hasManifest, let manifest = try? load(from: directoryURL) {
            let processingComplete = manifest.transcriptionStatus == .completed
                && manifest.analysisStatus == .completed
                && (manifest.clarificationStatus == .completed || manifest.clarificationStatus == .notRequired)
            return manifest.uploadStatus == .uploaded && processingComplete ? .uploaded : .protected
        }

        for audioURL in audioFiles {
            let sidecarURL = audioURL.deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: sidecarURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if json["session_package_uploaded_at_epoch"] != nil {
                return .uploaded
            }
        }

        return .protected
    }

    private static func synthesizeLegacyManifest(from directoryURL: URL) throws -> LocalSessionManifest {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let audioURL = files
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
        let createdAt = (try? directoryURL.resourceValues(forKeys: [.creationDateKey]).creationDate)?
            .timeIntervalSince1970 ?? 0

        var manifest = LocalSessionManifest(
            localSessionId: directoryURL.lastPathComponent,
            createdAt: createdAt,
            audioFileName: audioURL?.lastPathComponent
        )
        if audioURL != nil {
            manifest.audioStatus = .recordedLocally
        }

        if let audioURL {
            let sidecarURL = audioURL.deletingPathExtension().appendingPathExtension("json")
            if let data = try? Data(contentsOf: sidecarURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                manifest.locationLabel = nonEmptyString(json["location"])
                manifest.recordingStartedAt = doubleValue(json["recorded_at_epoch"])
                if let respondent = json["respondent_info"] as? [String: Any] {
                    manifest.respondentSnapshot = RespondentInfo(
                        isAnonymous: respondent["is_anonymous"] as? Bool ?? false,
                        name: nonEmptyString(respondent["name"]),
                        age: intValue(respondent["age"]),
                        ageRange: nonEmptyString(respondent["age_range"])
                            ?? intValue(respondent["age"]).flatMap(Self.standardAgeRangeLabel(for:)),
                        gender: nonEmptyString(respondent["gender"]) ?? "Unknown",
                        race: nonEmptyString(respondent["race"]),
                        email: nonEmptyString(respondent["email"]),
                        location: nonEmptyString(respondent["location"])
                            ?? manifest.locationLabel
                            ?? "Unknown Location"
                    )
                }
                if let rawPoint = json["recording_start_trajectory_point"] as? [String: Any],
                   let point = trajectoryPoint(from: rawPoint) {
                    manifest.locationPoint = point
                    manifest.locationStatus = .available
                    manifest.locationSource = .deviceGPS
                }
                if let location = json["resolved_location"] as? [String: Any] {
                    applyResolvedLocation(location, to: &manifest)
                }
                if let locationInfo = json["location_info"] as? [String: Any] {
                    manifest.locationInfo = decodeLocationInfo(locationInfo)
                }
                if let rawPoints = json["trajectory_points"] as? [[String: Any]] {
                    manifest.trajectoryPoints = rawPoints.compactMap(trajectoryPoint(from:))
                }
                if json["session_package_uploaded_at_epoch"] != nil {
                    manifest.uploadStatus = .uploaded
                }
            }
        }

        let packageURL = directoryURL.appendingPathComponent("session.json")
        if let data = try? Data(contentsOf: packageURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let metadata = json["metadata"] as? [String: Any]
            if let interviewer = json["interviewer_info"] as? [String: Any],
               let interviewerData = try? JSONSerialization.data(withJSONObject: interviewer),
               let profile = try? JSONDecoder().decode(InterviewerProfile.self, from: interviewerData) {
                manifest.interviewerSnapshot = profile
            }
            if let respondent = json["respondent_info"] as? [String: Any] {
                manifest.respondentSnapshot = RespondentInfo(
                    isAnonymous: respondent["is_anonymous"] as? Bool ?? false,
                    name: nonEmptyString(respondent["name"]),
                    age: intValue(respondent["age"]),
                    ageRange: nonEmptyString(respondent["age_range"])
                        ?? intValue(respondent["age"]).flatMap(Self.standardAgeRangeLabel(for:)),
                    gender: nonEmptyString(respondent["gender"]) ?? "Unknown",
                    race: nonEmptyString(respondent["race"]),
                    email: nonEmptyString(respondent["email"]),
                    location: nonEmptyString(respondent["location"])
                        ?? manifest.locationLabel
                        ?? "Unknown Location"
                )
            }
            if let questionnaire = metadata?["questionnaire"] as? [String: Any],
               let questionnaireData = try? JSONSerialization.data(withJSONObject: questionnaire),
               let snapshot = try? JSONDecoder().decode(Questionnaire.self, from: questionnaireData) {
                manifest.questionnaireSnapshot = snapshot
                manifest.questionnaireId = snapshot.id
                manifest.questionnaireVersion = snapshot.version
                manifest.questionnaireHash = snapshot.hash
            }
            if let cloud = metadata?["cloud"] as? [String: Any] {
                manifest.cloudSessionId = nonEmptyString(cloud["session_id"])
                manifest.cloudRespondentId = nonEmptyString(cloud["respondent_id"])
            }
            manifest.locationLabel = nonEmptyString(json["location_label"])
                ?? manifest.respondentSnapshot?.location
                ?? manifest.locationLabel
            if let location = json["location"] as? [String: Any] {
                applyResolvedLocation(location, to: &manifest)
            }
            if let locationInfo = json["location_info"] as? [String: Any] {
                manifest.locationInfo = decodeLocationInfo(locationInfo)
            }
            manifest.transcription = nonEmptyString(json["transcription"])
            if manifest.transcription != nil {
                manifest.transcriptionStatus = .completed
            }
            if let rawMatches = json["matched_questions"] as? [[String: Any]],
               let matchData = try? JSONSerialization.data(withJSONObject: rawMatches),
               let matches = try? JSONDecoder().decode([MatchedQuestion].self, from: matchData) {
                manifest.matchedQuestions = matches
                manifest.analysisStatus = .completed
                manifest.clarificationStatus = .completed
            }
            manifest.uploadStatus = manifest.uploadStatus == .uploaded ? .uploaded : .pending
        }

        return manifest
    }

    private static func applyResolvedLocation(_ raw: [String: Any], to manifest: inout LocalSessionManifest) {
        if let status = nonEmptyString(raw["status"]).flatMap(LocalSessionLocationStatus.init(rawValue:)) {
            manifest.locationStatus = status
        }
        if let source = nonEmptyString(raw["source"]).flatMap(LocalSessionLocationSource.init(rawValue:)) {
            manifest.locationSource = source
        }
        if let quality = nonEmptyString(raw["quality"]).flatMap(LocalSessionLocationQuality.init(rawValue:)) {
            manifest.locationQuality = quality
        }
        manifest.locationHorizontalAccuracyM = doubleValue(raw["horizontal_accuracy_m"])
            ?? manifest.locationHorizontalAccuracyM
        manifest.locationLabel = nonEmptyString(raw["label"]) ?? manifest.locationLabel

        if manifest.locationSource == .placeSearch {
            manifest.locationPoint = nil
            manifest.placeSnapshot = LocalSessionPlaceSnapshot(
                displayLabel: nonEmptyString(raw["label"]) ?? manifest.locationLabel ?? "Selected Place",
                formattedAddress: nonEmptyString(raw["formatted_address"]),
                latitude: doubleValue(raw["latitude"]),
                longitude: doubleValue(raw["longitude"])
            )
        }
        manifest.locationCoordinates = LocalSessionCoordinateSnapshot(
            latitude: doubleValue(raw["latitude"]),
            longitude: doubleValue(raw["longitude"])
        )
    }

    private static func decodeLocationInfo(_ raw: [String: Any]) -> SessionLocationInfo? {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(SessionLocationInfo.self, from: data)
    }

    private static func trajectoryPoint(from raw: [String: Any]) -> TrajectoryPoint? {
        guard let tsMs = int64Value(raw["ts_ms"]),
              let lat = doubleValue(raw["lat"]),
              let lon = doubleValue(raw["lon"]) else {
            return nil
        }
        return TrajectoryPoint(
            tsMs: tsMs,
            lat: lat,
            lon: lon,
            accuracyM: doubleValue(raw["accuracy_m"]),
            speedMps: doubleValue(raw["speed_mps"]),
            courseDeg: doubleValue(raw["course_deg"]),
            provider: raw["provider"] as? String,
            isBackground: raw["is_background"] as? Bool,
            sessionId: raw["session_id"] as? String
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
