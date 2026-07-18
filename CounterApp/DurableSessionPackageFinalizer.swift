import Foundation

enum DurableSessionPackageFinalizer {
    static func finalize(
        sessionDirectoryURL: URL,
        transcript: String,
        matchedQuestions: [MatchedQuestion],
        now: Date = Date()
    ) throws -> URL {
        let manifest = try LocalSessionManifestStore.load(from: sessionDirectoryURL)
        guard manifest.audioStatus == .recordedLocally,
              let audioFileName = manifest.audioFileName else {
            throw DurableProcessingError.audioUnavailable
        }
        let audioURL = sessionDirectoryURL.appendingPathComponent(audioFileName)
        let audioValues = try audioURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey])
        guard audioValues.isRegularFile == true,
              audioValues.isReadable != false,
              (audioValues.fileSize ?? 0) > 0 else {
            throw DurableProcessingError.audioUnavailable
        }
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else { throw DurableProcessingError.emptyTranscript }

        let questionnaire = manifest.questionnaireSnapshot.map(QuestionnaireSnapshot.init)
        let cloud = manifest.cloudSessionId.flatMap { sessionId in
            manifest.cloudRespondentId.map {
                CloudSnapshot(sessionId: sessionId, respondentId: $0)
            }
        }
        let label = manifest.placeSnapshot?.displayLabel
            ?? manifest.locationLabel
            ?? manifest.respondentSnapshot?.location
        let location = LocationSnapshot(
            status: manifest.locationStatus.rawValue,
            source: manifest.locationSource.rawValue,
            quality: manifest.locationQuality.rawValue,
            label: label,
            formattedAddress: manifest.placeSnapshot?.formattedAddress,
            latitude: manifest.locationCoordinates.latitude,
            longitude: manifest.locationCoordinates.longitude,
            horizontalAccuracyM: manifest.locationHorizontalAccuracyM
        )
        let cloudSessionId = manifest.cloudSessionId
        let recordingStart = manifest.locationSource == .deviceGPS
            ? manifest.locationPoint.map { TrajectorySnapshot($0, cloudSessionId: cloudSessionId) }
            : nil
        let trajectory = manifest.trajectoryPoints.map {
            TrajectorySnapshot($0, cloudSessionId: cloudSessionId)
        }
        let timestamp = now.timeIntervalSince1970
        let package = Package(
            metadata: Metadata(
                schemaVersion: 3,
                exportTime: exportTimestamp(now),
                timestamp: timestamp,
                localSessionId: manifest.localSessionId,
                questionnaireTitle: manifest.questionnaireSnapshot?.title ?? "Unknown",
                totalResponses: 1,
                questionnaire: questionnaire,
                cloud: cloud
            ),
            schemaVersion: 3,
            timestamp: timestamp,
            sessionId: manifest.localSessionId,
            localSessionId: manifest.localSessionId,
            interviewerInfo: manifest.interviewerSnapshot,
            respondentInfo: manifest.respondentSnapshot,
            locationLabel: label,
            location: location,
            audio: AudioSnapshot(
                fileName: audioFileName,
                localSessionId: manifest.localSessionId,
                recordedAtMs: manifest.recordingStartedAt.map { Int($0 * 1_000) },
                fileSizeBytes: audioValues.fileSize
            ),
            recordingStartTrajectoryPoint: recordingStart,
            trajectoryPoints: trajectory,
            transcription: normalizedTranscript,
            matchedQuestions: matchedQuestions
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(package)
        _ = try JSONSerialization.jsonObject(with: data)
        let packageURL = sessionDirectoryURL.appendingPathComponent("session.json")
        try data.write(to: packageURL, options: [.atomic])
        _ = try Data(contentsOf: packageURL)
        try LocalSessionManifestStore.update(in: sessionDirectoryURL, now: now) { value in
            value.transcriptionStatus = .completed
            value.transcription = normalizedTranscript
            value.analysisStatus = .completed
            value.matchedQuestions = matchedQuestions
            value.clarificationStatus = .completed
            value.uploadStatus = .pending
            value.retry = LocalSessionRetryMetadata()
        }
        return packageURL
    }

    private static func exportTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func capturedAt(_ timestampMs: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestampMs) / 1_000))
    }

    private struct Package: Encodable {
        let metadata: Metadata
        let schemaVersion: Int
        let timestamp: Double
        let sessionId: String
        let localSessionId: String
        let interviewerInfo: InterviewerProfile?
        let respondentInfo: RespondentInfo?
        let locationLabel: String?
        let location: LocationSnapshot
        let audio: AudioSnapshot
        let recordingStartTrajectoryPoint: TrajectorySnapshot?
        let trajectoryPoints: [TrajectorySnapshot]
        let transcription: String
        let matchedQuestions: [MatchedQuestion]

        enum CodingKeys: String, CodingKey {
            case metadata
            case schemaVersion = "schema_version"
            case timestamp
            case sessionId = "session_id"
            case localSessionId = "local_session_id"
            case interviewerInfo = "interviewer_info"
            case respondentInfo = "respondent_info"
            case locationLabel = "location_label"
            case location
            case audio
            case recordingStartTrajectoryPoint = "recording_start_trajectory_point"
            case trajectoryPoints = "trajectory_points"
            case transcription
            case matchedQuestions = "matched_questions"
        }
    }

    private struct Metadata: Encodable {
        let schemaVersion: Int
        let exportTime: String
        let timestamp: Double
        let localSessionId: String
        let questionnaireTitle: String
        let totalResponses: Int
        let questionnaire: QuestionnaireSnapshot?
        let cloud: CloudSnapshot?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case exportTime = "export_time"
            case timestamp
            case localSessionId = "local_session_id"
            case questionnaireTitle = "questionnaire_title"
            case totalResponses = "total_responses"
            case questionnaire
            case cloud
        }
    }

    private struct QuestionnaireSnapshot: Encodable {
        let id: String?
        let version: String?
        let title: String
        let description: String
        let hash: String?
        let questions: [QuestionSnapshot]

        init(_ questionnaire: Questionnaire) {
            id = questionnaire.id
            version = questionnaire.version
            title = questionnaire.title
            description = questionnaire.description
            hash = questionnaire.hash
            questions = questionnaire.questions.map(QuestionSnapshot.init)
        }
    }

    private struct QuestionSnapshot: Encodable {
        let id: Int
        let question: String
        let type: String
        let followUp: String?
        let keywords: [String]
        let options: [QuestionOption]
        let allowsMultiple: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case question
            case type
            case followUp = "follow_up"
            case keywords
            case options
            case allowsMultiple = "allows_multiple"
        }

        init(_ question: Question) {
            id = question.id
            self.question = question.question
            type = question.type
            followUp = question.followUp
            keywords = question.keywords
            options = question.options
            allowsMultiple = question.allowsMultiple
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(question, forKey: .question)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(followUp, forKey: .followUp)
            try container.encode(keywords, forKey: .keywords)
            if type.lowercased() == "multiple-choice" {
                try container.encode(allowsMultiple, forKey: .allowsMultiple)
                try container.encode(options, forKey: .options)
            }
        }
    }

    private struct CloudSnapshot: Encodable {
        let sessionId: String
        let respondentId: String

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case respondentId = "respondent_id"
        }
    }

    private struct AudioSnapshot: Encodable {
        let fileName: String
        let localSessionId: String
        let recordedAtMs: Int?
        let fileSizeBytes: Int?

        enum CodingKeys: String, CodingKey {
            case fileName = "file_name"
            case localSessionId = "local_session_id"
            case recordedAtMs = "recorded_at_ms"
            case fileSizeBytes = "file_size_bytes"
        }
    }

    private struct LocationSnapshot: Encodable {
        let status: String
        let source: String
        let quality: String
        let label: String?
        let formattedAddress: String?
        let latitude: Double?
        let longitude: Double?
        let horizontalAccuracyM: Double?

        enum CodingKeys: String, CodingKey {
            case status
            case source
            case quality
            case label
            case formattedAddress = "formatted_address"
            case latitude
            case longitude
            case horizontalAccuracyM = "horizontal_accuracy_m"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(status, forKey: .status)
            try container.encode(source, forKey: .source)
            try container.encode(quality, forKey: .quality)
            try container.encodeIfPresent(label, forKey: .label)
            try container.encodeIfPresent(formattedAddress, forKey: .formattedAddress)
            try container.encode(latitude, forKey: .latitude)
            try container.encode(longitude, forKey: .longitude)
            try container.encodeIfPresent(horizontalAccuracyM, forKey: .horizontalAccuracyM)
        }
    }

    private struct TrajectorySnapshot: Encodable {
        let lat: Double
        let lon: Double
        let timestampMs: Int64
        let capturedAt: String
        let accuracyM: Double?
        let speedMps: Double?
        let courseDeg: Double?
        let provider: String?
        let isBackground: Bool?
        let sessionId: String?

        enum CodingKeys: String, CodingKey {
            case lat
            case lon
            case timestampMs = "ts_ms"
            case capturedAt = "captured_at"
            case accuracyM = "accuracy_m"
            case speedMps = "speed_mps"
            case courseDeg = "course_deg"
            case provider
            case isBackground = "is_background"
            case sessionId = "session_id"
        }

        init(_ point: TrajectoryPoint, cloudSessionId: String?) {
            lat = point.lat
            lon = point.lon
            timestampMs = point.tsMs
            capturedAt = DurableSessionPackageFinalizer.capturedAt(point.tsMs)
            accuracyM = point.accuracyM
            speedMps = point.speedMps
            courseDeg = point.courseDeg
            provider = point.provider
            isBackground = point.isBackground
            sessionId = point.sessionId ?? cloudSessionId
        }
    }
}
