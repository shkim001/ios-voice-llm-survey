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

    struct ResolvedLocation {
        let status: String
        let source: String
        let quality: String?
        let label: String?
        let formattedAddress: String?
        let latitude: Double?
        let longitude: Double?

        var coordinate: CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            let value = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            return CLLocationCoordinate2DIsValid(value) ? value : nil
        }
    }

    struct MatchedAnswer {
        let questionId: Int?
        let question: String
        let answer: String
        let confidence: String?
    }

    let localSessionId: String
    let packageURL: URL?
    let directoryURL: URL
    let createdAt: Date
    let locationLabel: String
    let resolvedLocation: ResolvedLocation?
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
    let statusSummary: LocalSessionStatusSummary

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

    var needsProcessing: Bool {
        source == .local && statusSummary.primary != "Uploaded"
    }

    var canRetryInBatch: Bool {
        needsProcessing
            && statusSummary.canRetryNow
            && statusSummary.primary != "Clarification required"
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

    static func localSession(id: String) -> LocalSessionDashboardSession? {
        loadLocalSessions().first { $0.localSessionId == id }
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
            guard source == .local,
                  let manifest = try? LocalSessionManifestStore.loadOrSynthesize(from: directoryURL),
                  manifest.audioFileName != nil || manifest.audioStatus == .failed else {
                return nil
            }
            return draftSession(from: manifest, in: directoryURL)
        }

        let metadata = json["metadata"] as? [String: Any]
        let cloud = metadata?["cloud"] as? [String: Any]
        let interviewer = json["interviewer_info"] as? [String: Any]
        let respondent = json["respondent_info"] as? [String: Any]
        let audio = json["audio"] as? [String: Any]
        let location = json["location"] as? [String: Any]
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

        let locationLabel = nonEmptyString(location?["label"])
            ?? nonEmptyString(json["location_label"])
            ?? nonEmptyString(respondent?["location"])
            ?? "Unknown Location"
        let resolvedLocation = location.map {
            LocalSessionDashboardSession.ResolvedLocation(
                status: nonEmptyString($0["status"]) ?? "pending",
                source: nonEmptyString($0["source"]) ?? "none",
                quality: nonEmptyString($0["quality"]),
                label: nonEmptyString($0["label"]),
                formattedAddress: nonEmptyString($0["formatted_address"]),
                latitude: doubleValue($0["latitude"]),
                longitude: doubleValue($0["longitude"])
            )
        }
        let respondentName = nonEmptyString(respondent?["name"])
        let interviewerId = nonEmptyString(interviewer?["interviewer_id"])
            ?? nonEmptyString(interviewer?["email"])
        let interviewerName = nonEmptyString(interviewer?["name"])
        let interviewerEmail = nonEmptyString(interviewer?["email"])
        let audioFileName = nonEmptyString(audio?["file_name"])
        let transcription = nonEmptyString(json["transcription"]) ?? ""
        let manifest = try? LocalSessionManifestStore.loadOrSynthesize(from: directoryURL)
        let manifestUploadConfirmed = manifest?.uploadStatus == .uploaded
        let legacyUploadConfirmed = recordingMetadata(
            in: directoryURL,
            audioFileName: audioFileName
        )?["session_package_uploaded_at_epoch"] != nil
        let isUploaded = source == .cachedServer || manifestUploadConfirmed || legacyUploadConfirmed

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

        let statusSummary: LocalSessionStatusSummary
        if source == .cachedServer {
            var uploadedManifest = manifest ?? LocalSessionManifest(localSessionId: localSessionId)
            uploadedManifest.audioStatus = audioFileName == nil ? .preparing : .recordedLocally
            uploadedManifest.transcriptionStatus = .completed
            uploadedManifest.analysisStatus = .completed
            uploadedManifest.clarificationStatus = .completed
            uploadedManifest.uploadStatus = .uploaded
            statusSummary = .derive(from: uploadedManifest, hasFinalPackage: true)
        } else if var manifest {
            if isUploaded { manifest.uploadStatus = .uploaded }
            statusSummary = .derive(from: manifest, hasFinalPackage: true)
        } else {
            var legacy = LocalSessionManifest(localSessionId: localSessionId, audioFileName: audioFileName)
            legacy.audioStatus = audioFileName == nil ? .preparing : .recordedLocally
            legacy.transcriptionStatus = transcription.isEmpty ? .pending : .completed
            legacy.analysisStatus = answers.isEmpty ? .pending : .completed
            legacy.clarificationStatus = answers.isEmpty ? .pending : .completed
            legacy.uploadStatus = isUploaded ? .uploaded : .pending
            statusSummary = .derive(from: legacy, hasFinalPackage: true)
        }

        return LocalSessionDashboardSession(
            localSessionId: localSessionId,
            packageURL: packageURL,
            directoryURL: directoryURL,
            createdAt: createdAt,
            locationLabel: locationLabel,
            resolvedLocation: resolvedLocation,
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
            serverSessionId: serverSessionId ?? nonEmptyString(cloud?["session_id"]),
            statusSummary: statusSummary
        )
    }

    private static func draftSession(
        from manifest: LocalSessionManifest,
        in directoryURL: URL
    ) -> LocalSessionDashboardSession {
        let createdAt = manifest.createdAt > 0
            ? Date(timeIntervalSince1970: manifest.createdAt)
            : (resourceDate(for: directoryURL) ?? .distantPast)
        let resolvedLocation = LocalSessionDashboardSession.ResolvedLocation(
            status: manifest.locationStatus.rawValue,
            source: manifest.locationSource.rawValue,
            quality: manifest.locationQuality.rawValue,
            label: manifest.placeSnapshot?.displayLabel ?? manifest.locationLabel,
            formattedAddress: manifest.placeSnapshot?.formattedAddress,
            latitude: manifest.locationCoordinates.latitude,
            longitude: manifest.locationCoordinates.longitude
        )
        let transcriptURL = directoryURL.appendingPathComponent(
            manifest.transcriptFileName ?? FileTranscriptStore.fileName
        )
        let transcription = (try? String(contentsOf: transcriptURL, encoding: .utf8))
            ?? manifest.transcription
            ?? ""
        let answers = manifest.matchedQuestions.map {
            LocalSessionDashboardSession.MatchedAnswer(
                questionId: $0.matchedQuestionId,
                question: $0.matchedQuestion,
                answer: $0.finalAnswer ?? $0.extractedAnswer,
                confidence: $0.confidence
            )
        }
        let trajectory = manifest.trajectoryPoints.map {
            LocalSessionDashboardSession.TrajectoryPoint(
                latitude: $0.lat,
                longitude: $0.lon,
                timestampMs: $0.tsMs,
                capturedAt: nil
            )
        }
        return LocalSessionDashboardSession(
            localSessionId: manifest.localSessionId,
            packageURL: nil,
            directoryURL: directoryURL,
            createdAt: createdAt,
            locationLabel: manifest.placeSnapshot?.displayLabel
                ?? manifest.locationLabel
                ?? "Location not recorded",
            resolvedLocation: resolvedLocation,
            respondentName: manifest.respondentSnapshot?.name,
            interviewerId: manifest.interviewerSnapshot?.interviewerId,
            interviewerName: manifest.interviewerSnapshot?.name,
            interviewerEmail: manifest.interviewerSnapshot?.email,
            audioFileName: manifest.audioFileName,
            isUploaded: manifest.uploadStatus == .uploaded,
            transcription: transcription.trimmingCharacters(in: .whitespacesAndNewlines),
            matchedAnswers: answers,
            trajectoryPoints: trajectory,
            source: .local,
            serverSessionId: manifest.cloudSessionId,
            statusSummary: .derive(from: manifest, hasFinalPackage: false)
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
        case unprocessed
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
    private let onProcessSession: (URL) -> Void
    private var isBatchProcessing = false

    private lazy var refreshButton = UIBarButtonItem(
        barButtonSystemItem: .refresh,
        target: self,
        action: #selector(refreshTapped)
    )
    private lazy var selectButton = UIBarButtonItem(
        title: "Select",
        style: .plain,
        target: self,
        action: #selector(selectTapped)
    )
    private lazy var retryAllButton = UIBarButtonItem(
        title: "Retry All",
        style: .plain,
        target: self,
        action: #selector(retryAllTapped)
    )
    private lazy var cancelSelectionButton = UIBarButtonItem(
        barButtonSystemItem: .cancel,
        target: self,
        action: #selector(cancelSelectionTapped)
    )
    private lazy var selectAllUnprocessedButton = UIBarButtonItem(
        title: "All Unprocessed",
        style: .plain,
        target: self,
        action: #selector(selectAllUnprocessedTapped)
    )
    private lazy var deleteSelectedButton = UIBarButtonItem(
        title: "Delete",
        style: .plain,
        target: self,
        action: #selector(deleteSelectedTapped)
    )
    private lazy var downloadSelectedButton = UIBarButtonItem(
        title: "Get",
        style: .plain,
        target: self,
        action: #selector(downloadSelectedTapped)
    )
    private lazy var processSelectedButton = UIBarButtonItem(
        title: "Retry",
        style: .plain,
        target: self,
        action: #selector(processSelectedTapped)
    )

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(
        sessions: [LocalSessionDashboardSession],
        onProcessSession: @escaping (URL) -> Void = { _ in }
    ) {
        self.sessions = sessions
        self.serverSummaries = LocalSessionDashboardLibrary.loadCachedServerSummaries()
        self.onProcessSession = onProcessSession
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
        navigationItem.rightBarButtonItems = [refreshButton, selectButton, retryAllButton]
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DashboardCell")
        updateHeader()
        updateBatchButtons()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
        if editing {
            navigationItem.leftBarButtonItem = cancelSelectionButton
            navigationItem.rightBarButtonItems = [selectAllUnprocessedButton]
            setToolbarItems([
                processSelectedButton,
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                deleteSelectedButton,
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                downloadSelectedButton
            ], animated: animated)
            navigationController?.setToolbarHidden(false, animated: animated)
        } else {
            tableView.indexPathsForSelectedRows?.forEach { tableView.deselectRow(at: $0, animated: false) }
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(closeTapped)
            )
            navigationItem.rightBarButtonItems = [refreshButton, selectButton, retryAllButton]
            setToolbarItems(nil, animated: animated)
            navigationController?.setToolbarHidden(true, animated: animated)
        }
        updateBatchButtons()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .unprocessed:
            return "Unprocessed Sessions"
        case .device:
            return "Sessions on this device"
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
        content.secondaryTextProperties.numberOfLines = 4

        switch rows(for: indexPath.section)[indexPath.row] {
        case .session(let session):
            content.text = session.titleText
            content.secondaryText = [
                Self.dateFormatter.string(from: session.createdAt),
                session.locationLabel,
                "Interviewer: \(session.interviewerName ?? session.interviewerEmail ?? "Unknown")",
                session.statusSummary.messages.joined(separator: " • "),
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
        guard !tableView.isEditing else {
            updateBatchButtons()
            return
        }
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows(for: indexPath.section)[indexPath.row] {
        case .session(let session):
            navigationController?.pushViewController(makeDetailViewController(for: session), animated: true)
        case .server(let summary):
            openServerSession(summary, indexPath: indexPath)
        }
    }

    override func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard tableView.isEditing else { return }
        updateBatchButtons()
    }

    private func updateHeader() {
        let unprocessedCount = sessions.filter(\.needsProcessing).count
        let localCount = sessions.filter { $0.source == .local }.count
        let cachedCount = sessions.filter { $0.source == .cachedServer }.count
        let serverOnly = serverOnlySummaries().count
        let points = sessions.reduce(0) { $0 + $1.trajectoryPoints.count }
        let latest = sessions.first.map { Self.dateFormatter.string(from: $0.createdAt) } ?? "None"

        let label = UILabel()
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.text = "Unprocessed: \(unprocessedCount)    Local: \(localCount)    Cached: \(cachedCount)    Server: \(serverOnly)\nCached GPS points: \(points)\nLatest cached/local: \(latest)"
        label.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 72)
        label.textAlignment = .center
        tableView.tableHeaderView = label
        updateEmptyState()
    }

    private func updateEmptyState() {
        guard sessions.isEmpty, serverOnlySummaries().isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.text = "No sessions are saved on this device yet.\nTap Refresh to check for sessions available on the server."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        tableView.backgroundView = label
    }

    @objc private func refreshTapped() {
        guard SurveyAPIClient.shared.isConfigured() else {
            showAlert(message: "Survey API is not configured. Set Survey API Base URL in Settings.")
            return
        }

        refreshButton.isEnabled = false
        Task { [weak self] in
            do {
                let response = try await SurveyAPIClient.shared.listAdminSessions()
                LocalSessionDashboardLibrary.saveServerSummaries(response)
                await MainActor.run {
                    guard let self else { return }
                    self.serverSummaries = LocalSessionDashboardLibrary.serverSummaries(from: response)
                    self.sessions = LocalSessionDashboardLibrary.loadSessions()
                    self.refreshButton.isEnabled = true
                    self.updateHeader()
                    self.tableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self?.refreshButton.isEnabled = true
                    self?.showAlert(message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func selectTapped() {
        setEditing(true, animated: true)
    }

    @objc private func cancelSelectionTapped() {
        setEditing(false, animated: true)
    }

    @objc private func retryAllTapped() {
        let eligible = sessions.filter {
            $0.canRetryInBatch
        }
        guard !eligible.isEmpty else {
            showAlert(message: "No saved sessions are currently eligible for automatic retry. Sessions awaiting clarification must be opened individually.")
            return
        }
        guard !isBatchProcessing else { return }

        let alert = UIAlertController(
            title: "Retry All Unprocessed Sessions?",
            message: "The app will choose the correct stage for each of the \(eligible.count) eligible session(s) and process them one at a time. Original recordings remain safe on this device.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Retry All", style: .default) { [weak self] _ in
            self?.processSelectedSessions(eligible)
        })
        present(alert, animated: true)
    }

    @objc private func selectAllUnprocessedTapped() {
        let section = Section.unprocessed.rawValue
        for row in rows(for: section).indices {
            tableView.selectRow(at: IndexPath(row: row, section: section), animated: false, scrollPosition: .none)
        }
        updateBatchButtons()
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func deleteSelectedTapped() {
        let selectedSessions = selectedDeviceSessions()
        guard !selectedSessions.isEmpty else {
            showAlert(message: "Select one or more local or cached sessions to delete.")
            return
        }

        let localCount = selectedSessions.filter { $0.source == .local }.count
        let cachedCount = selectedSessions.filter { $0.source == .cachedServer }.count
        let pieces = [
            localCount == 0 ? nil : "\(localCount) local",
            cachedCount == 0 ? nil : "\(cachedCount) cached"
        ].compactMap { $0 }.joined(separator: " and ")
        let unuploadedCount = selectedSessions.filter {
            $0.source == .local && $0.statusSummary.primary != "Uploaded"
        }.count
        let unuploadedWarning = unuploadedCount > 0
            ? " \(unuploadedCount) selected session(s) are not confirmed uploaded; deleting them may destroy the only original recording."
            : ""
        let alert = UIAlertController(
            title: "Delete Selected Sessions?",
            message: "This permanently removes \(pieces) folder copy/copies from this iPad, including any original audio, manifest, transcript, and JSON inside them.\(unuploadedWarning) Uploaded server packages are not deleted.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteSelectedDeviceSessions(selectedSessions)
        })
        present(alert, animated: true)
    }

    @objc private func downloadSelectedTapped() {
        let selectedSummaries = selectedServerSummaries()
            .filter { !loadingServerSessionIds.contains($0.sessionId) }
        guard !selectedSummaries.isEmpty else {
            showAlert(message: "Select one or more server sessions to get.")
            return
        }
        guard SurveyAPIClient.shared.isConfigured() else {
            showAlert(message: "Survey API is not configured. Set Survey API Base URL in Settings.")
            return
        }

        downloadServerSummaries(selectedSummaries)
    }

    @objc private func processSelectedTapped() {
        let selectedSessions = selectedProcessableSessions()
        guard !selectedSessions.isEmpty else {
            showAlert(message: "Select one or more unprocessed sessions that can be retried. Clarification-required sessions must be opened individually.")
            return
        }
        guard !isBatchProcessing else { return }

        let alert = UIAlertController(
            title: "Retry Selected Sessions?",
            message: "The app will choose the correct stage for each of the \(selectedSessions.count) selected session(s) and process them one at a time. Sessions that require interviewer clarification will remain in Unprocessed Sessions for individual review.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.processSelectedSessions(selectedSessions)
        })
        present(alert, animated: true)
    }

    private func rows(for section: Int) -> [Row] {
        switch Section(rawValue: section) {
        case .unprocessed:
            return sessions
                .filter(\.needsProcessing)
                .sorted { $0.createdAt > $1.createdAt }
                .map(Row.session)
        case .device:
            return sessions
                .filter { !$0.needsProcessing }
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

    private func selectedRows() -> [Row] {
        (tableView.indexPathsForSelectedRows ?? []).compactMap { indexPath in
            let sectionRows = rows(for: indexPath.section)
            guard indexPath.row < sectionRows.count else { return nil }
            return sectionRows[indexPath.row]
        }
    }

    private func selectedDeviceSessions() -> [LocalSessionDashboardSession] {
        selectedRows().compactMap { row in
            if case .session(let session) = row { return session }
            return nil
        }
    }

    private func selectedProcessableSessions() -> [LocalSessionDashboardSession] {
        selectedDeviceSessions().filter {
            $0.canRetryInBatch
        }
    }

    private func selectedServerSummaries() -> [LocalSessionDashboardLibrary.ServerSessionSummary] {
        selectedRows().compactMap { row in
            if case .server(let summary) = row { return summary }
            return nil
        }
    }

    private func updateBatchButtons() {
        let deviceCount = selectedDeviceSessions().count
        let processCount = selectedProcessableSessions().count
        let serverCount = selectedServerSummaries()
            .filter { !loadingServerSessionIds.contains($0.sessionId) }
            .count
        deleteSelectedButton.isEnabled = deviceCount > 0
        downloadSelectedButton.isEnabled = serverCount > 0
        processSelectedButton.isEnabled = processCount > 0 && !isBatchProcessing
        retryAllButton.isEnabled = sessions.contains {
            $0.canRetryInBatch
        } && !isBatchProcessing
        deleteSelectedButton.title = deviceCount > 0 ? "Delete (\(deviceCount))" : "Delete"
        downloadSelectedButton.title = serverCount > 0 ? "Get (\(serverCount))" : "Get"
        processSelectedButton.title = processCount > 0 ? "Retry (\(processCount))" : "Retry"
    }

    private func processSelectedSessions(_ selectedSessions: [LocalSessionDashboardSession]) {
        isBatchProcessing = true
        processSelectedButton.isEnabled = false
        retryAllButton.isEnabled = false
        setEditing(false, animated: true)

        Task { [weak self] in
            let ids = Set(selectedSessions.map(\.localSessionId))
            let summary = await DeferredSessionOutbox.shared.retryNow(localSessionIds: ids)
            guard let self else { return }
            isBatchProcessing = false
            sessions = LocalSessionDashboardLibrary.loadSessions()
            updateHeader()
            tableView.reloadData()
            updateBatchButtons()

            let completed = summary.uploadedSessionIds.count
            let failed = summary.failedSessionIds.count
            let remaining = summary.deferredSessionIds.count
            let message = "Processed sequentially. Uploaded: \(completed). Failed: \(failed). Still awaiting another step or clarification: \(remaining). All original recordings remain stored locally."
            showAlert(message: message)
        }
    }

    private func deleteSelectedDeviceSessions(_ selectedSessions: [LocalSessionDashboardSession]) {
        var failures: [String] = []
        for session in selectedSessions {
            do {
                try LocalSessionDashboardLibrary.deleteLocalCopy(session)
            } catch {
                failures.append("\(session.titleText): \(error.localizedDescription)")
            }
        }

        setEditing(false, animated: true)
        sessions = LocalSessionDashboardLibrary.loadSessions()
        updateHeader()
        tableView.reloadData()

        if failures.isEmpty {
            showAlert(message: "Deleted \(selectedSessions.count) selected session copy/copies from this iPad.")
        } else {
            showAlert(message: "Deleted \(selectedSessions.count - failures.count) session copy/copies. Failed:\n\(failures.joined(separator: "\n"))")
        }
    }

    private func downloadServerSummaries(_ summaries: [LocalSessionDashboardLibrary.ServerSessionSummary]) {
        loadingServerSessionIds.formUnion(summaries.map(\.sessionId))
        refreshButton.isEnabled = false
        setEditing(false, animated: true)
        tableView.reloadData()

        Task { [weak self] in
            var successCount = 0
            var failures: [String] = []
            for summary in summaries {
                do {
                    let data = try await SurveyAPIClient.shared.fetchAdminSessionPackage(sessionId: summary.sessionId)
                    _ = try LocalSessionDashboardLibrary.saveServerPackage(data: data, serverSessionId: summary.sessionId)
                    successCount += 1
                } catch {
                    failures.append("\(summary.respondentName ?? summary.localSessionId ?? summary.sessionId): \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                guard let self else { return }
                summaries.forEach { self.loadingServerSessionIds.remove($0.sessionId) }
                self.refreshButton.isEnabled = true
                self.sessions = LocalSessionDashboardLibrary.loadSessions()
                self.updateHeader()
                self.tableView.reloadData()
                if failures.isEmpty {
                    self.showAlert(message: "Got \(successCount) server session package(s).")
                } else {
                    self.showAlert(message: "Got \(successCount) server session package(s). Failed:\n\(failures.joined(separator: "\n"))")
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
        LocalSessionDetailViewController(
            session: session,
            onProcessRequested: { [weak self] session in
                self?.onProcessSession(session.directoryURL)
            },
            onChanged: { [weak self] in
                self?.sessions = LocalSessionDashboardLibrary.loadSessions()
                self?.updateHeader()
                self?.tableView.reloadData()
            }
        )
    }
}

final class LocalSessionDetailViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case overview
        case actions
        case answers
        case transcript
    }

    private enum DetailAction {
        case map
        case retry
        case locationEditing
        case share
        case delete
    }

    private var session: LocalSessionDashboardSession
    private let onProcessRequested: (LocalSessionDashboardSession) -> Void
    private let onChanged: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(
        session: LocalSessionDashboardSession,
        onProcessRequested: @escaping (LocalSessionDashboardSession) -> Void = { _ in },
        onChanged: @escaping () -> Void = {}
    ) {
        self.session = session
        self.onProcessRequested = onProcessRequested
        self.onChanged = onChanged
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
            return actionRows().count
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
            switch actionRows()[indexPath.row] {
            case .map:
                content.text = "View Map"
                let hasMapLocation = !session.trajectoryPoints.isEmpty || session.resolvedLocation?.coordinate != nil
                if session.resolvedLocation?.source == "place_search" {
                    content.secondaryText = "Searched place (not device GPS); \(session.trajectoryPoints.count) GPS point(s)"
                } else {
                    content.secondaryText = "\(session.trajectoryPoints.count) device GPS point(s)"
                }
                cell.accessoryType = hasMapLocation ? .disclosureIndicator : .none
                cell.selectionStyle = hasMapLocation ? .default : .none
            case .retry:
                content.text = "Retry Now"
                content.secondaryText = "Resume this saved interview from its earliest incomplete stage."
                content.textProperties.color = .systemBlue
            case .locationEditing:
                content.text = "Edit Location (future)"
                content.secondaryText = "The current location source and null/pending coordinates are preserved for a future editor."
                content.textProperties.color = .secondaryLabel
                cell.selectionStyle = .none
            case .share:
                content.text = "Share session.json"
                content.secondaryText = session.packageURL?.lastPathComponent
                cell.accessoryType = .disclosureIndicator
            case .delete:
                content.text = deleteActionTitle()
                content.secondaryText = deleteActionSubtitle()
                content.textProperties.color = .systemRed
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

        switch actionRows()[indexPath.row] {
        case .map:
            guard !session.trajectoryPoints.isEmpty || session.resolvedLocation?.coordinate != nil else { return }
            navigationController?.pushViewController(
                LocalSessionMapViewController(session: session),
                animated: true
            )
        case .retry:
            retryNow()
        case .locationEditing:
            break
        case .share:
            shareSessionJSON(sourceView: tableView.cellForRow(at: indexPath) ?? tableView)
        case .delete:
            confirmDeleteLocalCopy()
        }
    }

    private func actionRows() -> [DetailAction] {
        var rows: [DetailAction] = [.map]
        if session.source == .local, session.statusSummary.canRetryNow {
            rows.append(.retry)
        }
        if session.source == .local {
            rows.append(.locationEditing)
        }
        if session.packageURL != nil {
            rows.append(.share)
        }
        rows.append(.delete)
        return rows
    }

    private func overviewRows() -> [(title: String, value: String)] {
        [
            ("Respondent", session.respondentName ?? "Unknown"),
            ("Interviewer", session.interviewerName ?? "Unknown"),
            ("Interviewer Email", session.interviewerEmail ?? session.interviewerId ?? "Unknown"),
            ("Date", Self.dateFormatter.string(from: session.createdAt)),
            ("Location", locationOverviewText()),
            ("Status", statusOverviewText()),
            ("Audio", session.audioFileName ?? "No audio listed"),
            ("Local ID", session.localSessionId)
        ]
    }

    private func locationOverviewText() -> String {
        guard let location = session.resolvedLocation else { return session.locationLabel }
        let source = location.source == "place_search" ? "Place search (not GPS)"
            : (location.source == "device_gps" ? "Device GPS" : "No GPS")
        return [location.label ?? session.locationLabel, location.formattedAddress, source, location.quality]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func shareSessionJSON(sourceView: UIView) {
        guard let packageURL = session.packageURL else { return }
        let vc = UIActivityViewController(activityItems: [packageURL], applicationActivities: nil)
        if let popover = vc.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(vc, animated: true)
    }

    private func statusOverviewText() -> String {
        var lines = session.statusSummary.messages
        if let timestamp = session.statusSummary.retryScheduledAt {
            lines.append("Next retry: \(Self.dateFormatter.string(from: Date(timeIntervalSince1970: timestamp)))")
        }
        if session.statusSummary.recordingIsSafeLocally,
           session.statusSummary.primary != "Uploaded" {
            lines.append("The original recording is safe on this device.")
        }
        return lines.joined(separator: "\n")
    }

    private func retryNow() {
        let uploadOnly = session.packageURL != nil
            && session.statusSummary.messages.contains("Waiting for upload")
        if !uploadOnly {
            onProcessRequested(session)
            return
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Retrying…", style: .plain, target: nil, action: nil)
        Task { [weak self] in
            guard let self else { return }
            let summary = await DeferredSessionOutbox.shared.retryNow(localSessionId: session.localSessionId)
            if let refreshed = LocalSessionDashboardLibrary.localSession(id: session.localSessionId) {
                session = refreshed
            }
            onChanged()
            navigationItem.rightBarButtonItem = nil
            tableView.reloadData()
            let message: String
            if summary.uploadedSessionIds.contains(session.localSessionId) {
                message = "The saved interview was uploaded successfully."
            } else if summary.failedSessionIds.contains(session.localSessionId) {
                message = "Retry failed. The original recording remains safe locally; review the status and try again later."
            } else if summary.duplicateRunSuppressed {
                message = "This interview is already being processed."
            } else {
                message = "The saved interview remains local and still needs processing, clarification, configuration, or connectivity."
            }
            let alert = UIAlertController(title: "Retry Now", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
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
                ? "Permanently removes this iPad folder, including its audio, manifest, and JSON. The uploaded server copy can be refreshed again."
                : "Permanently removes this local-only folder, including the original audio, manifest, and JSON. This may be the only copy and cannot be undone."
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
            onChanged()
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
        let sourceText = session.resolvedLocation?.source == "place_search"
            ? "Searched place (not device GPS)"
            : "Device GPS trajectory"
        statusLabel.text = "\(session.locationLabel)  |  \(sourceText)  |  \(session.trajectoryPoints.count) GPS point(s)"

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
        if coordinates.count > 1 {
            let route = MKPolyline(coordinates: coordinates, count: coordinates.count)
            polyline = route
            mapView.addOverlay(route)
        }

        if let first = coordinates.first {
            addAnnotation(title: "Device GPS start", coordinate: first)
            if let last = coordinates.last, coordinates.count > 1 {
                addAnnotation(title: "Device GPS end", coordinate: last)
            }
        }
        if let resolved = session.resolvedLocation,
           let coordinate = resolved.coordinate,
           resolved.source == "place_search" {
            addAnnotation(title: "Searched place (not GPS)", coordinate: coordinate)
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

        let center = session.trajectoryPoints.first.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        } ?? session.resolvedLocation?.coordinate
        guard let center else { return }
        let region = MKCoordinateRegion(
            center: center,
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
