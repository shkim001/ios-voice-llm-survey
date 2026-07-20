import UIKit
import AVFoundation

class ViewController: UIViewController, AVAudioPlayerDelegate {

    // MARK: - Properties
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var aggregateButton: UIButton!
    private var dashboardButton: UIButton?
    private var audioFilesButton: UIButton?
    private var locationModeButton: UIButton?

    // Recording state
    private var isRecording = false
    private var recordedData: String?
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingURL: URL?
    private weak var recordingMonitorViewController: RecordingMonitorViewController?
    private weak var recordingReviewViewController: RecordingReviewViewController?
    private var recordingStartTrajectoryPoint: TrajectoryPoint?
    private var interviewTrajectoryPoints: [TrajectoryPoint] = []

    // Per-participant session (local-only separation)
    private var sessionId: String?
    private var sessionDirectoryURL: URL?

    // Cloud (Survey API / Cloud SQL) session
    private var cloudRespondentId: String?
    private var cloudSessionId: String?

    // Inactivity auto-reset
    private var inactivityTimer: Timer?
    private let inactivityTimeoutSeconds: TimeInterval = 420

    // Questionnaire and analysis
    private var questionnaireData: QuestionnaireData?
    private var transcription: String?
    private var matchedQuestions: [MatchedQuestion] = []
    private var interviewerCheckedOptionCodesByQuestionId: [Int: [String]] = [:]
    private var respondentInfo: RespondentInfo?
    private var didOfferRecoveryThisAppearance = false
    /// Set when pushing from `MapViewController`; passed into the respondent form until a successful submit.
    var mapLocationPrefill: MapLocationPayload?

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        loadQuestionnaire()
        setupUI()
        initializeSessionAndPurge()
        resetInactivityTimer()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deferredSessionWorkDiscovered(_:)),
            name: .deferredSessionWorkDiscovered,
            object: nil
        )
        DeferredSessionOutbox.shared.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateLocationModeStatus()
        resetInactivityTimer()
        offerRecoverableInterviewIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        invalidateInactivityTimer()
    }

    // MARK: - UI Setup
    private func setupUI() {
        // Set title
        title = "Interview Recorder"

        // Add settings button to navigation bar
        let settingsButton = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            style: .plain,
            target: self,
            action: #selector(settingsButtonTapped)
        )

        navigationItem.rightBarButtonItems = [settingsButton]
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            style: .plain,
            target: self,
            action: #selector(sessionToolsButtonTapped)
        )

        // Request microphone permission
        requestMicrophonePermission()

        // Setup status label
        statusLabel.text = "Ready"
        statusLabel.font = UIFont.systemFont(ofSize: 18, weight: .regular)
        statusLabel.textAlignment = .center
        statusLabel.textColor = .systemGray
        statusLabel.numberOfLines = 0

        // Check API key status
        checkAPIKeyStatus()

        let locationButton = UIButton(type: .system)
        locationButton.translatesAutoresizingMaskIntoConstraints = false
        locationButton.contentHorizontalAlignment = .leading
        locationButton.addTarget(self, action: #selector(locationModeButtonTapped), for: .touchUpInside)
        locationButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
        if let stack = statusLabel.superview as? UIStackView,
           let statusIndex = stack.arrangedSubviews.firstIndex(of: statusLabel) {
            stack.insertArrangedSubview(locationButton, at: statusIndex + 1)
        }
        locationModeButton = locationButton
        updateLocationModeStatus()

        // Setup record button
        setupButton(recordButton, title: "Start Interview", backgroundColor: .systemRed)

        // Setup aggregate button
        setupButton(aggregateButton, title: "Aggregate Results", backgroundColor: .systemTeal)

        // Create and setup dashboard button programmatically
        let dashboardBtn = UIButton(type: .system)
        dashboardBtn.translatesAutoresizingMaskIntoConstraints = false
        setupButton(dashboardBtn, title: "Dashboard", backgroundColor: .systemIndigo)
        dashboardBtn.addTarget(self, action: #selector(dashboardButtonTapped(_:)), for: .touchUpInside)
        view.addSubview(dashboardBtn)
        self.dashboardButton = dashboardBtn

        // Create and setup audio files button programmatically
        let audioBtn = UIButton(type: .system)
        audioBtn.translatesAutoresizingMaskIntoConstraints = false
        setupButton(audioBtn, title: "Audio Files", backgroundColor: UIColor(red: 0.0, green: 0.36, blue: 0.16, alpha: 1.0))
        audioBtn.addTarget(self, action: #selector(audioFilesButtonTapped(_:)), for: .touchUpInside)
        view.addSubview(audioBtn)
        self.audioFilesButton = audioBtn

        // Add constraints for programmatic buttons positioned below aggregate button
        NSLayoutConstraint.activate([
            dashboardBtn.topAnchor.constraint(equalTo: aggregateButton.bottomAnchor, constant: 16),
            dashboardBtn.leadingAnchor.constraint(equalTo: aggregateButton.leadingAnchor),
            dashboardBtn.trailingAnchor.constraint(equalTo: aggregateButton.trailingAnchor),
            dashboardBtn.heightAnchor.constraint(equalToConstant: 50),

            audioBtn.topAnchor.constraint(equalTo: dashboardBtn.bottomAnchor, constant: 16),
            audioBtn.leadingAnchor.constraint(equalTo: aggregateButton.leadingAnchor),
            audioBtn.trailingAnchor.constraint(equalTo: aggregateButton.trailingAnchor),
            audioBtn.heightAnchor.constraint(equalToConstant: 50)
        ])

        dashboardBtn.isEnabled = true
        audioBtn.isEnabled = true
        dashboardBtn.alpha = 1.0
        audioBtn.alpha = 1.0
    }

    private func setupButton(_ button: UIButton, title: String, backgroundColor: UIColor) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = backgroundColor
        config.baseForegroundColor = .systemBackground
        config.cornerStyle = .medium
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
            return attributes
        }
        button.configuration = config
        button.layer.cornerRadius = 0
    }

    private func updateButton(_ button: UIButton, title: String, backgroundColor: UIColor) {
        if button.configuration == nil {
            setupButton(button, title: title, backgroundColor: backgroundColor)
            return
        }

        button.configuration?.title = title
        button.configuration?.baseBackgroundColor = backgroundColor
    }

    // MARK: - Button Actions
    @IBAction func recordButtonTapped(_ sender: UIButton) {
        resetInactivityTimer()
        // If not recording, show info form first
        if !isRecording {
            guard InterviewerProfileStore.shared.currentProfile != nil else {
                showMessage("Set interviewer name and email in Settings before starting an interview.")
                showInterviewerProfileInput()
                animateButton(sender)
                return
            }

            // Clear any stale analysis state before starting a new recording.
            transcription = nil
            matchedQuestions = []
            interviewerCheckedOptionCodesByQuestionId = [:]
            interviewTrajectoryPoints = []

            resolveFixedLocationIfNeededBeforeInterview { [weak self] in
                self?.selectQuestionnaireIfNeeded { [weak self] in
                    self?.showRespondentInfoForm { [weak self] info in
                        guard let self = self else { return }
                        self.respondentInfo = info

                        // Start recording only after the selected location snapshot is durable.
                        self.prepareAndStartRecording()
                        self.resetInactivityTimer()
                    }
                }
            }
            animateButton(sender)
            return
        }

        // Stop recording
        isRecording = false
        stopRecording(showReview: true)
        animateButton(sender)
    }

    private func submitRecordingForServerProcessing() {
        guard recordingURL != nil, sessionDirectoryURL != nil else {
            showMessage("No recording available. Please record first.")
            return
        }
        invalidateInactivityTimer()
        let completedLocalSessionId = sessionId
        statusLabel.text = "Recording saved locally\nSending to server for processing"
        statusLabel.textColor = .systemBlue
        startNextParticipant()
        Task { [weak self] in
            let summary = await DeferredSessionOutbox.shared.run(trigger: .sessionReady)
            guard let self, let completedLocalSessionId else { return }
            if summary.uploadedSessionIds.contains(completedLocalSessionId) {
                statusLabel.text = "Recording uploaded\nServer transcription and analysis queued"
                statusLabel.textColor = .systemGreen
            } else if summary.failedSessionIds.contains(completedLocalSessionId) {
                statusLabel.text = "Recording safe locally\nServer upload pending retry"
                statusLabel.textColor = .systemOrange
            } else {
                statusLabel.text = "Recording safe locally\nOpen Dashboard to check processing"
                statusLabel.textColor = .systemOrange
            }
            resetInactivityTimer()
        }
    }

    private func handleDurableProcessingOutcome(
        _ outcome: DurableProcessingOutcome,
        recordingURL: URL
    ) {
        resetInactivityTimer()
        switch outcome {
        case .needsClarification(let transcript, let matches),
             .analysisCompleted(let transcript, let matches):
            self.transcription = transcript
            let questions = questionnaireData?.questionnaire.questions ?? []
            let assistedMatches = applyInterviewerCheckedOptions(to: matches, questions: questions)
            let needsClarification = assistedMatches.contains { requiresClarification($0) }
            do {
                try updateCurrentManifest { manifest in
                    manifest.analysisStatus = .completed
                    manifest.matchedQuestions = assistedMatches
                    manifest.clarificationStatus = needsClarification ? .pending : .notRequired
                    manifest.analysisErrorCategory = nil
                    manifest.retry.lastError = nil
                }
            } catch {
                presentProcessingRecoveryAlert(
                    title: "Analysis Save Failed",
                    message: error.localizedDescription,
                    stage: .analysis
                )
                return
            }
            statusLabel.text = needsClarification ? "Analysis saved; clarification required" : "Analysis saved locally"
            statusLabel.textColor = .systemGreen
            resolveClarificationsIfNeeded(
                transcription: transcript,
                matchedQuestions: assistedMatches,
                recordingURL: recordingURL
            )
        case .readyToUpload:
            statusLabel.text = "Interview is ready to upload"
            statusLabel.textColor = .systemGreen
        case .deferred(let stage, _, let message):
            statusLabel.text = "Processing saved for later"
            statusLabel.textColor = .systemOrange
            presentProcessingRecoveryAlert(
                title: stage == .transcription ? "Transcription Requires Connectivity" : "Processing Deferred",
                message: message,
                stage: stage
            )
        case .failed(let stage, let category, let message):
            if category == .audioUnavailable {
                statusLabel.text = "Saved recording is not playable"
                statusLabel.textColor = .systemRed
                let alert = UIAlertController(
                    title: "Recording Cannot Be Processed",
                    message: message,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                    self?.startNextParticipant()
                })
                present(alert, animated: true)
                return
            }
            statusLabel.text = stage == .transcription ? "Transcription needs retry" : "LLM analysis needs retry"
            statusLabel.textColor = .systemRed
            presentProcessingRecoveryAlert(
                title: stage == .transcription ? "Transcription Failed" : "LLM Analysis Failed",
                message: message,
                stage: stage
            )
        case .alreadyRunning:
            statusLabel.text = "Processing is already running for this interview"
            statusLabel.textColor = .systemOrange
        }
    }

    private func presentProcessingRecoveryAlert(
        title: String,
        message: String,
        stage: DurableProcessingStage
    ) {
        let alert = UIAlertController(
            title: title,
            message: "\(message)\n\nThe original audio and saved progress remain on this iPad.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
            self?.submitRecordingForServerProcessing()
        })
        alert.addAction(UIAlertAction(title: "Process Later", style: .cancel) { [weak self] _ in
            self?.finishAndProcessLater(stage: stage)
        })
        present(alert, animated: true)
    }

    private func finishAndProcessLater(stage: DurableProcessingStage) {
        guard let sessionDirectoryURL, let recordingURL else {
            showBlockingRecordingError(
                title: "Draft Verification Failed",
                message: "The active interview was not cleared because its saved audio manifest could not be verified."
            )
            return
        }
        do {
            let manifest = try LocalSessionManifestStore.load(from: sessionDirectoryURL)
            guard manifest.audioStatus == .recordedLocally else { throw CocoaError(.fileReadCorruptFile) }
            try verifyRecordedAudio(at: recordingURL)
        } catch {
            showBlockingRecordingError(
                title: "Draft Verification Failed",
                message: "The active interview was not cleared because its saved audio or manifest could not be verified. \(error.localizedDescription)"
            )
            return
        }
        startNextParticipant()
        statusLabel.text = stage == .transcription
            ? "Audio saved; transcription pending"
            : "Audio and transcript saved; analysis pending"
        statusLabel.textColor = .systemOrange
    }

    @objc private func sessionToolsButtonTapped() {
        resetInactivityTimer()

        let alert = UIAlertController(
            title: "Session Tools",
            message: "Choose a utility action",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "Export Current Session JSON", style: .default) { [weak self] _ in
            self?.exportCurrentSessionJSON()
        })
        alert.addAction(UIAlertAction(title: "Dashboard", style: .default) { [weak self] _ in
            self?.showDashboard()
        })
        alert.addAction(UIAlertAction(title: "Review Unprocessed Sessions", style: .default) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self?.offerRecoverableInterviewIfNeeded(force: true)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.leftBarButtonItem
        }

        present(alert, animated: true)
    }

    private func offerRecoverableInterviewIfNeeded(force: Bool = false) {
        guard !isRecording, respondentInfo == nil, recordingURL == nil else { return }
        guard force || !didOfferRecoveryThisAppearance else { return }
        guard viewIfLoaded?.window != nil else { return }
        guard presentedViewController == nil else { return }
        didOfferRecoveryThisAppearance = true

        let directories = recoverableSessionDirectories()
        guard !directories.isEmpty else {
            if force { showMessage("No saved interview currently needs processing.") }
            return
        }

        let count = directories.count
        let alert = UIAlertController(
            title: count == 1 ? "Unprocessed Session Found" : "Unprocessed Sessions Found",
            message: "There \(count == 1 ? "is" : "are") \(count) saved session\(count == 1 ? "" : "s") waiting for processing or upload. The original recordings remain safe on this device. Would you like to review them now?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Review Now", style: .default) { [weak self] _ in
            self?.showDashboard()
        })
        alert.addAction(UIAlertAction(title: "Do Later", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func deferredSessionWorkDiscovered(_ notification: Notification) {
        offerRecoverableInterviewIfNeeded()
    }

    private func recoverableSessionDirectories() -> [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = documents.appendingPathComponent("SurveySessions", isDirectory: true)
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return directories.compactMap { directory -> (URL, TimeInterval)? in
            guard let manifest = try? LocalSessionManifestStore.load(from: directory),
                  manifest.audioStatus == .recordedLocally,
                  manifest.uploadStatus != .uploaded,
                  manifest.audioFileName != nil else { return nil }
            let requiresWork = manifest.transcriptionStatus != .completed
                || manifest.analysisStatus != .completed
                || manifest.clarificationStatus == .pending
                || manifest.uploadStatus != .uploaded
            return requiresWork ? (directory, manifest.updatedAt) : nil
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    private func resumeRecoverableInterview(in directoryURL: URL) {
        SessionLocationRetryPresenter.resolveIfNeeded(
            in: directoryURL,
            from: self
        ) { [weak self] shouldContinue in
            guard shouldContinue else { return }
            self?.resumeRecoverableInterviewAfterLocationResolution(in: directoryURL)
        }
    }

    private func resumeRecoverableInterviewAfterLocationResolution(in directoryURL: URL) {
        do {
            let session = try SessionManager.shared.resumeSession(at: directoryURL)
            var manifest = try LocalSessionManifestStore.load(from: directoryURL)
            guard let audioFileName = manifest.audioFileName else { throw CocoaError(.fileNoSuchFile) }
            let audioURL = directoryURL.appendingPathComponent(audioFileName)
            do {
                try verifyRecordedAudio(at: audioURL)
            } catch {
                let message = DurableProcessingError.audioUnavailable.localizedDescription
                try? LocalSessionManifestStore.update(in: directoryURL) { value in
                    value.audioStatus = .failed
                    value.transcriptionStatus = .failed
                    value.transcriptionErrorCategory = DurableProcessingErrorCategory.audioUnavailable.rawValue
                    value.retry.lastError = message
                    value.retry.lastAttemptAt = Date().timeIntervalSince1970
                    value.retry.nextRetryAt = nil
                }
                showBlockingRecordingError(
                    title: "Saved Recording Is Not Playable",
                    message: message
                )
                return
            }

            if manifest.questionnaireSnapshot == nil {
                let bundled = try QuestionnaireStore.shared.loadBundledQuestionnaire().questionnaire
                try LocalSessionManifestStore.update(in: directoryURL) { value in
                    value.questionnaireSnapshot = bundled
                    value.questionnaireId = bundled.id
                    value.questionnaireVersion = bundled.version
                    value.questionnaireHash = bundled.hash
                }
                manifest = try LocalSessionManifestStore.load(from: directoryURL)
            }

            sessionId = session.id
            sessionDirectoryURL = directoryURL
            recordingURL = audioURL
            respondentInfo = manifest.respondentSnapshot
            questionnaireData = manifest.questionnaireSnapshot.map { QuestionnaireData(questionnaire: $0) }
            transcription = manifest.transcription
            matchedQuestions = manifest.matchedQuestions
            cloudRespondentId = manifest.cloudRespondentId
            cloudSessionId = manifest.cloudSessionId
            recordingStartTrajectoryPoint = manifest.locationPoint
            interviewTrajectoryPoints = manifest.trajectoryPoints
            interviewerCheckedOptionCodesByQuestionId = Dictionary(uniqueKeysWithValues:
                manifest.interviewerCheckedOptionCodesByQuestionId.compactMap { key, value in
                    Int(key).map { ($0, value) }
                }
            )
            submitRecordingForServerProcessing()
        } catch {
            showBlockingRecordingError(
                title: "Saved Interview Could Not Be Resumed",
                message: error.localizedDescription
            )
        }
    }

    private func exportCurrentSessionJSON() {
        resetInactivityTimer()
        guard let transcription = transcription, !matchedQuestions.isEmpty else {
            showMessage("No analysis data to export")
            return
        }

        guard respondentInfo != nil else {
            showMessage("Missing respondent information")
            return
        }

        guard InterviewerProfileStore.shared.currentProfile != nil else {
            showMessage("Missing interviewer information")
            return
        }

        let package = makeSessionPackage(
            transcription: transcription,
            matchedQuestions: matchedQuestions,
            recordingURL: recordingURL
        )

        // Convert to JSON data
        guard let jsonData = try? encodeSessionPackage(package) else {
            showMessage("JSON conversion failed")
            return
        }

        // Save into the current per-participant session folder
        let fileName = "session.json"

        let sessionFileURL: URL
        do {
            let session = try SessionManager.shared.ensureCurrentSession()
            sessionId = session.id
            sessionDirectoryURL = session.directoryURL
            sessionFileURL = session.directoryURL.appendingPathComponent(fileName)
        } catch {
            statusLabel.text = "Failed to create session directory"
            statusLabel.textColor = .systemRed
            showMessage("Unable to create or access the session directory: \(error.localizedDescription)")
            return
        }

        do {
            try jsonData.write(to: sessionFileURL, options: [.atomic])

            // Show export success
            statusLabel.text = "JSON exported successfully!\nSaved to App Folder"
            statusLabel.textColor = .systemGreen

            // Show success message with file location
            let alert = UIAlertController(
                title: "Export Successful",
                message: "File saved to:\n\(fileName)\n\nLocation: App Folder/SurveySessions/\(sessionId ?? "unknown")",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "View JSON", style: .default) { _ in
                // Show JSON content in a scrollable view
                self.showJSONContent(String(data: jsonData, encoding: .utf8) ?? "")
            })
            alert.addAction(UIAlertAction(title: "Share", style: .default) { _ in
                // Show share sheet
                self.shareFile(url: sessionFileURL)
            })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(alert, animated: true)

        } catch {
            statusLabel.text = "Export failed"
            statusLabel.textColor = .systemRed
            showMessage("Failed to save file: \(error.localizedDescription)")
        }
    }

    @IBAction func aggregateButtonTapped(_ sender: UIButton) {
        resetInactivityTimer()
        animateButton(sender)

        // Show action menu
        let alert = UIAlertController(
            title: "Aggregate Results",
            message: "Please select an action",
            preferredStyle: .actionSheet
        )

        // Option 1: View by Location
        alert.addAction(UIAlertAction(title: "View by Location", style: .default) { [weak self] _ in
            self?.performLocationAggregation()
        })

        // Option 2: View All
        alert.addAction(UIAlertAction(title: "View All", style: .default) { [weak self] _ in
            self?.performAggregation(action: .view)
        })

        // Option 3: Export aggregated JSON
        alert.addAction(UIAlertAction(title: "Export Aggregated JSON", style: .default) { [weak self] _ in
            self?.performAggregation(action: .export)
        })

        // Option 4: Cancel
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // iPad support
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sender
            popover.sourceRect = sender.bounds
        }

        present(alert, animated: true)
    }

    @objc private func audioFilesButtonTapped(_ sender: UIButton) {
        resetInactivityTimer()
        animateButton(sender)

        guard !isRecording else {
            showMessage("Audio files are unavailable while recording")
            return
        }

        let alert = UIAlertController(
            title: "Audio Files",
            message: "Please select an action",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "View by Location", style: .default) { [weak self] _ in
            self?.showAudioFilesByLocation()
        })

        alert.addAction(UIAlertAction(title: "View All", style: .default) { [weak self] _ in
            self?.showAllAudioFiles()
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = sender
            popover.sourceRect = sender.bounds
        }

        present(alert, animated: true)
    }

    private func showAllAudioFiles() {
        let recordings = AudioRecordingLibrary.loadRecordings()
        guard !recordings.isEmpty else {
            showMessage("No audio files found")
            return
        }

        let vc = AudioFilesViewController(recordings: recordings)
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    private func showAudioFilesByLocation() {
        let grouped = AudioRecordingLibrary.groupedByLocation()
        guard !grouped.isEmpty else {
            showMessage("No audio files found")
            return
        }

        let vc = AudioLocationsViewController(groupedRecordings: grouped)
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    @objc private func dashboardButtonTapped(_ sender: UIButton) {
        resetInactivityTimer()
        animateButton(sender)
        showDashboard()
    }

    private func showDashboard() {
        guard !isRecording else {
            showMessage("Dashboard is unavailable while recording")
            return
        }

        let sessions = LocalSessionDashboardLibrary.loadSessions()
        let vc = LocalSessionDashboardViewController(sessions: sessions)
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    // Aggregation action type
    private enum AggregationAction {
        case view
        case export
    }

    // Aggregation result data structure
    private struct AggregationResult {
        let summary: String
        let statistics: [String: [String: Int]]
        let answerDisplayNames: [String: [String: String]]
        let questionTexts: [String: String]
        let questionIds: [String: Int]
        let questionnaireNames: [String: String]
        let processedFiles: Int
    }

    private struct AggregationSurveyRecord {
        let sourceURL: URL
        let survey: ExportedSurvey
    }

    // Perform aggregation operation
    private func performAggregation(action: AggregationAction) {
        statusLabel.text = "Aggregating historical responses..."
        statusLabel.textColor = .systemBlue
        aggregateButton.isEnabled = false
        aggregateButton.alpha = 0.5

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let records = try self.loadAggregationSurveyRecords()

                if records.isEmpty {
                    DispatchQueue.main.async {
                        self.statusLabel.text = "No historical data available for aggregation"
                        self.statusLabel.textColor = .systemOrange
                        self.showMessage("No analyzed session.json packages found for aggregation")
                        self.aggregateButton.isEnabled = true
                        self.aggregateButton.alpha = 1.0
                    }
                    return
                }

                var allQuestionKeys = Set<String>()
                var statistics: [String: [String: Int]] = [:]
                var answerDisplayNames: [String: [String: String]] = [:]
                var questionTexts: [String: String] = [:]
                var questionIds: [String: Int] = [:]
                var questionnaireNames: [String: String] = [:]

                var processedFiles = 0

                // Process responses in each session package.
                for record in records {
                    let exportEntry = record.survey
                    processedFiles += 1
                    let questionnaireKey = self.aggregationQuestionnaireKey(for: exportEntry)
                    questionnaireNames[questionnaireKey] = self.aggregationQuestionnaireName(for: exportEntry)
                    let expectedQuestionKeys = self.expectedAggregationQuestionKeys(
                        for: exportEntry,
                        questionTexts: &questionTexts,
                        questionIds: &questionIds,
                        questionnaireNames: &questionnaireNames
                    )
                    allQuestionKeys.formUnion(expectedQuestionKeys)

                    for questionKey in expectedQuestionKeys where statistics[questionKey] == nil {
                        statistics[questionKey] = [
                            "yes": 0,
                            "no": 0,
                            "unanswered": 0
                        ]
                    }

                    // Track questions that appear in this response
                    var currentResponseQuestionKeys: Set<String> = []

                    for item in exportEntry.matchedQuestions {
                        let questionKey = self.aggregationQuestionKey(
                            questionnaireKey: questionnaireKey,
                            questionId: item.matchedQuestionId
                        )
                        allQuestionKeys.insert(questionKey)
                        currentResponseQuestionKeys.insert(questionKey)
                        questionIds[questionKey] = item.matchedQuestionId

                        if let selectedCodes = item.selectedOptionCodes, !selectedCodes.isEmpty {
                            for (index, code) in selectedCodes.enumerated() {
                                let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                                guard !normalizedCode.isEmpty else { continue }
                                let answerType = "option:\(normalizedCode)"
                                statistics[questionKey, default: [:]][answerType, default: 0] += 1
                                if answerDisplayNames[questionKey] == nil {
                                    answerDisplayNames[questionKey] = [:]
                                }
                                let label = item.selectedOptionLabels?.indices.contains(index) == true ? item.selectedOptionLabels?[index] : nil
                                answerDisplayNames[questionKey]?[answerType] = label.map { "\(normalizedCode). \($0)" } ?? normalizedCode
                            }
                            if questionTexts[questionKey] == nil {
                                questionTexts[questionKey] = item.matchedQuestion
                            }
                            continue
                        }

                        let preferredAnswer = item.finalAnswer ?? item.extractedAnswer
                        guard let answer = preferredAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
                            continue
                        }

                        // Classify answer type: yes, no, or other
                        let normalizedAnswer = answer.lowercased()
                        let answerType: String

                        if normalizedAnswer.contains("yes") ||
                           normalizedAnswer.contains("good") || normalizedAnswer.contains("safe") ||
                           normalizedAnswer.contains("well") || normalizedAnswer.contains("appealing") {
                            answerType = "yes"
                        } else if normalizedAnswer.contains("no") ||
                                  normalizedAnswer.contains("unsafe") || normalizedAnswer.contains("poor") ||
                                  normalizedAnswer.contains("unappealing") {
                            answerType = "no"
                        } else {
                            // Cannot determine, keep original answer for display
                            answerType = normalizedAnswer
                        }

                        statistics[questionKey, default: [:]][answerType, default: 0] += 1

                        if answerDisplayNames[questionKey] == nil {
                            answerDisplayNames[questionKey] = [:]
                        }

                        // Save original answer for display (if yes/no type, save an example)
                        if answerType == "yes" || answerType == "no" {
                            if answerDisplayNames[questionKey]?[answerType] == nil {
                                answerDisplayNames[questionKey]?[answerType] = answerType == "yes" ? "Yes" : "No"
                            }
                        } else {
                            answerDisplayNames[questionKey]?[answerType] = answer
                        }

                        if questionTexts[questionKey] == nil {
                            questionTexts[questionKey] = item.matchedQuestion
                        }
                    }

                    // For questions from this session's questionnaire snapshot that don't appear, mark unanswered.
                    for questionKey in expectedQuestionKeys {
                        if !currentResponseQuestionKeys.contains(questionKey) {
                            statistics[questionKey, default: [:]]["unanswered", default: 0] += 1
                        }
                    }
                }

                if processedFiles == 0 {
                    DispatchQueue.main.async {
                        self.statusLabel.text = "No valid response data found"
                        self.statusLabel.textColor = .systemOrange
                        self.showMessage("No valid responses found in analyzed session packages")
                        self.aggregateButton.isEnabled = true
                        self.aggregateButton.alpha = 1.0
                    }
                    return
                }

                var summary = "Analyzed \(processedFiles) session package(s).\n\n"
                let sortedQuestionKeys = self.sortedAggregationQuestionKeys(
                    Array(allQuestionKeys),
                    questionIds: questionIds,
                    questionnaireNames: questionnaireNames
                )

                var currentQuestionnaireName: String?
                for questionKey in sortedQuestionKeys {
                    let questionnaireName = questionnaireNames[self.questionnaireKey(from: questionKey)] ?? "Unknown Questionnaire"
                    if questionnaireName != currentQuestionnaireName {
                        summary += "Questionnaire: \(questionnaireName)\n"
                        currentQuestionnaireName = questionnaireName
                    }
                    let questionId = questionIds[questionKey] ?? 0
                    let questionTitle = questionTexts[questionKey] ?? "Question \(questionId)"
                    summary += "Question \(questionId): \(questionTitle)\n"

                    let answerCounts = statistics[questionKey] ?? [:]

                    // Display yes, no, unanswered statistics
                    let yesCount = answerCounts["yes"] ?? 0
                    let noCount = answerCounts["no"] ?? 0
                    let unansweredCount = answerCounts["unanswered"] ?? 0
                    let totalCount = yesCount + noCount + unansweredCount

                    if totalCount > 0 {
                        summary += "  Total: \(totalCount) response(s)\n"
                        summary += "  Yes: \(yesCount) (\(totalCount > 0 ? Int(Double(yesCount) / Double(totalCount) * 100) : 0)%)\n"
                        summary += "  No: \(noCount) (\(totalCount > 0 ? Int(Double(noCount) / Double(totalCount) * 100) : 0)%)\n"
                        summary += "  Unanswered: \(unansweredCount) (\(totalCount > 0 ? Int(Double(unansweredCount) / Double(totalCount) * 100) : 0)%)\n"
                    }

                    // Display other answer types (if any)
                    let otherAnswers = answerCounts.filter { $0.key != "yes" && $0.key != "no" && $0.key != "unanswered" }
                    for (answerKey, count) in otherAnswers.sorted(by: { $0.value > $1.value }) {
                        let displayText = answerDisplayNames[questionKey]?[answerKey] ?? answerKey
                        summary += "  - \(displayText): \(count)\n"
                    }

                    summary += "\n"
                }

                let result = AggregationResult(
                    summary: summary,
                    statistics: statistics,
                    answerDisplayNames: answerDisplayNames,
                    questionTexts: questionTexts,
                    questionIds: questionIds,
                    questionnaireNames: questionnaireNames,
                    processedFiles: processedFiles
                )

                DispatchQueue.main.async {
                    self.statusLabel.text = "Aggregation complete. Processed \(processedFiles) record(s)"
                    self.statusLabel.textColor = .systemGreen

                    switch action {
                    case .view:
                        self.showScrollableContent(title: "Aggregation Results", content: result.summary)
                    case .export:
                        self.exportAggregationJSON(result: result)
                    }

                    self.aggregateButton.isEnabled = true
                    self.aggregateButton.alpha = 1.0
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Aggregation failed"
                    self.statusLabel.textColor = .systemRed
                    self.showMessage("Unable to access export directory: \(error.localizedDescription)")
                    self.aggregateButton.isEnabled = true
                    self.aggregateButton.alpha = 1.0
                }
            }
        }
    }

    private func aggregationQuestionnaireKey(for survey: ExportedSurvey) -> String {
        if let questionnaire = survey.metadata?.questionnaire {
            let id = questionnaire.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            let version = questionnaire.version?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id, !id.isEmpty, let version, !version.isEmpty {
                return "\(id)::\(version)"
            }
            if let id, !id.isEmpty {
                return id
            }
        }

        let title = aggregationQuestionnaireName(for: survey)
        return "title::\(title)"
    }

    private func aggregationQuestionnaireName(for survey: ExportedSurvey) -> String {
        let title = survey.metadata?.questionnaire?.title ?? survey.metadata?.questionnaireTitle
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = survey.metadata?.questionnaire?.version?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let trimmedTitle, !trimmedTitle.isEmpty else {
            return "Unknown Questionnaire"
        }

        if let version, !version.isEmpty {
            return "\(trimmedTitle) v\(version)"
        }
        return trimmedTitle
    }

    private func aggregationQuestionKey(questionnaireKey: String, questionId: Int) -> String {
        return "\(questionnaireKey)::q\(questionId)"
    }

    private func questionnaireKey(from questionKey: String) -> String {
        guard let range = questionKey.range(of: "::q", options: .backwards) else {
            return questionKey
        }
        return String(questionKey[..<range.lowerBound])
    }

    private func expectedAggregationQuestionKeys(
        for survey: ExportedSurvey,
        questionTexts: inout [String: String],
        questionIds: inout [String: Int],
        questionnaireNames: inout [String: String]
    ) -> Set<String> {
        let questionnaireKey = aggregationQuestionnaireKey(for: survey)
        questionnaireNames[questionnaireKey] = aggregationQuestionnaireName(for: survey)

        if let questions = survey.metadata?.questionnaire?.questions, !questions.isEmpty {
            return Set(questions.map { question in
                let questionKey = aggregationQuestionKey(questionnaireKey: questionnaireKey, questionId: question.id)
                questionTexts[questionKey] = question.question
                questionIds[questionKey] = question.id
                return questionKey
            })
        }

        // Older packages did not store the full questionnaire snapshot, so only questions that
        // appear in matched answers can be aggregated without guessing from the current app state.
        return Set(survey.matchedQuestions.map { item in
            let questionKey = aggregationQuestionKey(questionnaireKey: questionnaireKey, questionId: item.matchedQuestionId)
            if questionTexts[questionKey] == nil {
                questionTexts[questionKey] = item.matchedQuestion
            }
            questionIds[questionKey] = item.matchedQuestionId
            return questionKey
        })
    }

    private func sortedAggregationQuestionKeys(
        _ questionKeys: [String],
        questionIds: [String: Int],
        questionnaireNames: [String: String]
    ) -> [String] {
        return questionKeys.sorted { lhs, rhs in
            let lhsQuestionnaire = questionnaireNames[questionnaireKey(from: lhs)] ?? ""
            let rhsQuestionnaire = questionnaireNames[questionnaireKey(from: rhs)] ?? ""
            if lhsQuestionnaire != rhsQuestionnaire {
                return lhsQuestionnaire < rhsQuestionnaire
            }
            let lhsId = questionIds[lhs] ?? Int.max
            let rhsId = questionIds[rhs] ?? Int.max
            if lhsId != rhsId {
                return lhsId < rhsId
            }
            return lhs < rhs
        }
    }

    // Export aggregation results as JSON
    private func exportAggregationJSON(result: AggregationResult) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestampString = dateFormatter.string(from: Date())

        // Build JSON data structure
        var jsonData: [String: Any] = [
            "export_info": [
                "export_time": timestampString,
                "total_files_processed": result.processedFiles,
                "questionnaire_titles": Array(Set(result.questionnaireNames.values)).sorted()
            ],
            "aggregation_summary": result.summary,
            "statistics": [:]
        ]

        // Add statistics
        let sortedQuestionKeys = sortedAggregationQuestionKeys(
            Array(result.statistics.keys),
            questionIds: result.questionIds,
            questionnaireNames: result.questionnaireNames
        )
        var statisticsDict: [String: Any] = [:]

        for questionKey in sortedQuestionKeys {
            let questionId = result.questionIds[questionKey] ?? 0
            let questionTitle = result.questionTexts[questionKey] ?? "Question \(questionId)"
            var questionData: [String: Any] = [
                "questionnaire": result.questionnaireNames[questionnaireKey(from: questionKey)] ?? "Unknown Questionnaire",
                "question_id": questionId,
                "question_text": questionTitle,
                "answers": []
            ]

            let answerCounts = result.statistics[questionKey] ?? [:]
            let sortedAnswers = answerCounts.sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }

            var answersArray: [[String: Any]] = []
            for (answerKey, count) in sortedAnswers {
                let displayText = result.answerDisplayNames[questionKey]?[answerKey] ?? answerKey
                answersArray.append([
                    "answer": displayText,
                    "count": count
                ])
            }

            questionData["answers"] = answersArray
            statisticsDict[questionKey] = questionData
        }

        jsonData["statistics"] = statisticsDict

        // Convert to JSON data
        guard let jsonDataEncoded = try? JSONSerialization.data(withJSONObject: jsonData, options: .prettyPrinted) else {
            showMessage("JSON conversion failed")
            return
        }

        // Save to temporary file
        let fileName = "aggregation_results_\(Date().timeIntervalSince1970).json"
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileURL = tempDirectory.appendingPathComponent(fileName)

        do {
            try jsonDataEncoded.write(to: fileURL, options: [.atomic])

            // Use share functionality
            let activityViewController = UIActivityViewController(
                activityItems: [fileURL],
                applicationActivities: nil
            )

            // iPad support
            if let popover = activityViewController.popoverPresentationController {
                popover.sourceView = aggregateButton
                popover.sourceRect = aggregateButton.bounds
            }

            present(activityViewController, animated: true)

        } catch {
            showMessage("Failed to save file: \(error.localizedDescription)")
        }
    }

    // MARK: - Questionnaire Loading
    private func loadQuestionnaire() {
        do {
            let bundled = try QuestionnaireStore.shared.loadBundledQuestionnaire()
            let cached = QuestionnaireStore.shared.cachedQuestionnaires()
            let selected = QuestionnaireStore.shared.selectedQuestionnaire(
                from: cached,
                fallback: bundled.questionnaire
            )
            questionnaireData = QuestionnaireData(questionnaire: selected)
            print("Questionnaire loaded successfully: \(questionnaireData?.questionnaire.title ?? "Unknown")")
            refreshActiveQuestionnaires()
        } catch {
            print("Error loading questionnaire: \(error)")
            showMessage("Failed to load questionnaire: \(error.localizedDescription)")
        }
    }

    private func refreshActiveQuestionnaires() {
        guard SurveyAPIClient.shared.isConfigured() else { return }

        Task { [weak self] in
            do {
                let active = try await SurveyAPIClient.shared.fetchActiveQuestionnaires()
                guard !active.isEmpty else { return }
                await MainActor.run {
                    QuestionnaireStore.shared.saveCachedQuestionnaires(active)
                    let fallback = self?.questionnaireData?.questionnaire ?? active[0]
                    let selected = QuestionnaireStore.shared.selectedQuestionnaire(
                        from: active,
                        fallback: fallback
                    )
                    self?.questionnaireData = QuestionnaireData(questionnaire: selected)
                    print("Fetched \(active.count) active questionnaire(s). Current: \(selected.title)")
                }
            } catch {
                print("Questionnaire refresh failed: \(error.localizedDescription)")
            }
        }
    }

    private func selectQuestionnaireIfNeeded(completion: @escaping () -> Void) {
        let candidates = questionnaireSelectionCandidates()
        guard candidates.count > 1 || SurveyAPIClient.shared.isConfigured() else {
            if let only = candidates.first {
                QuestionnaireStore.shared.saveSelectedQuestionnaire(only)
                questionnaireData = QuestionnaireData(questionnaire: only)
            }
            completion()
            return
        }

        presentQuestionnaireSelection(cached: candidates, completion: completion)
    }

    private func questionnaireSelectionCandidates(_ remoteOrCached: [Questionnaire]? = nil) -> [Questionnaire] {
        var candidates = remoteOrCached ?? QuestionnaireStore.shared.cachedQuestionnaires()
        if let current = questionnaireData?.questionnaire,
           !candidates.contains(where: { $0.id == current.id && $0.version == current.version }) {
            candidates.insert(current, at: 0)
        }
        return candidates
    }

    private func presentQuestionnaireSelection(cached: [Questionnaire], completion: @escaping () -> Void) {
        let selector = QuestionnaireSelectionViewController(
            cached: cached,
            current: questionnaireData?.questionnaire,
            canRefresh: SurveyAPIClient.shared.isConfigured(),
            onSelect: { [weak self] questionnaire in
                QuestionnaireStore.shared.saveSelectedQuestionnaire(questionnaire)
                self?.questionnaireData = QuestionnaireData(questionnaire: questionnaire)
                completion()
            },
            onRefresh: { [weak self] in
                self?.refreshQuestionnaireSelection(completion: completion)
            }
        )
        selector.modalPresentationStyle = .overFullScreen
        selector.modalTransitionStyle = .crossDissolve
        present(selector, animated: true)
    }

    private func refreshQuestionnaireSelection(completion: @escaping () -> Void) {
        guard SurveyAPIClient.shared.isConfigured() else {
            showMessage("Survey API is not configured.")
            return
        }

        statusLabel.text = "Refreshing questionnaires..."
        statusLabel.textColor = .systemBlue

        Task { [weak self] in
            do {
                let active = try await SurveyAPIClient.shared.fetchActiveQuestionnaires()
                await MainActor.run {
                    guard let self else { return }
                    guard !active.isEmpty else {
                        self.statusLabel.text = "No published questionnaires found"
                        self.statusLabel.textColor = .systemOrange
                        self.showMessage("No published questionnaires were returned by the server.")
                        self.presentQuestionnaireSelection(
                            cached: self.questionnaireSelectionCandidates(),
                            completion: completion
                        )
                        return
                    }

                    QuestionnaireStore.shared.saveCachedQuestionnaires(active)
                    let fallback = self.questionnaireData?.questionnaire ?? active[0]
                    let selected = QuestionnaireStore.shared.selectedQuestionnaire(
                        from: active,
                        fallback: fallback
                    )
                    self.questionnaireData = QuestionnaireData(questionnaire: selected)
                    self.statusLabel.text = "Questionnaire list refreshed"
                    self.statusLabel.textColor = .systemGreen
                    self.presentQuestionnaireSelection(
                        cached: self.questionnaireSelectionCandidates(active),
                        completion: completion
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.statusLabel.text = "Questionnaire refresh failed"
                    self.statusLabel.textColor = .systemRed
                    self.showMessage("Failed to refresh questionnaires: \(error.localizedDescription)")
                    self.presentQuestionnaireSelection(
                        cached: self.questionnaireSelectionCandidates(),
                        completion: completion
                    )
                }
            }
        }
    }

    // MARK: - Permission Requests
    private func requestMicrophonePermission() {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if !granted {
                        self.showMessage("Microphone permission is required to record")
                    }
                }
            }
        } else {
            // Fallback for iOS < 17.0
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if !granted {
                        self.showMessage("Microphone permission is required to record")
                    }
                }
            }
        }
    }

    private func prepareAndStartRecording() {
        guard !isRecording else { return }

        let locationStore = SavedSurveyLocationStore.shared
        let mode = locationStore.mode
        let fixedLocation: SavedSurveyLocation?
        if mode == .fixed {
            guard let selected = locationStore.activeLocation else {
                showMissingFixedLocation()
                return
            }
            fixedLocation = selected
        } else {
            fixedLocation = nil
        }

        do {
            try verifyRecordingStorageCapacity()
            let session = try SessionManager.shared.ensureCurrentSession()
            sessionId = session.id
            sessionDirectoryURL = session.directoryURL
            let manifest = LocalSessionManifest(
                localSessionId: session.id,
                createdAt: session.createdAt.timeIntervalSince1970,
                interviewerSnapshot: InterviewerProfileStore.shared.currentProfile,
                respondentSnapshot: respondentInfo,
                questionnaireSnapshot: questionnaireData?.questionnaire,
                locationInfo: fixedLocation.map(SessionLocationInfo.fixed)
                    ?? (mode == .none ? .intentionallyDisabled : .device(collectionMethod: "pending_core_location")),
                locationStatus: mode == .device ? .acquiring : (mode == .fixed ? .available : .unavailable),
                locationSource: mode == .fixed ? .savedSurveyLocation : .none,
                locationQuality: .unknown,
                locationCoordinates: LocalSessionCoordinateSnapshot(
                    latitude: fixedLocation?.latitude,
                    longitude: fixedLocation?.longitude
                ),
                locationLabel: fixedLocation?.name
                    ?? (mode == .none ? "Location intentionally disabled" : respondentInfo?.location),
                placeSnapshot: fixedLocation.map {
                    LocalSessionPlaceSnapshot(
                        displayLabel: $0.name,
                        formattedAddress: $0.formattedAddress,
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                }
            )
            try LocalSessionManifestStore.save(manifest, to: session.directoryURL)
        } catch {
            showBlockingRecordingError(
                title: "Interview Draft Could Not Be Saved",
                message: "Recording was not started. \(error.localizedDescription)"
            )
            return
        }

        switch mode {
        case .fixed:
            do { _ = try locationStore.markActiveLocationUsed() }
            catch {
                showBlockingRecordingError(
                    title: "Fixed Location Could Not Be Updated",
                    message: "Recording was not started. \(error.localizedDescription)"
                )
                return
            }
            beginRecording(with: nil)
            return
        case .none:
            beginRecording(with: nil)
            return
        case .device:
            break
        }

        recordButton.isEnabled = false
        recordButton.alpha = 0.5
        statusLabel.text = "Checking GPS location...\nPlease wait"
        statusLabel.textColor = .systemBlue

        Task { [weak self] in
            let outcome = await TrajectoryTracker.shared.captureRecordingStartLocation()
            await MainActor.run {
                guard let self else { return }
                self.handleRecordingStartLocation(outcome)
            }
        }
    }

    private func verifyRecordingStorageCapacity() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let values = try documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard LocalRecordingStoragePolicy.hasSufficientCapacity(
            values.volumeAvailableCapacityForImportantUsage
        ) else {
            throw NSError(
                domain: "VoiceSurveyStorage",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "At least 100 MB of free storage is required before recording. Free space and try again."
                ]
            )
        }
    }

    private func handleRecordingStartLocation(_ outcome: RecordingStartLocationOutcome) {
        switch outcome {
        case .acceptable(let candidate):
            do {
                try persistLocationDecision(
                    status: .available,
                    source: .deviceGPS,
                    quality: candidate.quality,
                    horizontalAccuracyM: candidate.horizontalAccuracyM,
                    point: candidate.point,
                    place: nil,
                    error: nil
                )
                beginRecording(with: candidate.point)
            } catch {
                showLocationPersistenceFailure(error)
            }
        case .lowAccuracy(let candidate):
            do {
                try persistLocationDecision(
                    status: .lowAccuracy,
                    source: .deviceGPS,
                    quality: .low,
                    horizontalAccuracyM: candidate.horizontalAccuracyM,
                    point: candidate.point,
                    place: nil,
                    error: "GPS accuracy was (Int(candidate.horizontalAccuracyM.rounded())) meters."
                )
                presentLocationFallback(for: .lowAccuracy, lowAccuracyCandidate: candidate)
            } catch {
                showLocationPersistenceFailure(error)
            }
        case .failure(let failure):
            do {
                try persistLocationDecision(
                    status: RecordingStartLocationStateMapping.manifestStatus(for: failure),
                    source: .none,
                    quality: .unknown,
                    horizontalAccuracyM: nil,
                    point: nil,
                    place: nil,
                    error: locationFailureMessage(failure)
                )
                presentLocationFallback(for: failure, lowAccuracyCandidate: nil)
            } catch {
                showLocationPersistenceFailure(error)
            }
        }
    }

    private func beginRecording(with point: TrajectoryPoint?) {
        recordingStartTrajectoryPoint = point
        recordButton.isEnabled = true
        recordButton.alpha = 1.0
        isRecording = true
        startRecording(with: point)
    }

    private func persistLocationDecision(
        status: LocalSessionLocationStatus,
        source: LocalSessionLocationSource,
        quality: LocalSessionLocationQuality,
        horizontalAccuracyM: Double?,
        point: TrajectoryPoint?,
        place: LocalSessionPlaceSnapshot?,
        error: String?
    ) throws {
        guard let sessionDirectoryURL else { throw CocoaError(.fileNoSuchFile) }
        try LocalSessionManifestStore.update(in: sessionDirectoryURL) { manifest in
            manifest.locationStatus = status
            manifest.locationSource = source
            manifest.locationQuality = quality
            manifest.locationHorizontalAccuracyM = horizontalAccuracyM
            manifest.locationCoordinates = LocalSessionCoordinateSnapshot(
                latitude: place?.latitude ?? point?.lat,
                longitude: place?.longitude ?? point?.lon
            )
            manifest.locationPoint = point
            manifest.placeSnapshot = place
            manifest.locationLabel = place?.displayLabel ?? self.respondentInfo?.location
            manifest.trajectoryPoints = point.map { [$0] } ?? []
            if source == .deviceGPS {
                manifest.locationInfo = .device(
                    collectionMethod: "core_location",
                    name: manifest.locationLabel,
                    latitude: point?.lat,
                    longitude: point?.lon
                )
            } else if source == .placeSearch {
                manifest.locationInfo = .device(
                    collectionMethod: "mapkit_place_search",
                    name: place?.displayLabel,
                    address: place?.formattedAddress,
                    latitude: place?.latitude,
                    longitude: place?.longitude
                )
            } else {
                manifest.locationInfo = .device(collectionMethod: "unavailable_after_device_attempt")
            }
            manifest.retry.lastError = error
        }
    }

    private func presentLocationFallback(
        for failure: RecordingStartLocationFailure,
        lowAccuracyCandidate: RecordingStartLocationCandidate?
    ) {
        recordButton.isEnabled = true
        recordButton.alpha = 1
        isRecording = false
        statusLabel.text = "Choose how to set interview location"
        statusLabel.textColor = .systemOrange

        let alert = UIAlertController(
            title: lowAccuracyCandidate == nil ? "GPS Location Unavailable" : "GPS Accuracy Is Low",
            message: locationFailureMessage(failure) + "\n\nYou can retry, search for a place, or record without GPS.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Try GPS Again", style: .default) { [weak self] _ in
            self?.retryRecordingStartGPS()
        })
        if let candidate = lowAccuracyCandidate {
            alert.addAction(UIAlertAction(title: "Use Low-Accuracy GPS", style: .default) { [weak self] _ in
                guard let self else { return }
                do {
                    try self.persistLocationDecision(
                        status: .lowAccuracy,
                        source: .deviceGPS,
                        quality: .low,
                        horizontalAccuracyM: candidate.horizontalAccuracyM,
                        point: candidate.point,
                        place: nil,
                        error: nil
                    )
                    self.beginRecording(with: candidate.point)
                } catch {
                    self.showLocationPersistenceFailure(error)
                }
            })
        }
        alert.addAction(UIAlertAction(title: "Record Without GPS", style: .default) { [weak self] _ in
            guard let self else { return }
            do {
                try self.persistLocationDecision(
                    status: .unavailable,
                    source: .none,
                    quality: .unknown,
                    horizontalAccuracyM: nil,
                    point: nil,
                    place: nil,
                    error: nil
                )
                self.beginRecording(with: nil)
            } catch {
                self.showLocationPersistenceFailure(error)
            }
        })
        alert.addAction(UIAlertAction(title: "Search for an Address or Place", style: .default) { [weak self] _ in
            self?.presentPlaceSearch()
        })
        alert.addAction(UIAlertAction(title: "Cancel Interview", style: .cancel) { [weak self] _ in
            self?.cancelInterviewBeforeRecording()
        })
        present(alert, animated: true)
    }

    private func retryRecordingStartGPS() {
        do {
            try persistLocationDecision(
                status: .acquiring,
                source: .none,
                quality: .unknown,
                horizontalAccuracyM: nil,
                point: nil,
                place: nil,
                error: nil
            )
        } catch {
            showLocationPersistenceFailure(error)
            return
        }
        prepareAndStartRecordingFromExistingDraft()
    }

    private func prepareAndStartRecordingFromExistingDraft() {
        recordButton.isEnabled = false
        recordButton.alpha = 0.5
        statusLabel.text = "Checking GPS location...\nPlease wait"
        statusLabel.textColor = .systemBlue
        Task { [weak self] in
            let outcome = await TrajectoryTracker.shared.captureRecordingStartLocation()
            await MainActor.run { self?.handleRecordingStartLocation(outcome) }
        }
    }

    private func presentPlaceSearch() {
        let search = PlaceSearchViewController(
            onSelect: { [weak self] place in
                guard let self else { return }
                do {
                    try self.persistLocationDecision(
                        status: .available,
                        source: .placeSearch,
                        quality: .unknown,
                        horizontalAccuracyM: nil,
                        point: nil,
                        place: place,
                        error: nil
                    )
                    self.beginRecording(with: nil)
                } catch {
                    self.showLocationPersistenceFailure(error)
                }
            },
            onCancel: { [weak self] in
                self?.presentLocationFallback(for: .unavailable, lowAccuracyCandidate: nil)
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                let alert = UIAlertController(
                    title: "Place Search Failed",
                    message: "\(error.localizedDescription)\n\nReturn to the location choices to retry GPS, record without GPS, or search again.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Location Choices", style: .default) { [weak self] _ in
                    self?.presentLocationFallback(for: .unavailable, lowAccuracyCandidate: nil)
                })
                self.present(alert, animated: true)
            }
        )
        let navigation = UINavigationController(rootViewController: search)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func cancelInterviewBeforeRecording() {
        if let sessionDirectoryURL {
            try? LocalSessionManifestStore.remove(from: sessionDirectoryURL)
        }
        startNextParticipant()
        statusLabel.text = "Interview cancelled"
    }

    private func showLocationPersistenceFailure(_ error: Error) {
        recordButton.isEnabled = true
        recordButton.alpha = 1
        isRecording = false
        showBlockingRecordingError(
            title: "Location Choice Could Not Be Saved",
            message: "Recording was not started. \(error.localizedDescription)"
        )
    }

    private func locationFailureMessage(_ failure: RecordingStartLocationFailure) -> String {
        switch failure {
        case .permissionDenied: return "Location permission is denied."
        case .restricted: return "Location access is restricted on this device."
        case .timedOut: return "The GPS request timed out."
        case .unavailable: return "A current device GPS location is unavailable."
        case .stale: return "The available GPS location is older than 60 seconds."
        case .lowAccuracy: return "The device GPS estimate is less accurate than the 50-meter threshold."
        }
    }

    private func startRecording(with recordingStartPoint: TrajectoryPoint?) {
        resetInactivityTimer()
        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.playAndRecord, mode: .default)
            try audioSession.setActive(true)
        } catch {
            showMessage("Audio session setup failed: \(error.localizedDescription)")
            isRecording = false
            updateButton(recordButton, title: "Start Interview", backgroundColor: .systemRed)
            return
        }

        let url: URL
        do {
            // The recoverable session manifest already exists before this path is created.
            let session = try SessionManager.shared.ensureCurrentSession()
            sessionId = session.id
            sessionDirectoryURL = session.directoryURL

            url = try SessionManager.shared.makeRecordingURL()
            recordingURL = url
            try LocalSessionManifestStore.update(in: session.directoryURL) { manifest in
                manifest.audioFileName = url.lastPathComponent
                manifest.audioStatus = .preparing
            }
            writeRecordingMetadata(for: url, recordingStartPoint: recordingStartPoint)
        } catch {
            showMessage("Failed to create session/recording path: \(error.localizedDescription)")
            isRecording = false
            updateButton(recordButton, title: "Start Interview", backgroundColor: .systemRed)
            return
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            guard audioRecorder?.record() == true else {
                throw NSError(
                    domain: "VoiceSurveyRecording",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The audio recorder did not start."]
                )
            }
            if let sessionDirectoryURL {
                try LocalSessionManifestStore.update(in: sessionDirectoryURL) { manifest in
                    manifest.audioStatus = .recording
                    manifest.recordingStartedAt = Date().timeIntervalSince1970
                    manifest.retry.lastError = nil
                }
            }
            TrajectoryTracker.shared.startInterviewTracking(with: recordingStartPoint)
            interviewTrajectoryPoints = recordingStartPoint.map { [$0] } ?? []

            updateButton(recordButton, title: "Stop Recording", backgroundColor: .systemOrange)
            statusLabel.text = "Recording...\nSpeak into microphone"
            statusLabel.textColor = .systemRed
            dashboardButton?.isEnabled = false
            audioFilesButton?.isEnabled = false
            dashboardButton?.alpha = 0.5
            audioFilesButton?.alpha = 0.5
            presentRecordingMonitor()
        } catch {
            audioRecorder?.stop()
            if let sessionDirectoryURL {
                try? LocalSessionManifestStore.update(in: sessionDirectoryURL) { manifest in
                    manifest.audioStatus = .failed
                    manifest.retry.lastError = error.localizedDescription
                }
            }
            showBlockingRecordingError(
                title: "Recording Could Not Start",
                message: "The local session draft was kept. \(error.localizedDescription)"
            )
            isRecording = false
            updateButton(recordButton, title: "Start Interview", backgroundColor: .systemRed)
            dashboardButton?.isEnabled = true
            audioFilesButton?.isEnabled = true
            dashboardButton?.alpha = 1.0
            audioFilesButton?.alpha = 1.0
        }
    }

    private func stopRecording(showReview: Bool = false) {
        resetInactivityTimer()
        let stoppedAt = Date()
        audioRecorder?.stop()
        interviewTrajectoryPoints = TrajectoryTracker.shared.stopInterviewTracking()
        let monitorViewController = recordingMonitorViewController
        interviewerCheckedOptionCodesByQuestionId = monitorViewController?.selectedMultipleChoiceAnswers() ?? [:]
        if let recordingURL {
            updateRecordingTrajectoryMetadata(for: recordingURL, points: interviewTrajectoryPoints)
        }

        do {
            guard let recordingURL else {
                throw NSError(
                    domain: "VoiceSurveyRecording",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The recording path is missing."]
                )
            }
            try verifyRecordedAudio(at: recordingURL)
            guard let sessionDirectoryURL else {
                throw NSError(
                    domain: "VoiceSurveyRecording",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "The local session folder is missing."]
                )
            }
            let checkedOptions = Dictionary(uniqueKeysWithValues: interviewerCheckedOptionCodesByQuestionId.map {
                (String($0.key), $0.value)
            })
            try LocalSessionManifestStore.update(in: sessionDirectoryURL, now: stoppedAt) { manifest in
                manifest.audioStatus = .recordedLocally
                manifest.recordingStoppedAt = stoppedAt.timeIntervalSince1970
                manifest.trajectoryPoints = interviewTrajectoryPoints
                manifest.interviewerCheckedOptionCodesByQuestionId = checkedOptions
                manifest.retry.lastError = nil
            }
        } catch {
            if let sessionDirectoryURL {
                try? LocalSessionManifestStore.update(in: sessionDirectoryURL) { manifest in
                    manifest.audioStatus = .failed
                    manifest.recordingStoppedAt = stoppedAt.timeIntervalSince1970
                    manifest.trajectoryPoints = interviewTrajectoryPoints
                    manifest.retry.lastError = error.localizedDescription
                }
            }
            handleRecordingPersistenceFailure(error, monitorViewController: monitorViewController)
            return
        }

        updateButton(recordButton, title: "Start Interview", backgroundColor: .systemRed)
        statusLabel.text = "Recording stopped\nYou can play, recognize, or export"
        statusLabel.textColor = .systemGray

        dashboardButton?.isEnabled = true
        audioFilesButton?.isEnabled = true
        dashboardButton?.alpha = 1.0
        audioFilesButton?.alpha = 1.0

        recordedData = "Recording data - Timestamp: \(Date().timeIntervalSince1970)"
        recordingMonitorViewController = nil

        if showReview {
            if let monitorViewController {
                monitorViewController.dismiss(animated: true) { [weak self] in
                    self?.showPostRecordingReview()
                }
            } else {
                showPostRecordingReview()
            }
        } else {
            monitorViewController?.dismiss(animated: true)
        }
    }

    private func verifyRecordedAudio(at url: URL) throws {
        try PlayableInterviewAudioValidator().validate(audioURL: url)
    }

    private func handleRecordingPersistenceFailure(
        _ error: Error,
        monitorViewController: UIViewController?
    ) {
        isRecording = false
        recordButton.isEnabled = false
        recordButton.alpha = 0.5
        dashboardButton?.isEnabled = true
        audioFilesButton?.isEnabled = true
        dashboardButton?.alpha = 1.0
        audioFilesButton?.alpha = 1.0
        statusLabel.text = "Local recording verification failed"
        statusLabel.textColor = .systemRed
        recordingMonitorViewController = nil

        let presentError: () -> Void = { [weak self] in
            guard let self else { return }
            self.showBlockingRecordingError(
                title: "Recording Was Not Safely Finalized",
                message: "The app could not verify both the local audio and session manifest. The current participant was not reset. Files already written were kept.\n\n\(error.localizedDescription)"
            )
        }
        if let monitorViewController {
            monitorViewController.dismiss(animated: true, completion: presentError)
        } else {
            presentError()
        }
    }

    private func showBlockingRecordingError(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Files", style: .default))
        alert.addAction(UIAlertAction(title: "Discard Audio and Draft", style: .destructive) { [weak self] _ in
            self?.discardCurrentRecording()
        })
        present(alert, animated: true)
    }

    private func updateCurrentManifest(
        _ mutate: (inout LocalSessionManifest) -> Void
    ) throws {
        guard let sessionDirectoryURL else {
            throw NSError(
                domain: "LocalSessionManifest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The current session directory is unavailable."]
            )
        }
        try LocalSessionManifestStore.update(in: sessionDirectoryURL, mutate)
    }

    private func presentRecordingMonitor() {
        guard recordingMonitorViewController == nil else { return }

        let monitor = RecordingMonitorViewController()
        monitor.modalPresentationStyle = .fullScreen
        monitor.questions = questionnaireData?.questionnaire.questions ?? []
        monitor.levelProvider = { [weak self] in
            self?.currentRecordingLevel() ?? 0
        }
        monitor.onStopReview = { [weak self] in
            guard let self else { return }
            self.isRecording = false
            self.stopRecording(showReview: true)
        }
        monitor.onDiscard = { [weak self] in
            self?.confirmDiscardCurrentRecording()
        }

        recordingMonitorViewController = monitor
        present(monitor, animated: true)
    }

    private func currentRecordingLevel() -> Float {
        guard let recorder = audioRecorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let minDb: Float = -55
        let power = max(minDb, recorder.averagePower(forChannel: 0))
        return max(0, min(1, (power - minDb) / abs(minDb)))
    }

    private func showPostRecordingReview() {
        guard recordingURL != nil else { return }

        let review = RecordingReviewViewController()
        review.modalPresentationStyle = .overFullScreen
        review.modalTransitionStyle = .crossDissolve
        review.isModalInPresentation = true
        review.onPlay = { [weak self, weak review] in
            let isPlaying = self?.toggleRecordingPlaybackFromReview() ?? false
            review?.setPlaybackActive(isPlaying)
        }
        review.onAnalyze = { [weak self, weak review] in
            review?.dismiss(animated: true) {
                self?.recordingReviewViewController = nil
                self?.audioPlayer?.stop()
                self?.audioPlayer = nil
                self?.submitRecordingForServerProcessing()
            }
        }
        review.onDiscard = { [weak self, weak review] in
            guard let self else { return }
            self.confirmDiscardCurrentRecording(from: review)
        }

        recordingReviewViewController = review
        present(review, animated: true)
    }

    private func toggleRecordingPlaybackFromReview() -> Bool {
        guard let url = recordingURL else { return false }

        if let player = audioPlayer, player.isPlaying {
            player.stop()
            audioPlayer = nil
            statusLabel.text = "Playback stopped"
            statusLabel.textColor = .systemGray
            return false
        }

        do {
            try prepareForAudiblePlayback()
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.volume = 1.0
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            statusLabel.text = "Playing recording..."
            statusLabel.textColor = .systemPurple
            return true
        } catch {
            showMessage("Playback failed: \(error.localizedDescription)")
            return false
        }
    }

    private func prepareForAudiblePlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func confirmDiscardCurrentRecording(from presenter: UIViewController? = nil) {
        let alert = UIAlertController(
            title: "Discard Recording?",
            message: "This permanently deletes the current audio file, recording sidecar, and recoverable session draft from this iPad. This cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            self?.discardCurrentRecording()
        })

        let presentingViewController = presenter ?? recordingMonitorViewController ?? recordingReviewViewController ?? self
        presentingViewController.present(alert, animated: true)
    }

    private func discardCurrentRecording() {
        resetInactivityTimer()

        if isRecording {
            isRecording = false
            audioRecorder?.stop()
            interviewTrajectoryPoints = TrajectoryTracker.shared.stopInterviewTracking()
        }
        audioPlayer?.stop()
        audioPlayer = nil

        if let recordingURL {
            let metadataURL = recordingMetadataURL(for: recordingURL)
            do {
                if FileManager.default.fileExists(atPath: recordingURL.path) {
                    try FileManager.default.removeItem(at: recordingURL)
                }
                if FileManager.default.fileExists(atPath: metadataURL.path) {
                    try FileManager.default.removeItem(at: metadataURL)
                }
                if let sessionDirectoryURL {
                    try LocalSessionManifestStore.remove(from: sessionDirectoryURL)
                }
            } catch {
                showMessage("Failed to discard recording: \(error.localizedDescription)")
                return
            }
        }

        audioRecorder = nil
        recordingURL = nil
        recordingStartTrajectoryPoint = nil
        interviewTrajectoryPoints = []
        transcription = nil
        matchedQuestions = []
        interviewerCheckedOptionCodesByQuestionId = [:]
        recordedData = nil

        recordingMonitorViewController?.dismiss(animated: true)
        recordingMonitorViewController = nil
        recordingReviewViewController?.dismiss(animated: true)
        recordingReviewViewController = nil

        updateButton(recordButton, title: "Start Interview", backgroundColor: .systemRed)
        dashboardButton?.isEnabled = true
        audioFilesButton?.isEnabled = true
        dashboardButton?.alpha = 1.0
        audioFilesButton?.alpha = 1.0

        statusLabel.text = "Recording discarded\nReady to start again"
        statusLabel.textColor = .systemGray

        SessionManager.shared.clearCurrentSessionIfEmpty()
        sessionId = nil
        sessionDirectoryURL = nil
    }

    private func writeRecordingMetadata(for recordingURL: URL, recordingStartPoint: TrajectoryPoint?) {
        let metadataURL = recordingURL.deletingPathExtension().appendingPathExtension("json")
        var metadata: [String: Any] = [
            "recording_file": recordingURL.lastPathComponent,
            "recorded_at_epoch": Date().timeIntervalSince1970,
            "session_id": sessionId ?? "",
            "location": respondentInfo?.location ?? "",
            "trajectory_points": recordingStartPoint.map { [trajectoryPointDictionary($0)] } ?? []
        ]
        if let recordingStartPoint {
            metadata["recording_start_trajectory_point"] = trajectoryPointDictionary(recordingStartPoint)
        }
        if let sessionDirectoryURL,
           let manifest = try? LocalSessionManifestStore.load(from: sessionDirectoryURL) {
            var location: [String: Any] = [
                "status": manifest.locationStatus.rawValue,
                "source": manifest.locationSource.rawValue,
                "quality": manifest.locationQuality.rawValue
            ]
            location["horizontal_accuracy_m"] = manifest.locationHorizontalAccuracyM
            location["label"] = manifest.placeSnapshot?.displayLabel ?? manifest.locationLabel
            location["formatted_address"] = manifest.placeSnapshot?.formattedAddress
            location["latitude"] = (manifest.locationCoordinates.latitude as Any?) ?? NSNull()
            location["longitude"] = (manifest.locationCoordinates.longitude as Any?) ?? NSNull()
            metadata["resolved_location"] = location
            if let locationInfo = manifest.locationInfo,
               let locationInfoData = try? JSONEncoder().encode(locationInfo),
               let locationInfoObject = try? JSONSerialization.jsonObject(with: locationInfoData) {
                metadata["location_info"] = locationInfoObject
            }
        }

        if let info = respondentInfo {
            var respondentMetadata: [String: Any] = [
                "is_anonymous": info.isAnonymous,
                "age_range": info.ageRange ?? "",
                "gender": info.gender,
                "race": info.race ?? "",
                "location": info.location
            ]
            if let name = info.name {
                respondentMetadata["name"] = name
            }
            if let age = info.age {
                respondentMetadata["age"] = age
            }
            if let email = info.email {
                respondentMetadata["email"] = email
            }
            metadata["respondent_info"] = respondentMetadata
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metadataURL, options: [.atomic])
        } catch {
            print("Failed to write recording metadata: \(error.localizedDescription)")
        }
    }

    private func updateRecordingTrajectoryMetadata(for recordingURL: URL, points: [TrajectoryPoint]) {
        guard !points.isEmpty else { return }
        let metadataURL = recordingURL.deletingPathExtension().appendingPathExtension("json")
        var metadata = recordingMetadata(for: recordingURL) ?? [:]
        metadata["trajectory_points"] = points.map { trajectoryPointDictionary($0) }
        if metadata["recording_start_trajectory_point"] == nil, let first = points.first {
            metadata["recording_start_trajectory_point"] = trajectoryPointDictionary(first)
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metadataURL, options: [.atomic])
        } catch {
            print("Failed to update recording trajectory metadata: \(error.localizedDescription)")
        }
    }

    private func trajectoryPointDictionary(_ point: TrajectoryPoint) -> [String: Any] {
        var dict: [String: Any] = [
            "lat": point.lat,
            "lon": point.lon,
            "ts_ms": point.tsMs,
            "captured_at": readableTimestamp(for: point.tsMs)
        ]
        if let accuracyM = point.accuracyM { dict["accuracy_m"] = accuracyM }
        if let speedMps = point.speedMps { dict["speed_mps"] = speedMps }
        if let courseDeg = point.courseDeg { dict["course_deg"] = courseDeg }
        if let provider = point.provider { dict["provider"] = provider }
        if let isBackground = point.isBackground { dict["is_background"] = isBackground }
        if let sessionId = point.sessionId, !sessionId.isEmpty { dict["session_id"] = sessionId }
        return dict
    }

    private func readableTimestamp(for tsMs: Int64) -> String {
        return Self.readableTimestampString(for: tsMs)
    }

    private static func readableTimestampString(for tsMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(tsMs) / 1000.0)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private struct SessionPackage: Encodable {
        let metadata: SessionPackageMetadata
        let schemaVersion: Int
        let timestamp: Double
        let sessionId: String
        let localSessionId: String
        let interviewerInfo: InterviewerProfile?
        let respondentInfo: RespondentInfo?
        let locationLabel: String?
        let locationInfo: SessionLocationInfo?
        let location: SessionPackageLocation
        let audio: SessionPackageAudio?
        let recordingStartTrajectoryPoint: SessionPackageTrajectoryPoint?
        let trajectoryPoints: [SessionPackageTrajectoryPoint]
        let transcription: String
        let matchedQuestions: [MatchedQuestion]

        enum CodingKeys: String, CodingKey {
            case metadata
            case schemaVersion = "schema_version"
            case timestamp
            case sessionId = "session_id"
            case localSessionId = "local_session_id"
            case interviewerInfo = "interviewer_info"
            case respondentInfo = "respondent_info"
            case locationLabel = "location_label"
            case locationInfo = "location_info"
            case location
            case audio
            case recordingStartTrajectoryPoint = "recording_start_trajectory_point"
            case trajectoryPoints = "trajectory_points"
            case transcription
            case matchedQuestions = "matched_questions"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(metadata, forKey: .metadata)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(localSessionId, forKey: .localSessionId)
            try container.encodeIfPresent(interviewerInfo, forKey: .interviewerInfo)
            try container.encodeIfPresent(respondentInfo, forKey: .respondentInfo)
            try container.encodeIfPresent(locationLabel, forKey: .locationLabel)
            try container.encodeIfPresent(locationInfo, forKey: .locationInfo)
            try container.encode(location, forKey: .location)
            try container.encodeIfPresent(audio, forKey: .audio)
            try container.encodeIfPresent(recordingStartTrajectoryPoint, forKey: .recordingStartTrajectoryPoint)
            try container.encode(trajectoryPoints, forKey: .trajectoryPoints)
            try container.encode(transcription, forKey: .transcription)
            try container.encode(matchedQuestions, forKey: .matchedQuestions)
        }
    }

    private struct SessionPackageMetadata: Encodable {
        let schemaVersion: Int
        let exportTime: String
        let timestamp: Double
        let localSessionId: String
        let questionnaireTitle: String
        let totalResponses: Int
        let questionnaire: SessionPackageQuestionnaire?
        let cloud: SessionPackageCloud?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case exportTime = "export_time"
            case timestamp
            case localSessionId = "local_session_id"
            case questionnaireTitle = "questionnaire_title"
            case totalResponses = "total_responses"
            case questionnaire
            case cloud
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(exportTime, forKey: .exportTime)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(localSessionId, forKey: .localSessionId)
            try container.encode(questionnaireTitle, forKey: .questionnaireTitle)
            try container.encode(totalResponses, forKey: .totalResponses)
            try container.encodeIfPresent(questionnaire, forKey: .questionnaire)
            try container.encodeIfPresent(cloud, forKey: .cloud)
        }
    }

    private struct SessionPackageQuestionnaire: Encodable {
        let id: String?
        let version: String?
        let title: String
        let description: String
        let hash: String?
        let questions: [SessionPackageQuestion]
    }

    private struct SessionPackageQuestion: Encodable {
        let id: Int
        let question: String
        let type: String
        let followUp: String?
        let keywords: [String]
        let options: [QuestionOption]
        let allowsMultiple: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case question
            case type
            case followUp = "follow_up"
            case keywords
            case options
            case allowsMultiple = "allows_multiple"
        }
    }

    private struct SessionPackageCloud: Encodable {
        let sessionId: String
        let respondentId: String

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case respondentId = "respondent_id"
        }
    }

    private struct SessionPackageAudio: Encodable {
        let fileName: String
        let localSessionId: String?
        let recordedAtMs: Int?
        let fileSizeBytes: Int?

        enum CodingKeys: String, CodingKey {
            case fileName = "file_name"
            case localSessionId = "local_session_id"
            case recordedAtMs = "recorded_at_ms"
            case fileSizeBytes = "file_size_bytes"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(fileName, forKey: .fileName)
            try container.encodeIfPresent(localSessionId, forKey: .localSessionId)
            try container.encodeIfPresent(recordedAtMs, forKey: .recordedAtMs)
            try container.encodeIfPresent(fileSizeBytes, forKey: .fileSizeBytes)
        }
    }

    private struct SessionPackageLocation: Encodable {
        let status: String
        let source: String
        let quality: String
        let label: String?
        let formattedAddress: String?
        let latitude: Double?
        let longitude: Double?
        let horizontalAccuracyM: Double?

        enum CodingKeys: String, CodingKey {
            case status
            case source
            case quality
            case label
            case formattedAddress = "formatted_address"
            case latitude
            case longitude
            case horizontalAccuracyM = "horizontal_accuracy_m"
        }
    }

    private struct SessionPackageTrajectoryPoint: Encodable {
        let tsMs: Int64
        let capturedAt: String
        let lat: Double
        let lon: Double
        let accuracyM: Double?
        let speedMps: Double?
        let courseDeg: Double?
        let provider: String?
        let isBackground: Bool?
        let sessionId: String?

        enum CodingKeys: String, CodingKey {
            case lat
            case lon
            case tsMs = "ts_ms"
            case capturedAt = "captured_at"
            case accuracyM = "accuracy_m"
            case speedMps = "speed_mps"
            case courseDeg = "course_deg"
            case provider
            case isBackground = "is_background"
            case sessionId = "session_id"
        }

        init(_ point: TrajectoryPoint) {
            tsMs = point.tsMs
            capturedAt = ViewController.readableTimestampString(for: point.tsMs)
            lat = point.lat
            lon = point.lon
            accuracyM = point.accuracyM
            speedMps = point.speedMps
            courseDeg = point.courseDeg
            provider = point.provider
            isBackground = point.isBackground
            sessionId = point.sessionId
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(lat, forKey: .lat)
            try container.encode(lon, forKey: .lon)
            try container.encode(tsMs, forKey: .tsMs)
            try container.encode(capturedAt, forKey: .capturedAt)
            try container.encodeIfPresent(accuracyM, forKey: .accuracyM)
            try container.encodeIfPresent(speedMps, forKey: .speedMps)
            try container.encodeIfPresent(courseDeg, forKey: .courseDeg)
            try container.encodeIfPresent(provider, forKey: .provider)
            try container.encodeIfPresent(isBackground, forKey: .isBackground)
            try container.encodeIfPresent(sessionId, forKey: .sessionId)
        }
    }

    private func makeSessionPackage(
        transcription: String,
        matchedQuestions: [MatchedQuestion],
        recordingURL: URL?
    ) -> SessionPackage {
        let timestamp = Date().timeIntervalSince1970
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestampString = dateFormatter.string(from: Date())
        let manifest = sessionDirectoryURL.flatMap { try? LocalSessionManifestStore.load(from: $0) }
        let packageQuestionnaire = manifest?.questionnaireSnapshot ?? questionnaireData?.questionnaire

        let questionnaire = packageQuestionnaire.map {
            SessionPackageQuestionnaire(
                id: $0.id,
                version: $0.version,
                title: $0.title,
                description: $0.description,
                hash: $0.hash,
                questions: $0.questions.map {
                    SessionPackageQuestion(
                        id: $0.id,
                        question: $0.question,
                        type: $0.type,
                        followUp: $0.followUp,
                        keywords: $0.keywords,
                        options: $0.options,
                        allowsMultiple: $0.allowsMultiple
                    )
                }
            )
        }
        let cloud = cloudSessionId.flatMap { cloudSessionId in
            cloudRespondentId.map {
                SessionPackageCloud(sessionId: cloudSessionId, respondentId: $0)
            }
        }
        let metadata = SessionPackageMetadata(
            schemaVersion: 3,
            exportTime: timestampString,
            timestamp: timestamp,
            localSessionId: sessionId ?? "",
            questionnaireTitle: packageQuestionnaire?.title ?? "Unknown",
            totalResponses: 1,
            questionnaire: questionnaire,
            cloud: cloud
        )

        let place = manifest?.placeSnapshot
        let resolvedPoint = manifest?.locationPoint
        let location = SessionPackageLocation(
            status: manifest?.locationStatus.rawValue ?? LocalSessionLocationStatus.pending.rawValue,
            source: manifest?.locationSource.rawValue ?? LocalSessionLocationSource.none.rawValue,
            quality: manifest?.locationQuality.rawValue ?? LocalSessionLocationQuality.unknown.rawValue,
            label: place?.displayLabel ?? manifest?.locationLabel ?? respondentInfo?.location,
            formattedAddress: place?.formattedAddress,
            latitude: manifest?.locationCoordinates.latitude ?? place?.latitude ?? resolvedPoint?.lat,
            longitude: manifest?.locationCoordinates.longitude ?? place?.longitude ?? resolvedPoint?.lon,
            horizontalAccuracyM: manifest?.locationHorizontalAccuracyM
        )

        var audio: SessionPackageAudio?
        var recordingStartPoint: SessionPackageTrajectoryPoint?
        var trajectoryPoints: [SessionPackageTrajectoryPoint] = []
        if let recordingURL {
            var fileSizeBytes: Int?
            if let attributes = try? FileManager.default.attributesOfItem(atPath: recordingURL.path),
               let size = attributes[.size] as? NSNumber {
                fileSizeBytes = size.intValue
            }
            audio = SessionPackageAudio(
                fileName: recordingURL.lastPathComponent,
                localSessionId: sessionIdForRecording(recordingURL),
                recordedAtMs: recordedAtMs(for: recordingURL),
                fileSizeBytes: fileSizeBytes
            )

            if let point = recordingStartTrajectoryPoint(
                for: recordingURL,
                cloudSessionId: cloudSessionId ?? ""
            ) {
                recordingStartPoint = SessionPackageTrajectoryPoint(point)
            }
            trajectoryPoints = interviewTrajectoryPoints(
                for: recordingURL,
                cloudSessionId: cloudSessionId ?? ""
            ).map { SessionPackageTrajectoryPoint($0) }
        }

        return SessionPackage(
            metadata: metadata,
            schemaVersion: 3,
            timestamp: timestamp,
            sessionId: sessionId ?? "",
            localSessionId: sessionId ?? "",
            interviewerInfo: manifest?.interviewerSnapshot ?? InterviewerProfileStore.shared.currentProfile,
            respondentInfo: manifest?.respondentSnapshot ?? respondentInfo,
            locationLabel: location.label,
            locationInfo: manifest?.locationInfo,
            location: location,
            audio: audio,
            recordingStartTrajectoryPoint: recordingStartPoint,
            trajectoryPoints: trajectoryPoints,
            transcription: transcription,
            matchedQuestions: matchedQuestions
        )
    }

    private func encodeSessionPackage(_ package: SessionPackage) throws -> Data {
        let json = orderedObject([
            ("metadata", sessionPackageMetadataJSON(package.metadata, indent: 1)),
            ("schema_version", jsonNumber(package.schemaVersion)),
            ("timestamp", jsonNumber(package.timestamp)),
            ("session_id", jsonString(package.sessionId)),
            ("local_session_id", jsonString(package.localSessionId)),
            ("interviewer_info", package.interviewerInfo.map { interviewerInfoJSON($0, indent: 1) }),
            ("respondent_info", package.respondentInfo.map { respondentInfoJSON($0, indent: 1) }),
            ("location_label", jsonString(package.locationLabel)),
            ("location_info", package.locationInfo.map { locationInfoJSON($0, indent: 1) }),
            ("location", sessionPackageLocationJSON(package.location, indent: 1)),
            ("audio", package.audio.map { sessionPackageAudioJSON($0, indent: 1) }),
            ("recording_start_trajectory_point", package.recordingStartTrajectoryPoint.map { trajectoryPointJSON($0, indent: 1) }),
            ("trajectory_points", trajectoryPointsJSON(package.trajectoryPoints, indent: 1)),
            ("transcription", jsonString(package.transcription)),
            ("matched_questions", matchedQuestionsJSON(package.matchedQuestions, indent: 1))
        ], indent: 0)
        return Data(json.utf8)
    }

    private func sessionPackageMetadataJSON(_ metadata: SessionPackageMetadata, indent: Int) -> String {
        return orderedObject([
            ("schema_version", jsonNumber(metadata.schemaVersion)),
            ("export_time", jsonString(metadata.exportTime)),
            ("timestamp", jsonNumber(metadata.timestamp)),
            ("local_session_id", jsonString(metadata.localSessionId)),
            ("questionnaire_title", jsonString(metadata.questionnaireTitle)),
            ("total_responses", jsonNumber(metadata.totalResponses)),
            ("questionnaire", metadata.questionnaire.map { questionnaireJSON($0, indent: indent + 1) }),
            ("cloud", metadata.cloud.map { cloudJSON($0, indent: indent + 1) })
        ], indent: indent)
    }

    private func questionnaireJSON(_ questionnaire: SessionPackageQuestionnaire, indent: Int) -> String {
        return orderedObject([
            ("id", jsonString(questionnaire.id)),
            ("version", jsonString(questionnaire.version)),
            ("title", jsonString(questionnaire.title)),
            ("description", jsonString(questionnaire.description)),
            ("hash", jsonString(questionnaire.hash)),
            ("questions", sessionPackageQuestionsJSON(questionnaire.questions, indent: indent + 1))
        ], indent: indent)
    }

    private func sessionPackageQuestionsJSON(_ questions: [SessionPackageQuestion], indent: Int) -> String {
        let values = questions.map { question in
            orderedObject([
                ("id", jsonNumber(question.id)),
                ("question", jsonString(question.question)),
                ("type", jsonString(question.type)),
                ("follow_up", jsonString(question.followUp)),
                ("keywords", jsonStringArray(question.keywords, indent: indent + 1)),
                ("allows_multiple", question.type.lowercased() == "multiple-choice" ? jsonBool(question.allowsMultiple) : nil),
                ("options", question.type.lowercased() == "multiple-choice" ? questionOptionsJSON(question.options, indent: indent + 1) : nil)
            ], indent: indent + 1)
        }
        return orderedArray(values, indent: indent)
    }

    private func questionOptionsJSON(_ options: [QuestionOption], indent: Int) -> String {
        let values = options.map { option in
            orderedObject([
                ("code", jsonString(option.code)),
                ("text", jsonString(option.text))
            ], indent: indent + 1)
        }
        return orderedArray(values, indent: indent)
    }

    private func cloudJSON(_ cloud: SessionPackageCloud, indent: Int) -> String {
        return orderedObject([
            ("session_id", jsonString(cloud.sessionId)),
            ("respondent_id", jsonString(cloud.respondentId))
        ], indent: indent)
    }

    private func interviewerInfoJSON(_ info: InterviewerProfile, indent: Int) -> String {
        return orderedObject([
            ("interviewer_id", jsonString(info.interviewerId)),
            ("name", jsonString(info.name)),
            ("email", jsonString(info.email)),
            ("identity_scope", jsonString(info.identityScope))
        ], indent: indent)
    }

    private func respondentInfoJSON(_ info: RespondentInfo, indent: Int) -> String {
        return orderedObject([
            ("is_anonymous", jsonBool(info.isAnonymous)),
            ("name", jsonString(info.name)),
            ("age", jsonNumber(info.age)),
            ("age_range", jsonString(info.ageRange)),
            ("gender", jsonString(info.gender)),
            ("race", jsonString(info.race)),
            ("email", jsonString(info.email)),
            ("location", jsonString(info.location))
        ], indent: indent)
    }

    private func sessionPackageAudioJSON(_ audio: SessionPackageAudio, indent: Int) -> String {
        return orderedObject([
            ("file_name", jsonString(audio.fileName)),
            ("local_session_id", jsonString(audio.localSessionId)),
            ("recorded_at_ms", jsonNumber(audio.recordedAtMs)),
            ("file_size_bytes", jsonNumber(audio.fileSizeBytes))
        ], indent: indent)
    }

    private func sessionPackageLocationJSON(_ location: SessionPackageLocation, indent: Int) -> String {
        orderedObject([
            ("status", jsonString(location.status)),
            ("source", jsonString(location.source)),
            ("quality", jsonString(location.quality)),
            ("label", jsonString(location.label)),
            ("formatted_address", jsonString(location.formattedAddress)),
            ("latitude", jsonNumber(location.latitude) ?? "null"),
            ("longitude", jsonNumber(location.longitude) ?? "null"),
            ("horizontal_accuracy_m", jsonNumber(location.horizontalAccuracyM))
        ], indent: indent)
    }

    private func locationInfoJSON(_ info: SessionLocationInfo, indent: Int) -> String {
        orderedObject([
            ("mode", jsonString(info.mode.rawValue)),
            ("collection_method", jsonString(info.collectionMethod)),
            ("saved_location_id", jsonString(info.savedLocationId?.uuidString)),
            ("location_name", jsonString(info.locationName)),
            ("formatted_address", jsonString(info.formattedAddress)),
            ("map_item_identifier", jsonString(info.mapItemIdentifier)),
            ("latitude", jsonNumber(info.latitude) ?? "null"),
            ("longitude", jsonNumber(info.longitude) ?? "null")
        ], indent: indent)
    }

    private func trajectoryPointJSON(_ point: SessionPackageTrajectoryPoint, indent: Int) -> String {
        return orderedObject([
            ("lat", jsonNumber(point.lat)),
            ("lon", jsonNumber(point.lon)),
            ("ts_ms", jsonNumber(point.tsMs)),
            ("captured_at", jsonString(point.capturedAt)),
            ("accuracy_m", jsonNumber(point.accuracyM)),
            ("speed_mps", jsonNumber(point.speedMps)),
            ("course_deg", jsonNumber(point.courseDeg)),
            ("provider", jsonString(point.provider)),
            ("is_background", jsonBool(point.isBackground)),
            ("session_id", jsonString(point.sessionId))
        ], indent: indent)
    }

    private func trajectoryPointsJSON(_ points: [SessionPackageTrajectoryPoint], indent: Int) -> String {
        let values = points.map { trajectoryPointJSON($0, indent: indent + 1) }
        return orderedArray(values, indent: indent)
    }

    private func matchedQuestionsJSON(_ matchedQuestions: [MatchedQuestion], indent: Int) -> String {
        let values = matchedQuestions.map { matched in
            orderedObject([
                ("matched_question_id", jsonNumber(matched.matchedQuestionId)),
                ("matched_question", jsonString(matched.matchedQuestion)),
                ("extracted_answer", jsonString(matched.extractedAnswer)),
                ("selected_option_codes", matched.selectedOptionCodes.map { jsonStringArray($0, indent: indent + 1) }),
                ("selected_option_labels", matched.selectedOptionLabels.map { jsonStringArray($0, indent: indent + 1) }),
                ("confidence", jsonString(matched.confidence)),
                ("clarification_needed", jsonBool(matched.clarificationNeeded)),
                ("final_answer", jsonString(matched.finalAnswer)),
                ("manually_clarified", jsonBool(matched.manuallyClarified)),
                ("clarification_note", jsonString(matched.clarificationNote)),
                ("answer_source", jsonString(matched.answerSource))
            ], indent: indent + 1)
        }
        return orderedArray(values, indent: indent)
    }

    private func orderedObject(_ pairs: [(String, String?)], indent: Int) -> String {
        let kept = pairs.compactMap { key, value -> (String, String)? in
            guard let value else { return nil }
            return (key, value)
        }
        guard !kept.isEmpty else { return "{}" }

        let currentIndent = String(repeating: "  ", count: indent)
        let childIndent = String(repeating: "  ", count: indent + 1)
        let lines = kept.map { key, value in
            "\(childIndent)\(jsonFragment(key)): \(value)"
        }
        return "{\n\(lines.joined(separator: ",\n"))\n\(currentIndent)}"
    }

    private func orderedArray(_ values: [String], indent: Int) -> String {
        guard !values.isEmpty else { return "[]" }

        let currentIndent = String(repeating: "  ", count: indent)
        let childIndent = String(repeating: "  ", count: indent + 1)
        let lines = values.map { value in
            "\(childIndent)\(value)"
        }
        return "[\n\(lines.joined(separator: ",\n"))\n\(currentIndent)]"
    }

    private func jsonString(_ value: String?) -> String? {
        guard let value else { return nil }
        return jsonFragment(value)
    }

    private func jsonStringArray(_ values: [String], indent: Int) -> String {
        return orderedArray(values.map { jsonFragment($0) }, indent: indent)
    }

    private func jsonNumber(_ value: Int?) -> String? {
        guard let value else { return nil }
        return jsonFragment(value)
    }

    private func jsonNumber(_ value: Int64?) -> String? {
        guard let value else { return nil }
        return jsonFragment(value)
    }

    private func jsonNumber(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return jsonFragment(value)
    }

    private func jsonBool(_ value: Bool?) -> String? {
        guard let value else { return nil }
        return value ? "true" : "false"
    }

    private func jsonFragment(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let arrayString = String(data: data, encoding: .utf8),
              arrayString.count >= 2 else {
            return "null"
        }
        return String(arrayString.dropFirst().dropLast())
    }

    private func writeSessionPackageJSON(
        transcription: String,
        matchedQuestions: [MatchedQuestion],
        recordingURL: URL?
    ) throws -> URL {
        let session = try SessionManager.shared.ensureCurrentSession()
        sessionId = session.id
        sessionDirectoryURL = session.directoryURL

        let package = makeSessionPackage(
            transcription: transcription,
            matchedQuestions: matchedQuestions,
            recordingURL: recordingURL
        )
        let jsonData = try encodeSessionPackage(package)
        let url = session.directoryURL.appendingPathComponent("session.json")
        try jsonData.write(to: url, options: [.atomic])
        return url
    }

    private func resolveClarificationsIfNeeded(
        transcription: String,
        matchedQuestions: [MatchedQuestion],
        recordingURL: URL?
    ) {
        let uncertainIndices = matchedQuestions.enumerated().compactMap { index, matched in
            requiresClarification(matched) ? index : nil
        }

        guard !uncertainIndices.isEmpty else {
            finalizeLLMResults(
                transcription: transcription,
                matchedQuestions: matchedQuestions,
                recordingURL: recordingURL
            )
            return
        }

        showClarificationPrompt(
            transcription: transcription,
            originalMatchedQuestions: matchedQuestions,
            currentMatchedQuestions: matchedQuestions,
            uncertainIndices: uncertainIndices,
            position: 0,
            recordingURL: recordingURL
        )
    }

    private func requiresClarification(_ matched: MatchedQuestion) -> Bool {
        if matched.manuallyClarified == true { return false }
        return matched.clarificationNeeded || matched.confidence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "high"
    }

    private func applyInterviewerCheckedOptions(
        to matches: [MatchedQuestion],
        questions: [Question]
    ) -> [MatchedQuestion] {
        guard !interviewerCheckedOptionCodesByQuestionId.isEmpty else {
            return matches
        }

        var updatedMatches = matches
        let questionsById = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0) })

        for (questionId, checkedCodes) in interviewerCheckedOptionCodesByQuestionId {
            guard let question = questionsById[questionId],
                  question.type.lowercased() == "multiple-choice",
                  !checkedCodes.isEmpty else {
                continue
            }

            let validOptions = Dictionary(uniqueKeysWithValues: question.options.map { ($0.code.uppercased(), $0.text) })
            let orderedCodes = question.options
                .map { $0.code.uppercased() }
                .filter { checkedCodes.map { $0.uppercased() }.contains($0) && validOptions[$0] != nil }
            guard !orderedCodes.isEmpty else {
                continue
            }

            let labels = orderedCodes.compactMap { validOptions[$0] }
            let checkedAnswer = labels.isEmpty ? orderedCodes.joined(separator: ", ") : labels.joined(separator: ", ")

            if let existingIndex = updatedMatches.firstIndex(where: { $0.matchedQuestionId == questionId }) {
                let existing = updatedMatches[existingIndex]
                let noteParts = [
                    "Interviewer checked choices used as primary answer.",
                    "LLM transcript answer: \(existing.extractedAnswer)"
                ]
                updatedMatches[existingIndex] = MatchedQuestion(
                    matchedQuestionId: existing.matchedQuestionId,
                    matchedQuestion: existing.matchedQuestion,
                    extractedAnswer: checkedAnswer,
                    selectedOptionCodes: orderedCodes,
                    selectedOptionLabels: labels,
                    confidence: "high",
                    clarificationNeeded: false,
                    finalAnswer: checkedAnswer,
                    manuallyClarified: existing.manuallyClarified,
                    clarificationNote: noteParts.joined(separator: " "),
                    answerSource: "interviewer_checked"
                )
            } else {
                updatedMatches.append(
                    MatchedQuestion(
                        matchedQuestionId: question.id,
                        matchedQuestion: question.question,
                        extractedAnswer: checkedAnswer,
                        selectedOptionCodes: orderedCodes,
                        selectedOptionLabels: labels,
                        confidence: "high",
                        clarificationNeeded: false,
                        finalAnswer: checkedAnswer,
                        manuallyClarified: false,
                        clarificationNote: "Interviewer checked choices used as primary answer; voice transcript retained as supporting evidence.",
                        answerSource: "interviewer_checked"
                    )
                )
            }
        }

        return updatedMatches.sorted { lhs, rhs in
            if lhs.matchedQuestionId == rhs.matchedQuestionId {
                return lhs.matchedQuestion < rhs.matchedQuestion
            }
            return lhs.matchedQuestionId < rhs.matchedQuestionId
        }
    }

    private func showClarificationPrompt(
        transcription: String,
        originalMatchedQuestions: [MatchedQuestion],
        currentMatchedQuestions: [MatchedQuestion],
        uncertainIndices: [Int],
        position: Int,
        recordingURL: URL?
    ) {
        guard position < uncertainIndices.count else {
            finalizeLLMResults(
                transcription: transcription,
                matchedQuestions: currentMatchedQuestions,
                recordingURL: recordingURL
            )
            return
        }

        let matchedIndex = uncertainIndices[position]
        let matched = currentMatchedQuestions[matchedIndex]
        let question = questionnaireData?.questionnaire.questions.first { $0.id == matched.matchedQuestionId }
        let snippet = transcriptSnippet(for: matched, question: question, transcription: transcription)
        let optionText = multipleChoiceOptionText(for: question)
        let optionSection = optionText.isEmpty ? "" : "\nOptions:\n\(optionText)\n"

        let alert = UIAlertController(
            title: "Clarification Needed \(position + 1) of \(uncertainIndices.count)",
            message: """
            Question:
            \(matched.matchedQuestion)
            \(optionSection)

            LLM answer:
            \(matched.extractedAnswer)

            Confidence: \(matched.confidence)

            Transcript:
            \(snippet)
            """,
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = question?.type.lowercased() == "multiple-choice" ? "Final answer codes, e.g. 1, 3" : "Custom final answer"
            textField.text = matched.finalAnswer ?? ""
        }
        alert.addTextField { textField in
            textField.placeholder = "Optional clarification note"
        }

        let continueWithUpdate: (String?, Bool) -> Void = { [weak self] selectedAnswer, useOriginalAnswer in
            guard let self else { return }
            var updatedQuestions = currentMatchedQuestions
            let customAnswer = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = alert.textFields?.dropFirst().first?.text
            if useOriginalAnswer {
                updatedQuestions[matchedIndex] = matched.withAcceptedOriginalAnswer(note: note)
            } else {
                let finalAnswer = customAnswer?.isEmpty == false ? customAnswer : selectedAnswer
                let selectedOptions = self.selectedOptions(from: finalAnswer, question: question)
                updatedQuestions[matchedIndex] = matched.withManualClarification(
                    finalAnswer: finalAnswer,
                    note: note,
                    selectedOptionCodes: selectedOptions.codes,
                    selectedOptionLabels: selectedOptions.labels
                )
            }

            do {
                try self.updateCurrentManifest { manifest in
                    manifest.matchedQuestions = updatedQuestions
                    manifest.clarificationStatus = .pending
                    manifest.retry.lastError = nil
                }
            } catch {
                self.showBlockingRecordingError(
                    title: "Clarification Save Failed",
                    message: "This clarification was not advanced because the recoverable session manifest could not be updated. \(error.localizedDescription)"
                )
                return
            }

            self.showClarificationPrompt(
                transcription: transcription,
                originalMatchedQuestions: originalMatchedQuestions,
                currentMatchedQuestions: updatedQuestions,
                uncertainIndices: uncertainIndices,
                position: position + 1,
                recordingURL: recordingURL
            )
        }

        alert.addAction(UIAlertAction(title: "Use Original Answer", style: .default) { _ in
            continueWithUpdate(matched.extractedAnswer, true)
        })

        if question?.type.lowercased() == "yes-no" {
            alert.addAction(UIAlertAction(title: "Yes", style: .default) { _ in continueWithUpdate("Yes", false) })
            alert.addAction(UIAlertAction(title: "No", style: .default) { _ in continueWithUpdate("No", false) })
            alert.addAction(UIAlertAction(title: "Not sure", style: .default) { _ in continueWithUpdate("Not sure", false) })
        }

        if let question, question.type.lowercased() == "multiple-choice", !question.allowsMultiple {
            for option in question.options.prefix(10) {
                let code = option.code.uppercased()
                alert.addAction(UIAlertAction(title: "\(code). \(option.text)", style: .default) { _ in continueWithUpdate(code, false) })
            }
        }

        alert.addAction(UIAlertAction(title: "Use Custom Text", style: .default) { _ in
            continueWithUpdate(nil, false)
        })
        alert.addAction(UIAlertAction(title: "Leave Unresolved", style: .cancel) { [weak self] _ in
            guard let self else { return }
            self.showClarificationPrompt(
                transcription: transcription,
                originalMatchedQuestions: originalMatchedQuestions,
                currentMatchedQuestions: currentMatchedQuestions,
                uncertainIndices: uncertainIndices,
                position: position + 1,
                recordingURL: recordingURL
            )
        })

        present(alert, animated: true)
    }

    private func multipleChoiceOptionText(for question: Question?) -> String {
        guard let question,
              question.type.lowercased() == "multiple-choice",
              !question.options.isEmpty else {
            return ""
        }
        return question.options
            .prefix(10)
            .map { "\($0.code.uppercased()). \($0.text)" }
            .joined(separator: "\n\n")
    }

    private func selectedOptions(from answer: String?, question: Question?) -> (codes: [String]?, labels: [String]?) {
        guard let question,
              question.type.lowercased() == "multiple-choice",
              !question.options.isEmpty,
              let answer else {
            return (nil, nil)
        }

        let validOptions = Dictionary(uniqueKeysWithValues: question.options.map { ($0.code.uppercased(), $0.text) })
        let aliasToCode = optionCodeAliases(for: Set(validOptions.keys))
        let alternatives = aliasToCode.keys
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs < rhs }
                return lhs.count > rhs.count
            }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        guard !alternatives.isEmpty else {
            return (nil, nil)
        }
        let pattern = "(?<![A-Za-z0-9])(?:\(alternatives))(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (nil, nil)
        }
        let range = NSRange(answer.startIndex..<answer.endIndex, in: answer)
        let codes = regex.matches(in: answer, options: [], range: range).compactMap { match -> String? in
            guard let codeRange = Range(match.range, in: answer) else { return nil }
            let matchedText = String(answer[codeRange]).uppercased()
            return aliasToCode[matchedText]
        }
        let uniqueCodes = Array(NSOrderedSet(array: codes)).compactMap { $0 as? String }
        guard !uniqueCodes.isEmpty else {
            return (nil, nil)
        }
        let labels = uniqueCodes.compactMap { validOptions[$0] }
        return (uniqueCodes, labels)
    }

    private func optionCodeAliases(for validCodes: Set<String>) -> [String: String] {
        let spokenNumberAliases: [String: [String]] = [
            "1": ["ONE", "NUMBER ONE", "FIRST"],
            "2": ["TWO", "TO", "TOO", "NUMBER TWO", "SECOND"],
            "3": ["THREE", "NUMBER THREE", "THIRD"],
            "4": ["FOUR", "FOR", "NUMBER FOUR", "FOURTH"],
            "5": ["FIVE", "NUMBER FIVE", "FIFTH"],
            "6": ["SIX", "NUMBER SIX", "SIXTH"],
            "7": ["SEVEN", "NUMBER SEVEN", "SEVENTH"],
            "8": ["EIGHT", "ATE", "NUMBER EIGHT", "EIGHTH"],
            "9": ["NINE", "NUMBER NINE", "NINTH"],
            "10": ["TEN", "NUMBER TEN", "TENTH"]
        ]
        var aliases: [String: String] = [:]
        for code in validCodes {
            let normalizedCode = code.uppercased()
            aliases[normalizedCode] = normalizedCode
            for alias in spokenNumberAliases[normalizedCode] ?? [] {
                aliases[alias] = normalizedCode
            }
        }
        return aliases
    }

    private func transcriptSnippet(for matched: MatchedQuestion, question: Question?, transcription: String) -> String {
        let text = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return transcription }

        let lowerText = text.lowercased()
        let lowerNSString = lowerText as NSString

        func rangeOfPhrase(_ phrase: String?) -> NSRange? {
            guard let phrase else { return nil }
            let normalized = phrase
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count >= 4 else { return nil }

            let range = lowerNSString.range(of: normalized)
            return range.location == NSNotFound ? nil : range
        }

        func trimmedSubstring(location: Int, length: Int) -> String {
            let boundedLocation = max(0, min(location, lowerNSString.length))
            let boundedEnd = max(boundedLocation, min(boundedLocation + length, lowerNSString.length))
            let start = String.Index(utf16Offset: boundedLocation, in: text)
            let end = String.Index(utf16Offset: boundedEnd, in: text)
            return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let questionRange = [
            question?.question,
            matched.matchedQuestion
        ].compactMap { rangeOfPhrase($0) }.first

        if let questionRange {
            let followingQuestionRanges = (questionnaireData?.questionnaire.questions ?? [])
                .filter { $0.id != matched.matchedQuestionId }
                .compactMap { rangeOfPhrase($0.question) }
                .filter { $0.location > questionRange.location }
                .sorted { $0.location < $1.location }

            let segmentEnd = followingQuestionRanges.first?.location ?? lowerNSString.length
            let segmentLength = min(max(segmentEnd - questionRange.location, questionRange.length), 360)
            let segment = trimmedSubstring(location: questionRange.location, length: segmentLength)
            if !segment.isEmpty {
                return segment
            }
        }

        let answerRange = [
            matched.finalAnswer,
            matched.extractedAnswer
        ].compactMap { rangeOfPhrase($0) }.first

        if let answerRange {
            let location = max(0, answerRange.location - 80)
            let length = min(220, lowerNSString.length - location)
            let segment = trimmedSubstring(location: location, length: length)
            if !segment.isEmpty {
                return segment
            }
        }

        let keywordRange = (question?.keywords ?? [])
            .sorted { $0.count > $1.count }
            .compactMap { rangeOfPhrase($0) }
            .first

        if let keywordRange {
            let location = max(0, keywordRange.location - 60)
            let length = min(220, lowerNSString.length - location)
            let segment = trimmedSubstring(location: location, length: length)
            if !segment.isEmpty {
                return segment
            }
        }

        return text.count > 240 ? String(text.prefix(240)) + "..." : text
    }

    private func finalizeLLMResults(
        transcription: String,
        matchedQuestions: [MatchedQuestion],
        recordingURL: URL?
    ) {
        do {
            try updateCurrentManifest { manifest in
                manifest.transcriptionStatus = .completed
                manifest.transcription = transcription
                manifest.analysisStatus = .completed
                manifest.matchedQuestions = matchedQuestions
                manifest.clarificationStatus = .completed
                manifest.uploadStatus = .notReady
                manifest.retry.lastError = nil
            }
        } catch {
            showBlockingRecordingError(
                title: "Analysis Save Failed",
                message: "The finalized answers could not be persisted in the recoverable session manifest. The participant was not reset. \(error.localizedDescription)"
            )
            return
        }

        self.matchedQuestions = matchedQuestions
        displayResults(transcription: transcription, matchedQuestions: matchedQuestions)

        let resultSummary = matchedQuestions.map { matched in
            "Q\(matched.matchedQuestionId): \(matched.finalAnswer ?? matched.extractedAnswer)"
        }.joined(separator: "\n")
        recordedData = "Transcription: \(transcription)\n\nMatched Questions:\n\(resultSummary)"

        statusLabel.text = "AI analysis complete locally\nSaving the final package…"
        statusLabel.textColor = .systemGreen

        do {
            _ = try writeSessionPackageJSON(
                transcription: transcription,
                matchedQuestions: matchedQuestions,
                recordingURL: recordingURL
            )
            try updateCurrentManifest { manifest in
                manifest.uploadStatus = .pending
                manifest.retry.lastError = nil
            }
        } catch {
            statusLabel.text = "Analysis complete, but local package save failed"
            statusLabel.textColor = .systemRed
            showBlockingRecordingError(
                title: "Final Package Save Failed",
                message: "The interview remains recoverable and was not reset. \(error.localizedDescription)"
            )
            return
        }

        let completedLocalSessionId = sessionId
        startNextParticipant()
        statusLabel.text = "Recording and analysis saved locally\nWaiting for upload"
        statusLabel.textColor = .systemGreen
        Task { [weak self] in
            let summary = await DeferredSessionOutbox.shared.run(trigger: .sessionReady)
            guard let self, let completedLocalSessionId else { return }
            if summary.uploadedSessionIds.contains(completedLocalSessionId) {
                statusLabel.text = "Analysis saved and uploaded"
                statusLabel.textColor = .systemGreen
            } else if summary.failedSessionIds.contains(completedLocalSessionId) {
                statusLabel.text = "Analysis saved locally\nUpload pending retry"
                statusLabel.textColor = .systemOrange
            }
        }
    }

    // MARK: - Results Display
    private func displayResults(transcription: String, matchedQuestions: [MatchedQuestion]) {
        var resultText = "Transcription:\n\(transcription)\n\n"
        resultText += "Matched Questions:\n"

        for matched in matchedQuestions {
            resultText += "\nQuestion \(matched.matchedQuestionId): \(matched.matchedQuestion)\n"
            resultText += "Answer: \(matched.extractedAnswer)\n"
            if let codes = matched.selectedOptionCodes, !codes.isEmpty {
                resultText += "Selected choices: \(codes.joined(separator: ", "))\n"
            }
            if let labels = matched.selectedOptionLabels, !labels.isEmpty {
                resultText += "Choice labels: \(labels.joined(separator: ", "))\n"
            }
            if let finalAnswer = matched.finalAnswer, !finalAnswer.isEmpty {
                resultText += "Final answer: \(finalAnswer)\n"
            }
            resultText += "Confidence: \(matched.confidence)\n"
            if matched.clarificationNeeded {
                resultText += "Clarification needed\n"
            }
            if matched.manuallyClarified == true {
                resultText += "Manually clarified\n"
            }
        }

        showScrollableContent(title: "Analysis Results", content: resultText)
    }

    // MARK: - AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.statusLabel.text = "Playback complete"
            self.statusLabel.textColor = .systemGray
            self.recordingReviewViewController?.setPlaybackActive(false)
        }
    }

    // MARK: - Helper Methods
    private func animateButton(_ button: UIButton) {
        UIView.animate(withDuration: 0.1, animations: {
            button.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { _ in
            UIView.animate(withDuration: 0.1) {
                button.transform = CGAffineTransform.identity
            }
        }
    }

    // MARK: - Multi-user session helpers

    private func initializeSessionAndPurge() {
        // Best-effort purge of old sessions (local-only retention)
        SessionManager.shared.purgeEmptySessions()
        SessionManager.shared.purgeOldSessions(keepLast: 50, maxAgeDays: 7)
        sessionId = nil
        sessionDirectoryURL = nil
    }

    private func startNextParticipant() {
        // A recording must pass the same audio + manifest verification as a manual Stop
        // before participant state can be cleared.
        if isRecording {
            isRecording = false
            stopRecording(showReview: true)
            return
        }

        if let player = audioPlayer, player.isPlaying {
            player.stop()
        }
        audioPlayer = nil
        audioRecorder = nil

        // Clear participant-specific state
        respondentInfo = nil
        transcription = nil
        matchedQuestions = []
        interviewerCheckedOptionCodesByQuestionId = [:]
        cloudRespondentId = nil
        cloudSessionId = nil
        recordedData = nil
        recordingURL = nil
        recordingStartTrajectoryPoint = nil
        interviewTrajectoryPoints = []

        // Reset UI state
        updateButton(recordButton, title: "Start Interview", backgroundColor: .systemRed)
        dashboardButton?.isEnabled = true
        audioFilesButton?.isEnabled = true
        dashboardButton?.alpha = 1.0
        audioFilesButton?.alpha = 1.0

        statusLabel.text = "Ready for next participant"
        statusLabel.textColor = .systemGray

        // Start a fresh session
        SessionManager.shared.clearCurrentSessionIfEmpty()
        sessionId = nil
        sessionDirectoryURL = nil

        resetInactivityTimer()
    }

    // MARK: - Inactivity auto-reset

    private func resetInactivityTimer() {
        invalidateInactivityTimer()
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: inactivityTimeoutSeconds, repeats: false) { [weak self] _ in
            self?.handleInactivityTimeout()
        }
    }

    private func invalidateInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    private func handleInactivityTimeout() {
        DispatchQueue.main.async {
            self.startNextParticipant()
        }
    }

    private func showMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        present(alert, animated: true)

        // Auto dismiss after 1.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            alert.dismiss(animated: true)
        }
    }

    private func showJSONContent(_ jsonString: String) {
        showScrollableContent(title: "Exported JSON", content: jsonString)
    }

    private func shareFile(url: URL) {
        let activityViewController = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )

        // For iPad
        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        present(activityViewController, animated: true)
    }

    private func loadAggregationSurveyRecords() throws -> [AggregationSurveyRecord] {
        let fileManager = FileManager.default
        let decoder = JSONDecoder()
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionsRoot = documentsURL.appendingPathComponent("SurveySessions", isDirectory: true)

        var records: [AggregationSurveyRecord] = []
        var seenKeys = Set<String>()

        func appendIfValid(_ url: URL, fallbackKey: String) {
            do {
                let data = try Data(contentsOf: url)
                let survey = try decoder.decode(ExportedSurvey.self, from: data)
                let key = aggregationIdentity(for: survey) ?? fallbackKey
                guard !seenKeys.contains(key) else { return }
                seenKeys.insert(key)
                records.append(AggregationSurveyRecord(sourceURL: url, survey: survey))
            } catch {
                print("Failed to process aggregation source \(url.lastPathComponent): \(error)")
            }
        }

        if fileManager.fileExists(atPath: sessionsRoot.path) {
            let sessionDirectories = (try? fileManager.contentsOfDirectory(
                at: sessionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for directory in sessionDirectories {
                let isDirectory = (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory else { continue }
                let sessionJSON = directory.appendingPathComponent("session.json")
                guard fileManager.fileExists(atPath: sessionJSON.path) else { continue }
                appendIfValid(sessionJSON, fallbackKey: "session:\(directory.lastPathComponent)")
            }
        }

        return records
    }

    private func aggregationIdentity(for survey: ExportedSurvey) -> String? {
        let candidates = [
            survey.localSessionId,
            survey.metadata?.localSessionId
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func jsonToPrettyString(_ json: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func ensureAggregatedExportsDirectory() throws -> URL {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exportsURL = documentsURL.appendingPathComponent("AggregatedExports", isDirectory: true)

        if !fileManager.fileExists(atPath: exportsURL.path) {
            try fileManager.createDirectory(at: exportsURL, withIntermediateDirectories: true, attributes: nil)
        }

        return exportsURL
    }

    private func showScrollableContent(title: String, content: String) {
        let viewController = AggregationTextViewController(title: title, content: content)
        viewController.modalPresentationStyle = .formSheet
        present(viewController, animated: true)
    }

    // MARK: - Settings & API Key Management
    @objc private func settingsButtonTapped() {
        showAPIKeySettings()
    }

    @objc private func locationModeButtonTapped() {
        showLocationSettings()
    }

    private func showLocationSettings() {
        let controller = SurveyLocationSettingsViewController { [weak self] in
            self?.updateLocationModeStatus()
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func updateLocationModeStatus() {
        guard let button = locationModeButton else { return }
        let store = SavedSurveyLocationStore.shared
        var configuration = UIButton.Configuration.gray()
        configuration.image = UIImage(systemName: "location.circle.fill")
        configuration.imagePadding = 10
        configuration.cornerStyle = .medium
        configuration.titleAlignment = .leading
        switch store.mode {
        case .device:
            configuration.title = "Device Location"
            configuration.subtitle = "Location will be collected at interview start"
            configuration.baseForegroundColor = .systemBlue
        case .fixed:
            configuration.title = "Fixed Location — \(store.activeLocation?.name ?? "Selection Required")"
            if let activeLocation = store.activeLocation {
                configuration.subtitle = activeLocation.needsCoordinateResolution
                    ? "Address saved; map point will retry before interview"
                    : "Saved map point will be used"
            } else {
                configuration.subtitle = "Choose a saved location before starting"
            }
            configuration.baseForegroundColor = store.activeLocation == nil ? .systemRed : .systemGreen
        case .none:
            configuration.title = "No Location"
            configuration.subtitle = "Location collection is disabled"
            configuration.baseForegroundColor = .systemOrange
        }
        button.configuration = configuration
        button.accessibilityHint = "Opens Location Mode settings"
    }

    private func showMissingFixedLocation() {
        let alert = UIAlertController(
            title: "Fixed Location Required",
            message: "The previously selected saved location is no longer available. Choose another saved location, Device Location, or No Location before starting.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Location Settings", style: .default) { [weak self] _ in
            self?.showLocationSettings()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func resolveFixedLocationIfNeededBeforeInterview(completion: @escaping () -> Void) {
        let store = SavedSurveyLocationStore.shared
        guard store.mode == .fixed else { completion(); return }
        guard let location = store.activeLocation else {
            showMissingFixedLocation()
            return
        }
        guard location.needsCoordinateResolution else { completion(); return }
        guard let address = location.formattedAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            completion()
            return
        }

        let progress = UIAlertController(
            title: "Resolving Saved Address",
            message: "Searching Apple Maps before this interview starts...",
            preferredStyle: .alert
        )
        present(progress, animated: true)
        Task { [weak self, weak progress] in
            guard let self else { return }
            let outcome = await ManualSurveyLocationAddressResolution.resolve(
                typedAddress: address,
                using: MapKitSurveyLocationAddressResolver()
            )
            progress?.dismiss(animated: true) { [weak self] in
                self?.handleFixedLocationResolution(
                    outcome,
                    original: location,
                    completion: completion
                )
            }
        }
    }

    private func handleFixedLocationResolution(
        _ outcome: ManualAddressResolutionOutcome,
        original: SavedSurveyLocation,
        completion: @escaping () -> Void
    ) {
        switch outcome {
        case let .candidates(candidates):
            if candidates.count == 1, let candidate = candidates.first {
                confirmResolvedFixedLocation(candidate, original: original, completion: completion)
                return
            }
            let chooser = UIAlertController(
                title: "Choose the Exact Address",
                message: "Apple Maps found more than one match. Select the correct location before the interview starts.",
                preferredStyle: .actionSheet
            )
            for candidate in candidates.prefix(10) {
                let title = [candidate.name, candidate.formattedAddress]
                    .compactMap { $0 }
                    .joined(separator: " — ")
                chooser.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                    self?.confirmResolvedFixedLocation(
                        candidate,
                        original: original,
                        completion: completion
                    )
                })
            }
            chooser.addAction(UIAlertAction(title: "Cancel Interview", style: .cancel))
            if let popover = chooser.popoverPresentationController {
                popover.sourceView = locationModeButton ?? view
                popover.sourceRect = locationModeButton?.bounds ?? CGRect(
                    x: view.bounds.midX,
                    y: view.bounds.midY,
                    width: 1,
                    height: 1
                )
            }
            present(chooser, animated: true)
        case .addressOnly:
            let alert = UIAlertController(
                title: "Map Point Still Unavailable",
                message: "Apple Maps could not resolve this saved address. You can retry, continue offline with the truthful address-only location, or cancel this interview.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
                self?.resolveFixedLocationIfNeededBeforeInterview(completion: completion)
            })
            alert.addAction(UIAlertAction(title: "Continue Address Only", style: .default) { _ in
                completion()
            })
            alert.addAction(UIAlertAction(title: "Cancel Interview", style: .cancel))
            present(alert, animated: true)
        }
    }

    private func confirmResolvedFixedLocation(
        _ candidate: SurveyLocationAddressCandidate,
        original: SavedSurveyLocation,
        completion: @escaping () -> Void
    ) {
        let controller = LocationConfirmationViewController(
            candidate: candidate,
            suggestedName: original.name,
            original: original,
            onCancel: { [weak self] in self?.dismiss(animated: true) },
            onSave: { [weak self] resolved in
                guard let self else { return }
                do {
                    try SavedSurveyLocationStore.shared.save(resolved, makeActive: true)
                    self.dismiss(animated: true) {
                        self.updateLocationModeStatus()
                        completion()
                    }
                } catch {
                    self.dismiss(animated: true) {
                        let alert = UIAlertController(
                            title: "Location Could Not Be Saved",
                            message: error.localizedDescription,
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        self.present(alert, animated: true)
                    }
                }
            }
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func checkAPIKeyStatus() {
        if !SurveyAPIClient.shared.isConfigured() {
            statusLabel.text = "⚠️ Please configure the Survey API in Settings"
            statusLabel.textColor = .systemOrange
        }
    }

    private func showAPIKeySettings() {
        let interviewer = InterviewerProfileStore.shared.currentProfile
        let alert = UIAlertController(
            title: "Settings",
            message: "Processing: Survey server\nCurrent interviewer: \(interviewer?.name ?? "Not set")\nLocation Mode: \(SavedSurveyLocationStore.shared.mode.title)",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "App Settings", style: .default) { [weak self] _ in
            self?.showAppConfigurationSettings()
        })
        alert.addAction(UIAlertAction(title: "Interviewer Settings", style: .default) { [weak self] _ in
            self?.showInterviewerSettings()
        })
        alert.addAction(UIAlertAction(title: "Location Mode and Saved Locations", style: .default) { [weak self] _ in
            self?.showLocationSettings()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        present(alert, animated: true)
    }

    private func showAppConfigurationSettings() {
        let alert = UIAlertController(
            title: "App Settings",
            message: "Transcription and answer analysis run on the configured Survey server.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Configure Survey API Base URL", style: .default) { [weak self] _ in
            self?.showSurveyAPIBaseURLInput()
        })
        alert.addAction(UIAlertAction(title: "Configure Survey API Key", style: .default) { [weak self] _ in
            self?.showSurveyAPIKeyInput()
        })
        alert.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
            self?.showAPIKeySettings()
        })

        present(alert, animated: true)
    }

    private func showInterviewerSettings() {
        let interviewer = InterviewerProfileStore.shared.currentProfile
        let alert = UIAlertController(
            title: "Interviewer Settings",
            message: "Current interviewer: \(interviewer?.name ?? "Not set")",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Configure Interviewer", style: .default) { [weak self] _ in
            self?.showInterviewerProfileInput()
        })
        alert.addAction(UIAlertAction(title: "Select Saved Interviewer", style: .default) { [weak self] _ in
            self?.showSavedInterviewerSelection()
        })
        if !InterviewerProfileStore.shared.profiles.isEmpty {
            alert.addAction(UIAlertAction(title: "Delete Saved Interviewer", style: .destructive) { [weak self] _ in
                self?.showSavedInterviewerDeletion()
            })
        }
        alert.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
            self?.showAPIKeySettings()
        })

        present(alert, animated: true)
    }

    private func showAPIProviderSelection() {
        let alert = UIAlertController(
            title: "Select API Provider",
            message: "Choose the LLM API provider to use",
            preferredStyle: .actionSheet
        )

        let currentProvider = LLMService.shared.currentProvider

        for provider in APIProvider.allCases {
            let title = provider == currentProvider ? "\(provider.displayName) ✓" : provider.displayName
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                LLMService.shared.setAPIProvider(provider)
                self?.checkAPIKeyStatus()
                self?.showMessage("Switched to \(provider.rawValue)")
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // iPad support
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        present(alert, animated: true)
    }

    private func showAPIKeyInput(for provider: APIProvider) {
        let providerName = provider == .openai ? "OpenAI" : "Gemini"
        let apiKeyURL = provider == .openai ? "https://platform.openai.com/api-keys" : "https://makersuite.google.com/app/apikey"

        let alert = UIAlertController(
            title: "\(providerName) API Key Settings",
            message: "Enter your \(providerName) API Key\n\nGet your API key from: \(apiKeyURL)",
            preferredStyle: .alert
        )

        // Get current API key status
        let hasExistingKey = LLMService.shared.hasAPIKey(for: provider)
        let currentKey = LLMService.shared.getAPIKey(for: provider)

        alert.addTextField { textField in
            if hasExistingKey {
                textField.placeholder = "API key is configured (enter new key to update)"
                // Show masked version of existing key
                if !currentKey.isEmpty {
                    let maskedKey = String(currentKey.prefix(8)) + "..." + String(currentKey.suffix(4))
                    textField.text = maskedKey
                }
            } else {
                textField.placeholder = "Enter your \(providerName) API Key"
            }
            textField.isSecureTextEntry = true
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }

        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let textField = alert.textFields?.first,
                  let apiKey = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !apiKey.isEmpty else {
                self?.showMessage("API key cannot be empty")
                return
            }

            // If the input is the masked key, don't update
            if hasExistingKey && !currentKey.isEmpty {
                let maskedKey = String(currentKey.prefix(8)) + "..." + String(currentKey.suffix(4))
                if apiKey == maskedKey {
                    self?.showMessage("API key unchanged")
                    return
                }
            }

            LLMService.shared.setAPIKey(apiKey, for: provider)
            self?.checkAPIKeyStatus()
            self?.showMessage("\(providerName) API key saved successfully")
        })

        if hasExistingKey {
            alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
                LLMService.shared.setAPIKey("", for: provider)
                self?.checkAPIKeyStatus()
                self?.showMessage("\(providerName) API key cleared")
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        present(alert, animated: true)
    }

    private func showCustomLLMBaseURLInput() {
        let currentURL = LLMService.shared.getCustomLLMBaseURL()

        let alert = UIAlertController(
            title: "Custom LLM Base URL",
            message: "Optional: point the app to a self-hosted OpenAI-compatible endpoint.\n\nExample:\nhttp://YOUR_VM_IP:8000/v1",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "http://YOUR_VM_IP:8000/v1"
            textField.text = currentURL.isEmpty ? nil : currentURL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.keyboardType = .URL
        }

        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let text = alert.textFields?.first?.text else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            LLMService.shared.setCustomLLMBaseURL(trimmed.isEmpty ? nil : trimmed)
            self?.showMessage("Custom LLM base URL \(trimmed.isEmpty ? "cleared" : "saved")")
        })

        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            LLMService.shared.setCustomLLMBaseURL(nil)
            self?.showMessage("Custom LLM base URL cleared")
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        present(alert, animated: true)
    }

    // MARK: - Survey API (Cloud SQL) Settings

    private func showSurveyAPIBaseURLInput() {
        let current = SurveyAPIClient.shared.baseURLString
        let alert = UIAlertController(
            title: "Survey API Base URL",
            message: "Set the base URL for your FastAPI server.\n\nExample:\nhttps://YOUR_DOMAIN\nor\nhttp://YOUR_VM_IP:8000",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "https://YOUR_DOMAIN"
            textField.text = current.isEmpty ? nil : current
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.keyboardType = .URL
        }

        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            let text = alert.textFields?.first?.text ?? ""
            SurveyAPIClient.shared.baseURLString = text
            self?.showMessage("Survey API base URL \(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "cleared" : "saved")")
        })

        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            SurveyAPIClient.shared.baseURLString = ""
            self?.showMessage("Survey API base URL cleared")
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showSurveyAPIKeyInput() {
        let current = SurveyAPIClient.shared.apiKey
        let hasExisting = !current.isEmpty
        let alert = UIAlertController(
            title: "Survey API Key",
            message: "Optional: set X-API-Key for your Survey API server.",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            if hasExisting {
                textField.placeholder = "API key is configured (enter new key to update)"
                let masked = String(current.prefix(6)) + "..." + String(current.suffix(4))
                textField.text = masked
            } else {
                textField.placeholder = "Enter API key (optional)"
            }
            textField.isSecureTextEntry = true
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }

        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            let text = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if hasExisting {
                let masked = String(current.prefix(6)) + "..." + String(current.suffix(4))
                if text == masked {
                    self?.showMessage("Survey API key unchanged")
                    return
                }
            }
            SurveyAPIClient.shared.apiKey = text
            self?.showMessage(text.isEmpty ? "Survey API key cleared" : "Survey API key saved")
        })

        if hasExisting {
            alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
                SurveyAPIClient.shared.apiKey = ""
                self?.showMessage("Survey API key cleared")
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showInterviewerProfileInput() {
        let current = InterviewerProfileStore.shared.currentProfile
        let alert = UIAlertController(
            title: "Interviewer Profile",
            message: "Enter the interviewer name and email. The email is used as the interviewer ID across devices.",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "Name"
            textField.text = current?.name
            textField.autocapitalizationType = .words
            textField.autocorrectionType = .yes
        }

        alert.addTextField { textField in
            textField.placeholder = "email@columbia.edu"
            textField.text = current?.email
            textField.keyboardType = .emailAddress
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }

        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let email = alert.textFields?.dropFirst().first?.text ?? ""
            let normalizedEmail = InterviewerProfile.normalizedEmail(email)

            guard !name.isEmpty else {
                self?.showMessage("Interviewer name cannot be empty")
                return
            }
            guard InterviewerProfile.isValidEmail(normalizedEmail) else {
                self?.showMessage("Enter a valid interviewer email")
                return
            }

            let localProfile = InterviewerProfile(name: name, email: normalizedEmail, identityScope: "device")
            guard SurveyAPIClient.shared.isConfigured() else {
                InterviewerProfileStore.shared.saveCurrentProfile(localProfile)
                self?.showMessage("Interviewer saved locally")
                return
            }

            Task { [weak self] in
                do {
                    let response = try await SurveyAPIClient.shared.resolveInterviewer(name: name, email: normalizedEmail)
                    await MainActor.run {
                        InterviewerProfileStore.shared.saveCurrentProfile(response.profile)
                        self?.showMessage("Interviewer saved")
                    }
                } catch {
                    await MainActor.run {
                        InterviewerProfileStore.shared.saveCurrentProfile(localProfile)
                        self?.showMessage("Interviewer saved locally. Server lookup failed: \(error.localizedDescription)")
                    }
                }
            }
        })

        if current != nil {
            alert.addAction(UIAlertAction(title: "Clear Current", style: .destructive) { [weak self] _ in
                InterviewerProfileStore.shared.clearCurrentProfile()
                self?.showMessage("Current interviewer cleared")
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showSavedInterviewerSelection() {
        let profiles = InterviewerProfileStore.shared.profiles
        guard !profiles.isEmpty else {
            showMessage("None saved")
            return
        }

        let alert = UIAlertController(
            title: "Select Interviewer",
            message: "Choose the person using this device now.",
            preferredStyle: .actionSheet
        )

        let currentId = InterviewerProfileStore.shared.currentProfile?.interviewerId
        for profile in profiles {
            let marker = profile.interviewerId == currentId ? " ✓" : ""
            alert.addAction(UIAlertAction(title: "\(profile.name) (\(profile.email))\(marker)", style: .default) { [weak self] _ in
                InterviewerProfileStore.shared.saveCurrentProfile(profile)
                self?.showMessage("Current interviewer: \(profile.name)")
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        present(alert, animated: true)
    }

    private func showSavedInterviewerDeletion() {
        let profiles = InterviewerProfileStore.shared.profiles
        guard !profiles.isEmpty else {
            showMessage("No saved interviewers")
            return
        }

        let alert = UIAlertController(
            title: "Delete Saved Interviewer",
            message: "Remove a saved interviewer from this device. Existing session records will keep their saved interviewer name and email.",
            preferredStyle: .actionSheet
        )

        let currentId = InterviewerProfileStore.shared.currentProfile?.interviewerId
        for profile in profiles {
            let marker = profile.interviewerId == currentId ? " (current)" : ""
            alert.addAction(UIAlertAction(title: "\(profile.name) (\(profile.email))\(marker)", style: .destructive) { [weak self] _ in
                self?.confirmDeleteSavedInterviewer(profile)
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        present(alert, animated: true)
    }

    private func confirmDeleteSavedInterviewer(_ profile: InterviewerProfile) {
        let alert = UIAlertController(
            title: "Delete \(profile.name)?",
            message: "This removes \(profile.email) from saved interviewers on this device only. Past sessions and server records are not deleted.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            InterviewerProfileStore.shared.deleteProfile(interviewerId: profile.interviewerId)
            self?.showMessage("Deleted saved interviewer: \(profile.name)")
        })
        present(alert, animated: true)
    }

    private func recordingMetadataURL(for recordingURL: URL) -> URL {
        return recordingURL.deletingPathExtension().appendingPathExtension("json")
    }

    private func recordingMetadata(for recordingURL: URL) -> [String: Any]? {
        let metadataURL = recordingMetadataURL(for: recordingURL)
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func recordedAtMs(for recordingURL: URL) -> Int? {
        if let epoch = recordingMetadata(for: recordingURL)?["recorded_at_epoch"] as? Double {
            return Int(epoch * 1000)
        }
        if let date = try? recordingURL.resourceValues(forKeys: [.creationDateKey]).creationDate {
            return Int(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }

    private func sessionIdForRecording(_ recordingURL: URL) -> String? {
        if let metadataSessionId = recordingMetadata(for: recordingURL)?["session_id"] as? String,
           !metadataSessionId.isEmpty {
            return metadataSessionId
        }
        return recordingURL.deletingLastPathComponent().lastPathComponent
    }

    private func recordingStartTrajectoryPoint(
        for recordingURL: URL,
        cloudSessionId: String
    ) -> TrajectoryPoint? {
        if let point = recordingStartTrajectoryPoint {
            return pointWithCloudSessionId(point, cloudSessionId)
        }

        guard let raw = recordingMetadata(for: recordingURL)?["recording_start_trajectory_point"] as? [String: Any] else {
            return nil
        }
        guard let tsMs = int64Value(raw["ts_ms"]),
              let lat = doubleValue(raw["lat"]),
              let lon = doubleValue(raw["lon"]) else {
            return nil
        }

        let point = TrajectoryPoint(
            tsMs: tsMs,
            lat: lat,
            lon: lon,
            accuracyM: doubleValue(raw["accuracy_m"]),
            speedMps: doubleValue(raw["speed_mps"]),
            courseDeg: doubleValue(raw["course_deg"]),
            provider: raw["provider"] as? String ?? "recording-start",
            isBackground: raw["is_background"] as? Bool,
            sessionId: cloudSessionId
        )
        recordingStartTrajectoryPoint = point
        return point
    }

    private func interviewTrajectoryPoints(
        for recordingURL: URL,
        cloudSessionId: String
    ) -> [TrajectoryPoint] {
        if isRecording {
            let currentPoints = TrajectoryTracker.shared.currentInterviewPoints()
            if !currentPoints.isEmpty {
                interviewTrajectoryPoints = currentPoints
            }
        }

        if !interviewTrajectoryPoints.isEmpty {
            return interviewTrajectoryPoints.map { pointWithCloudSessionId($0, cloudSessionId) }
        }

        if let rawPoints = recordingMetadata(for: recordingURL)?["trajectory_points"] as? [[String: Any]] {
            let points = rawPoints.compactMap { trajectoryPoint(from: $0, cloudSessionId: cloudSessionId) }
            if !points.isEmpty {
                interviewTrajectoryPoints = points
                return points
            }
        }

        if let startPoint = recordingStartTrajectoryPoint(for: recordingURL, cloudSessionId: cloudSessionId) {
            return [startPoint]
        }

        return []
    }

    private func trajectoryPoint(
        from raw: [String: Any],
        cloudSessionId: String
    ) -> TrajectoryPoint? {
        guard let tsMs = int64Value(raw["ts_ms"]),
              let lat = doubleValue(raw["lat"]),
              let lon = doubleValue(raw["lon"]) else {
            return nil
        }

        return TrajectoryPoint(
            tsMs: tsMs,
            lat: lat,
            lon: lon,
            accuracyM: doubleValue(raw["accuracy_m"]),
            speedMps: doubleValue(raw["speed_mps"]),
            courseDeg: doubleValue(raw["course_deg"]),
            provider: raw["provider"] as? String ?? "interview",
            isBackground: raw["is_background"] as? Bool,
            sessionId: cloudSessionId
        )
    }

    private func pointWithCloudSessionId(
        _ point: TrajectoryPoint,
        _ cloudSessionId: String
    ) -> TrajectoryPoint {
        return TrajectoryPoint(
            tsMs: point.tsMs,
            lat: point.lat,
            lon: point.lon,
            accuracyM: point.accuracyM,
            speedMps: point.speedMps,
            courseDeg: point.courseDeg,
            provider: point.provider,
            isBackground: point.isBackground,
            sessionId: cloudSessionId
        )
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Int64 { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    // MARK: - Respondent Info Form
    private func showRespondentInfoForm(completion: @escaping (RespondentInfo) -> Void) {
        let infoVC = RespondentInfoViewController()
        let locationStore = SavedSurveyLocationStore.shared
        if locationStore.mode == .fixed {
            infoVC.initialSurveyLocation = locationStore.activeLocation?.name
        }
        infoVC.onInfoSubmitted = { [weak self] info in
            self?.dismiss(animated: true) {
                completion(info)
            }
        }
        infoVC.onCancel = { [weak self] in
            self?.dismiss(animated: true)
        }

        let navController = UINavigationController(rootViewController: infoVC)
        navController.modalPresentationStyle = .fullScreen
        present(navController, animated: true)
    }

    // MARK: - Location-based Aggregation
    private func performLocationAggregation() {
        statusLabel.text = "Aggregating by location..."
        statusLabel.textColor = .systemBlue
        aggregateButton.isEnabled = false
        aggregateButton.alpha = 0.5

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let records = try self.loadAggregationSurveyRecords()

                if records.isEmpty {
                    DispatchQueue.main.async {
                        self.statusLabel.text = "No historical data available"
                        self.statusLabel.textColor = .systemOrange
                        self.showMessage("No analyzed session.json packages found for aggregation")
                        self.aggregateButton.isEnabled = true
                        self.aggregateButton.alpha = 1.0
                    }
                    return
                }

                // Group files by location
                var locationData: [String: [ExportedSurvey]] = [:]

                for record in records {
                    let exportEntry = record.survey
                    let location = exportEntry.respondentInfo?.location ?? "Unknown Location"
                    locationData[location, default: []].append(exportEntry)
                }

                if locationData.isEmpty {
                    DispatchQueue.main.async {
                        self.statusLabel.text = "No location data found"
                        self.statusLabel.textColor = .systemOrange
                        self.showMessage("No location information found in export files")
                        self.aggregateButton.isEnabled = true
                        self.aggregateButton.alpha = 1.0
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.statusLabel.text = "Aggregation complete"
                    self.statusLabel.textColor = .systemGreen
                    self.aggregateButton.isEnabled = true
                    self.aggregateButton.alpha = 1.0

                    // Show location aggregation view
                    let locationVC = LocationAggregationViewController()
                    locationVC.locationData = locationData
                    locationVC.exportsDirectory = try? self.ensureAggregatedExportsDirectory()

                    let navController = UINavigationController(rootViewController: locationVC)
                    self.present(navController, animated: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Aggregation failed"
                    self.statusLabel.textColor = .systemRed
                    self.showMessage("Unable to access export directory: \(error.localizedDescription)")
                    self.aggregateButton.isEnabled = true
                    self.aggregateButton.alpha = 1.0
                }
            }
        }
    }
}

final class AggregationTextViewController: UIViewController {
    private let contentTitle: String
    private let content: String

    init(title: String, content: String) {
        self.contentTitle = title
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = contentTitle
        buildUI()
    }

    private func buildUI() {
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = contentTitle
        titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        var closeConfig = UIButton.Configuration.filled()
        closeConfig.title = "Done"
        closeConfig.baseBackgroundColor = .systemBlue
        closeConfig.baseForegroundColor = .white
        closeConfig.cornerStyle = .medium
        closeButton.configuration = closeConfig
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.text = content.isEmpty ? "No aggregation details were generated." : content
        textView.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        textView.textColor = .label
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 8
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        textView.isEditable = false
        textView.alwaysBounceVertical = true

        view.addSubview(titleLabel)
        view.addSubview(textView)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            textView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            textView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -16),

            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            closeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            closeButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}

private final class QuestionnaireSelectionViewController: UIViewController {
    private let cached: [Questionnaire]
    private let current: Questionnaire?
    private let canRefresh: Bool
    private let onSelect: (Questionnaire) -> Void
    private let onRefresh: () -> Void

    init(
        cached: [Questionnaire],
        current: Questionnaire?,
        canRefresh: Bool,
        onSelect: @escaping (Questionnaire) -> Void,
        onRefresh: @escaping () -> Void
    ) {
        self.cached = cached
        self.current = current
        self.canRefresh = canRefresh
        self.onSelect = onSelect
        self.onRefresh = onRefresh
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        buildUI()
    }

    private func buildUI() {
        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = .systemBackground
        panel.layer.cornerRadius = 18
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.18
        panel.layer.shadowRadius = 20
        panel.layer.shadowOffset = CGSize(width: 0, height: 8)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Choose Questionnaire"
        titleLabel.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center

        let messageLabel = UILabel()
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.text = cached.isEmpty ? "Refresh to load published questionnaires from the server." : "Select the survey to use for this interview."
        messageLabel.font = UIFont.systemFont(ofSize: 18)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        let listHeight = min(max(CGFloat(max(cached.count, 1)) * 62, 62), 330)

        let listStack = UIStackView()
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.axis = .vertical
        listStack.spacing = 10

        if cached.isEmpty {
            let emptyLabel = UILabel()
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            emptyLabel.text = "No questionnaires loaded yet."
            emptyLabel.font = UIFont.systemFont(ofSize: 18, weight: .medium)
            emptyLabel.textColor = .secondaryLabel
            emptyLabel.textAlignment = .center
            listStack.addArrangedSubview(emptyLabel)
            emptyLabel.heightAnchor.constraint(equalToConstant: 52).isActive = true
        } else {
            for (index, questionnaire) in cached.enumerated() {
                let button = makeQuestionnaireButton(for: questionnaire, index: index)
                listStack.addArrangedSubview(button)
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            }
        }

        let actionStack = UIStackView()
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.axis = .vertical
        actionStack.spacing = 10
        actionStack.distribution = .fillEqually

        if canRefresh {
            actionStack.addArrangedSubview(
                makeActionButton(
                    title: "Refresh List",
                    backgroundColor: .systemGreen,
                    foregroundColor: .white,
                    action: #selector(refreshTapped)
                )
            )
        }

        actionStack.addArrangedSubview(
            makeActionButton(
                title: "Cancel",
                backgroundColor: .systemRed,
                foregroundColor: .white,
                action: #selector(cancelTapped)
            )
        )

        view.addSubview(panel)
        panel.addSubview(titleLabel)
        panel.addSubview(messageLabel)
        panel.addSubview(scrollView)
        panel.addSubview(actionStack)
        scrollView.addSubview(listStack)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            panel.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),

            titleLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),

            scrollView.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22),
            scrollView.heightAnchor.constraint(equalToConstant: listHeight),

            listStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            listStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            actionStack.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 14),
            actionStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            actionStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22),
            actionStack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -22)
        ])

        for button in actionStack.arrangedSubviews {
            button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        }
    }

    private func makeQuestionnaireButton(for questionnaire: Questionnaire, index: Int) -> UIButton {
        let versionText = questionnaire.version.map { " v\($0)" } ?? ""
        let isCurrent = questionnaire.id == current?.id && questionnaire.version == current?.version
        let marker = isCurrent ? " ✓" : ""
        let button = makeConfiguredButton(
            title: "\(questionnaire.title)\(versionText)\(marker)",
            backgroundColor: isCurrent ? .systemBlue.withAlphaComponent(0.16) : .secondarySystemFill,
            foregroundColor: .label,
            fontSize: 18
        )
        button.tag = index
        button.addTarget(self, action: #selector(questionnaireTapped(_:)), for: .touchUpInside)
        button.contentHorizontalAlignment = .center
        return button
    }

    private func makeActionButton(
        title: String,
        backgroundColor: UIColor,
        foregroundColor: UIColor,
        action: Selector
    ) -> UIButton {
        let button = makeConfiguredButton(
            title: title,
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            fontSize: 19
        )
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makeConfiguredButton(
        title: String,
        backgroundColor: UIColor,
        foregroundColor: UIColor,
        fontSize: CGFloat
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.filled()
        var attributedTitle = AttributedString(title)
        attributedTitle.font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        config.attributedTitle = attributedTitle
        config.baseBackgroundColor = backgroundColor
        config.baseForegroundColor = foregroundColor
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        button.configuration = config
        button.titleLabel?.numberOfLines = 0
        return button
    }

    @objc private func questionnaireTapped(_ sender: UIButton) {
        guard cached.indices.contains(sender.tag) else { return }
        let questionnaire = cached[sender.tag]
        dismiss(animated: true) { [onSelect] in
            onSelect(questionnaire)
        }
    }

    @objc private func refreshTapped() {
        dismiss(animated: true) { [onRefresh] in
            onRefresh()
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }
}

private final class RecordingReviewViewController: UIViewController {
    var onPlay: (() -> Void)?
    var onAnalyze: (() -> Void)?
    var onDiscard: (() -> Void)?

    private let statusLabel = UILabel()
    private let playButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        buildUI()
    }

    private func buildUI() {
        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = .systemBackground
        panel.layer.cornerRadius = 16
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.18
        panel.layer.shadowRadius = 20
        panel.layer.shadowOffset = CGSize(width: 0, height: 8)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Review Recording"
        titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center

        let messageLabel = UILabel()
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.text = "Listen as many times as needed, then analyze or discard this interview."
        messageLabel.font = UIFont.systemFont(ofSize: 16)
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Ready to review"
        statusLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = .systemGray
        statusLabel.textAlignment = .center

        configureButton(playButton, title: "Play Audio", color: .systemPurple, action: #selector(playTapped))
        let analyzeButton = makeButton(title: "Analyze Answers", color: .systemBlue, action: #selector(analyzeTapped))
        let discardButton = makeButton(title: "Discard Recording", color: .systemRed, action: #selector(discardTapped))

        let stack = UIStackView(arrangedSubviews: [playButton, analyzeButton, discardButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        stack.distribution = .fillEqually

        view.addSubview(panel)
        panel.addSubview(titleLabel)
        panel.addSubview(messageLabel)
        panel.addSubview(statusLabel)
        panel.addSubview(stack)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 430),

            titleLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),

            statusLabel.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),

            stack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -24),
            playButton.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    private func makeButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        configureButton(button, title: title, color: color, action: action)
        return button
    }

    private func configureButton(_ button: UIButton, title: String, color: UIColor, action: Selector? = nil) {
        button.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = color
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        button.configuration = config
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        if let action {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
    }

    func setPlaybackActive(_ isActive: Bool) {
        var config = playButton.configuration ?? UIButton.Configuration.filled()
        config.title = isActive ? "Stop Audio" : "Play Audio"
        config.baseBackgroundColor = isActive ? .systemRed : .systemPurple
        playButton.configuration = config
        statusLabel.text = isActive ? "Playing audio..." : "Ready to review"
        statusLabel.textColor = isActive ? .systemPurple : .systemGray
    }

    @objc private func playTapped() {
        onPlay?()
    }

    @objc private func analyzeTapped() {
        onAnalyze?()
    }

    @objc private func discardTapped() {
        onDiscard?()
    }
}

private final class RecordingMonitorViewController: UIViewController {
    var questions: [Question] = []
    var levelProvider: (() -> Float)?
    var onStopReview: (() -> Void)?
    var onDiscard: (() -> Void)?

    private let waveformView = RecordingWaveformView()
    private let timerLabel = UILabel()
    private let qualityLabel = UILabel()
    private var startedAt = Date()
    private var timer: Timer?
    private var recentLevels: [Float] = []
    private var selectedOptionCodesByQuestionId: [Int: Set<String>] = [:]
    private var optionButtonsByQuestionId: [Int: [String: UIButton]] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        isModalInPresentation = true
        buildUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.fire()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    func selectedMultipleChoiceAnswers() -> [Int: [String]] {
        var answers: [Int: [String]] = [:]
        for question in questions where question.type.lowercased() == "multiple-choice" {
            let selectedCodes = selectedOptionCodesByQuestionId[question.id] ?? []
            let orderedCodes = question.options
                .map { $0.code.uppercased() }
                .filter { selectedCodes.contains($0) }
            if !orderedCodes.isEmpty {
                answers[question.id] = orderedCodes
            }
        }
        return answers
    }

    private func buildUI() {
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        timerLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        timerLabel.textAlignment = .center
        timerLabel.text = "00:00"

        qualityLabel.translatesAutoresizingMaskIntoConstraints = false
        qualityLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        qualityLabel.textAlignment = .center
        qualityLabel.textColor = .systemOrange
        qualityLabel.text = "Listening for voice..."

        let monitorPage = makeMonitorPage()

        let stopButton = UIButton(type: .system)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        var stopConfig = UIButton.Configuration.filled()
        stopConfig.title = "Stop & Review"
        stopConfig.baseBackgroundColor = .systemGreen
        stopConfig.baseForegroundColor = .white
        stopConfig.cornerStyle = .medium
        stopButton.configuration = stopConfig
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)

        let discardButton = UIButton(type: .system)
        discardButton.translatesAutoresizingMaskIntoConstraints = false
        var discardConfig = UIButton.Configuration.filled()
        discardConfig.title = "Discard Recording"
        discardConfig.baseBackgroundColor = .systemRed
        discardConfig.baseForegroundColor = .white
        discardConfig.cornerStyle = .medium
        discardButton.configuration = discardConfig
        discardButton.addTarget(self, action: #selector(discardTapped), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [discardButton, stopButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually

        view.addSubview(timerLabel)
        view.addSubview(qualityLabel)
        view.addSubview(monitorPage)
        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            timerLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            timerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            timerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            qualityLabel.topAnchor.constraint(equalTo: timerLabel.bottomAnchor, constant: 8),
            qualityLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            qualityLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            monitorPage.topAnchor.constraint(equalTo: qualityLabel.bottomAnchor, constant: 18),
            monitorPage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            monitorPage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            monitorPage.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),

            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            buttonStack.heightAnchor.constraint(equalToConstant: 56)
        ])
    }

    private func makeMonitorPage() -> UIView {
        let page = UIView()
        page.translatesAutoresizingMaskIntoConstraints = false

        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.backgroundColor = .secondarySystemBackground
        waveformView.layer.cornerRadius = 8
        waveformView.clipsToBounds = true

        let questionsBox = makeQuestionsBox()

        page.addSubview(waveformView)
        page.addSubview(questionsBox)

        NSLayoutConstraint.activate([
            waveformView.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            waveformView.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 24),
            waveformView.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -24),
            waveformView.heightAnchor.constraint(equalToConstant: 76),

            questionsBox.topAnchor.constraint(equalTo: waveformView.bottomAnchor, constant: 10),
            questionsBox.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 24),
            questionsBox.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -24),
            questionsBox.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -8)
        ])

        return page
    }

    private func makeQuestionsBox() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 8
        container.clipsToBounds = true

        let questionScrollView = UIScrollView()
        questionScrollView.translatesAutoresizingMaskIntoConstraints = false
        questionScrollView.isPagingEnabled = true
        questionScrollView.showsHorizontalScrollIndicator = false
        questionScrollView.alwaysBounceHorizontal = true

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 0
        stack.alignment = .fill
        stack.distribution = .fill
        var questionCards: [UIView] = []

        if questions.isEmpty {
            let card = makeQuestionCard(
                items: [QuestionCardItem(
                    questionId: -1,
                    title: "Questionnaire not loaded",
                    detail: "Check that questionnaire.json is bundled with the app.",
                    answerType: "Unavailable",
                    options: [],
                    allowsMultiple: false
                )]
            )
            stack.addArrangedSubview(card)
            questionCards.append(card)
        } else {
            var startIndex = 0
            while startIndex < questions.count {
                let slideEnd = startIndex + 1
                let slideQuestions = questions[startIndex..<slideEnd]
                let items = slideQuestions.enumerated().map { offset, question in
                    QuestionCardItem(
                        questionId: question.id,
                        title: "\(startIndex + offset + 1) of \(questions.count): \(question.question)",
                        detail: question.followUp.map { "Follow-up: \($0)" },
                        answerType: answerTypeLabel(for: question),
                        options: question.options,
                        allowsMultiple: question.allowsMultiple
                    )
                }
                let card = makeQuestionCard(items: items)
                stack.addArrangedSubview(card)
                questionCards.append(card)
                startIndex = slideEnd
            }
        }

        container.addSubview(questionScrollView)
        questionScrollView.addSubview(stack)

        var constraints: [NSLayoutConstraint] = [
            questionScrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            questionScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            questionScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            questionScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),

            stack.topAnchor.constraint(equalTo: questionScrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: questionScrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: questionScrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: questionScrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: questionScrollView.frameLayoutGuide.heightAnchor)
        ]
        constraints.append(contentsOf: questionCards.map {
            $0.widthAnchor.constraint(equalTo: questionScrollView.frameLayoutGuide.widthAnchor)
        })
        NSLayoutConstraint.activate(constraints)

        return container
    }

    private struct QuestionCardItem {
        let questionId: Int
        let title: String
        let detail: String?
        let answerType: String
        let options: [QuestionOption]
        let allowsMultiple: Bool
    }

    private func makeQuestionCard(items: [QuestionCardItem]) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 8
        card.clipsToBounds = true

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        stack.distribution = .fillEqually

        for item in items {
            stack.addArrangedSubview(makeQuestionBlock(item))
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])

        return card
    }

    private func makeQuestionBlock(_ item: QuestionCardItem) -> UIView {
        let block = UIView()
        block.translatesAutoresizingMaskIntoConstraints = false

        let answerBadge = UILabel()
        answerBadge.translatesAutoresizingMaskIntoConstraints = false
        answerBadge.text = item.answerType
        answerBadge.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        answerBadge.textColor = .white
        answerBadge.backgroundColor = .systemBlue
        answerBadge.textAlignment = .center
        answerBadge.adjustsFontSizeToFitWidth = true
        answerBadge.minimumScaleFactor = 0.75
        answerBadge.layer.cornerRadius = 5
        answerBadge.clipsToBounds = true

        let questionLabel = UILabel()
        questionLabel.translatesAutoresizingMaskIntoConstraints = false
        questionLabel.text = item.title
        questionLabel.font = UIFont.systemFont(ofSize: item.options.isEmpty ? 34 : 30, weight: .semibold)
        questionLabel.textColor = .label
        questionLabel.numberOfLines = 0
        questionLabel.adjustsFontSizeToFitWidth = true
        questionLabel.minimumScaleFactor = 0.68
        questionLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let followUpLabel = UILabel()
        followUpLabel.translatesAutoresizingMaskIntoConstraints = false
        followUpLabel.text = item.detail
        followUpLabel.font = UIFont.systemFont(ofSize: 21, weight: .medium)
        followUpLabel.textColor = .secondaryLabel
        followUpLabel.numberOfLines = 0
        followUpLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        block.addSubview(answerBadge)
        block.addSubview(questionLabel)

        var constraints: [NSLayoutConstraint] = [
            answerBadge.topAnchor.constraint(equalTo: block.topAnchor),
            answerBadge.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            answerBadge.heightAnchor.constraint(equalToConstant: 30),
            answerBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),

            questionLabel.topAnchor.constraint(equalTo: answerBadge.bottomAnchor, constant: 6),
            questionLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            questionLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor)
        ]

        let contentTopAnchor: NSLayoutYAxisAnchor
        if item.detail != nil {
            block.addSubview(followUpLabel)
            constraints.append(contentsOf: [
                followUpLabel.topAnchor.constraint(equalTo: questionLabel.bottomAnchor, constant: 8),
                followUpLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor),
                followUpLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor)
            ])
            contentTopAnchor = followUpLabel.bottomAnchor
        } else {
            contentTopAnchor = questionLabel.bottomAnchor
        }

        if !item.options.isEmpty {
            let optionsScrollView = UIScrollView()
            optionsScrollView.translatesAutoresizingMaskIntoConstraints = false
            optionsScrollView.alwaysBounceVertical = true
            optionsScrollView.showsVerticalScrollIndicator = true

            let optionStack = UIStackView()
            optionStack.translatesAutoresizingMaskIntoConstraints = false
            optionStack.axis = .vertical
            optionStack.spacing = 10

            block.addSubview(optionsScrollView)
            optionsScrollView.addSubview(optionStack)

            optionButtonsByQuestionId[item.questionId] = [:]
            for option in item.options {
                let code = option.code.uppercased()
                let optionButton = makeOptionButton(
                    questionId: item.questionId,
                    code: code,
                    text: option.text,
                    allowsMultiple: item.allowsMultiple
                )
                optionStack.addArrangedSubview(optionButton)
                optionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
                optionButtonsByQuestionId[item.questionId]?[code] = optionButton
            }

            constraints.append(contentsOf: [
                optionsScrollView.topAnchor.constraint(equalTo: contentTopAnchor, constant: 10),
                optionsScrollView.leadingAnchor.constraint(equalTo: block.leadingAnchor),
                optionsScrollView.trailingAnchor.constraint(equalTo: block.trailingAnchor),
                optionsScrollView.bottomAnchor.constraint(equalTo: block.bottomAnchor),

                optionStack.topAnchor.constraint(equalTo: optionsScrollView.contentLayoutGuide.topAnchor),
                optionStack.leadingAnchor.constraint(equalTo: optionsScrollView.contentLayoutGuide.leadingAnchor),
                optionStack.trailingAnchor.constraint(equalTo: optionsScrollView.contentLayoutGuide.trailingAnchor),
                optionStack.bottomAnchor.constraint(equalTo: optionsScrollView.contentLayoutGuide.bottomAnchor),
                optionStack.widthAnchor.constraint(equalTo: optionsScrollView.frameLayoutGuide.widthAnchor)
            ])
        } else {
            constraints.append(contentTopAnchor.constraint(lessThanOrEqualTo: block.bottomAnchor))
        }

        NSLayoutConstraint.activate(constraints)

        return block
    }

    private func makeOptionButton(
        questionId: Int,
        code: String,
        text: String,
        allowsMultiple: Bool
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.numberOfLines = 0
        button.addAction(UIAction { [weak self] _ in
            self?.toggleOption(questionId: questionId, code: code, allowsMultiple: allowsMultiple)
        }, for: .touchUpInside)
        updateOptionButton(button, code: code, text: text, isSelected: false)
        return button
    }

    private func toggleOption(questionId: Int, code: String, allowsMultiple: Bool) {
        let normalizedCode = code.uppercased()
        var selectedCodes = selectedOptionCodesByQuestionId[questionId] ?? []

        if selectedCodes.contains(normalizedCode) {
            selectedCodes.remove(normalizedCode)
        } else {
            if allowsMultiple {
                selectedCodes.insert(normalizedCode)
            } else {
                selectedCodes = [normalizedCode]
            }
        }

        selectedOptionCodesByQuestionId[questionId] = selectedCodes
        refreshOptionButtons(questionId: questionId)
    }

    private func refreshOptionButtons(questionId: Int) {
        guard let buttons = optionButtonsByQuestionId[questionId] else { return }
        let selectedCodes = selectedOptionCodesByQuestionId[questionId] ?? []
        for question in questions where question.id == questionId {
            for option in question.options {
                let code = option.code.uppercased()
                guard let button = buttons[code] else { continue }
                updateOptionButton(
                    button,
                    code: code,
                    text: option.text,
                    isSelected: selectedCodes.contains(code)
                )
            }
        }
    }

    private func updateOptionButton(
        _ button: UIButton,
        code: String,
        text: String,
        isSelected: Bool
    ) {
        var config = UIButton.Configuration.filled()
        var title = AttributedString("\(isSelected ? "[x]" : "[ ]") \(code). \(text)")
        title.font = UIFont.systemFont(ofSize: 24, weight: .semibold)
        config.attributedTitle = title
        config.baseBackgroundColor = isSelected ? .systemGreen.withAlphaComponent(0.22) : .secondarySystemFill
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        button.configuration = config
        button.accessibilityLabel = "\(isSelected ? "Selected" : "Not selected") choice \(code), \(text)"
    }

    private func answerTypeLabel(for question: Question) -> String {
        switch question.type.lowercased() {
        case "yes-no":
            return "Yes / No"
        case "impression":
            return "Impression"
        default:
            return question.type.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private func tick() {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        timerLabel.text = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)

        let level = levelProvider?() ?? 0
        recentLevels.append(level)
        if recentLevels.count > 18 {
            recentLevels.removeFirst(recentLevels.count - 18)
        }

        waveformView.append(level: level)
        updateQualityLabel()
    }

    private func updateQualityLabel() {
        let average = recentLevels.isEmpty ? 0 : recentLevels.reduce(0, +) / Float(recentLevels.count)

        if average > 0.22 {
            qualityLabel.text = "Voice detected"
            qualityLabel.textColor = .systemGreen
        } else if average > 0.08 {
            qualityLabel.text = "Voice is quiet"
            qualityLabel.textColor = .systemOrange
        } else {
            qualityLabel.text = "No clear voice detected"
            qualityLabel.textColor = .systemRed
        }
    }

    @objc private func stopTapped() {
        onStopReview?()
    }

    @objc private func discardTapped() {
        onDiscard?()
    }
}

private final class RecordingWaveformView: UIView {
    private var levels: [Float] = Array(repeating: 0, count: 42)

    func append(level: Float) {
        levels.append(max(0, min(1, level)))
        if levels.count > 42 {
            levels.removeFirst(levels.count - 42)
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.clear(rect)

        let barCount = levels.count
        let gap: CGFloat = 4
        let barWidth = max(3, (rect.width - CGFloat(barCount - 1) * gap) / CGFloat(barCount))
        let midY = rect.midY

        UIColor.systemBlue.setFill()
        for (index, level) in levels.enumerated() {
            let x = CGFloat(index) * (barWidth + gap)
            let height = max(8, CGFloat(level) * rect.height * 0.86)
            let barRect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
            let path = UIBezierPath(roundedRect: barRect, cornerRadius: barWidth / 2)
            path.fill()
        }
    }
}
