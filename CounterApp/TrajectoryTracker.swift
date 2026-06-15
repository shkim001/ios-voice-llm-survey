import Foundation
import CoreLocation
import UIKit

/// Minimal trajectory tracking:
/// - uses Significant Location Change (battery friendly)
/// - captures a one-time GPS point when LLM answers are uploaded
/// - persists points locally
/// - uploads opportunistically when app is active (and also after each new point)
final class TrajectoryTracker: NSObject, CLLocationManagerDelegate {
    static let shared = TrajectoryTracker()

    private let manager = CLLocationManager()
    private var isTracking = false
    private var isFlushing = false
    private var lastKnownLocation: CLLocation?

    private override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = true
    }

    // MARK: - Public

    func startIfPossible() {
        guard SurveyAPIClient.shared.isConfigured() else { return }
        guard currentRespondentId() != nil else { return }

        ensureAuthorization()

        // Significant-change tracking can continue in the background with "Always" permission.
        if !isTracking {
            isTracking = true
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    func stop() {
        isTracking = false
        manager.stopMonitoringSignificantLocationChanges()
    }

    func flushPendingNow() {
        Task { [weak self] in
            await self?.flushLoop()
        }
    }

    func captureLLMRecognitionPointNow() async {
        guard SurveyAPIClient.shared.isConfigured() else { return }
        guard currentRespondentId() != nil else { return }

        do {
            let loc = try await OneShotLocationRequester.currentLocation()
            lastKnownLocation = loc
            await appendAndFlushLLMRecognitionPoint(from: loc, timestamp: loc.timestamp)
        } catch {
            if let fallback = bestCachedLocation(maxAgeSeconds: 10 * 60) {
                await appendAndFlushLLMRecognitionPoint(from: fallback, timestamp: Date())
                print("LLM recognition location capture used cached location after failure: \(error.localizedDescription)")
            } else {
                print("LLM recognition location capture failed: \(error.localizedDescription)")
            }
        }
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

        // Re-evaluate tracking state
        if respondentId == nil {
            stop()
        } else {
            startIfPossible()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            startIfPossible()
        case .authorizedWhenInUse:
            // Encourage upgrade to Always for background tracking
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        guard let respondentId = currentRespondentId() else { return }
        guard SurveyAPIClient.shared.isConfigured() else { return }
        lastKnownLocation = loc

        let point = PendingTrajectoryStore.Point(
            tsMs: Int64(loc.timestamp.timeIntervalSince1970 * 1000.0),
            lat: loc.coordinate.latitude,
            lon: loc.coordinate.longitude,
            accuracyM: loc.horizontalAccuracy >= 0 ? Double(loc.horizontalAccuracy) : nil,
            speedMps: loc.speed >= 0 ? Double(loc.speed) : nil,
            courseDeg: loc.course >= 0 ? Double(loc.course) : nil,
            provider: "significant-change",
            isBackground: UIApplication.shared.applicationState != .active,
            sessionId: currentSessionId()
        )

        PendingTrajectoryStore.shared.append(point)

        // Best-effort: attempt upload soon after capturing a point.
        Task { [weak self] in
            await self?.flushLoop()
        }

        _ = respondentId // keep for clarity; respondentId is used in flush
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

    private func ensureAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    private func bestCachedLocation(maxAgeSeconds: TimeInterval) -> CLLocation? {
        let candidates = [lastKnownLocation, manager.location].compactMap { $0 }
        return candidates
            .filter { isUsable($0, maxAgeSeconds: maxAgeSeconds) }
            .sorted { $0.timestamp > $1.timestamp }
            .first
    }

    private func isUsable(_ location: CLLocation, maxAgeSeconds: TimeInterval) -> Bool {
        guard CLLocationCoordinate2DIsValid(location.coordinate) else { return false }
        guard location.horizontalAccuracy >= 0 else { return false }
        return abs(location.timestamp.timeIntervalSinceNow) <= maxAgeSeconds
    }

    private func appendAndFlushLLMRecognitionPoint(from loc: CLLocation, timestamp: Date) async {
        let wasFlushing = isFlushing
        let point = PendingTrajectoryStore.Point(
            tsMs: Int64(timestamp.timeIntervalSince1970 * 1000.0),
            lat: loc.coordinate.latitude,
            lon: loc.coordinate.longitude,
            accuracyM: loc.horizontalAccuracy >= 0 ? Double(loc.horizontalAccuracy) : nil,
            speedMps: loc.speed >= 0 ? Double(loc.speed) : nil,
            courseDeg: loc.course >= 0 ? Double(loc.course) : nil,
            provider: "llm-recognition",
            isBackground: await MainActor.run { UIApplication.shared.applicationState != .active },
            sessionId: currentSessionId()
        )

        PendingTrajectoryStore.shared.append(point)

        if wasFlushing {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.flushLoop()
            }
        } else {
            await flushLoop()
        }
    }

    private func flushLoop() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        guard SurveyAPIClient.shared.isConfigured() else { return }
        guard let respondentId = currentRespondentId() else { return }

        // Upload up to N points per flush; keep looping briefly to reduce backlog.
        for _ in 0..<5 {
            let batch = PendingTrajectoryStore.shared.drain(max: 250)
            if batch.isEmpty { return }

            do {
                try await SurveyAPIClient.shared.postTrajectory(respondentId: respondentId, points: batch)
            } catch {
                PendingTrajectoryStore.shared.requeueFront(batch)
                return
            }
        }
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
