import UIKit
import AVFoundation
import Speech

class ViewController: UIViewController, AVAudioPlayerDelegate {

    // MARK: - Properties
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var playButton: UIButton!
    @IBOutlet weak var llmButton: UIButton!
    @IBOutlet weak var exportButton: UIButton!
    @IBOutlet weak var aggregateButton: UIButton!
    private var dashboardButton: UIButton?
    private var audioFilesButton: UIButton?
    private var clearButton: UIButton?  // Created programmatically

    // Recording state
    private var isRecording = false
    private var recordedData: String?
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingURL: URL?
    private weak var recordingMonitorViewController: RecordingMonitorViewController?
    private weak var recordingReviewViewController: RecordingReviewViewController?
    private var recordingStartTrajectoryPoint: PendingTrajectoryStore.Point?
    private var interviewTrajectoryPoints: [PendingTrajectoryStore.Point] = []

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
    private var respondentInfo: RespondentInfo?
    /// Set when pushing from `MapViewController`; passed into the respondent form until a successful submit.
    var mapLocationPrefill: MapLocationPayload?

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        loadQuestionnaire()
        requestSpeechPermission()
        setupUI()
        initializeSessionAndPurge()
        resetInactivityTimer()

        // Legacy answer-row retries are intentionally disabled under package-based storage.
        Task { [weak self] in
            await self?.flushPendingSurveyUploads()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resetInactivityTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        invalidateInactivityTimer()
    }

    // MARK: - UI Setup
    private func setupUI() {
        // Set title
        title = "Voice Recognition"

        // Add settings button to navigation bar
        let settingsButton = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            style: .plain,
            target: self,
            action: #selector(settingsButtonTapped)
        )

        // Add questionnaire button to navigation bar
        let questionnaireButton = UIBarButtonItem(
            image: UIImage(systemName: "doc.text"),
            style: .plain,
            target: self,
            action: #selector(questionnaireButtonTapped)
        )

        navigationItem.rightBarButtonItems = [settingsButton, questionnaireButton]
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

        // Setup record button
        setupButton(recordButton, title: "Start Interview", backgroundColor: .systemRed)

        // Setup play button
        setupButton(playButton, title: "Play Recording", backgroundColor: .systemPurple)

        // Analyze now happens from the post-recording review flow.
        setupButton(llmButton, title: "Analyze Answers", backgroundColor: .systemBlue)
        llmButton.isHidden = true

        // The session package is saved automatically after analysis/clarification.
        setupButton(exportButton, title: "Start Next Participant", backgroundColor: .systemGreen)

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

        // Create and setup clear button programmatically
        let clearBtn = UIButton(type: .system)
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        setupButton(clearBtn, title: "Clear JSON Files", backgroundColor: .systemOrange)
        clearBtn.addTarget(self, action: #selector(clearButtonTapped(_:)), for: .touchUpInside)
        view.addSubview(clearBtn)
        self.clearButton = clearBtn

        // Add constraints for programmatic buttons positioned below aggregate button
        NSLayoutConstraint.activate([
            dashboardBtn.topAnchor.constraint(equalTo: aggregateButton.bottomAnchor, constant: 16),
            dashboardBtn.leadingAnchor.constraint(equalTo: aggregateButton.leadingAnchor),
            dashboardBtn.trailingAnchor.constraint(equalTo: audioBtn.leadingAnchor, constant: -12),
            dashboardBtn.heightAnchor.constraint(equalToConstant: 50),
            dashboardBtn.widthAnchor.constraint(equalTo: audioBtn.widthAnchor),

            audioBtn.topAnchor.constraint(equalTo: dashboardBtn.topAnchor),
            audioBtn.trailingAnchor.constraint(equalTo: aggregateButton.trailingAnchor),
            audioBtn.heightAnchor.constraint(equalToConstant: 50),

            clearBtn.topAnchor.constraint(equalTo: dashboardBtn.bottomAnchor, constant: 16),
            clearBtn.leadingAnchor.constraint(equalTo: aggregateButton.leadingAnchor),
            clearBtn.trailingAnchor.constraint(equalTo: aggregateButton.trailingAnchor),
            clearBtn.heightAnchor.constraint(equalToConstant: 50)
        ])

        // Initial state: play disabled; Start Next Participant remains available.
        playButton.isEnabled = false
        llmButton.isEnabled = false
        exportButton.isEnabled = true
        dashboardBtn.isEnabled = true
        audioBtn.isEnabled = true
        playButton.alpha = 0.5
        llmButton.alpha = 0.5
        exportButton.alpha = 1.0
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

            // Clear previous state when starting a new recording (same participant/session unless "Start next participant" was used)
            transcription = nil
            matchedQuestions = []
            interviewTrajectoryPoints = []

            // Analysis now runs from the post-recording review flow.
            llmButton.isEnabled = true  // Can start LLM analysis after recording
            exportButton.isEnabled = true
            llmButton.alpha = 1.0
            exportButton.alpha = 1.0

            showRespondentInfoForm { [weak self] info in
                guard let self = self else { return }
                self.respondentInfo = info

                // Create a Cloud session up-front (best-effort). If it fails, we can still enqueue answers later.
                Task { [weak self] in
                    await self?.ensureCloudSessionCreated()
                }

                // Start recording only after a fresh GPS point is captured.
                self.prepareAndStartRecording()
                self.resetInactivityTimer()
            }
            animateButton(sender)
            return
        }

