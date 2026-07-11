import Foundation

final class SurveyAPIClient {
    static let shared = SurveyAPIClient()
    private init() {}
    
    // MARK: - Settings
    
    private enum DefaultsKeys {
        static let surveyAPIBaseURL = "SurveyAPI_Base_URL"
        static let surveyAPIKey = "SurveyAPI_Key"
    }
    
    var baseURLString: String {
        get { UserDefaults.standard.string(forKey: DefaultsKeys.surveyAPIBaseURL) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: DefaultsKeys.surveyAPIBaseURL)
        }
    }
    
    var apiKey: String {
        get { UserDefaults.standard.string(forKey: DefaultsKeys.surveyAPIKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: DefaultsKeys.surveyAPIKey)
        }
    }
    
    func isConfigured() -> Bool {
        return !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    // MARK: - Models
    
    struct SessionCreateRequest: Encodable {
        let questionnaireVersion: String
        let appVersion: String?
        let locale: String?
        let respondentId: String?
        
        enum CodingKeys: String, CodingKey {
            case questionnaireVersion = "questionnaire_version"
            case appVersion = "app_version"
            case locale
            case respondentId = "respondent_id"
        }
    }
    
    struct SessionCreateResponse: Decodable {
        let respondentId: String
        let sessionId: String
        let questionnaireVersion: String
        
        enum CodingKeys: String, CodingKey {
            case respondentId = "respondent_id"
            case sessionId = "session_id"
            case questionnaireVersion = "questionnaire_version"
        }
    }
    
    struct AnswersBatch: Encodable {
        let answers: [AnswerItem]
    }
    
    struct AnswerItem: Encodable {
        let questionId: String
        let value: AnyJSON
        
        enum CodingKeys: String, CodingKey {
            case questionId = "question_id"
            case value
        }
    }
    
    // MARK: - API
    
    func createSession(questionnaireVersion: String, appVersion: String?, locale: String?) async throws -> SessionCreateResponse {
        let body = SessionCreateRequest(
            questionnaireVersion: questionnaireVersion,
            appVersion: appVersion,
            locale: locale,
            respondentId: nil
        )
        return try await requestJSON(
            method: "POST",
            path: "/sessions",
            body: body,
            responseType: SessionCreateResponse.self
        )
    }
    
    func postAnswers(sessionId: String, answers: [[String: Any]]) async throws {
        let items = answers.map { dict -> AnswerItem in
            let qid = (dict["question_id"] as? String) ?? ""
            let value = dict["value"] as? [String: Any] ?? [:]
            return AnswerItem(questionId: qid, value: AnyJSON(value))
        }.filter { !$0.questionId.isEmpty }
        
        let body = AnswersBatch(answers: items)
        _ = try await requestData(
            method: "POST",
            path: "/sessions/\(sessionId)/answers",
            body: body
        )
    }

    struct TrajectoryBatch: Encodable {
        let points: [PendingTrajectoryStore.Point]
    }

    struct AudioUploadResponse: Decodable {
        let id: Int
        let sessionId: String
        let filename: String
        let storagePath: String
        let fileSizeBytes: Int
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case id
            case sessionId = "session_id"
            case filename
            case storagePath = "storage_path"
            case fileSizeBytes = "file_size_bytes"
            case sha256
        }
    }

    struct SessionPackageUploadResponse: Decodable {
        let sessionId: String
        let respondentId: String
        let packageDir: String
        let jsonPath: String
        let audioPath: String?
        let jsonFileSizeBytes: Int
        let audioFileSizeBytes: Int?
        let jsonSha256: String
        let audioSha256: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case respondentId = "respondent_id"
            case packageDir = "package_dir"
            case jsonPath = "json_path"
            case audioPath = "audio_path"
            case jsonFileSizeBytes = "json_file_size_bytes"
            case audioFileSizeBytes = "audio_file_size_bytes"
            case jsonSha256 = "json_sha256"
            case audioSha256 = "audio_sha256"
        }
    }

    struct AdminSessionListResponse: Codable {
        let sessions: [AdminSessionSummary]
        let count: Int
    }

    struct AdminSessionSummary: Codable {
        let sessionId: String
        let cloudSessionId: String?
        let localSessionId: String?
        let createdAt: String?
        let exportTime: String?
        let uploadedAt: String?
        let respondentName: String?
        let respondentLocation: String?
        let locationLabel: String?
        let questionnaireTitle: String?
        let answerCount: Int?
        let trajectoryPointCount: Int?
        let audioFilename: String?
        let recordedAtMs: Int?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cloudSessionId = "cloud_session_id"
            case localSessionId = "local_session_id"
            case createdAt = "created_at"
            case exportTime = "export_time"
            case uploadedAt = "uploaded_at"
            case respondentName = "respondent_name"
            case respondentLocation = "respondent_location"
            case locationLabel = "location_label"
            case questionnaireTitle = "questionnaire_title"
            case answerCount = "answer_count"
            case trajectoryPointCount = "trajectory_point_count"
            case audioFilename = "audio_filename"
            case recordedAtMs = "recorded_at_ms"
        }
    }
    
    func postTrajectory(respondentId: String, points: [PendingTrajectoryStore.Point]) async throws {
        let body = TrajectoryBatch(points: points)
        _ = try await requestData(
            method: "POST",
            path: "/respondents/\(respondentId)/trajectory",
            body: body
        )
    }

    func uploadAudio(
        sessionId: String,
        fileURL: URL,
        recordedAtMs: Int?,
        localSessionId: String?
    ) async throws -> AudioUploadResponse {
        let url = try makeURL(path: "/sessions/\(sessionId)/audio")
        let boundary = "Boundary-\(UUID().uuidString)"
        let filename = fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL)

        var body = Data()
        appendFormField(name: "recorded_at_ms", value: recordedAtMs.map(String.init), to: &body, boundary: boundary)
        appendFormField(name: "local_session_id", value: localSessionId, to: &body, boundary: boundary)
        appendFileField(
            name: "file",
            filename: filename,
            contentType: "audio/mp4",
            data: fileData,
            to: &body,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        req.timeoutInterval = 120.0

        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw SurveyAPIError.invalidHTTPResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SurveyAPIError.httpError(statusCode: http.statusCode, bodyPreview: String(raw.prefix(500)))
        }

        do {
            return try JSONDecoder().decode(AudioUploadResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SurveyAPIError.decodingFailed(rawPreview: String(raw.prefix(300)))
        }
    }

    func uploadSessionPackage(
        sessionId: String,
        sessionJSONURL: URL,
        audioURL: URL?,
        localSessionId: String?
    ) async throws -> SessionPackageUploadResponse {
        let url = try makeURL(path: "/sessions/\(sessionId)/package")
        let boundary = "Boundary-\(UUID().uuidString)"
        let sessionJSONData = try Data(contentsOf: sessionJSONURL)

        var body = Data()
        appendFormField(name: "local_session_id", value: localSessionId, to: &body, boundary: boundary)
        appendFileField(
            name: "session_json",
            filename: sessionJSONURL.lastPathComponent,
            contentType: "application/json",
            data: sessionJSONData,
            to: &body,
            boundary: boundary
        )

        if let audioURL {
            let audioData = try Data(contentsOf: audioURL)
            appendFileField(
                name: "audio",
                filename: audioURL.lastPathComponent,
                contentType: "audio/mp4",
                data: audioData,
                to: &body,
                boundary: boundary
            )
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        req.timeoutInterval = 120.0

        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw SurveyAPIError.invalidHTTPResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SurveyAPIError.httpError(statusCode: http.statusCode, bodyPreview: String(raw.prefix(500)))
        }

        do {
            return try JSONDecoder().decode(SessionPackageUploadResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SurveyAPIError.decodingFailed(rawPreview: String(raw.prefix(300)))
        }
    }

    func listAdminSessions() async throws -> AdminSessionListResponse {
        let data = try await requestData(method: "GET", path: "/admin/sessions")
        do {
            return try JSONDecoder().decode(AdminSessionListResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SurveyAPIError.decodingFailed(rawPreview: String(raw.prefix(300)))
        }
    }

    func fetchAdminSessionPackage(sessionId: String) async throws -> Data {
        try await requestData(method: "GET", path: "/admin/sessions/\(sessionId)")
    }
    
    // MARK: - Networking internals
    
    private func makeURL(path: String) throws -> URL {
        let base = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            throw SurveyAPIError.notConfigured
        }
        
        var normalizedBase = base
        if normalizedBase.hasSuffix("/") { normalizedBase.removeLast() }
        
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: normalizedBase + normalizedPath) else {
            throw SurveyAPIError.invalidBaseURL
        }
        return url
    }
    
    private func makeRequest(method: String, url: URL, bodyData: Data?) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        req.httpBody = bodyData
        req.timeoutInterval = 20.0
        return req
    }
    
    private func requestJSON<T: Decodable, B: Encodable>(
        method: String,
        path: String,
        body: B,
        responseType: T.Type
    ) async throws -> T {
        let data = try await requestData(method: method, path: path, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SurveyAPIError.decodingFailed(rawPreview: String(raw.prefix(300)))
        }
    }
    
    private func requestData<B: Encodable>(method: String, path: String, body: B) async throws -> Data {
        let url = try makeURL(path: path)
        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(body)
        
        let req = makeRequest(method: method, url: url, bodyData: bodyData)
        let (data, response) = try await URLSession.shared.data(for: req)
        
        guard let http = response as? HTTPURLResponse else {
            throw SurveyAPIError.invalidHTTPResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SurveyAPIError.httpError(statusCode: http.statusCode, bodyPreview: String(raw.prefix(500)))
        }
        return data
    }

    private func requestData(method: String, path: String) async throws -> Data {
        let url = try makeURL(path: path)
        let req = makeRequest(method: method, url: url, bodyData: nil)
        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw SurveyAPIError.invalidHTTPResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SurveyAPIError.httpError(statusCode: http.statusCode, bodyPreview: String(raw.prefix(500)))
        }
        return data
    }

    private func appendFormField(name: String, value: String?, to body: inout Data, boundary: String) {
        guard let value, !value.isEmpty else { return }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private func appendFileField(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        to body: inout Data,
        boundary: String
    ) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }
}

