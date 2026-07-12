import MapKit
import UIKit

struct LocalSessionDashboardSession {
    enum Source {
        case local
        case cachedServer
    }

    struct TrajectoryPoint {
        let latitude: Double
        let longitude: Double
        let timestampMs: Int64?
        let capturedAt: String?
    }

    struct MatchedAnswer {
        let questionId: Int?
        let question: String
        let answer: String
        let confidence: String?
    }

    let localSessionId: String
    let packageURL: URL
    let directoryURL: URL
    let createdAt: Date
    let locationLabel: String
    let respondentName: String?
    let interviewerId: String?
    let interviewerName: String?
    let interviewerEmail: String?
    let audioFileName: String?
    let isUploaded: Bool
    let transcription: String
    let matchedAnswers: [MatchedAnswer]
    let trajectoryPoints: [TrajectoryPoint]
    let source: Source
    let serverSessionId: String?

    var titleText: String {
        if let respondentName, !respondentName.isEmpty {
            return respondentName
        }
        return localSessionId
    }

    var sourceLabel: String {
        switch source {
        case .local:
            return isUploaded ? "Local + uploaded" : "Local"
        case .cachedServer:
            return "Cached"
        }
    }
}

enum LocalSessionDashboardLibrary {
    struct ServerSessionSummary {
        let sessionId: String
        let localSessionId: String?
        let createdAt: Date?
        let createdAtLabel: String?
        let respondentName: String?
        let interviewerName: String?
        let interviewerEmail: String?
        let locationLabel: String
        let answerCount: Int?
        let trajectoryPointCount: Int?
        let audioFilename: String?
    }

    static func loadSessions() -> [LocalSessionDashboardSession] {
        loadLocalSessions() + loadCachedServerSessions()
    }