        // Stop recording
        isRecording = false
        stopRecording(showReview: true)
        animateButton(sender)
    }

    @IBAction func playButtonTapped(_ sender: UIButton) {
        resetInactivityTimer()
        guard let url = recordingURL else {
            showMessage("No recording to play")
            return
        }

        // Check if already playing
        if let player = audioPlayer, player.isPlaying {
            // Stop playing
            player.stop()
            audioPlayer = nil

            updateButton(playButton, title: "Play Recording", backgroundColor: .systemPurple)
            statusLabel.text = "Playback stopped"
            statusLabel.textColor = .systemGray
        } else {
            // Start playing
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.delegate = self
                audioPlayer?.play()

                statusLabel.text = "Playing recording..."
                statusLabel.textColor = .systemPurple

                updateButton(playButton, title: "Stop Playback", backgroundColor: .systemRed)

            } catch {
                showMessage("Playback failed: \(error.localizedDescription)")
            }
        }

        animateButton(sender)
    }

    @IBAction func llmButtonTapped(_ sender: UIButton) {
        resetInactivityTimer()
        runLLMRecognition()
        animateButton(sender)
    }

    private func runLLMRecognition() {
        guard let recordingURL = recordingURL else {
            showMessage("No recording available. Please record first.")
            return
        }

        // Disable button to prevent duplicate clicks
        llmButton.isEnabled = false
        llmButton.alpha = 0.5
        statusLabel.text = "Transcribing audio...\nPlease wait"
        statusLabel.textColor = .systemBlue

        // Step 1: Transcribe audio
        transcribeAudio(url: recordingURL) { [weak self] transcription in
            guard let self = self else { return }

            guard let transcription = transcription, !transcription.isEmpty else {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Transcription failed"
                    self.statusLabel.textColor = .systemRed
                    self.llmButton.isEnabled = true
                    self.llmButton.alpha = 1.0
                    self.showMessage("Failed to transcribe audio. Please try again.")
                }
                return
            }

            self.transcription = transcription

            DispatchQueue.main.async {
                self.statusLabel.text = "Analyzing with LLM...\nPlease wait"
                self.statusLabel.textColor = .systemBlue
            }

            // Step 2: Analyze with POE API
            guard let questions = self.questionnaireData?.questionnaire.questions else {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Questionnaire not loaded"
                    self.statusLabel.textColor = .systemRed
                    self.llmButton.isEnabled = true
                    self.llmButton.alpha = 1.0
                }
                return
            }

            Task {
                do {
                    let matchedQuestions = try await LLMService.shared.analyzeTranscription(transcription, questions: questions)

                    await MainActor.run {
                        self.resolveClarificationsIfNeeded(
                            transcription: transcription,
                            matchedQuestions: matchedQuestions,
                            recordingURL: recordingURL
                        )
                    }
                } catch {
                    DispatchQueue.main.async {
                        let errorMessage = error.localizedDescription
                        self.statusLabel.text = "LLM analysis failed\nCheck error details"
                        self.statusLabel.textColor = .systemRed
                        self.llmButton.isEnabled = true
                        self.llmButton.alpha = 1.0

                        // Show detailed error in alert
                        let alert = UIAlertController(
                            title: "API Call Failed",
                            message: errorMessage,
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        self.present(alert, animated: true)

                        // Also log to console
                        print("LLM API Error: \(errorMessage)")
                    }
                }
            }
        }
    }

    @IBAction func exportButtonTapped(_ sender: UIButton) {
        resetInactivityTimer()
        animateButton(sender)
        startNextParticipant()
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
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.leftBarButtonItem
        }

        present(alert, animated: true)
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
            try jsonData.write(to: sessionFileURL)

            // Mirror into SurveyExports as well (keeps aggregation/clear flows working)
            if let exportsDirectory = try? ensureExportsDirectory() {
                let mirrorName = "survey_results_\(sessionId ?? "unknown")_\(Date().timeIntervalSince1970).json"
                let mirrorURL = exportsDirectory.appendingPathComponent(mirrorName)
                try? jsonData.write(to: mirrorURL)
            }

            // Show export success
            statusLabel.text = "JSON exported successfully!\nSaved to App Folder"
            statusLabel.textColor = .systemGreen

            // Show success message with file location
            let alert = UIAlertController(
                title: "Export Successful",
                message: "File saved to:\n\(fileName)\n\nLocation: App Folder/SurveySessions/\(sessionId ?? "unknown")\n\n(Also mirrored to App Folder/SurveyExports for aggregation.)",
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

            // Also print file path for debugging
            print("File saved to: \(sessionFileURL.path)")

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
        guard !sessions.isEmpty else {
            showMessage("No local session packages found yet")
            return
        }

        let vc = LocalSessionDashboardViewController(sessions: sessions)
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    @objc func clearButtonTapped(_ sender: UIButton) {
        animateButton(sender)

        let alert = UIAlertController(
            title: "Clear JSON Files",
            message: "Are you sure you want to delete all exported JSON questionnaire response files? This action cannot be undone.",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.clearAllJSONFiles()
        })

        present(alert, animated: true)
    }

    private func clearAllJSONFiles() {
        statusLabel.text = "Clearing JSON files..."
        statusLabel.textColor = .systemOrange
        clearButton?.isEnabled = false
        clearButton?.alpha = 0.5

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let exportsDirectory = try self.ensureExportsDirectory()
                let fileManager = FileManager.default

                // Get all JSON files
                let fileURLs = try fileManager.contentsOfDirectory(
                    at: exportsDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension.lowercased() == "json" }

                var deletedCount = 0
                for fileURL in fileURLs {
                    do {
                        try fileManager.removeItem(at: fileURL)
                        deletedCount += 1
                    } catch {
                        print("Failed to delete file \(fileURL.lastPathComponent): \(error)")
                    }
                }

                DispatchQueue.main.async {
                    self.statusLabel.text = "Cleared \(deletedCount) JSON file(s)"
                    self.statusLabel.textColor = .systemGreen
                    self.clearButton?.isEnabled = true
                    self.clearButton?.alpha = 1.0

                    if deletedCount > 0 {
                        self.showMessage("Successfully deleted \(deletedCount) JSON questionnaire response file(s)")
                    } else {
                        self.showMessage("No JSON files found to delete")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Clear failed"
                    self.statusLabel.textColor = .systemRed
                    self.showMessage("Unable to access export directory: \(error.localizedDescription)")
                    self.clearButton?.isEnabled = true
                    self.clearButton?.alpha = 1.0
                }
            }
        }
    }

    // Aggregation action type
    private enum AggregationAction {
        case view
        case export
    }

    // Aggregation result data structure
    private struct AggregationResult {
        let summary: String
        let statistics: [Int: [String: Int]]
        let answerDisplayNames: [Int: [String: String]]
        let questionTexts: [Int: String]
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

                // Get all question IDs
                let allQuestionIds: Set<Int>
                if let questions = self.questionnaireData?.questionnaire.questions {
                    allQuestionIds = Set(questions.map { $0.id })
                } else {
                    allQuestionIds = Set()
                }

                var statistics: [Int: [String: Int]] = [:]
                var answerDisplayNames: [Int: [String: String]] = [:]
                var questionTexts: [Int: String] = [:]

                // Initialize statistics for all questions
                for questionId in allQuestionIds {
                    statistics[questionId] = [
                        "yes": 0,
                        "no": 0,
                        "unanswered": 0
                    ]
                }

                if let questions = self.questionnaireData?.questionnaire.questions {
                    for question in questions {
                        questionTexts[question.id] = question.question
                    }
                }

                var processedFiles = 0

                // Process responses in each session package.
                for record in records {
                    let exportEntry = record.survey
                    processedFiles += 1

                    // Track question IDs that appear in this response
                    var currentResponseQuestionIds: Set<Int> = []

                    for item in exportEntry.matchedQuestions {
                        currentResponseQuestionIds.insert(item.matchedQuestionId)

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

                        statistics[item.matchedQuestionId, default: [:]][answerType, default: 0] += 1

                        if answerDisplayNames[item.matchedQuestionId] == nil {
                            answerDisplayNames[item.matchedQuestionId] = [:]
                        }

                        // Save original answer for display (if yes/no type, save an example)
                        if answerType == "yes" || answerType == "no" {
                            if answerDisplayNames[item.matchedQuestionId]?[answerType] == nil {
                                answerDisplayNames[item.matchedQuestionId]?[answerType] = answerType == "yes" ? "Yes" : "No"
                            }
                        } else {
                            answerDisplayNames[item.matchedQuestionId]?[answerType] = answer
                        }

                        if questionTexts[item.matchedQuestionId] == nil {
                            questionTexts[item.matchedQuestionId] = item.matchedQuestion
                        }
                    }

                    // For questions that don't appear in this response, mark as unanswered
                    for questionId in allQuestionIds {
                        if !currentResponseQuestionIds.contains(questionId) {
                            statistics[questionId, default: [:]]["unanswered", default: 0] += 1
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
                let sortedQuestionIds = allQuestionIds.sorted()

                for questionId in sortedQuestionIds {
                    let questionTitle = questionTexts[questionId] ?? "Question \(questionId)"
                    summary += "Question \(questionId): \(questionTitle)\n"

                    let answerCounts = statistics[questionId] ?? [:]

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
                        let displayText = answerDisplayNames[questionId]?[answerKey] ?? answerKey
                        summary += "  - \(displayText): \(count)\n"
                    }

                    summary += "\n"
                }

                let result = AggregationResult(
                    summary: summary,
                    statistics: statistics,
                    answerDisplayNames: answerDisplayNames,
                    questionTexts: questionTexts,
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
                "questionnaire_title": questionnaireData?.questionnaire.title ?? "Unknown"
            ],
            "aggregation_summary": result.summary,
            "statistics": [:]
        ]

        // Add statistics
        let sortedQuestionIds = result.statistics.keys.sorted()
        var statisticsDict: [String: Any] = [:]

        for questionId in sortedQuestionIds {
            let questionTitle = result.questionTexts[questionId] ?? "Question \(questionId)"
            var questionData: [String: Any] = [
                "question_id": questionId,
                "question_text": questionTitle,
                "answers": []
            ]

            let answerCounts = result.statistics[questionId] ?? [:]
            let sortedAnswers = answerCounts.sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }

            var answersArray: [[String: Any]] = []
            for (answerKey, count) in sortedAnswers {
                let displayText = result.answerDisplayNames[questionId]?[answerKey] ?? answerKey
                answersArray.append([
                    "answer": displayText,
                    "count": count
                ])
            }

            questionData["answers"] = answersArray
            statisticsDict["question_\(questionId)"] = questionData
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
            try jsonDataEncoded.write(to: fileURL)

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
        guard let url = Bundle.main.url(forResource: "questionnaire", withExtension: "json") else {
            print("Error: questionnaire.json not found in bundle")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            questionnaireData = try decoder.decode(QuestionnaireData.self, from: data)
            print("Questionnaire loaded successfully: \(questionnaireData?.questionnaire.title ?? "Unknown")")
        } catch {
            print("Error loading questionnaire: \(error)")
            showMessage("Failed to load questionnaire: \(error.localizedDescription)")
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

    private func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    print("Speech recognition authorized")
                case .denied, .restricted, .notDetermined:
                    self.showMessage("Speech recognition permission is required for transcription")
                @unknown default:
                    break
                }
            }
        }
    }

    private func prepareAndStartRecording() {
        guard !isRecording else { return }

        recordButton.isEnabled = false
        recordButton.alpha = 0.5
        statusLabel.text = "Checking GPS location...\nPlease wait"
        statusLabel.textColor = .systemBlue

        Task { [weak self] in
            do {
                let point = try await TrajectoryTracker.shared.captureRequiredRecordingStartPoint()
                await MainActor.run {
                    guard let self = self else { return }
                    self.recordingStartTrajectoryPoint = point
                    self.recordButton.isEnabled = true
                    self.recordButton.alpha = 1.0
                    self.isRecording = true
                    self.startRecording(with: point)
                }
            } catch {
                await MainActor.run {
                    guard let self = self else { return }
                    self.recordingStartTrajectoryPoint = nil
                    self.isRecording = false
                    self.recordButton.isEnabled = true
                    self.recordButton.alpha = 1.0
                    self.statusLabel.text = "GPS location unavailable"
                    self.statusLabel.textColor = .systemRed
                    self.showMessage("Could not get a current GPS location, so recording was not started. Please make sure Location Services are enabled and try again.")
                }
            }
        }
    }

    private func startRecording(with recordingStartPoint: PendingTrajectoryStore.Point) {
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
            // Create/ensure per-participant session folder and store recording inside it
            let session = try SessionManager.shared.ensureCurrentSession()
            sessionId = session.id
            sessionDirectoryURL = session.directoryURL

            url = try SessionManager.shared.makeRecordingURL()
            recordingURL = url
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
            audioRecorder?.record()
            TrajectoryTracker.shared.startInterviewTracking(with: recordingStartPoint)
            interviewTrajectoryPoints = [recordingStartPoint]

            updateButton(recordButton, title: "Stop Recording", backgroundColor: .systemOrange)
            statusLabel.text = "Recording...\nSpeak into microphone"
            statusLabel.textColor = .systemRed
            dashboardButton?.isEnabled = false
            audioFilesButton?.isEnabled = false
            exportButton.isEnabled = false
            dashboardButton?.alpha = 0.5
            audioFilesButton?.alpha = 0.5
            exportButton.alpha = 0.5
            presentRecordingMonitor()
        } catch {
            showMessage("Recording failed to start: \(error.localizedDescription)")
            isRecording = false
            updateButton(recordButton, title: "Start Interview", backgroundColor: .systemRed)
            dashboardButton?.isEnabled = true
            audioFilesButton?.isEnabled = true
            exportButton.isEnabled = true
            dashboardButton?.alpha = 1.0
            audioFilesButton?.alpha = 1.0
            exportButton.alpha = 1.0
        }
    }

    private func stopRecording(showReview: Bool = false) {
        resetInactivityTimer()
        audioRecorder?.stop()
        interviewTrajectoryPoints = TrajectoryTracker.shared.stopInterviewTracking()
        if let recordingURL {
            updateRecordingTrajectoryMetadata(for: recordingURL, points: interviewTrajectoryPoints)
        }

        updateButton(recordButton, title: "Start Interview", backgroundColor: .systemRed)
        statusLabel.text = "Recording stopped\nYou can play, recognize, or export"
        statusLabel.textColor = .systemGray

        // Enable buttons
        playButton.isEnabled = true
        exportButton.isEnabled = true
        playButton.alpha = 1.0
        exportButton.alpha = 1.0
        dashboardButton?.isEnabled = true
        audioFilesButton?.isEnabled = true
        dashboardButton?.alpha = 1.0
        audioFilesButton?.alpha = 1.0

        recordedData = "Recording data - Timestamp: \(Date().timeIntervalSince1970)"
        let monitorViewController = recordingMonitorViewController
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
                self?.runLLMRecognition()
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
            updateButton(playButton, title: "Play Recording", backgroundColor: .systemPurple)
            statusLabel.text = "Playback stopped"
            statusLabel.textColor = .systemGray
            return false
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            updateButton(playButton, title: "Stop Playback", backgroundColor: .systemRed)
            statusLabel.text = "Playing recording..."
            statusLabel.textColor = .systemPurple
            return true
        } catch {
            showMessage("Playback failed: \(error.localizedDescription)")
            return false
        }
    }

    private func confirmDiscardCurrentRecording(from presenter: UIViewController? = nil) {
        let alert = UIAlertController(
            title: "Discard Recording?",
            message: "This deletes the current audio file and its local recording metadata. This cannot be undone.",
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
        recordedData = nil

        recordingMonitorViewController?.dismiss(animated: true)
        recordingMonitorViewController = nil
        recordingReviewViewController?.dismiss(animated: true)
        recordingReviewViewController = nil

        updateButton(recordButton, title: "Start Interview", backgroundColor: .systemRed)
        updateButton(playButton, title: "Play Recording", backgroundColor: .systemPurple)
        playButton.isEnabled = false
        llmButton.isEnabled = false
        exportButton.isEnabled = true
        playButton.alpha = 0.5
        llmButton.alpha = 0.5
        exportButton.alpha = 1.0
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

    private func writeRecordingMetadata(for recordingURL: URL, recordingStartPoint: PendingTrajectoryStore.Point) {
        let metadataURL = recordingURL.deletingPathExtension().appendingPathExtension("json")
        var metadata: [String: Any] = [
            "recording_file": recordingURL.lastPathComponent,
            "recorded_at_epoch": Date().timeIntervalSince1970,
            "session_id": sessionId ?? "",
            "location": respondentInfo?.location ?? "",
            "recording_start_trajectory_point": trajectoryPointDictionary(recordingStartPoint),
            "trajectory_points": [trajectoryPointDictionary(recordingStartPoint)]
        ]

        if let info = respondentInfo {
            metadata["respondent_info"] = [
                "name": info.name,
                "age": info.age,
                "gender": info.gender,
                "phone": info.phone,
                "location": info.location
            ]
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metadataURL, options: [.atomic])
        } catch {
            print("Failed to write recording metadata: \(error.localizedDescription)")
        }
    }

    private func updateRecordingTrajectoryMetadata(for recordingURL: URL, points: [PendingTrajectoryStore.Point]) {
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

    private func trajectoryPointDictionary(_ point: PendingTrajectoryStore.Point) -> [String: Any] {
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
        let title: String
        let description: String
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

        init(_ point: PendingTrajectoryStore.Point) {
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

        let questionnaire = questionnaireData.map {
            SessionPackageQuestionnaire(
                title: $0.questionnaire.title,
                description: $0.questionnaire.description
            )
        }
        let cloud = cloudSessionId.flatMap { cloudSessionId in
            cloudRespondentId.map {
                SessionPackageCloud(sessionId: cloudSessionId, respondentId: $0)
            }
        }
        let metadata = SessionPackageMetadata(
            schemaVersion: 2,
            exportTime: timestampString,
            timestamp: timestamp,
            localSessionId: sessionId ?? "",
            questionnaireTitle: questionnaireData?.questionnaire.title ?? "Unknown",
            totalResponses: 1,
            questionnaire: questionnaire,
            cloud: cloud
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
            schemaVersion: 2,
            timestamp: timestamp,
            sessionId: sessionId ?? "",
            localSessionId: sessionId ?? "",
            interviewerInfo: InterviewerProfileStore.shared.currentProfile,
            respondentInfo: respondentInfo,
            locationLabel: respondentInfo?.location,
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
            ("title", jsonString(questionnaire.title)),
            ("description", jsonString(questionnaire.description))
        ], indent: indent)
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
            ("name", jsonString(info.name)),
            ("age", jsonNumber(info.age)),
            ("gender", jsonString(info.gender)),
            ("phone", jsonString(info.phone)),
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
        return matched.clarificationNeeded || matched.confidence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "high"
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

        let alert = UIAlertController(
            title: "Clarification Needed \(position + 1) of \(uncertainIndices.count)",
            message: """
            Question:
            \(matched.matchedQuestion)

            LLM answer:
            \(matched.extractedAnswer)

            Confidence: \(matched.confidence)

            Transcript:
            \(snippet)
            """,
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "Custom final answer"
            textField.text = matched.finalAnswer ?? ""
        }
        alert.addTextField { textField in
            textField.placeholder = "Optional clarification note"
        }

        let continueWithUpdate: (String?) -> Void = { [weak self] selectedAnswer in
            guard let self else { return }
            var updatedQuestions = currentMatchedQuestions
            let customAnswer = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = alert.textFields?.dropFirst().first?.text
            let finalAnswer = customAnswer?.isEmpty == false ? customAnswer : selectedAnswer
            updatedQuestions[matchedIndex] = matched.withManualClarification(finalAnswer: finalAnswer, note: note)

            self.showClarificationPrompt(
                transcription: transcription,
                originalMatchedQuestions: originalMatchedQuestions,
                currentMatchedQuestions: updatedQuestions,
                uncertainIndices: uncertainIndices,
                position: position + 1,
                recordingURL: recordingURL
            )
        }

        if question?.type.lowercased() == "yes-no" {
            alert.addAction(UIAlertAction(title: "Yes", style: .default) { _ in continueWithUpdate("Yes") })
            alert.addAction(UIAlertAction(title: "No", style: .default) { _ in continueWithUpdate("No") })
            alert.addAction(UIAlertAction(title: "Not sure", style: .default) { _ in continueWithUpdate("Not sure") })
        }

        alert.addAction(UIAlertAction(title: "Use Custom Text", style: .default) { _ in
            continueWithUpdate(nil)
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

    private func transcriptSnippet(for matched: MatchedQuestion, question: Question?, transcription: String) -> String {
        let normalizedTranscript = transcription.lowercased()
        var phrases = [matched.matchedQuestion]
        if let questionText = question?.question {
            phrases.append(questionText)
        }
        phrases.append(contentsOf: question?.keywords ?? [])

        let candidateTerms = phrases
            .flatMap { phrase in
                phrase
                    .lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 4 }
            }

        if let term = candidateTerms.first(where: { normalizedTranscript.range(of: $0) != nil }),
           let range = normalizedTranscript.range(of: term) {
            let start = transcription.index(range.lowerBound, offsetBy: -120, limitedBy: transcription.startIndex) ?? transcription.startIndex
            let end = transcription.index(range.upperBound, offsetBy: 220, limitedBy: transcription.endIndex) ?? transcription.endIndex
            return String(transcription[start..<end])
        }

        if transcription.count > 500 {
            return String(transcription.prefix(500)) + "..."
        }
        return transcription
    }

    private func finalizeLLMResults(
        transcription: String,
        matchedQuestions: [MatchedQuestion],
        recordingURL: URL?
    ) {
        self.matchedQuestions = matchedQuestions
        displayResults(transcription: transcription, matchedQuestions: matchedQuestions)

        let resultSummary = matchedQuestions.map { matched in
            "Q\(matched.matchedQuestionId): \(matched.finalAnswer ?? matched.extractedAnswer)"
        }.joined(separator: "\n")
        recordedData = "Transcription: \(transcription)\n\nMatched Questions:\n\(resultSummary)"

        statusLabel.text = "Analysis complete!\n\(matchedQuestions.count) question(s) matched"
        statusLabel.textColor = .systemGreen

        llmButton.isEnabled = true
        llmButton.alpha = 1.0
        exportButton.isEnabled = true
        exportButton.alpha = 1.0

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try self.writeSessionPackageJSON(
                    transcription: transcription,
                    matchedQuestions: matchedQuestions,
                    recordingURL: recordingURL
                )
            } catch {
                print("Failed to write local session package: \(error.localizedDescription)")
            }
            await self.uploadSessionPackageToCloud(
                transcription: transcription,
                matchedQuestions: matchedQuestions,
                recordingURL: recordingURL
            )
        }
    }

    // MARK: - Speech Recognition
    private func transcribeAudio(url: URL, completion: @escaping (String?) -> Void) {
        resetInactivityTimer()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            completion(nil)
            return
        }

        if !recognizer.isAvailable {
            completion(nil)
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        recognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                print("Speech recognition error: \(error)")
                completion(nil)
                return
            }

            if let result = result, result.isFinal {
                completion(result.bestTranscription.formattedString)
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

        // Show results in alert
        let alert = UIAlertController(title: "Analysis Results", message: resultText, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.updateButton(self.playButton, title: "Play Recording", backgroundColor: .systemPurple)
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
        // Stop any active recording/playback while keeping the saved recording in its session folder.
        if isRecording {
            isRecording = false
            audioRecorder?.stop()
            interviewTrajectoryPoints = TrajectoryTracker.shared.stopInterviewTracking()
            if let recordingURL {
                updateRecordingTrajectoryMetadata(for: recordingURL, points: interviewTrajectoryPoints)
            }
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
        cloudRespondentId = nil
        cloudSessionId = nil
        TrajectoryTracker.shared.setCurrentIdentity(respondentId: nil, sessionId: nil)
        recordedData = nil
        recordingURL = nil
        recordingStartTrajectoryPoint = nil
        interviewTrajectoryPoints = []

        // Reset UI state
        updateButton(recordButton, title: "Start Interview", backgroundColor: .systemRed)
        playButton.isEnabled = false
        exportButton.isEnabled = true
        playButton.alpha = 0.5
        exportButton.alpha = 1.0
        llmButton.isEnabled = false
        llmButton.alpha = 0.5
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
        let exportsRoot = documentsURL.appendingPathComponent("SurveyExports", isDirectory: true)

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

        if fileManager.fileExists(atPath: exportsRoot.path) {
            let exportFiles = (try? fileManager.contentsOfDirectory(
                at: exportsRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for fileURL in exportFiles where fileURL.pathExtension.lowercased() == "json" {
                appendIfValid(fileURL, fallbackKey: "export:\(fileURL.lastPathComponent)")
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

    private func ensureExportsDirectory() throws -> URL {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exportsURL = documentsURL.appendingPathComponent("SurveyExports", isDirectory: true)

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

    @objc private func questionnaireButtonTapped() {
        let questionnaireVC = QuestionnaireViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        questionnaireVC.modalPresentationStyle = .fullScreen

        let navController = UINavigationController(rootViewController: questionnaireVC)
        present(navController, animated: true)
    }

    private func checkAPIKeyStatus() {
        let currentProvider = LLMService.shared.currentProvider
        if !LLMService.shared.hasAPIKey() {
            let providerName = currentProvider == .openai ? "OpenAI" : "Gemini"
            statusLabel.text = "⚠️ Please configure \(providerName) API key in Settings"
            statusLabel.textColor = .systemOrange
        }
    }

    private func showAPIKeySettings() {
        let interviewer = InterviewerProfileStore.shared.currentProfile
        let alert = UIAlertController(
            title: "App Settings",
            message: "Current LLM: \(LLMService.shared.currentProvider.displayName)\nCurrent interviewer: \(interviewer?.name ?? "Not set")",
            preferredStyle: .alert
        )

        // Add API provider selection
        alert.addAction(UIAlertAction(title: "Select API Provider", style: .default) { [weak self] _ in
            self?.showAPIProviderSelection()
        })

        // Add OpenAI API key configuration
        alert.addAction(UIAlertAction(title: "Configure OpenAI API Key", style: .default) { [weak self] _ in
            self?.showAPIKeyInput(for: .openai)
        })

        // Add Gemini API key configuration
        alert.addAction(UIAlertAction(title: "Configure Gemini API Key", style: .default) { [weak self] _ in
            self?.showAPIKeyInput(for: .gemini)
        })

        // Add custom LLM base URL configuration
        alert.addAction(UIAlertAction(title: "Configure Custom LLM Base URL", style: .default) { [weak self] _ in
            self?.showCustomLLMBaseURLInput()
        })

        // Survey API configuration (Cloud SQL persistence)
        alert.addAction(UIAlertAction(title: "Configure Survey API Base URL", style: .default) { [weak self] _ in
            self?.showSurveyAPIBaseURLInput()
        })
        alert.addAction(UIAlertAction(title: "Configure Survey API Key", style: .default) { [weak self] _ in
            self?.showSurveyAPIKeyInput()
        })

        alert.addAction(UIAlertAction(title: "Configure Interviewer", style: .default) { [weak self] _ in
            self?.showInterviewerProfileInput()
        })
        if InterviewerProfileStore.shared.profiles.count > 1 {
            alert.addAction(UIAlertAction(title: "Select Saved Interviewer", style: .default) { [weak self] _ in
                self?.showSavedInterviewerSelection()
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

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
            showMessage("No saved interviewers")
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

    // MARK: - Survey API (Cloud SQL) Upload Flow

    private func appVersionString() -> String? {
        let dict = Bundle.main.infoDictionary
        let short = dict?["CFBundleShortVersionString"] as? String
        let build = dict?["CFBundleVersion"] as? String
        if let short, let build { return "\(short) (\(build))" }
        return short ?? build
    }

    private func ensureCloudSessionCreated() async {
        guard SurveyAPIClient.shared.isConfigured() else { return }
        if cloudSessionId != nil { return }

        do {
            let resp = try await SurveyAPIClient.shared.createSession(
                questionnaireVersion: "1",
                appVersion: appVersionString(),
                locale: Locale.current.identifier
            )
            cloudRespondentId = resp.respondentId
            cloudSessionId = resp.sessionId
            TrajectoryTracker.shared.setCurrentIdentity(respondentId: resp.respondentId, sessionId: resp.sessionId)
        } catch {
            // Best-effort: don't block the survey; the local session package remains available on device.
            print("Survey API createSession failed: \(error.localizedDescription)")
        }
    }

    private func uploadSessionPackageToCloud(transcription: String, matchedQuestions: [MatchedQuestion], recordingURL: URL?) async {
        guard SurveyAPIClient.shared.isConfigured() else { return }

        if cloudSessionId == nil {
            await ensureCloudSessionCreated()
        }
        guard let sid = cloudSessionId else { return }

        do {
            let packageURL = try writeSessionPackageJSON(
                transcription: transcription,
                matchedQuestions: matchedQuestions,
                recordingURL: recordingURL
            )
            let response = try await SurveyAPIClient.shared.uploadSessionPackage(
                sessionId: sid,
                sessionJSONURL: packageURL,
                audioURL: recordingURL,
                localSessionId: sessionId
            )
            if let recordingURL {
                markSessionPackageUploaded(for: recordingURL, response: response)
            }
            print("Survey API session package upload succeeded: \(response.packageDir)")
        } catch {
            print("Survey API session package upload failed: \(error.localizedDescription)")
        }
    }

    private func uploadRecordingStartTrajectoryIfNeeded(sessionId: String, recordingURL: URL?) async {
        guard let recordingURL else { return }
        guard !isRecordingStartTrajectoryUploadMarked(for: recordingURL) else { return }
        guard let point = recordingStartTrajectoryPoint(for: recordingURL, cloudSessionId: sessionId) else { return }

        do {
            try await TrajectoryTracker.shared.uploadRecordingStartPoint(point)
            markRecordingStartTrajectoryUploaded(for: recordingURL)
        } catch {
            print("Recording-start trajectory upload failed; point remains in recording metadata for retry: \(error.localizedDescription)")
        }
    }

    private func uploadAudioToCloudIfNeeded(sessionId: String, recordingURL: URL?) async {
        guard let recordingURL else { return }
        guard FileManager.default.fileExists(atPath: recordingURL.path) else { return }
        if isAudioUploadMarked(for: recordingURL) { return }

        do {
            let response = try await SurveyAPIClient.shared.uploadAudio(
                sessionId: sessionId,
                fileURL: recordingURL,
                recordedAtMs: recordedAtMs(for: recordingURL),
                localSessionId: sessionIdForRecording(recordingURL)
            )
            markAudioUploaded(for: recordingURL, response: response)
            print("Survey API audio upload succeeded: \(response.storagePath)")
        } catch {
            print("Survey API audio upload failed: \(error.localizedDescription)")
        }
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
    ) -> PendingTrajectoryStore.Point? {
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

        let point = PendingTrajectoryStore.Point(
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
    ) -> [PendingTrajectoryStore.Point] {
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
    ) -> PendingTrajectoryStore.Point? {
        guard let tsMs = int64Value(raw["ts_ms"]),
              let lat = doubleValue(raw["lat"]),
              let lon = doubleValue(raw["lon"]) else {
            return nil
        }

        return PendingTrajectoryStore.Point(
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
        _ point: PendingTrajectoryStore.Point,
        _ cloudSessionId: String
    ) -> PendingTrajectoryStore.Point {
        return PendingTrajectoryStore.Point(
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

    private func isAudioUploadMarked(for recordingURL: URL) -> Bool {
        return recordingMetadata(for: recordingURL)?["audio_uploaded_at_epoch"] != nil
    }

    private func isRecordingStartTrajectoryUploadMarked(for recordingURL: URL) -> Bool {
        return recordingMetadata(for: recordingURL)?["recording_start_trajectory_uploaded_at_epoch"] != nil
    }

    private func markAudioUploaded(for recordingURL: URL, response: SurveyAPIClient.AudioUploadResponse) {
        let metadataURL = recordingMetadataURL(for: recordingURL)
        var metadata = recordingMetadata(for: recordingURL) ?? [:]
        metadata["audio_uploaded_at_epoch"] = Date().timeIntervalSince1970
        metadata["audio_upload_id"] = response.id
        metadata["audio_server_storage_path"] = response.storagePath
        metadata["audio_server_sha256"] = response.sha256
        metadata["audio_server_file_size_bytes"] = response.fileSizeBytes

        do {
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metadataURL, options: [.atomic])
        } catch {
            print("Failed to mark audio as uploaded: \(error.localizedDescription)")
        }
    }

    private func markSessionPackageUploaded(
        for recordingURL: URL,
        response: SurveyAPIClient.SessionPackageUploadResponse
    ) {
        let metadataURL = recordingMetadataURL(for: recordingURL)
        var metadata = recordingMetadata(for: recordingURL) ?? [:]
        metadata["session_package_uploaded_at_epoch"] = Date().timeIntervalSince1970
        metadata["server_package_dir"] = response.packageDir
        metadata["server_session_json_path"] = response.jsonPath
        metadata["server_session_json_sha256"] = response.jsonSha256
        if let audioPath = response.audioPath {
            metadata["server_audio_path"] = audioPath
        }
        if let audioSha256 = response.audioSha256 {
            metadata["server_audio_sha256"] = audioSha256
        }
        if let audioFileSizeBytes = response.audioFileSizeBytes {
            metadata["server_audio_file_size_bytes"] = audioFileSizeBytes
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metadataURL, options: [.atomic])
        } catch {
            print("Failed to mark session package as uploaded: \(error.localizedDescription)")
        }
    }

    private func markRecordingStartTrajectoryUploaded(for recordingURL: URL) {
        let metadataURL = recordingMetadataURL(for: recordingURL)
        var metadata = recordingMetadata(for: recordingURL) ?? [:]
        metadata["recording_start_trajectory_uploaded_at_epoch"] = Date().timeIntervalSince1970

        do {
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metadataURL, options: [.atomic])
        } catch {
            print("Failed to mark recording-start trajectory as uploaded: \(error.localizedDescription)")
        }
    }

    private func flushPendingSurveyUploads() async {
        // Legacy answer-row retries are disabled for new package-based storage.
        // New interviews upload `session.json` plus audio through /sessions/{id}/package.
    }

    // MARK: - Respondent Info Form
    private func showRespondentInfoForm(completion: @escaping (RespondentInfo) -> Void) {
        let infoVC = RespondentInfoViewController()
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
                    locationVC.questionnaireData = self.questionnaireData
                    locationVC.exportsDirectory = try? self.ensureExportsDirectory()

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

private final class RecordingMonitorViewController: UIViewController, UIScrollViewDelegate {
    var questions: [Question] = []
    var levelProvider: (() -> Float)?
    var onStopReview: (() -> Void)?
    var onDiscard: (() -> Void)?

    private let waveformView = RecordingWaveformView()
    private let timerLabel = UILabel()
    private let qualityLabel = UILabel()
    private let scrollView = UIScrollView()
    private let pageControl = UIPageControl()
    private var startedAt = Date()
    private var timer: Timer?
    private var recentLevels: [Float] = []

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

    private func buildUI() {
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Recording Interview"
        titleLabel.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center

        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        timerLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        timerLabel.textAlignment = .center
        timerLabel.text = "00:00"

        qualityLabel.translatesAutoresizingMaskIntoConstraints = false
        qualityLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        qualityLabel.textAlignment = .center
        qualityLabel.textColor = .systemOrange
        qualityLabel.text = "Listening for voice..."

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        let monitorPage = makeMonitorPage()
        let tipsPage = makeTipsPage()
        contentView.addSubview(monitorPage)
        contentView.addSubview(tipsPage)

        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.numberOfPages = 2
        pageControl.currentPage = 0

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

        view.addSubview(titleLabel)
        view.addSubview(timerLabel)
        view.addSubview(qualityLabel)
        view.addSubview(scrollView)
        view.addSubview(pageControl)
        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            timerLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            timerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            timerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            qualityLabel.topAnchor.constraint(equalTo: timerLabel.bottomAnchor, constant: 8),
            qualityLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            qualityLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            scrollView.topAnchor.constraint(equalTo: qualityLabel.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: pageControl.topAnchor, constant: -8),

            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            monitorPage.topAnchor.constraint(equalTo: contentView.topAnchor),
            monitorPage.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            monitorPage.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            monitorPage.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            tipsPage.topAnchor.constraint(equalTo: contentView.topAnchor),
            tipsPage.leadingAnchor.constraint(equalTo: monitorPage.trailingAnchor),
            tipsPage.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tipsPage.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            tipsPage.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            pageControl.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),
            pageControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),

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

        let caption = UILabel()
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.text = "The bars should move while the respondent speaks. If they stay flat, move closer or check the microphone."
        caption.font = UIFont.systemFont(ofSize: 16)
        caption.textColor = .secondaryLabel
        caption.textAlignment = .center
        caption.numberOfLines = 0

        let questionsBox = makeQuestionsBox()

        page.addSubview(waveformView)
        page.addSubview(caption)
        page.addSubview(questionsBox)

        NSLayoutConstraint.activate([
            waveformView.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            waveformView.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 24),
            waveformView.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -24),
            waveformView.heightAnchor.constraint(equalToConstant: 96),

            caption.topAnchor.constraint(equalTo: waveformView.bottomAnchor, constant: 10),
            caption.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 32),
            caption.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -32),

            questionsBox.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 14),
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

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Survey Questions"
        title.font = UIFont.systemFont(ofSize: 23, weight: .bold)
        title.textColor = .label

        let questionScrollView = UIScrollView()
        questionScrollView.translatesAutoresizingMaskIntoConstraints = false
        questionScrollView.isPagingEnabled = true
        questionScrollView.showsHorizontalScrollIndicator = false
        questionScrollView.alwaysBounceHorizontal = true

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .fill
        stack.distribution = .fill
        var questionCards: [UIView] = []

        if questions.isEmpty {
            let card = makeQuestionCard(
                items: [QuestionCardItem(
                    title: "Questionnaire not loaded",
                    detail: "Check that questionnaire.json is bundled with the app.",
                    answerType: "Unavailable"
                )]
            )
            stack.addArrangedSubview(card)
            questionCards.append(card)
        } else {
            for startIndex in stride(from: 0, to: questions.count, by: 2) {
                let slideQuestions = questions[startIndex..<min(startIndex + 2, questions.count)]
                let items = slideQuestions.enumerated().map { offset, question in
                    QuestionCardItem(
                        title: "\(startIndex + offset + 1) of \(questions.count): \(question.question)",
                        detail: question.followUp.map { "Follow-up: \($0)" },
                        answerType: answerTypeLabel(for: question)
                    )
                }
                let card = makeQuestionCard(items: items)
                stack.addArrangedSubview(card)
                questionCards.append(card)
            }
        }

        let hintLabel = UILabel()
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.text = "Swipe left or right for more questions"
        hintLabel.font = UIFont.systemFont(ofSize: 15)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center

        container.addSubview(title)
        container.addSubview(questionScrollView)
        container.addSubview(hintLabel)
        questionScrollView.addSubview(stack)

        var constraints: [NSLayoutConstraint] = [
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            questionScrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            questionScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            questionScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            questionScrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -8),

            hintLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

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
        let title: String
        let detail: String?
        let answerType: String
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
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])

        return card
    }

    private func makeQuestionBlock(_ item: QuestionCardItem) -> UIView {
        let block = UIView()
        block.translatesAutoresizingMaskIntoConstraints = false

        let answerBadge = UILabel()
        answerBadge.translatesAutoresizingMaskIntoConstraints = false
        answerBadge.text = item.answerType
        answerBadge.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        answerBadge.textColor = .white
        answerBadge.backgroundColor = .systemBlue
        answerBadge.textAlignment = .center
        answerBadge.layer.cornerRadius = 6
        answerBadge.clipsToBounds = true

        let questionLabel = UILabel()
        questionLabel.translatesAutoresizingMaskIntoConstraints = false
        questionLabel.text = item.title
        questionLabel.font = UIFont.systemFont(ofSize: 27, weight: .semibold)
        questionLabel.textColor = .label
        questionLabel.numberOfLines = 0
        questionLabel.adjustsFontSizeToFitWidth = true
        questionLabel.minimumScaleFactor = 0.75

        let detailLabel = UILabel()
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.text = item.detail ?? "Expected answer: \(item.answerType)"
        detailLabel.font = UIFont.systemFont(ofSize: 18)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        block.addSubview(answerBadge)
        block.addSubview(questionLabel)
        block.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            answerBadge.topAnchor.constraint(equalTo: block.topAnchor),
            answerBadge.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            answerBadge.heightAnchor.constraint(equalToConstant: 34),
            answerBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

            questionLabel.topAnchor.constraint(equalTo: answerBadge.bottomAnchor, constant: 8),
            questionLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            questionLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor),

            detailLabel.topAnchor.constraint(equalTo: questionLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: block.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: block.bottomAnchor)
        ])

        return block
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

    private func makeTipsPage() -> UIView {
        let page = UIView()
        page.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = """
        Quick field check

        Keep the iPad microphone pointed toward the respondent.
        Watch for moving bars during answers.
        Use Discard Recording for accidental or unnecessary interviews.
        Stop & Review before analyzing answers.
        """
        label.font = UIFont.systemFont(ofSize: 21, weight: .medium)
        label.textColor = .label
        label.numberOfLines = 0
        label.textAlignment = .left

        page.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: page.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 36),
            label.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36)
        ])

        return page
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

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let page = Int(round(scrollView.contentOffset.x / max(1, scrollView.bounds.width)))
        pageControl.currentPage = page
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
