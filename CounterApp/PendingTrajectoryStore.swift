import Foundation

final class PendingTrajectoryStore {
    static let shared = PendingTrajectoryStore()
    private init() {}
    
    struct Point: Codable {
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
    
    func append(_ point: Point) {
        var all = loadAll()
        all.append(point)
        saveAll(all)
    }
    
    func appendMany(_ points: [Point]) {
        guard !points.isEmpty else { return }
        var all = loadAll()
        all.append(contentsOf: points)
        saveAll(all)
    }
    
    func drain(max: Int) -> [Point] {
        let maxCount = Swift.max(1, Swift.min(max, 5000))
        var all = loadAll()
        guard !all.isEmpty else { return [] }
        let batch = Array(all.prefix(maxCount))
        all.removeFirst(batch.count)
        saveAll(all)
        return batch
    }
    
    func requeueFront(_ points: [Point]) {
        guard !points.isEmpty else { return }
        var all = loadAll()
        all.insert(contentsOf: points, at: 0)
        saveAll(all)
    }
    
    private func url() throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return docs.appendingPathComponent("pending_trajectory_points.json")
    }
    
    private func loadAll() -> [Point] {
        do {
            let u = try url()
            guard FileManager.default.fileExists(atPath: u.path) else { return [] }
            let data = try Data(contentsOf: u)
            return try JSONDecoder().decode([Point].self, from: data)
        } catch {
            return []
        }
    }
    
    private func saveAll(_ points: [Point]) {
        do {
            let u = try url()
            let data = try JSONEncoder().encode(points)
            try data.write(to: u, options: [.atomic])
        } catch {
            // best-effort
        }
    }
}

