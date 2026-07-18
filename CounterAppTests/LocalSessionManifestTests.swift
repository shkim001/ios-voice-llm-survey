import Foundation
import CoreLocation
import Testing
@testable import CounterApp

struct LocalSessionManifestTests {
    @Test func manifestRoundTripPreservesCaptureSnapshot() throws {
        let point = PendingTrajectoryStore.Point(
            tsMs: 1_700_000_000_000,
            lat: 40.8075,
            lon: -73.9626,
            accuracyM: 5,
            speedMps: nil,
            courseDeg: nil,
            provider: "recording-start",
            isBackground: false,
            sessionId: nil
        )
        let questionnaire = Questionnaire(
            id: "street-assessment",
            version: "3",
            title: "Street Assessment",
            description: "Field questionnaire",
            status: "published",
            hash: "abc123",
            questions: [
                Question(
                    id: 1,
                    question: "Are there places to sit?",
                    type: "yes-no",
                    followUp: nil,
                    keywords: ["seat"]
                )
            ]
        )
        var manifest = LocalSessionManifest(
            localSessionId: "local-1",
            createdAt: 100,
            audioFileName: "recording_100.m4a",
            interviewerSnapshot: InterviewerProfile(
                name: "Field Worker",
                email: "worker@example.com",
                identityScope: "device"
            ),
            respondentSnapshot: RespondentInfo(
                isAnonymous: false,
                name: "Respondent",
                age: 70,
                gender: "Prefer not to say",
                phone: nil,
                location: "Broadway"
            ),
            questionnaireSnapshot: questionnaire,
            locationStatus: .available,
            locationSource: .deviceGPS,
            locationLabel: "Broadway",
            locationPoint: point,
            trajectoryPoints: [point]
        )
        manifest.audioStatus = .recordedLocally
        manifest.recordingStartedAt = 101
        manifest.recordingStoppedAt = 120
        manifest.transcriptionStatus = .completed
        manifest.transcription = "Yes, there are benches."
        manifest.retry = LocalSessionRetryMetadata(retryCount: 2, lastError: "Previous error")

        let decoded = try JSONDecoder().decode(
            LocalSessionManifest.self,
            from: JSONEncoder().encode(manifest)
        )

        #expect(decoded.schemaVersion == LocalSessionManifest.currentSchemaVersion)
        #expect(decoded.localSessionId == "local-1")
        #expect(decoded.audioFileName == "recording_100.m4a")
        #expect(decoded.audioStatus == .recordedLocally)
        #expect(decoded.interviewerSnapshot?.email == "worker@example.com")
        #expect(decoded.respondentSnapshot?.name == "Respondent")
        #expect(decoded.questionnaireId == "street-assessment")
        #expect(decoded.questionnaireVersion == "3")
        #expect(decoded.questionnaireSnapshot?.questions.first?.id == 1)
        #expect(decoded.locationPoint?.lat == 40.8075)
        #expect(decoded.trajectoryPoints.count == 1)
        #expect(decoded.transcription == "Yes, there are benches.")
        #expect(decoded.retry.retryCount == 2)
    }