// MARK: - Errors

enum SurveyAPIError: LocalizedError {
    case notConfigured
    case invalidBaseURL
    case invalidHTTPResponse
    case httpError(statusCode: Int, bodyPreview: String)
    case decodingFailed(rawPreview: String)
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Survey API is not configured. Set Survey API Base URL in Settings."
        case .invalidBaseURL:
            return "Survey API base URL is invalid."
        case .invalidHTTPResponse:
            return "Invalid HTTP response from Survey API."
        case .httpError(let status, let preview):
            return "Survey API error (HTTP \(status)).\n\n\(preview)"
        case .decodingFailed(let preview):
            return "Failed to decode Survey API response.\n\n\(preview)"
        }
    }
}

// MARK: - AnyJSON (minimal heterogeneous JSON encoder)

struct AnyJSON: Encodable {
    private let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let v as String:
            try container.encode(v)
        case let v as Bool:
            try container.encode(v)
        case let v as Int:
            try container.encode(v)
        case let v as Double:
            try container.encode(v)
        case let v as Float:
            try container.encode(v)
        case let v as [String: Any]:
            try container.encode(v.mapValues { AnyJSON($0) })
        case let v as [Any]:
            try container.encode(v.map { AnyJSON($0) })
        default:
            // Fallback: best-effort stringification to avoid crashing uploads
            try container.encode(String(describing: value))
        }
    }
}
