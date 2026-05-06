import Foundation

final class PendingSurveyUploadStore {
    static let shared = PendingSurveyUploadStore()
    private init() {}
    
    struct PendingBatch: Codable {
        let sessionId: String
        let createdAt: TimeInterval
        let answers: [PendingAnswerItem]
    }
    
    struct PendingAnswerItem: Codable {
        let questionId: String
        let value: [String: AnyCodable]
        
        enum CodingKeys: String, CodingKey {
            case questionId = "question_id"
            case value
        }
    }
    
    func enqueue(sessionId: String, answers: [[String: Any]]) {
        let items: [PendingAnswerItem] = answers.compactMap { dict in
            guard let qid = dict["question_id"] as? String, !qid.isEmpty else { return nil }
            let value = dict["value"] as? [String: Any] ?? [:]
            let wrapped = value.mapValues { AnyCodable($0) }
            return PendingAnswerItem(questionId: qid, value: wrapped)
        }
        
        guard !items.isEmpty else { return }
        
        let batch = PendingBatch(sessionId: sessionId, createdAt: Date().timeIntervalSince1970, answers: items)
        var all = loadAll()
        all.append(batch)
        saveAll(all)
    }
    
    func drain() -> [PendingBatch] {
        let all = loadAll()
        saveAll([])
        return all
    }
    
    func requeue(_ batch: PendingBatch) {
        var all = loadAll()
        all.append(batch)
        saveAll(all)
    }
    
    private func url() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return docs.appendingPathComponent("pending_survey_uploads.json")
    }
    
    private func loadAll() -> [PendingBatch] {
        do {
            let u = try url()
            guard FileManager.default.fileExists(atPath: u.path) else { return [] }
            let data = try Data(contentsOf: u)
            return try JSONDecoder().decode([PendingBatch].self, from: data)
        } catch {
            return []
        }
    }
    
    private func saveAll(_ batches: [PendingBatch]) {
        do {
            let u = try url()
            let data = try JSONEncoder().encode(batches)
            try data.write(to: u, options: [.atomic])
        } catch {
            // best-effort
        }
    }
}

struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else {
            value = NSNull()
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        default:
            try container.encode(String(describing: value))
        }
    }
}