    @Test func olderManifestDefaultsMissingFieldsConservatively() throws {
        let data = Data(
            """
            {
              "local_session_id": "legacy-local",
              "created_at": 50,
              "audio_file_name": "legacy.m4a"
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(LocalSessionManifest.self, from: data)

        #expect(decoded.schemaVersion == 0)
        #expect(decoded.audioStatus == .recordedLocally)
        #expect(decoded.locationStatus == .pending)
        #expect(decoded.locationSource == .none)
        #expect(decoded.locationCoordinates.latitude == nil)
        #expect(decoded.locationCoordinates.longitude == nil)
        #expect(decoded.transcriptionStatus == .pending)
        #expect(decoded.analysisStatus == .pending)
        #expect(decoded.clarificationStatus == .pending)
        #expect(decoded.uploadStatus == .notReady)
        #expect(decoded.trajectoryPoints.isEmpty)
        #expect(decoded.retry.retryCount == 0)
    }

    @Test func unknownFutureStatusDoesNotBreakDecoding() throws {
        let data = Data(
            """
            {
              "local_session_id": "future-local",
              "audio_status": "future-audio-state",
              "location_status": "future-location-state",
              "upload_status": "future-upload-state"
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(LocalSessionManifest.self, from: data)

        #expect(decoded.audioStatus == .preparing)
        #expect(decoded.locationStatus == .pending)
        #expect(decoded.uploadStatus == .notReady)
    }

    @Test func placeSearchSnapshotRoundTripStaysSeparateFromTrajectory() throws {
        let place = LocalSessionPlaceSnapshot(
            displayLabel: "Butler Library",
            formattedAddress: "535 W 114th St, New York, NY",
            latitude: 40.8063,
            longitude: -73.9632
        )
        let manifest = LocalSessionManifest(
            localSessionId: "place-search",
            locationStatus: .available,
            locationSource: .placeSearch,
            locationQuality: .unknown,
            locationCoordinates: LocalSessionCoordinateSnapshot(
                latitude: place.latitude,
                longitude: place.longitude
            ),
            locationLabel: place.displayLabel,
            placeSnapshot: place
        )

        let decoded = try JSONDecoder().decode(
            LocalSessionManifest.self,
            from: JSONEncoder().encode(manifest)
        )

        #expect(decoded.locationSource == .placeSearch)
        #expect(decoded.placeSnapshot == place)
        #expect(decoded.locationCoordinates.latitude == 40.8063)
        #expect(decoded.locationPoint == nil)
        #expect(decoded.trajectoryPoints.isEmpty)
    }

    @Test func gpsClassificationUsesFreshnessAndFiftyMeterThreshold() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let acceptable = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40.8075, longitude: -73.9626),
            altitude: 0,
            horizontalAccuracy: 25,
            verticalAccuracy: -1,
            timestamp: now
        )
        let low = CLLocation(
            coordinate: acceptable.coordinate,
            altitude: 0,
            horizontalAccuracy: 75,
            verticalAccuracy: -1,
            timestamp: now
        )
        let stale = CLLocation(
            coordinate: acceptable.coordinate,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: -1,
            timestamp: now.addingTimeInterval(-61)
        )

