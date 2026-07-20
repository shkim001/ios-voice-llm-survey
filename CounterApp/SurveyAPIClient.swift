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
        let questionnaireId: String?
        let appVersion: String?
        let locale: String?
        let respondentId: String?
        let localSessionId: String?
        
        enum CodingKeys: String, CodingKey {
            case questionnaireVersion = "questionnaire_version"
            case questionnaireId = "questionnaire_id"
            case appVersion = "app_version"
            case locale
            case respondentId = "respondent_id"
            case localSessionId = "local_session_id"
        }
    }
    
    struct SessionCreateResponse: Decodable {
        let respondentId: String
        let sessionId: String
        let questionnaireVersion: String
        let questionnaireId: String?
        
        enum CodingKeys: String, CodingKey {
            case respondentId = "respondent_id"
            case sessionId = "session_id"
            case questionnaireVersion = "questionnaire_version"
            case questionnaireId = "questionnaire_id"
        }
    }
    
    struct InterviewerResolveRequest: Encodable {
        let name: String
        let email: String
    }

    struct InterviewerResolveResponse: Codable {
        let interviewerId: String
        let name: String
        let email: String
        let identityScope: String

        enum CodingKeys: String, CodingKey {
            case interviewerId = "interviewer_id"
            case name
            case email
            case identityScope = "identity_scope"
        }

        var profile: InterviewerProfile {
            InterviewerProfile(
                interviewerId: interviewerId,
                name: name,
                email: email,
                identityScope: identityScope
            )
        }
    }
    
    // MARK: - API
    
    func createSession(
        questionnaireId: String?,
        questionnaireVersion: String,
        appVersion: String?,
        locale: String?,
        localSessionId: String? = nil
    ) async throws -> SessionCreateResponse {
        let body = SessionCreateRequest(
            questionnaireVersion: questionnaireVersion,
            questionnaireId: questionnaireId,
            appVersion: appVersion,
            locale: locale,
            respondentId: nil,
            localSessionId: localSessionId
        )
        return try await requestJSON(
            method: "POST",
            path: "/sessions",
            body: body,
            responseType: SessionCreateResponse.self
        )
    }

    func fetchActiveQuestionnaires() async throws -> [Questionnaire] {
        let data = try await requestData(method: "GET", path: "/questionnaires/active")
        let response = try JSONDecoder().decode(QuestionnaireListResponse.self, from: data)
        return response.questionnaires
    }

    func resolveInterviewer(name: String, email: String) async throws -> InterviewerResolveResponse {
        let body = InterviewerResolveRequest(name: name, email: email)
        return try await requestJSON(
            method: "POST",
            path: "/interviewers/resolve",
            body: body,
            responseType: InterviewerResolveResponse.self
        )
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

    struct ProcessingClarification: Codable, Equatable {
        let clarificationId: String
        let matchedIndex: Int
        let questionPart: String?
        let questionId: Int?
        let questionText: String?
        let answerType: String
        let modelAnswer: String?
        let confidence: String?
        let transcriptSegment: String
        let allowedAnswers: [String]
        let allowsMultiple: Bool

        enum CodingKeys: String, CodingKey {
            case clarificationId = "clarification_id"
            case matchedIndex = "matched_index"
            case questionPart = "question_part"
            case questionId = "question_id"
            case questionText = "question_text"
            case answerType = "answer_type"
            case modelAnswer = "model_answer"
            case confidence
            case transcriptSegment = "transcript_segment"
            case allowedAnswers = "allowed_answers"
            case allowsMultiple = "allows_multiple"
        }
    }

    struct ProcessingJobResponse: Codable, Equatable {
        let sessionId: String
        let respondentId: String
        let localSessionId: String
        let status: String
        let revision: Int
        let attemptCount: Int
        let errorCategory: String?
        let errorMessage: String?
        let resultAvailable: Bool
        let clarifications: [ProcessingClarification]

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case respondentId = "respondent_id"
            case localSessionId = "local_session_id"
            case status
            case revision
            case attemptCount = "attempt_count"
            case errorCategory = "error_category"
            case errorMessage = "error_message"
            case resultAvailable = "result_available"
            case clarifications
        }
    }

    struct ClarificationAnswerRequest: Encodable {
        let clarificationId: String
        let matchedIndex: Int
        let finalAnswer: String
        let note: String?
        let selectedOptionCodes: [String]?
        let selectedOptionLabels: [String]?
        let useOriginalAnswer: Bool

        enum CodingKeys: String, CodingKey {
            case clarificationId = "clarification_id"
            case matchedIndex = "matched_index"
            case finalAnswer = "final_answer"
            case note
            case selectedOptionCodes = "selected_option_codes"
            case selectedOptionLabels = "selected_option_labels"
            case useOriginalAnswer = "use_original_answer"
        }
    }

    private struct ClarificationSubmissionRequest: Encodable {
        let expectedRevision: Int
        let answers: [ClarificationAnswerRequest]

        enum CodingKeys: String, CodingKey {
            case expectedRevision = "expected_revision"
            case answers
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
        let interviewerId: String?
        let interviewerName: String?
        let interviewerEmail: String?
        let locationLabel: String?
        let questionnaireId: String?
        let questionnaireVersion: String?
        let questionnaireTitle: String?
        let questionnaireHash: String?
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
            case interviewerId = "interviewer_id"
            case interviewerName = "interviewer_name"
            case interviewerEmail = "interviewer_email"
            case locationLabel = "location_label"
            case questionnaireId = "questionnaire_id"
            case questionnaireVersion = "questionnaire_version"
            case questionnaireTitle = "questionnaire_title"
            case questionnaireHash = "questionnaire_hash"
            case answerCount = "answer_count"
            case trajectoryPointCount = "trajectory_point_count"
            case audioFilename = "audio_filename"
            case recordedAtMs = "recorded_at_ms"
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

    func uploadProcessingInput(
        sessionId: String,
        inputManifestURL: URL,
        audioURL: URL,
        localSessionId: String
    ) async throws -> ProcessingJobResponse {
        let url = try makeURL(path: "/sessions/\(sessionId)/processing-input")
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        appendFormField(name: "local_session_id", value: localSessionId, to: &body, boundary: boundary)
        appendFileField(
            name: "input_manifest",
            filename: inputManifestURL.lastPathComponent,
            contentType: "application/json",
            data: try Data(contentsOf: inputManifestURL),
            to: &body,
            boundary: boundary
        )
        appendFileField(
            name: "audio",
            filename: audioURL.lastPathComponent,
            contentType: "audio/mp4",
            data: try Data(contentsOf: audioURL),
            to: &body,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }
        request.timeoutInterval = 180
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        return try decodeResponse(ProcessingJobResponse.self, data: data, response: response)
    }

    func fetchProcessingJob(sessionId: String) async throws -> ProcessingJobResponse {
        let data = try await requestData(method: "GET", path: "/processing-jobs/\(sessionId)")
        do {
            return try JSONDecoder().decode(ProcessingJobResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SurveyAPIError.decodingFailed(rawPreview: String(raw.prefix(300)))
        }
    }

    func fetchProcessingResult(sessionId: String) async throws -> Data {
        try await requestData(method: "GET", path: "/processing-jobs/\(sessionId)/result")
    }

    func retryProcessingJob(sessionId: String) async throws -> ProcessingJobResponse {
        let data = try await requestData(method: "POST", path: "/processing-jobs/\(sessionId)/retry")
        do {
            return try JSONDecoder().decode(ProcessingJobResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SurveyAPIError.decodingFailed(rawPreview: String(raw.prefix(300)))
        }
    }

    func submitProcessingClarifications(
        sessionId: String,
        expectedRevision: Int,
        answers: [ClarificationAnswerRequest]
    ) async throws -> ProcessingJobResponse {
        try await requestJSON(
            method: "POST",
            path: "/processing-jobs/\(sessionId)/clarifications",
            body: ClarificationSubmissionRequest(expectedRevision: expectedRevision, answers: answers),
            responseType: ProcessingJobResponse.self
        )
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

    private func decodeResponse<T: Decodable>(
        _ type: T.Type,
        data: Data,
        response: URLResponse
    ) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw SurveyAPIError.invalidHTTPResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SurveyAPIError.httpError(statusCode: http.statusCode, bodyPreview: String(raw.prefix(500)))
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw SurveyAPIError.decodingFailed(rawPreview: String(raw.prefix(300)))
        }
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
