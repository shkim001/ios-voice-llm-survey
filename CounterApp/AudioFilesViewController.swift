import AVFoundation
import UIKit

struct AudioRecordingItem {
    let url: URL
    let sessionId: String
    let location: String
    let recordedAt: Date

    var displayName: String {
        url.lastPathComponent
    }
}

final class AudioLocationsViewController: UITableViewController {
    private let groupedRecordings: [(location: String, recordings: [AudioRecordingItem])]

    init(groupedRecordings: [(location: String, recordings: [AudioRecordingItem])]) {
        self.groupedRecordings = groupedRecordings
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Audio by Location"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "LocationCell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        groupedRecordings.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "LocationCell", for: indexPath)
        let item = groupedRecordings[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.location
        content.secondaryText = "\(item.recordings.count) audio file(s)"
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = groupedRecordings[indexPath.row]
        let vc = AudioFilesViewController(recordings: item.recordings, title: item.location)
        navigationController?.pushViewController(vc, animated: true)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}

final class AudioFilesViewController: UITableViewController, AVAudioPlayerDelegate {
    private var recordings: [AudioRecordingItem]
    private var audioPlayer: AVAudioPlayer?
    private var playingURL: URL?

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(recordings: [AudioRecordingItem], title: String = "Audio Files") {
        self.recordings = recordings.sorted { $0.recordedAt > $1.recordedAt }
        super.init(style: .insetGrouped)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let closeButton = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )
        if let first = navigationController?.viewControllers.first, first === self {
            navigationItem.leftBarButtonItem = closeButton
        } else {
            navigationItem.rightBarButtonItem = closeButton
        }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "AudioCell")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        recordings.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "AudioCell", for: indexPath)
        let item = recordings[indexPath.row]

        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.displayName
        content.secondaryText = "\(Self.displayDateFormatter.string(from: item.recordedAt))  |  \(item.location)"
        cell.contentConfiguration = content
        cell.accessoryType = item.url == playingURL ? .checkmark : .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = recordings[indexPath.row]
        showActions(for: item, sourceView: tableView.cellForRow(at: indexPath) ?? tableView)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playingURL = nil
        tableView.reloadData()
    }

    private func showActions(for item: AudioRecordingItem, sourceView: UIView) {
        let alert = UIAlertController(
            title: item.displayName,
            message: "\(Self.displayDateFormatter.string(from: item.recordedAt))\n\(item.location)",
            preferredStyle: .actionSheet
        )

        if playingURL == item.url, audioPlayer?.isPlaying == true {
            alert.addAction(UIAlertAction(title: "Stop Playback", style: .default) { [weak self] _ in
                self?.stopPlayback()
            })
        } else {
            alert.addAction(UIAlertAction(title: "Play", style: .default) { [weak self] _ in
                self?.play(item)
            })
        }

        alert.addAction(UIAlertAction(title: "Share or Save to Files", style: .default) { [weak self] _ in
            self?.share(item, sourceView: sourceView)
        })
        alert.addAction(UIAlertAction(title: "Delete Audio File", style: .destructive) { [weak self] _ in
            self?.confirmDelete(item)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }

        present(alert, animated: true)
    }

    private func play(_ item: AudioRecordingItem) {
        stopPlayback()

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: item.url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            playingURL = item.url
            tableView.reloadData()
        } catch {
            showAlert(message: "Playback failed: \(error.localizedDescription)")
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingURL = nil
        tableView.reloadData()
    }

    private func share(_ item: AudioRecordingItem, sourceView: UIView) {
        let vc = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        if let popover = vc.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(vc, animated: true)
    }
    
    private func confirmDelete(_ item: AudioRecordingItem) {
        let alert = UIAlertController(
            title: "Delete Audio File?",
            message: "This permanently deletes \(item.displayName) and its recording sidecar from this iPad. The session manifest and survey JSON remain, but the original audio cannot be recovered or uploaded. This cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.delete(item)
        })
        present(alert, animated: true)
    }
    
    private func delete(_ item: AudioRecordingItem) {
        if playingURL == item.url {
            stopPlayback()
        }
        
        do {
            try FileManager.default.removeItem(at: item.url)
            let metadataURL = item.url.deletingPathExtension().appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                try? FileManager.default.removeItem(at: metadataURL)
            }
            let sessionDirectory = item.url.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: LocalSessionManifestStore.url(in: sessionDirectory).path
            ) {
                try LocalSessionManifestStore.update(in: sessionDirectory) { manifest in
                    manifest.audioStatus = .failed
                    if manifest.uploadStatus != .uploaded {
                        manifest.uploadStatus = .failed
                    }
                    manifest.retry.lastError = "Original audio was explicitly deleted on this device."
                    manifest.retry.nextRetryAt = nil
                }
            }
            
            recordings.removeAll { $0.url == item.url }
            if recordings.isEmpty {
                tableView.reloadData()
                showAlert(message: "Audio file deleted. No audio files remain in this view.") { [weak self] in
                    self?.closeTapped()
                }
            } else {
                tableView.reloadData()
            }
        } catch {
            showAlert(message: "Delete failed: \(error.localizedDescription)")
        }
    }

    private func showAlert(message: String, completion: (() -> Void)? = nil) {
        let alert = UIAlertController(title: "Audio Files", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completion?()
        })
        present(alert, animated: true)
    }

    @objc private func closeTapped() {
        stopPlayback()
        dismiss(animated: true)
    }
}

