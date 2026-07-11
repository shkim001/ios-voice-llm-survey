import MapKit
import UIKit

struct LocalSessionDashboardSession {
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
    let audioFileName: String?
    let isUploaded: Bool
    let transcription: String
    let matchedAnswers: [MatchedAnswer]
    let trajectoryPoints: [TrajectoryPoint]

    var titleText: String {
        if let respondentName, !respondentName.isEmpty {
            return respondentName
        }
        return localSessionId
    }
}

enum LocalSessionDashboardLibrary {
    static func loadSessions() -> [LocalSessionDashboardSession] {
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
            .compactMap { loadSession(in: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static func loadSession(in directoryURL: URL) -> LocalSessionDashboardSession? {
        let packageURL = directoryURL.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let metadata = json["metadata"] as? [String: Any]
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
            audioFileName: audioFileName,
            isUploaded: isUploaded,
            transcription: transcription,
            matchedAnswers: answers,
            trajectoryPoints: trajectoryPoints
        )
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
}

final class LocalSessionDashboardViewController: UITableViewController {
    private var sessions: [LocalSessionDashboardSession]

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(sessions: [LocalSessionDashboardSession]) {
        self.sessions = sessions
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

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sessions.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Local Sessions"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DashboardCell", for: indexPath)
        let session = sessions[indexPath.row]

        var content = UIListContentConfiguration.subtitleCell()
        content.text = session.titleText
        content.secondaryText = [
            Self.dateFormatter.string(from: session.createdAt),
            session.locationLabel,
            "\(session.matchedAnswers.count) answer(s)",
            "\(session.trajectoryPoints.count) GPS point(s)",
            session.isUploaded ? "uploaded" : "local"
        ].joined(separator: "  |  ")
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            LocalSessionDetailViewController(session: sessions[indexPath.row]),
            animated: true
        )
    }

    private func updateHeader() {
        let uploaded = sessions.filter(\.isUploaded).count
        let localOnly = sessions.count - uploaded
        let points = sessions.reduce(0) { $0 + $1.trajectoryPoints.count }
        let latest = sessions.first.map { Self.dateFormatter.string(from: $0.createdAt) } ?? "None"

        let label = UILabel()
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.text = "Total: \(sessions.count)    Uploaded: \(uploaded)    Local: \(localOnly)\nGPS points: \(points)\nLatest: \(latest)"
        label.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 72)
        label.textAlignment = .center
        tableView.tableHeaderView = label
    }

    @objc private func refreshTapped() {
        sessions = LocalSessionDashboardLibrary.loadSessions()
        updateHeader()
        tableView.reloadData()
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(session: LocalSessionDashboardSession) {
        self.session = session
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
            return 6
        case .actions:
            return 2
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
                content.text = "Share session.json"
                content.secondaryText = session.packageURL.lastPathComponent
                cell.accessoryType = .disclosureIndicator
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
        } else {
            shareSessionJSON(sourceView: tableView.cellForRow(at: indexPath) ?? tableView)
        }
    }

    private func overviewRows() -> [(title: String, value: String)] {
        [
            ("Respondent", session.respondentName ?? "Unknown"),
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
