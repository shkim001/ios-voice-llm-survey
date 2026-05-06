import Foundation
import CoreLocation
import UIKit

/// Minimal trajectory tracking:
/// - uses Significant Location Change (battery friendly)
/// - persists points locally
/// - uploads opportunistically when app is active (and also after each new point)
final class TrajectoryTracker: NSObject, CLLocationManagerDelegate {
    static let shared = TrajectoryTracker()
    
    private let manager = CLLocationManager()
    private var isTracking = false
    private var isFlushing = false
    
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