enum AudioRecordingLibrary {
    static func loadRecordings() -> [AudioRecordingItem] {
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

        return sessionDirs.flatMap { sessionDir in
            loadRecordings(in: sessionDir)
        }
        .sorted { $0.recordedAt > $1.recordedAt }
    }

    static func groupedByLocation() -> [(location: String, recordings: [AudioRecordingItem])] {
        let grouped = Dictionary(grouping: loadRecordings()) { $0.location }
        return grouped
            .map { location, recordings in
                (location: location, recordings: recordings.sorted { $0.recordedAt > $1.recordedAt })
            }
            .sorted { lhs, rhs in
                let lhsNewest = lhs.recordings.first?.recordedAt ?? .distantPast
                let rhsNewest = rhs.recordings.first?.recordedAt ?? .distantPast
                if lhsNewest == rhsNewest {
                    return lhs.location.localizedCaseInsensitiveCompare(rhs.location) == .orderedAscending
                }
                return lhsNewest > rhsNewest
            }
    }

    private static func loadRecordings(in sessionDir: URL) -> [AudioRecordingItem] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let sessionId = sessionDir.lastPathComponent
        let fallbackLocation = locationFromSurveyExport(in: files) ?? "Unknown Location"

        return files
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .map { url in
                let metadata = metadataForRecording(url)
                return AudioRecordingItem(
                    url: url,
                    sessionId: sessionId,
                    location: metadata.location ?? fallbackLocation,
                    recordedAt: metadata.recordedAt ?? recordedAt(for: url)
                )
            }
    }

    private static func metadataForRecording(_ url: URL) -> (location: String?, recordedAt: Date?) {
        let metadataURL = url.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        let location = (json["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let epoch = json["recorded_at_epoch"] as? TimeInterval
        return (
            location?.isEmpty == false ? location : nil,
            epoch.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func locationFromSurveyExport(in files: [URL]) -> String? {
        let decoder = JSONDecoder()
        let exportFiles = files.filter {
            $0.pathExtension.lowercased() == "json" && $0.lastPathComponent.hasPrefix("survey_results_")
        }

        for url in exportFiles.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url),
                  let survey = try? decoder.decode(ExportedSurvey.self, from: data),
                  let location = survey.respondentInfo?.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !location.isEmpty else {
                continue
            }
            return location
        }

        return nil
    }

    private static func recordedAt(for url: URL) -> Date {
        if let timestamp = timestampFromRecordingFilename(url.deletingPathExtension().lastPathComponent) {
            return Date(timeIntervalSince1970: timestamp)
        }

        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }

    private static func timestampFromRecordingFilename(_ name: String) -> TimeInterval? {
        guard name.hasPrefix("recording_") else { return nil }
        let raw = String(name.dropFirst("recording_".count))
        return TimeInterval(raw)
    }
}
