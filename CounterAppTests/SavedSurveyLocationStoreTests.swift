import Foundation
import Testing
@testable import CounterApp

@Suite(.serialized)
struct SavedSurveyLocationStoreTests {
    @Test func typedAddressResolutionReturnsMapKitCoordinatesAndIdentifier() async {
        let candidate = SurveyLocationAddressCandidate(
            name: "Canaan Senior Service Center",
            formattedAddress: "1428 5th Ave, New York, NY 10035",
            latitude: 40.7991,
            longitude: -73.9475,
            mapItemIdentifier: "mapkit-canaan-1428"
        )

        let outcome = await ManualSurveyLocationAddressResolution.resolve(
            typedAddress: "1428 5th Ave, New York, NY 10035",
            using: StubAddressResolver(result: .success([candidate]))
        )

        #expect(outcome == .candidates([candidate]))
    }

    @Test func unresolvedTypedAddressFallsBackWithoutFabricatingCoordinates() async {
        let outcome = await ManualSurveyLocationAddressResolution.resolve(
            typedAddress: "Offline address",
            using: StubAddressResolver(result: .failure(StubResolutionError.offline))
        )

        #expect(outcome == .addressOnly)
    }

    @Test func retryKeepsMultipleMapMatchesUnselectedForClarification() async {
        let first = SurveyLocationAddressCandidate(
            name: "Canaan Senior Center",
            formattedAddress: "1428 5th Ave, New York, NY",
            latitude: 40.7991,
            longitude: -73.9475,
            mapItemIdentifier: "first"
        )
        let second = SurveyLocationAddressCandidate(
            name: "Canaan Senior Center",
            formattedAddress: "77 S Canaan Rd, Canaan, CT",
            latitude: 41.9642,
            longitude: -73.2918,
            mapItemIdentifier: "second"
        )

        let outcome = await ManualSurveyLocationAddressResolution.resolve(
            typedAddress: "Canaan Senior Center",
            using: StubAddressResolver(result: .success([first, second]))
        )

        #expect(outcome == .candidates([first, second]))
    }

    @Test func confirmedRetryUpdatesSameSavedLocationWithMapPoint() throws {
        var unresolved = makeLocation()
        unresolved.latitude = nil
        unresolved.longitude = nil
        unresolved.mapItemIdentifier = nil
        let candidate = SurveyLocationAddressCandidate(
            name: "Resolved Site",
            formattedAddress: "535 W 114th St, New York, NY 10027",
            latitude: 40.8063,
            longitude: -73.9632,
            mapItemIdentifier: "resolved-map-item"
        )

        #expect(unresolved.needsCoordinateResolution)
        let resolved = unresolved.resolved(
            with: candidate,
            confirmedName: unresolved.name,
            at: Date(timeIntervalSince1970: 200)
        )
        let snapshot = SessionLocationInfo.fixed(resolved)

        #expect(resolved.id == unresolved.id)
        #expect(resolved.createdAt == unresolved.createdAt)
        #expect(resolved.lastUsedAt == unresolved.lastUsedAt)
        #expect(!resolved.needsCoordinateResolution)
        #expect(snapshot.latitude == 40.8063)
        #expect(snapshot.longitude == -73.9632)
        #expect(snapshot.mapItemIdentifier == "resolved-map-item")
    }

    @Test func savedSessionRetryPersistsCoordinatesAndInvalidatesAddressOnlyPackage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var unresolved = makeLocation()
        unresolved.latitude = nil
        unresolved.longitude = nil
        unresolved.mapItemIdentifier = nil
        var manifest = LocalSessionManifest(
            localSessionId: "address-only-retry",
            audioFileName: "recording.m4a",
            locationInfo: .fixed(unresolved),
            locationStatus: .available,
            locationSource: .savedSurveyLocation,
            locationCoordinates: LocalSessionCoordinateSnapshot(),
            locationLabel: unresolved.name,
            placeSnapshot: LocalSessionPlaceSnapshot(
                displayLabel: unresolved.name,
                formattedAddress: unresolved.formattedAddress,
                latitude: nil,
                longitude: nil
            )
        )
        manifest.audioStatus = .recordedLocally
        try LocalSessionManifestStore.save(manifest, to: directory)
        try Data([0x01, 0x02]).write(to: directory.appendingPathComponent("recording.m4a"))
        let packageURL = directory.appendingPathComponent("session.json")
        try Data("{\"location_info\":{}}".utf8).write(to: packageURL)

