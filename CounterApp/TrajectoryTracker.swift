import Foundation
import CoreLocation
import UIKit

/// Minimal trajectory tracking:
/// - captures a required one-time GPS point before recording starts
/// - uploads that saved point when a cloud respondent/session identity exists
final class TrajectoryTracker: NSObject, CLLocationManagerDelegate {
    static let shared = TrajectoryTracker()

    private let manager = CLLocationManager()
    private var lastKnownLocation: CLLocation?

    private override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = true
    }

    // MARK: - Public

    func startIfPossible() {
        stop()
    }

    func stop() {
        manager.stopMonitoringSignificantLocationChanges()
    }

    func flushPendingNow() {
        stop()
    }

    func captureRequiredRecordingStartPoint() async throws -> PendingTrajectoryStore.Point {
        let loc = try await OneShotLocationRequester.currentLocation()
        guard isUsable(loc, maxAgeSeconds: 60) else {
            throw OneShotLocationError.unavailable
        }

        lastKnownLocation = loc
        return makePoint(
            from: loc,
            timestamp: Date(),
            provider: "recording-start",
            isBackground: await MainActor.run { UIApplication.shared.applicationState != .active },
            sessionId: currentSessionId()
        )
    }

    func uploadRecordingStartPoint(_ point: PendingTrajectoryStore.Point) async throws {
        guard SurveyAPIClient.shared.isConfigured() else { return }
        guard let respondentId = currentRespondentId() else { return }
        try await SurveyAPIClient.shared.postTrajectory(respondentId: respondentId, points: [point])
    }

    func setCurrentIdentity(respondentId: String?, sessionId: String?) {
        if let respondentId {
            UserDefaults.standard.set(respondentId, forKey: DefaultsKeys.respondentId)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.respondentId)
        }
        if let sessionId {
            UserDefaults.standard.set(sessionId, forKey: DefaultsKeys.sessionId)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.sessionId)
        }

        if respondentId == nil {
            stop()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        stop()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastKnownLocation = loc
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Best-effort: don't spam UI; logs help debugging.
        print("TrajectoryTracker location error: \(error.localizedDescription)")
    }

    // MARK: - Internals

    private enum DefaultsKeys {
        static let respondentId = "SurveyAPI_CurrentRespondentID"
        static let sessionId = "SurveyAPI_CurrentSessionID"
    }

    private func currentRespondentId() -> String? {
        let id = UserDefaults.standard.string(forKey: DefaultsKeys.respondentId)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false) ? id : nil
    }

    private func currentSessionId() -> String? {
        let id = UserDefaults.standard.string(forKey: DefaultsKeys.sessionId)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false) ? id : nil
    }

    private func isUsable(_ location: CLLocation, maxAgeSeconds: TimeInterval) -> Bool {
        guard CLLocationCoordinate2DIsValid(location.coordinate) else { return false }
        guard location.horizontalAccuracy >= 0 else { return false }
        return abs(location.timestamp.timeIntervalSinceNow) <= maxAgeSeconds
    }

    private func makePoint(
        from loc: CLLocation,
        timestamp: Date,
        provider: String,
        isBackground: Bool,
        sessionId: String?
    ) -> PendingTrajectoryStore.Point {
        return PendingTrajectoryStore.Point(
            tsMs: Int64(timestamp.timeIntervalSince1970 * 1000.0),
            lat: loc.coordinate.latitude,
            lon: loc.coordinate.longitude,
            accuracyM: loc.horizontalAccuracy >= 0 ? Double(loc.horizontalAccuracy) : nil,
            speedMps: loc.speed >= 0 ? Double(loc.speed) : nil,
            courseDeg: loc.course >= 0 ? Double(loc.course) : nil,
            provider: provider,
            isBackground: isBackground,
            sessionId: sessionId
        )
    }
}

private enum OneShotLocationError: LocalizedError {
    case permissionDenied
    case unavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Location permission is not available."
        case .unavailable:
            return "Unable to get a current location."
        case .timedOut:
            return "Timed out while requesting current location."
        }
    }
}

@MainActor
private final class OneShotLocationRequester: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?

    static func currentLocation(timeoutSeconds: TimeInterval = 10) async throws -> CLLocation {
        let requester = OneShotLocationRequester(timeoutSeconds: timeoutSeconds)
        return try await requester.request()
    }

    private init(timeoutSeconds: TimeInterval) {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        timeoutTask = Task { [weak self] in
            let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await self?.finish(with: .failure(OneShotLocationError.timedOut))
        }
    }

    private func request() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            requestLocationWhenAuthorized()
        }
    }

    private func requestLocationWhenAuthorized() {
        guard CLLocationManager.locationServicesEnabled() else {
            finish(with: .failure(OneShotLocationError.unavailable))
            return
        }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(with: .failure(OneShotLocationError.permissionDenied))
        @unknown default:
            finish(with: .failure(OneShotLocationError.unavailable))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        requestLocationWhenAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(with: .failure(OneShotLocationError.unavailable))
            return
        }
        finish(with: .success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil

        switch result {
        case .success(let location):
            continuation.resume(returning: location)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