    static func loadLocalSessions() -> [LocalSessionDashboardSession] {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionsRoot = documents.appendingPathComponent("SurveySessions", isDirectory: true)
        guard let sessionDirs = try? fm.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return sessionDirs
            .compactMap { loadSession(in: $0, source: .local, serverSessionId: nil) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func loadCachedServerSessions() -> [LocalSessionDashboardSession] {
        let fm = FileManager.default
        guard let cacheRoot = try? cacheRootDirectory(),
              let sessionDirs = try? fm.contentsOfDirectory(
                at: cacheRoot,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return sessionDirs
            .compactMap { loadSession(in: $0, source: .cachedServer, serverSessionId: $0.lastPathComponent) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func cachedSession(serverSessionId: String) -> LocalSessionDashboardSession? {
        guard let url = try? cacheDirectory(for: serverSessionId) else { return nil }
        return loadSession(in: url, source: .cachedServer, serverSessionId: serverSessionId)
    }

    static func saveServerPackage(data: Data, serverSessionId: String) throws -> LocalSessionDashboardSession {
        _ = try JSONSerialization.jsonObject(with: data)
        let directory = try cacheDirectory(for: serverSessionId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let packageURL = directory.appendingPathComponent("session.json")
        try data.write(to: packageURL, options: [.atomic])
        guard let session = loadSession(in: directory, source: .cachedServer, serverSessionId: serverSessionId) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return session
    }

    static func deleteLocalCopy(_ session: LocalSessionDashboardSession) throws {
        let fm = FileManager.default
        switch session.source {
        case .local, .cachedServer:
            if fm.fileExists(atPath: session.directoryURL.path) {
                try fm.removeItem(at: session.directoryURL)
            }
        }
    }

    static func loadCachedServerSummaries() -> [ServerSessionSummary] {
        guard let url = try? serverListCacheURL(),
              let data = try? Data(contentsOf: url),
              let response = try? JSONDecoder().decode(SurveyAPIClient.AdminSessionListResponse.self, from: data) else {
            return []
        }
        return response.sessions.map(serverSummary)
    }

    static func saveServerSummaries(_ response: SurveyAPIClient.AdminSessionListResponse) {
        guard let url = try? serverListCacheURL(),
              let data = try? JSONEncoder().encode(AdminSessionListCache(response: response)) else {
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try? data.write(to: url, options: [.atomic])
    }

    static func serverSummaries(from response: SurveyAPIClient.AdminSessionListResponse) -> [ServerSessionSummary] {
        response.sessions.map(serverSummary)
    }

    private static func loadSession(
        in directoryURL: URL,
        source: LocalSessionDashboardSession.Source,
        serverSessionId: String?
    ) -> LocalSessionDashboardSession? {
        let packageURL = directoryURL.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let metadata = json["metadata"] as? [String: Any]
        let cloud = metadata?["cloud"] as? [String: Any]
        let interviewer = json["interviewer_info"] as? [String: Any]
        let respondent = json["respondent_info"] as? [String: Any]
        let audio = json["audio"] as? [String: Any]
        let rawAnswers = json["matched_questions"] as? [[String: Any]] ?? []
        let rawTrajectory = json["trajectory_points"] as? [[String: Any]] ?? []

        let localSessionId = nonEmptyString(json["local_session_id"])
            ?? nonEmptyString(metadata?["local_session_id"])
            ?? directoryURL.lastPathComponent
        let timestamp = doubleValue(json["timestamp"])
            ?? doubleValue(metadata?["timestamp"])
        let createdAt = timestamp.map { Date(timeIntervalSince1970: $0) }
            ?? resourceDate(for: packageURL)
            ?? resourceDate(for: directoryURL)
            ?? .distantPast

        let locationLabel = nonEmptyString(json["location_label"])
            ?? nonEmptyString(respondent?["location"])
            ?? "Unknown Location"
        let respondentName = nonEmptyString(respondent?["name"])
        let interviewerId = nonEmptyString(interviewer?["interviewer_id"])
            ?? nonEmptyString(interviewer?["email"])
        let interviewerName = nonEmptyString(interviewer?["name"])
        let interviewerEmail = nonEmptyString(interviewer?["email"])
        let audioFileName = nonEmptyString(audio?["file_name"])
        let transcription = nonEmptyString(json["transcription"]) ?? ""
        let isUploaded = recordingMetadata(in: directoryURL, audioFileName: audioFileName)?["session_package_uploaded_at_epoch"] != nil

        let answers = rawAnswers.map { raw in
            LocalSessionDashboardSession.MatchedAnswer(
                questionId: intValue(raw["matched_question_id"]),
                question: nonEmptyString(raw["matched_question"]) ?? "Question",
                answer: nonEmptyString(raw["extracted_answer"]) ?? "",
                confidence: nonEmptyString(raw["confidence"])
            )
        }

        let trajectoryPoints = rawTrajectory.compactMap { raw -> LocalSessionDashboardSession.TrajectoryPoint? in
            guard let lat = doubleValue(raw["lat"]),
                  let lon = doubleValue(raw["lon"]),
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else {
                return nil
            }

            return LocalSessionDashboardSession.TrajectoryPoint(
                latitude: lat,
                longitude: lon,
                timestampMs: int64Value(raw["ts_ms"]),
                capturedAt: nonEmptyString(raw["captured_at"])
            )
        }

        return LocalSessionDashboardSession(
            localSessionId: localSessionId,
            packageURL: packageURL,
            directoryURL: directoryURL,
            createdAt: createdAt,
            locationLabel: locationLabel,
            respondentName: respondentName,
            interviewerId: interviewerId,
            interviewerName: interviewerName,
            interviewerEmail: interviewerEmail,
            audioFileName: audioFileName,
            isUploaded: isUploaded,
            transcription: transcription,
            matchedAnswers: answers,
            trajectoryPoints: trajectoryPoints,
            source: source,
            serverSessionId: serverSessionId ?? nonEmptyString(cloud?["session_id"])
        )
    }

    private struct AdminSessionListCache: Encodable {
        let sessions: [SurveyAPIClient.AdminSessionSummary]
        let count: Int

        init(response: SurveyAPIClient.AdminSessionListResponse) {
            sessions = response.sessions
            count = response.count
        }
    }

    private static func serverSummary(_ summary: SurveyAPIClient.AdminSessionSummary) -> ServerSessionSummary {
        let createdLabel = summary.createdAt ?? summary.exportTime ?? summary.uploadedAt
        return ServerSessionSummary(
            sessionId: summary.sessionId,
            localSessionId: summary.localSessionId,
            createdAt: dateValue(createdLabel),
            createdAtLabel: createdLabel,
            respondentName: summary.respondentName,
            interviewerName: summary.interviewerName,
            interviewerEmail: summary.interviewerEmail,
            locationLabel: nonEmptyString(summary.locationLabel)
                ?? nonEmptyString(summary.respondentLocation)
                ?? "Unknown Location",
            answerCount: summary.answerCount,
            trajectoryPointCount: summary.trajectoryPointCount,
            audioFilename: summary.audioFilename
        )
    }

    private static func cacheRootDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("DashboardCache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        return root
    }

    private static func cacheDirectory(for serverSessionId: String) throws -> URL {
        try cacheRootDirectory().appendingPathComponent(safeCacheName(serverSessionId), isDirectory: true)
    }

    private static func serverListCacheURL() throws -> URL {
        try cacheRootDirectory().appendingPathComponent("admin_session_list.json")
    }

    private static func safeCacheName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }
        return scalars.joined()
    }

    private static func recordingMetadata(in directoryURL: URL, audioFileName: String?) -> [String: Any]? {
        guard let audioFileName else { return nil }
        let metadataURL = directoryURL
            .appendingPathComponent(audioFileName)
            .deletingPathExtension()
            .appendingPathExtension("json")
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func resourceDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func dateValue(_ value: String?) -> Date? {
        guard let value else { return nil }

        let isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFractional.date(from: value) {
            return date
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) {
            return date
        }

        let display = DateFormatter()
        display.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return display.date(from: value)
    }
}

final class LocalSessionDashboardViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case device
        case server
    }

    private enum Row {
        case session(LocalSessionDashboardSession)
        case server(LocalSessionDashboardLibrary.ServerSessionSummary)
    }

    private var sessions: [LocalSessionDashboardSession]
    private var serverSummaries: [LocalSessionDashboardLibrary.ServerSessionSummary]
    private var loadingServerSessionIds: Set<String> = []

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(sessions: [LocalSessionDashboardSession]) {
        self.sessions = sessions
        self.serverSummaries = LocalSessionDashboardLibrary.loadCachedServerSummaries()
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Dashboard"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh,
            target: self,
            action: #selector(refreshTapped)
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DashboardCell")
        updateHeader()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .device:
            return "Ready on this device"
        case .server:
            return "Available on server"
        case .none:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(for: section).count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DashboardCell", for: indexPath)

        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.numberOfLines = 2

        switch rows(for: indexPath.section)[indexPath.row] {
        case .session(let session):
            content.text = session.titleText
            content.secondaryText = [
                Self.dateFormatter.string(from: session.createdAt),
                session.locationLabel,
                "Interviewer: \(session.interviewerName ?? session.interviewerEmail ?? "Unknown")",
                "\(session.matchedAnswers.count) answer(s)",
                "\(session.trajectoryPoints.count) GPS point(s)",
                session.sourceLabel
            ].joined(separator: "  |  ")
            cell.accessoryType = .disclosureIndicator
        case .server(let summary):
            content.text = summary.respondentName ?? summary.localSessionId ?? summary.sessionId
            content.secondaryText = [
                serverDateText(summary),
                summary.locationLabel,
                "Interviewer: \(summary.interviewerName ?? summary.interviewerEmail ?? "Unknown")",
                "\(summary.answerCount ?? 0) answer(s)",
                "\(summary.trajectoryPointCount ?? 0) GPS point(s)",
                loadingServerSessionIds.contains(summary.sessionId) ? "downloading" : "server"
            ].joined(separator: "  |  ")
            cell.accessoryType = .disclosureIndicator
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows(for: indexPath.section)[indexPath.row] {
        case .session(let session):
            navigationController?.pushViewController(makeDetailViewController(for: session), animated: true)
        case .server(let summary):
            openServerSession(summary, indexPath: indexPath)
        }
    }

    private func updateHeader() {
        let localCount = sessions.filter { $0.source == .local }.count
        let cachedCount = sessions.filter { $0.source == .cachedServer }.count
        let serverOnly = serverOnlySummaries().count
        let points = sessions.reduce(0) { $0 + $1.trajectoryPoints.count }
        let latest = sessions.first.map { Self.dateFormatter.string(from: $0.createdAt) } ?? "None"

        let label = UILabel()
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.text = "Local: \(localCount)    Cached: \(cachedCount)    Server: \(serverOnly)\nCached GPS points: \(points)\nLatest cached/local: \(latest)"
        label.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 72)
        label.textAlignment = .center
        tableView.tableHeaderView = label
    }

    @objc private func refreshTapped() {
        guard SurveyAPIClient.shared.isConfigured() else {
            showAlert(message: "Survey API is not configured. Set Survey API Base URL in Settings.")
            return
        }

        navigationItem.rightBarButtonItem?.isEnabled = false
        Task { [weak self] in
            do {
                let response = try await SurveyAPIClient.shared.listAdminSessions()
                LocalSessionDashboardLibrary.saveServerSummaries(response)
                await MainActor.run {
                    guard let self else { return }
                    self.serverSummaries = LocalSessionDashboardLibrary.serverSummaries(from: response)
                    self.sessions = LocalSessionDashboardLibrary.loadSessions()
                    self.navigationItem.rightBarButtonItem?.isEnabled = true
                    self.updateHeader()
                    self.tableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self?.navigationItem.rightBarButtonItem?.isEnabled = true
                    self?.showAlert(message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    private func rows(for section: Int) -> [Row] {
        switch Section(rawValue: section) {
        case .device:
            return sessions
                .sorted { $0.createdAt > $1.createdAt }
                .map(Row.session)
        case .server:
            return serverOnlySummaries().map(Row.server)
        case .none:
            return []
        }
    }

    private func serverOnlySummaries() -> [LocalSessionDashboardLibrary.ServerSessionSummary] {
        let loadedServerIds = Set(sessions.compactMap(\.serverSessionId))
        let localCloudIds = Set(sessions.compactMap { session -> String? in
            guard session.source == .local else { return nil }
            return session.serverSessionId
        })

        return serverSummaries
            .filter { !loadedServerIds.contains($0.sessionId) && !localCloudIds.contains($0.sessionId) }
            .sorted {
                switch ($0.createdAt, $1.createdAt) {
                case let (lhs?, rhs?):
                    return lhs > rhs
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return $0.sessionId < $1.sessionId
                }
            }
    }

    private func openServerSession(_ summary: LocalSessionDashboardLibrary.ServerSessionSummary, indexPath: IndexPath) {
        if let cached = LocalSessionDashboardLibrary.cachedSession(serverSessionId: summary.sessionId) {
            sessions = LocalSessionDashboardLibrary.loadSessions()
            tableView.reloadData()
            navigationController?.pushViewController(makeDetailViewController(for: cached), animated: true)
            return
        }

        guard !loadingServerSessionIds.contains(summary.sessionId) else { return }
        guard SurveyAPIClient.shared.isConfigured() else {
            showAlert(message: "Survey API is not configured. Set Survey API Base URL in Settings.")
            return
        }

        loadingServerSessionIds.insert(summary.sessionId)
        tableView.reloadRows(at: [indexPath], with: .automatic)

        Task { [weak self] in
            do {
                let data = try await SurveyAPIClient.shared.fetchAdminSessionPackage(sessionId: summary.sessionId)
                let cached = try LocalSessionDashboardLibrary.saveServerPackage(data: data, serverSessionId: summary.sessionId)
                await MainActor.run {
                    guard let self else { return }
                    self.loadingServerSessionIds.remove(summary.sessionId)
                    self.sessions = LocalSessionDashboardLibrary.loadSessions()
                    self.updateHeader()
                    self.tableView.reloadData()
                    self.navigationController?.pushViewController(self.makeDetailViewController(for: cached), animated: true)
                }
            } catch {
                await MainActor.run {
                    self?.loadingServerSessionIds.remove(summary.sessionId)
                    self?.tableView.reloadData()
                    self?.showAlert(message: error.localizedDescription)
                }
            }
        }
    }

    private func serverDateText(_ summary: LocalSessionDashboardLibrary.ServerSessionSummary) -> String {
        if let createdAt = summary.createdAt {
            return Self.dateFormatter.string(from: createdAt)
        }
        return summary.createdAtLabel ?? "Unknown Date"
    }

    private func showAlert(message: String) {
        let alert = UIAlertController(title: "Dashboard", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func makeDetailViewController(for session: LocalSessionDashboardSession) -> LocalSessionDetailViewController {
        LocalSessionDetailViewController(session: session) { [weak self] in
            self?.sessions = LocalSessionDashboardLibrary.loadSessions()
            self?.updateHeader()
            self?.tableView.reloadData()
        }
    }
}

final class LocalSessionDetailViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case overview
        case actions
        case answers
        case transcript
    }

    private let session: LocalSessionDashboardSession
    private let onDeleted: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(session: LocalSessionDashboardSession, onDeleted: @escaping () -> Void = {}) {
        self.session = session
        self.onDeleted = onDeleted
        super.init(style: .insetGrouped)
        title = "Session"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DetailCell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .overview:
            return 8
        case .actions:
            return 3
        case .answers:
            return max(session.matchedAnswers.count, 1)
        case .transcript:
            return 1
        case .none:
            return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .overview:
            return "Overview"
        case .actions:
            return "Actions"
        case .answers:
            return "Matched Answers"
        case .transcript:
            return "Transcript"
        case .none:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DetailCell", for: indexPath)
        cell.accessoryType = .none
        cell.selectionStyle = .default

        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.numberOfLines = 0

        switch Section(rawValue: indexPath.section) {
        case .overview:
            let rows = overviewRows()
            content.text = rows[indexPath.row].title
            content.secondaryText = rows[indexPath.row].value
            cell.selectionStyle = .none
        case .actions:
            if indexPath.row == 0 {
                content.text = "View Map"
                content.secondaryText = "\(session.trajectoryPoints.count) GPS point(s)"
                cell.accessoryType = session.trajectoryPoints.isEmpty ? .none : .disclosureIndicator
                cell.selectionStyle = session.trajectoryPoints.isEmpty ? .none : .default
            } else {
                if indexPath.row == 1 {
                    content.text = "Share session.json"
                    content.secondaryText = session.packageURL.lastPathComponent
                    cell.accessoryType = .disclosureIndicator
                } else {
                    content.text = deleteActionTitle()
                    content.secondaryText = deleteActionSubtitle()
                    content.textProperties.color = .systemRed
                    cell.accessoryType = .none
                }
            }
        case .answers:
            if session.matchedAnswers.isEmpty {
                content.text = "No matched answers"
                content.secondaryText = nil
                cell.selectionStyle = .none
            } else {
                let answer = session.matchedAnswers[indexPath.row]
                let prefix = answer.questionId.map { "Q\($0): " } ?? ""
                content.text = prefix + answer.question
                content.secondaryText = [answer.answer, answer.confidence].compactMap { $0 }.joined(separator: "  |  ")
                cell.selectionStyle = .none
            }
        case .transcript:
            content.text = session.transcription.isEmpty ? "No transcript" : session.transcription
            content.secondaryText = nil
            content.textProperties.numberOfLines = 0
            cell.selectionStyle = .none
        case .none:
            break
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .actions else { return }

        if indexPath.row == 0 {
            guard !session.trajectoryPoints.isEmpty else { return }
            navigationController?.pushViewController(
                LocalSessionMapViewController(session: session),
                animated: true
            )
        } else if indexPath.row == 1 {
            shareSessionJSON(sourceView: tableView.cellForRow(at: indexPath) ?? tableView)
        } else {
            confirmDeleteLocalCopy()
        }
    }

    private func overviewRows() -> [(title: String, value: String)] {
        [
            ("Respondent", session.respondentName ?? "Unknown"),
            ("Interviewer", session.interviewerName ?? "Unknown"),
            ("Interviewer Email", session.interviewerEmail ?? session.interviewerId ?? "Unknown"),
            ("Date", Self.dateFormatter.string(from: session.createdAt)),
            ("Location", session.locationLabel),
            ("Status", session.isUploaded ? "Uploaded" : "Local only"),
            ("Audio", session.audioFileName ?? "No audio listed"),
            ("Local ID", session.localSessionId)
        ]
    }

    private func shareSessionJSON(sourceView: UIView) {
        let vc = UIActivityViewController(activityItems: [session.packageURL], applicationActivities: nil)
        if let popover = vc.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(vc, animated: true)
    }

    private func deleteActionTitle() -> String {
        switch session.source {
        case .local:
            return "Delete local session files"
        case .cachedServer:
            return "Remove cached server copy"
        }
    }

    private func deleteActionSubtitle() -> String {
        switch session.source {
        case .local:
            return session.isUploaded
                ? "Removes this iPad copy only. Server copy can be refreshed again."
                : "Removes this local-only session from this iPad."
        case .cachedServer:
            return "Removes the downloaded dashboard cache. Opening the server row downloads it again."
        }
    }

    private func confirmDeleteLocalCopy() {
        let alert = UIAlertController(
            title: deleteActionTitle(),
            message: deleteActionSubtitle(),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteLocalCopy()
        })
        present(alert, animated: true)
    }

    private func deleteLocalCopy() {
        do {
            try LocalSessionDashboardLibrary.deleteLocalCopy(session)
            onDeleted()
            navigationController?.popViewController(animated: true)
        } catch {
            let alert = UIAlertController(
                title: "Delete Failed",
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

final class LocalSessionMapViewController: UIViewController {
    private let session: LocalSessionDashboardSession
    private let mapView = MKMapView()
    private let statusLabel = UILabel()
    private var polyline: MKPolyline?

    init(session: LocalSessionDashboardSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = "Route Map"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Fit",
            style: .plain,
            target: self,
            action: #selector(fitRoute)
        )

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.showsCompass = true
        mapView.showsScale = true

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "\(session.locationLabel)  |  \(session.trajectoryPoints.count) GPS point(s)"

        view.addSubview(mapView)
        view.addSubview(statusLabel)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: guide.topAnchor),
            mapView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12)
        ])

        drawRoute()
    }

    private func drawRoute() {
        let coordinates = session.trajectoryPoints.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard !coordinates.isEmpty else { return }

        if coordinates.count > 1 {
            let route = MKPolyline(coordinates: coordinates, count: coordinates.count)
            polyline = route
            mapView.addOverlay(route)
        }

        addAnnotation(title: "Start", coordinate: coordinates[0])
        if let last = coordinates.last, coordinates.count > 1 {
            addAnnotation(title: "End", coordinate: last)
        }

        fitRoute()
    }

    private func addAnnotation(title: String, coordinate: CLLocationCoordinate2D) {
        let annotation = MKPointAnnotation()
        annotation.title = title
        annotation.coordinate = coordinate
        mapView.addAnnotation(annotation)
    }

    @objc private func fitRoute() {
        if let polyline {
            mapView.setVisibleMapRect(
                polyline.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 64, left: 32, bottom: 64, right: 32),
                animated: true
            )
            return
        }

        guard let first = session.trajectoryPoints.first else { return }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
            latitudinalMeters: 400,
            longitudinalMeters: 400
        )
        mapView.setRegion(region, animated: true)
    }
}

extension LocalSessionMapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let route = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: route)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 5
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }
}
