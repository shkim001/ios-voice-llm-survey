import Foundation
import CoreLocation
import UIKit

enum RecordingStartLocationFailure: Equatable {
    case permissionDenied
    case restricted
    case timedOut
    case unavailable
    case stale
    case lowAccuracy
}

struct RecordingStartLocationCandidate {
    let point: TrajectoryPoint
    let horizontalAccuracyM: Double
    let quality: LocalSessionLocationQuality
}

enum RecordingStartLocationOutcome {
    case acceptable(RecordingStartLocationCandidate)
    case lowAccuracy(RecordingStartLocationCandidate)
    case failure(RecordingStartLocationFailure)
}

enum RecordingStartLocationFallbackDecision: Equatable {
    case retryGPS
    case useLowAccuracyGPS
    case recordWithoutGPS
    case searchForPlace
    case cancelInterview
}

enum RecordingStartLocationStateMapping {
    static func manifestStatus(for failure: RecordingStartLocationFailure) -> LocalSessionLocationStatus {
        switch failure {
        case .permissionDenied, .restricted: return .permissionDenied
        case .timedOut: return .timedOut
        case .lowAccuracy: return .lowAccuracy
        case .unavailable, .stale: return .unavailable
        }
    }
}

/// Interview trajectory tracking:
/// - attempts a fresh GPS point before recording starts
/// - samples the latest available GPS location while recording
/// - uploads the saved recording-start point when a cloud identity exists
final class TrajectoryTracker: NSObject, CLLocationManagerDelegate {
    static let shared = TrajectoryTracker()
    static let recordingStartAccuracyThresholdM: CLLocationAccuracy = 50
    static let recordingStartMaximumAge: TimeInterval = 60

    private let manager = CLLocationManager()
    private let samplingInterval: TimeInterval = 15.0
    private var lastKnownLocation: CLLocation?
    private var interviewPoints: [TrajectoryPoint] = []
    private var samplingTimer: Timer?
    private var activeInterviewSessionId: String?

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
        manager.stopUpdatingLocation()
        samplingTimer?.invalidate()
        samplingTimer = nil
    }

    func flushPendingNow() {
        stop()
    }

    func captureRecordingStartLocation() async -> RecordingStartLocationOutcome {
        do {
            let location = try await OneShotLocationRequester.currentLocation()
            let isBackground = await MainActor.run { UIApplication.shared.applicationState != .active }
            let classification = Self.classifyRecordingStartLocation(
                location,
                sessionId: nil,
                isBackground: isBackground
            )
            switch classification {
            case .acceptable, .lowAccuracy:
                lastKnownLocation = location
            case .failure:
                break
            }
            return classification
        } catch let error as OneShotLocationError {
            switch error {
            case .permissionDenied: return .failure(.permissionDenied)
            case .restricted: return .failure(.restricted)
            case .timedOut: return .failure(.timedOut)
            case .unavailable: return .failure(.unavailable)
            }
        } catch {
            return .failure(.unavailable)
        }
    }

    static func classifyRecordingStartLocation(
        _ location: CLLocation,
        now: Date = Date(),
        sessionId: String? = nil,
        isBackground: Bool = false
    ) -> RecordingStartLocationOutcome {
        guard CLLocationCoordinate2DIsValid(location.coordinate), location.horizontalAccuracy >= 0 else {
            return .failure(.unavailable)
        }
        guard abs(location.timestamp.timeIntervalSince(now)) <= recordingStartMaximumAge else {
            return .failure(.stale)
        }

        let accuracy = Double(location.horizontalAccuracy)
        let quality: LocalSessionLocationQuality = accuracy <= 10 ? .high
            : (accuracy <= Double(recordingStartAccuracyThresholdM) ? .acceptable : .low)
        let point = TrajectoryPoint(
            tsMs: Int64(now.timeIntervalSince1970 * 1000.0),
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            accuracyM: accuracy,
            speedMps: location.speed >= 0 ? Double(location.speed) : nil,
            courseDeg: location.course >= 0 ? Double(location.course) : nil,
            provider: "recording-start",
            isBackground: isBackground,
            sessionId: sessionId
        )
        let candidate = RecordingStartLocationCandidate(
            point: point,
            horizontalAccuracyM: accuracy,
            quality: quality
        )
        return quality == .low ? .lowAccuracy(candidate) : .acceptable(candidate)
    }

    func startInterviewTracking(with startPoint: TrajectoryPoint?) {
        stopInterviewTracking()

        interviewPoints = startPoint.map { [$0] } ?? []
        guard let startPoint else { return }
        activeInterviewSessionId = startPoint.sessionId

        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false

        if CLLocationManager.locationServicesEnabled() {
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                break
            @unknown default:
                break
            }
        }

        let timer = Timer(timeInterval: samplingInterval, repeats: true) { [weak self] _ in
            self?.sampleLatestInterviewLocation()
        }
        samplingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult
    func stopInterviewTracking() -> [TrajectoryPoint] {
        if samplingTimer != nil {
            sampleLatestInterviewLocation()
        }
        samplingTimer?.invalidate()
        samplingTimer = nil
        manager.stopUpdatingLocation()
        activeInterviewSessionId = nil
        return interviewPoints
    }

    func currentInterviewPoints() -> [TrajectoryPoint] {
        return interviewPoints
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if samplingTimer == nil {
            stop()
            return
        }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
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

    private func sampleLatestInterviewLocation() {
        guard let loc = lastKnownLocation, isUsable(loc, maxAgeSeconds: 60) else { return }
        let point = makePoint(
            from: loc,
            timestamp: Date(),
            provider: "interview",
            isBackground: UIApplication.shared.applicationState != .active,
            sessionId: activeInterviewSessionId
        )
        interviewPoints.append(point)
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
    ) -> TrajectoryPoint {
        return TrajectoryPoint(
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
    case restricted
    case unavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Location permission was denied."
        case .restricted:
            return "Location access is restricted on this device."
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
        case .denied:
            finish(with: .failure(OneShotLocationError.permissionDenied))
        case .restricted:
            finish(with: .failure(OneShotLocationError.restricted))
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
        let locationError = error as? CLError
        if locationError?.code == .denied {
            switch manager.authorizationStatus {
            case .restricted:
                finish(with: .failure(OneShotLocationError.restricted))
            default:
                finish(with: .failure(OneShotLocationError.permissionDenied))
            }
        } else {
            finish(with: .failure(OneShotLocationError.unavailable))
        }
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