        if case .acceptable(let candidate) = TrajectoryTracker.classifyRecordingStartLocation(acceptable, now: now) {
            #expect(candidate.quality == .acceptable)
            #expect(candidate.horizontalAccuracyM == 25)
        } else {
            Issue.record("Expected acceptable GPS result")
        }
        if case .lowAccuracy(let candidate) = TrajectoryTracker.classifyRecordingStartLocation(low, now: now) {
            #expect(candidate.quality == .low)
            #expect(candidate.horizontalAccuracyM == 75)
        } else {
            Issue.record("Expected low-accuracy GPS result")
        }
        if case .failure(let failure) = TrajectoryTracker.classifyRecordingStartLocation(stale, now: now) {
            #expect(failure == .stale)
        } else {
            Issue.record("Expected stale GPS result")
        }
    }

    @Test func gpsFailuresMapToPersistentRecoveryStates() {
        #expect(RecordingStartLocationStateMapping.manifestStatus(for: .permissionDenied) == .permissionDenied)
        #expect(RecordingStartLocationStateMapping.manifestStatus(for: .restricted) == .permissionDenied)
        #expect(RecordingStartLocationStateMapping.manifestStatus(for: .timedOut) == .timedOut)
        #expect(RecordingStartLocationStateMapping.manifestStatus(for: .stale) == .unavailable)
        #expect(RecordingStartLocationStateMapping.manifestStatus(for: .lowAccuracy) == .lowAccuracy)
    }

    @Test func atomicStoreSupportsRecordingStateTransitions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = LocalSessionManifest(
            localSessionId: "transition-local",
            createdAt: 10,
            audioFileName: "recording.m4a"
        )
        try LocalSessionManifestStore.save(manifest, to: directory)
        try LocalSessionManifestStore.update(in: directory, now: Date(timeIntervalSince1970: 11)) { value in
            value.audioStatus = .recording
            value.recordingStartedAt = 11
        }
        try LocalSessionManifestStore.update(in: directory, now: Date(timeIntervalSince1970: 20)) { value in
            value.audioStatus = .recordedLocally
            value.recordingStoppedAt = 20
        }

        let decoded = try LocalSessionManifestStore.load(from: directory)
        #expect(decoded.audioStatus == .recordedLocally)
        #expect(decoded.recordingStartedAt == 11)
        #expect(decoded.recordingStoppedAt == 20)
        #expect(decoded.updatedAt == 20)
    }

    @Test func retentionProtectsPendingAndLegacyUnuploadedAudio() throws {
        let pendingDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: pendingDirectory) }
        try Data([0x01]).write(to: pendingDirectory.appendingPathComponent("recording.m4a"))
        var pending = LocalSessionManifest(
            localSessionId: "pending",
            audioFileName: "recording.m4a"
        )
        pending.audioStatus = .recordedLocally
        pending.uploadStatus = .pending
        try LocalSessionManifestStore.save(pending, to: pendingDirectory)
        #expect(LocalSessionManifestStore.retentionState(for: pendingDirectory) == .protected)

        let legacyDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        try Data([0x01]).write(to: legacyDirectory.appendingPathComponent("legacy.m4a"))
        #expect(LocalSessionManifestStore.retentionState(for: legacyDirectory) == .protected)
    }

    @Test func legacySidecarSynthesizesRecoverableDefaults() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0x01, 0x02]).write(to: directory.appendingPathComponent("legacy.m4a"))
        try Data(
            """
            {
              "recorded_at_epoch": 123,
              "location": "Legacy Block",
              "respondent_info": {
                "name": "Legacy Respondent",
                "age": 65,
                "gender": "Unknown",
                "location": "Legacy Block"
              },
              "recording_start_trajectory_point": {
                "ts_ms": 123000,
                "lat": 40.8,
                "lon": -73.9,
                "provider": "recording-start"
              }
            }
            """.utf8
        ).write(to: directory.appendingPathComponent("legacy.json"), options: [.atomic])

        let manifest = try LocalSessionManifestStore.loadOrSynthesize(from: directory)

        #expect(manifest.schemaVersion == LocalSessionManifest.currentSchemaVersion)
        #expect(manifest.audioFileName == "legacy.m4a")
        #expect(manifest.audioStatus == .recordedLocally)
        #expect(manifest.recordingStartedAt == 123)
        #expect(manifest.respondentSnapshot?.name == "Legacy Respondent")
        #expect(manifest.respondentSnapshot?.isAnonymous == false)
        #expect(manifest.locationStatus == .available)
        #expect(manifest.locationSource == .deviceGPS)
        #expect(manifest.locationPoint?.lat == 40.8)
        #expect(manifest.transcriptionStatus == .pending)
        #expect(manifest.uploadStatus == .notReady)
    }

    @Test func retentionAllowsOnlyConfirmedCompletedUploads() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0x01]).write(to: directory.appendingPathComponent("recording.m4a"))

        var manifest = LocalSessionManifest(
            localSessionId: "uploaded",
            audioFileName: "recording.m4a"
        )
        manifest.audioStatus = .recordedLocally
        manifest.transcriptionStatus = .completed
        manifest.analysisStatus = .completed
        manifest.clarificationStatus = .notRequired
        manifest.uploadStatus = .uploaded
        try LocalSessionManifestStore.save(manifest, to: directory)

        #expect(LocalSessionManifestStore.retentionState(for: directory) == .uploaded)

        try LocalSessionManifestStore.update(in: directory) { value in
            value.analysisStatus = .pending
        }
        #expect(LocalSessionManifestStore.retentionState(for: directory) == .protected)
    }

    @Test func statusSummaryNeverConfusesLocalSafetyWithUpload() {
        var manifest = LocalSessionManifest(localSessionId: "status", audioFileName: "recording.m4a")
        manifest.audioStatus = .recordedLocally
        manifest.locationStatus = .unavailable
        manifest.locationSource = .none

        var summary = LocalSessionStatusSummary.derive(from: manifest, hasFinalPackage: false)
        #expect(summary.primary == "Waiting for transcription")
        #expect(summary.messages.contains("Recording saved locally"))
        #expect(summary.messages.contains("Location missing"))
        #expect(!summary.messages.contains("Uploaded"))

        manifest.transcriptionStatus = .completed
        manifest.analysisStatus = .pendingRetry
        manifest.retry.nextRetryAt = 500
        summary = .derive(from: manifest, hasFinalPackage: false)
        #expect(summary.primary == "Failed — action required")
        #expect(summary.messages.contains("Waiting for AI analysis"))
        #expect(summary.messages.contains("Retry scheduled"))
        #expect(summary.canRetryNow)

        manifest.analysisStatus = .completed
        manifest.clarificationStatus = .completed
        manifest.uploadStatus = .pending
        manifest.retry = LocalSessionRetryMetadata()
        summary = .derive(from: manifest, hasFinalPackage: true)
        #expect(summary.primary == "Waiting for upload")
        #expect(!summary.messages.contains("Uploaded"))

        manifest.uploadStatus = .uploaded
        summary = .derive(from: manifest, hasFinalPackage: true)
        #expect(summary.primary == "Uploaded")
        #expect(!summary.canRetryNow)
    }

    @Test func statusSummaryDistinguishesGPSAndManualPlaceLocation() {
        var manifest = LocalSessionManifest(localSessionId: "location", audioFileName: "recording.m4a")
        manifest.audioStatus = .recordedLocally
        manifest.locationStatus = .lowAccuracy
        manifest.locationSource = .deviceGPS
        manifest.locationQuality = .low
        var summary = LocalSessionStatusSummary.derive(from: manifest, hasFinalPackage: false)
        #expect(summary.messages.contains("Low-accuracy GPS"))

        manifest.locationStatus = .available
        manifest.locationSource = .placeSearch
        manifest.locationQuality = .unknown
        summary = .derive(from: manifest, hasFinalPackage: false)
        #expect(summary.messages.contains("Address selected manually"))
        #expect(!summary.messages.contains("Low-accuracy GPS"))
    }

    @Test func metadataOnlyManifestIsSafelyCleanable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try LocalSessionManifestStore.save(
            LocalSessionManifest(localSessionId: "metadata-only"),
            to: directory
        )

        #expect(LocalSessionManifestStore.retentionState(for: directory) == .emptyMetadataOnly)
    }

    @Test func moreThanFiftyPendingAudioFoldersRemainProtected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var directories: [URL] = []
        for index in 0..<60 {
            let directory = root.appendingPathComponent("pending-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0x01]).write(to: directory.appendingPathComponent("recording.m4a"))
            var manifest = LocalSessionManifest(
                localSessionId: "pending-\(index)",
                audioFileName: "recording.m4a"
            )
            manifest.audioStatus = .recordedLocally
            manifest.uploadStatus = .pending
            try LocalSessionManifestStore.save(manifest, to: directory)
            directories.append(directory)
        }

        #expect(directories.allSatisfy {
            LocalSessionManifestStore.retentionState(for: $0) == .protected
        })
    }

    @Test func recordingStoragePolicyBlocksKnownLowCapacity() {
        #expect(LocalRecordingStoragePolicy.hasSufficientCapacity(nil))
        #expect(!LocalRecordingStoragePolicy.hasSufficientCapacity(99 * 1_024 * 1_024))
        #expect(LocalRecordingStoragePolicy.hasSufficientCapacity(100 * 1_024 * 1_024))
    }

    @Test func fourPrimaryConnectivityAndLocationStatesRemainRecoverable() {
        func manifest(hasGPS: Bool, processingComplete: Bool) -> LocalSessionManifest {
            var value = LocalSessionManifest(localSessionId: UUID().uuidString, audioFileName: "recording.m4a")
            value.audioStatus = .recordedLocally
            value.locationStatus = hasGPS ? .available : .unavailable
            value.locationSource = hasGPS ? .deviceGPS : .none
            if processingComplete {
                value.transcriptionStatus = .completed
                value.analysisStatus = .completed
                value.clarificationStatus = .completed
                value.uploadStatus = .pending
            }
            return value
        }

        let onlineGPS = LocalSessionStatusSummary.derive(
            from: manifest(hasGPS: true, processingComplete: true),
            hasFinalPackage: true
        )
        let offlineGPS = LocalSessionStatusSummary.derive(
            from: manifest(hasGPS: true, processingComplete: false),
            hasFinalPackage: false
        )
        let onlineNoGPS = LocalSessionStatusSummary.derive(
            from: manifest(hasGPS: false, processingComplete: true),
            hasFinalPackage: true
        )
        let offlineNoGPS = LocalSessionStatusSummary.derive(
            from: manifest(hasGPS: false, processingComplete: false),
            hasFinalPackage: false
        )

        #expect(onlineGPS.primary == "Waiting for upload")
        #expect(offlineGPS.primary == "Waiting for transcription")
        #expect(onlineNoGPS.messages.contains("Location missing"))
        #expect(onlineNoGPS.primary == "Waiting for upload")
        #expect(offlineNoGPS.messages.contains("Location missing"))
        #expect(offlineNoGPS.recordingIsSafeLocally)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalSessionManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