        let candidate = SurveyLocationAddressCandidate(
            name: "Resolved Research Site",
            formattedAddress: "535 W 114th St, New York, NY 10027",
            latitude: 40.8063,
            longitude: -73.9632,
            mapItemIdentifier: "retry-map-item"
        )
        try LocalSessionManifestStore.resolveFixedLocationForRetry(
            in: directory,
            candidate: candidate,
            confirmedName: "Research Site"
        )

        let updated = try LocalSessionManifestStore.load(from: directory)
        #expect(updated.locationInfo?.latitude == 40.8063)
        #expect(updated.locationInfo?.longitude == -73.9632)
        #expect(updated.locationInfo?.mapItemIdentifier == "retry-map-item")
        #expect(updated.locationCoordinates.latitude == 40.8063)
        #expect(updated.locationCoordinates.longitude == -73.9632)
        #expect(updated.placeSnapshot?.formattedAddress == candidate.formattedAddress)
        #expect(updated.locationInfo?.savedLocationId == unresolved.id)
        #expect(!FileManager.default.fileExists(atPath: packageURL.path))

        let rebuiltURL = try DurableSessionPackageFinalizer.finalize(
            sessionDirectoryURL: directory,
            transcript: "Recovered interview transcript",
            matchedQuestions: []
        )
        let rebuilt = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: rebuiltURL)) as? [String: Any]
        )
        let rebuiltLocation = try #require(rebuilt["location_info"] as? [String: Any])
        #expect(rebuiltLocation["latitude"] as? Double == 40.8063)
        #expect(rebuiltLocation["longitude"] as? Double == -73.9632)
        #expect(rebuiltLocation["map_item_identifier"] as? String == "retry-map-item")
    }

    @Test func locationAndModePersistenceRoundTrip() throws {
        let defaults = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = SavedSurveyLocationStore(defaults: defaults)
        let location = makeLocation()

        try store.save(location, makeActive: true)
        store.mode = .fixed

        let reloaded = SavedSurveyLocationStore(defaults: defaults)
        #expect(reloaded.mode == .fixed)
        #expect(reloaded.activeLocation == location)
        #expect(reloaded.sortedLocations.first?.id == location.id)
    }

    @Test func deletingActiveLocationClearsSelectionWithoutChangingMode() throws {
        let defaults = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = SavedSurveyLocationStore(defaults: defaults)
        let location = makeLocation()
        try store.save(location, makeActive: true)
        store.mode = .fixed

        let deletedActive = try store.delete(id: location.id)

        #expect(deletedActive)
        #expect(store.activeLocation == nil)
        #expect(store.mode == .fixed)
    }

    @Test func fixedSessionSnapshotIsIndependentFromLaterEdits() throws {
        let original = makeLocation()
        let snapshot = SessionLocationInfo.fixed(original)
        var edited = original
        edited.name = "Renamed Later"
        edited.formattedAddress = "Different address"

        #expect(snapshot.mode == .fixed)
        #expect(snapshot.collectionMethod == "saved_survey_location")
        #expect(snapshot.locationName == "Research Site")
        #expect(snapshot.formattedAddress == "535 W 114th St")
        #expect(snapshot.mapItemIdentifier == "map-item-1")
        #expect(snapshot.locationName != edited.name)
    }

    @Test func noLocationSnapshotEncodesExplicitNullCoordinates() throws {
        let data = try JSONEncoder().encode(SessionLocationInfo.intentionallyDisabled)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["mode"] as? String == "none")
        #expect(json["collection_method"] as? String == "intentionally_not_collected")
        #expect(json["latitude"] is NSNull)
        #expect(json["longitude"] is NSNull)
    }

    @Test func olderManifestWithoutLocationInfoStillDecodes() throws {
        let data = Data("""
        {
          "local_session_id": "old-session",
          "location_status": "available",
          "location_source": "device_gps"
        }
        """.utf8)

        let manifest = try JSONDecoder().decode(LocalSessionManifest.self, from: data)
        #expect(manifest.locationInfo == nil)
        #expect(manifest.locationSource == .deviceGPS)
    }

    @Test func durablePackageWritesFixedSnapshotWithoutFakeTrajectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = makeLocation()
        var manifest = LocalSessionManifest(
            localSessionId: "fixed-package",
            audioFileName: "recording.m4a",
            locationInfo: .fixed(location),
            locationStatus: .available,
            locationSource: .savedSurveyLocation,
            locationCoordinates: LocalSessionCoordinateSnapshot(
                latitude: location.latitude,
                longitude: location.longitude
            ),
            locationLabel: location.name,
            placeSnapshot: LocalSessionPlaceSnapshot(
                displayLabel: location.name,
                formattedAddress: location.formattedAddress,
                latitude: location.latitude,
                longitude: location.longitude
            )
        )
        manifest.audioStatus = .recordedLocally
        try LocalSessionManifestStore.save(manifest, to: directory)
        try Data([0x01, 0x02]).write(to: directory.appendingPathComponent("recording.m4a"))

        let packageURL = try DurableSessionPackageFinalizer.finalize(
            sessionDirectoryURL: directory,
            transcript: "Interview transcript",
            matchedQuestions: []
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: packageURL)) as? [String: Any]
        )
        let locationInfo = try #require(json["location_info"] as? [String: Any])

        #expect(locationInfo["mode"] as? String == "fixed")
        #expect(locationInfo["collection_method"] as? String == "saved_survey_location")
        #expect(locationInfo["location_name"] as? String == "Research Site")
        #expect(locationInfo["map_item_identifier"] as? String == "map-item-1")
        #expect((json["trajectory_points"] as? [[String: Any]])?.isEmpty == true)
        #expect(json["recording_start_trajectory_point"] == nil)
    }

    @Test func nativeDashboardPrefersFixedLocationInfoWithCoordinates() throws {
        let result = LocalSessionDashboardLocationResolver.resolve(json: [
            "location_info": [
                "mode": "fixed",
                "collection_method": "saved_survey_location",
                "location_name": "Correct fixed site",
                "formatted_address": "1428 5th Ave, New York, NY",
                "latitude": 40.7991,
                "longitude": -73.9475
            ],
            "location": [
                "label": "Legacy duplicate",
                "latitude": 1.0,
                "longitude": 2.0
            ]
        ])

        #expect(result.label == "Correct fixed site")
        #expect(result.location?.mode == "fixed")
        #expect(result.location?.collectionMethod == "saved_survey_location")
        #expect(result.location?.formattedAddress == "1428 5th Ave, New York, NY")
        #expect(result.location?.latitude == 40.7991)
        #expect(result.location?.longitude == -73.9475)
    }

    @Test func nativeDashboardPreservesAddressOnlyFixedLocation() throws {
        let result = LocalSessionDashboardLocationResolver.resolve(json: [
            "location_info": [
                "mode": "fixed",
                "collection_method": "saved_survey_location",
                "location_name": "Canaan Senior Service Center",
                "formatted_address": "1428 5th Ave, New York, NY",
                "latitude": NSNull(),
                "longitude": NSNull()
            ]
        ])

        #expect(result.label == "Canaan Senior Service Center")
        #expect(result.location?.formattedAddress == "1428 5th Ave, New York, NY")
        #expect(result.location?.coordinate == nil)
    }

    private var defaultsSuiteName: String { "SavedSurveyLocationStoreTests" }

    private func temporaryDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }

    private func makeLocation() -> SavedSurveyLocation {
        SavedSurveyLocation(
            id: UUID(uuidString: "5D445D5B-E4B6-4B72-AB5B-42232C3D10D3")!,
            name: "Research Site",
            formattedAddress: "535 W 114th St",
            latitude: 40.8063,
            longitude: -73.9632,
            mapItemIdentifier: "map-item-1",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            lastUsedAt: nil
        )
    }
}

private enum StubResolutionError: Error {
    case offline
}

private struct StubAddressResolver: SurveyLocationAddressResolving {
    let result: Result<[SurveyLocationAddressCandidate], Error>

    func candidates(forTypedAddress address: String) async throws -> [SurveyLocationAddressCandidate] {
        try result.get()
    }
}
