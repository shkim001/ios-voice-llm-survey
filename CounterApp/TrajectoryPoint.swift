import Foundation

struct TrajectoryPoint: Codable, Equatable {
    let tsMs: Int64
    let lat: Double
    let lon: Double
    let accuracyM: Double?
    let speedMps: Double?
    let courseDeg: Double?
    let provider: String?
    let isBackground: Bool?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case tsMs = "ts_ms"
        case lat
        case lon
        case accuracyM = "accuracy_m"
        case speedMps = "speed_mps"
        case courseDeg = "course_deg"
        case provider
        case isBackground = "is_background"
        case sessionId = "session_id"
    }
}
