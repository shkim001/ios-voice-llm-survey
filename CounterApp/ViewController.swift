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
    private var audioFilesButton: UIButton?
    private var clearButton: UIButton?  // Created programmatically

    // Recording state
    private var isRecording = false
    private var recordedData: String?
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingURL: URL?
    private var recordingStartTrajectoryPoint: PendingTrajectoryStore.Point?

    // Per-participant session (local-only separation)
    private var sessionId: String?
    private var sessionDirectoryURL: URL?

    // Cloud (Survey API / Cloud SQL) session
    private var cloudRespondentId: String?
    private var cloudSessionId: String?

    // Inactivity auto-reset
    private var inactivityTimer: Timer?
    private let inactivityTimeoutSeconds: TimeInterval = 180

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
        setupButton(recordButton, title: "Start Recording", backgroundColor: .systemRed)

        // Setup play button
        setupButton(playButton, title: "Play Recording", backgroundColor: .systemPurple)

        // Setup LLM button
        setupButton(llmButton, title: "LLM Recognition", backgroundColor: .systemBlue)

        // Setup export button
        setupButton(exportButton, title: "Export JSON", backgroundColor: .systemGreen)

        // Setup aggregate button
        setupButton(aggregateButton, title: "Aggregate Results", backgroundColor: .systemTeal)

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
        clearBtn.setTitle("Clear JSON Files", for: .normal)
        clearBtn.backgroundColor = .systemOrange
        clearBtn.setTitleColor(.white, for: .normal)
        clearBtn.layer.cornerRadius = 12
        clearBtn.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        clearBtn.addTarget(self, action: #selector(clearButtonTapped(_:)), for: .touchUpInside)
        view.addSubview(clearBtn)
        self.clearButton = clearBtn

        // Add constraints for programmatic buttons positioned below aggregate button
        NSLayoutConstraint.activate([
            audioBtn.topAnchor.constraint(equalTo: aggregateButton.bottomAnchor, constant: 16),
            audioBtn.leadingAnchor.constraint(equalTo: aggregateButton.leadingAnchor),
            audioBtn.trailingAnchor.constraint(equalTo: aggregateButton.trailingAnchor),
            audioBtn.heightAnchor.constraint(equalToConstant: 50),

            clearBtn.topAnchor.constraint(equalTo: audioBtn.bottomAnchor, constant: 16),
            clearBtn.leadingAnchor.constraint(equalTo: aggregateButton.leadingAnchor),
            clearBtn.trailingAnchor.constraint(equalTo: aggregateButton.trailingAnchor),
            clearBtn.heightAnchor.constraint(equalToConstant: 50)
        ])

        // Initial state: play, LLM and export buttons disabled
        playButton.isEnabled = false
        llmButton.isEnabled = false
        exportButton.isEnabled = false
        audioBtn.isEnabled = true
        playButton.alpha = 0.5
        llmButton.alpha = 0.5
        exportButton.alpha = 0.5
        audioBtn.alpha = 1.0
    }

    private func setupButton(_ button: UIButton, title: String, backgroundColor: UIColor) {
        button.setTitle(title, for: .normal)
        button.backgroundColor = backgroundColor
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
    }

    // MARK: - Button Actions
    @IBAction func recordButtonTapped(_ sender: UIButton) {
        resetInactivityTimer()
        // If not recording, show info form first
        if !isRecording {
            // Clear previous state when starting a new recording (same participant/session unless "Start next participant" was used)
            transcription = nil
            matchedQuestions = []

            // Disable LLM and export buttons until new analysis is done
            llmButton.isEnabled = true  // Can start LLM analysis after recording
            exportButton.isEnabled = false
            llmButton.alpha = 1.0
            exportButton.alpha = 0.5

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
        stopRecording()
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

            playButton.setTitle("Play Recording", for: .normal)
            playButton.backgroundColor = .systemPurple
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

                playButton.setTitle("Stop Playback", for: .normal)
                playButton.backgroundColor = .systemRed

            } catch {
                showMessage("Playback failed: \(error.localizedDescription)")
            }
        }

        animateButton(sender)
    }

    @IBAction func llmButtonTapped(_ sender: UIButton) {
        resetInactivityTimer()
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

                    DispatchQueue.main.async {
                        self.matchedQuestions = matchedQuestions
                        self.displayResults(transcription: transcription, matchedQuestions: matchedQuestions)

                        // Update recorded data
                        let resultSummary = matchedQuestions.map { "Q\($0.matchedQuestionId): \($0.extractedAnswer)" }.joined(separator: "\n")
                        self.recordedData = "Transcription: \(transcription)\n\nMatched Questions:\n\(resultSummary)"

                        self.statusLabel.text = "Analysis complete!\n\(matchedQuestions.count) question(s) matched"
                        self.statusLabel.textColor = .systemGreen

                        self.llmButton.isEnabled = true
                        self.llmButton.alpha = 1.0
                    }

                    // Best-effort: upload one complete session package to the Survey API.
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

        animateButton(sender)
    }

    @IBAction func exportButtonTapped(_ sender: UIButton) {
        resetInactivityTimer()
        guard let transcription = transcription, !matchedQuestions.isEmpty else {
            showMessage("No analysis data to export")
            return
        }

        guard let respondentInfo = respondentInfo else {
            showMessage("Missing respondent information")
            return
        }

        let exportData = makeSessionPackageJSON(
            transcription: transcription,
            matchedQuestions: matchedQuestions,
            recordingURL: recordingURL
        )

        // Convert to JSON data
        guard let jsonData = try? JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted) else {
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
            animateButton(sender)
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
            alert.addAction(UIAlertAction(title: "Start next participant", style: .default) { [weak self] _ in
                self?.startNextParticipant()
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

        animateButton(sender)
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

        // Option 3: Export JSON
        alert.addAction(UIAlertAction(title: "Export JSON", style: .default) { [weak self] _ in
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

    // Perform aggregation operation
    private func performAggregation(action: AggregationAction) {
        statusLabel.text = "Aggregating historical responses..."
        statusLabel.textColor = .systemBlue
        aggregateButton.isEnabled = false
        aggregateButton.alpha = 0.5

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let exportsDirectory = try self.ensureExportsDirectory()
                let fileManager = FileManager.default
                let fileURLs = try fileManager.contentsOfDirectory(at: exportsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { $0.pathExtension.lowercased() == "json" }

                if fileURLs.isEmpty {
                    DispatchQueue.main.async {
                        self.statusLabel.text = "No historical data available for aggregation"
                        self.statusLabel.textColor = .systemOrange
                        self.showMessage("No export files available for aggregation")
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

                let decoder = JSONDecoder()
                var processedFiles = 0
                var allResponseQuestionIds: Set<Int> = []

                // First pass: collect all question IDs that appear in responses
                for fileURL in fileURLs {
                    do {
                        let data = try Data(contentsOf: fileURL)
                        let exportEntry = try decoder.decode(ExportedSurvey.self, from: data)

                        for item in exportEntry.matchedQuestions {
                            allResponseQuestionIds.insert(item.matchedQuestionId)
                        }
                    } catch {
                        print("Failed to process file \(fileURL.lastPathComponent): \(error)")
                    }
                }

                // Second pass: process responses in each file
                for fileURL in fileURLs {
                    do {
                        let data = try Data(contentsOf: fileURL)
                        let exportEntry = try decoder.decode(ExportedSurvey.self, from: data)
                        processedFiles += 1

                        // Track question IDs that appear in this response
                        var currentResponseQuestionIds: Set<Int> = []

                        for item in exportEntry.matchedQuestions {
                            currentResponseQuestionIds.insert(item.matchedQuestionId)

                            guard let answer = item.extractedAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
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

                    } catch {
                        print("Failed to process file \(fileURL.lastPathComponent): \(error)")
                    }
                }

                if processedFiles == 0 {
                    DispatchQueue.main.async {
                        self.statusLabel.text = "No valid response data found"
                        self.statusLabel.textColor = .systemOrange
                        self.showMessage("No valid responses found in any export files")
                        self.aggregateButton.isEnabled = true
                        self.aggregateButton.alpha = 1.0
                    }
                    return
                }

                var summary = "Analyzed \(processedFiles) export file(s).\n\n"
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
            recordButton.setTitle("Start Recording", for: .normal)
            recordButton.backgroundColor = .systemRed
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
            recordButton.setTitle("Start Recording", for: .normal)
            recordButton.backgroundColor = .systemRed
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
            audioRecorder?.record()

            recordButton.setTitle("Stop Recording", for: .normal)
            recordButton.backgroundColor = .systemOrange
            statusLabel.text = "Recording...\nSpeak into microphone"
            statusLabel.textColor = .systemRed
            audioFilesButton?.isEnabled = false
            audioFilesButton?.alpha = 0.5
        } catch {
            showMessage("Recording failed to start: \(error.localizedDescription)")
            isRecording = false
            recordButton.setTitle("Start Recording", for: .normal)
            recordButton.backgroundColor = .systemRed
            audioFilesButton?.isEnabled = true
            audioFilesButton?.alpha = 1.0
        }
    }

    private func stopRecording() {
        resetInactivityTimer()
        audioRecorder?.stop()

        recordButton.setTitle("Start Recording", for: .normal)
        recordButton.backgroundColor = .systemRed
        statusLabel.text = "Recording stopped\nYou can play, recognize, or export"
        statusLabel.textColor = .systemGray

        // Enable buttons
        playButton.isEnabled = true
        llmButton.isEnabled = true
        exportButton.isEnabled = true
        playButton.alpha = 1.0
        llmButton.alpha = 1.0
        exportButton.alpha = 1.0
        audioFilesButton?.isEnabled = true
        audioFilesButton?.alpha = 1.0

        recordedData = "Recording data - Timestamp: \(Date().timeIntervalSince1970)"
    }

    private func writeRecordingMetadata(for recordingURL: URL, recordingStartPoint: PendingTrajectoryStore.Point) {
        let metadataURL = recordingURL.deletingPathExtension().appendingPathExtension("json")
        var metadata: [String: Any] = [
            "recording_file": recordingURL.lastPathComponent,
            "recorded_at_epoch": Date().timeIntervalSince1970,
            "session_id": sessionId ?? "",
            "location": respondentInfo?.location ?? "",
            "recording_start_trajectory_point": trajectoryPointDictionary(recordingStartPoint)
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

    private func trajectoryPointDictionary(_ point: PendingTrajectoryStore.Point) -> [String: Any] {
        var dict: [String: Any] = [
            "ts_ms": point.tsMs,
            "lat": point.lat,
            "lon": point.lon
        ]
        if let accuracyM = point.accuracyM { dict["accuracy_m"] = accuracyM }
        if let speedMps = point.speedMps { dict["speed_mps"] = speedMps }
        if let courseDeg = point.courseDeg { dict["course_deg"] = courseDeg }
        if let provider = point.provider { dict["provider"] = provider }
        if let isBackground = point.isBackground { dict["is_background"] = isBackground }
        if let sessionId = point.sessionId, !sessionId.isEmpty { dict["session_id"] = sessionId }
        return dict
    }

    private func makeSessionPackageJSON(
        transcription: String,
        matchedQuestions: [MatchedQuestion],
        recordingURL: URL?
    ) -> [String: Any] {
        let timestamp = Date().timeIntervalSince1970
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestampString = dateFormatter.string(from: Date())

        var metadata: [String: Any] = [
            "schema_version": 2,
            "export_time": timestampString,
            "timestamp": timestamp,
            "local_session_id": sessionId ?? "",
            "questionnaire_title": questionnaireData?.questionnaire.title ?? "Unknown",
            "total_responses": 1
        ]

        if let questionnaire = questionnaireData {
            metadata["questionnaire"] = [
                "title": questionnaire.questionnaire.title,
                "description": questionnaire.questionnaire.description
            ]
        }

        if let cloudSessionId, let cloudRespondentId {
            metadata["cloud"] = [
                "session_id": cloudSessionId,
                "respondent_id": cloudRespondentId
            ]
        }

        var exportData: [String: Any] = [
            "metadata": metadata,
            // Kept at top level for existing aggregation/server indexing code.
            "schema_version": 2,
            "timestamp": timestamp,
            "session_id": sessionId ?? "",
            "local_session_id": sessionId ?? ""
        ]

        if let respondentInfo {
            exportData["respondent_info"] = [
                "name": respondentInfo.name,
                "age": respondentInfo.age,
                "gender": respondentInfo.gender,
                "phone": respondentInfo.phone,
                "location": respondentInfo.location
            ]
            exportData["location_label"] = respondentInfo.location
        }

        if let recordingURL {
            var audio: [String: Any] = [
                "file_name": recordingURL.lastPathComponent
            ]
            if let localSessionId = sessionIdForRecording(recordingURL) {
                audio["local_session_id"] = localSessionId
            }
            if let recordedAtMs = recordedAtMs(for: recordingURL) {
                audio["recorded_at_ms"] = recordedAtMs
            }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: recordingURL.path),
               let size = attributes[.size] as? NSNumber {
                audio["file_size_bytes"] = size.intValue
            }
            exportData["audio"] = audio

            if let point = recordingStartTrajectoryPoint(
                for: recordingURL,
                cloudSessionId: cloudSessionId ?? ""
            ) {
                exportData["recording_start_trajectory_point"] = trajectoryPointDictionary(point)
            }

            if let sidecar = recordingMetadata(for: recordingURL) {
                exportData["recording_metadata"] = sidecar
            }
        }

        exportData["transcription"] = transcription
        exportData["matched_questions"] = matchedQuestions.map { matched in
            [
                "matched_question_id": matched.matchedQuestionId,
                "matched_question": matched.matchedQuestion,
                "extracted_answer": matched.extractedAnswer,
                "confidence": matched.confidence,
                "clarification_needed": matched.clarificationNeeded
            ]
        }

        return exportData
    }

    private func writeSessionPackageJSON(
        transcription: String,
        matchedQuestions: [MatchedQuestion],
        recordingURL: URL?
    ) throws -> URL {
        let session = try SessionManager.shared.ensureCurrentSession()
        sessionId = session.id
        sessionDirectoryURL = session.directoryURL

        let package = makeSessionPackageJSON(
            transcription: transcription,
            matchedQuestions: matchedQuestions,
            recordingURL: recordingURL
        )
        let jsonData = try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted])
        let url = session.directoryURL.appendingPathComponent("session.json")
        try jsonData.write(to: url, options: [.atomic])
        return url
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
            resultText += "Confidence: \(matched.confidence)\n"
            if matched.clarificationNeeded {
                resultText += "⚠️ Clarification needed\n"
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
            self.playButton.setTitle("Play Recording", for: .normal)
            self.playButton.backgroundColor = .systemPurple
            self.statusLabel.text = "Playback complete"
            self.statusLabel.textColor = .systemGray
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
        SessionManager.shared.purgeOldSessions(keepLast: 50, maxAgeDays: 7)

        do {
            let session = try SessionManager.shared.startNewSession()
            sessionId = session.id
            sessionDirectoryURL = session.directoryURL
        } catch {
            sessionId = nil
            sessionDirectoryURL = nil
        }
    }

    private func startNextParticipant() {
        // Stop any active recording/playback while keeping the saved recording in its session folder.
        if isRecording {
            isRecording = false
            audioRecorder?.stop()
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

        // Reset UI state
        recordButton.setTitle("Start Recording", for: .normal)
        recordButton.backgroundColor = .systemRed
        playButton.isEnabled = false
        exportButton.isEnabled = false
        playButton.alpha = 0.5
        exportButton.alpha = 0.5
        llmButton.isEnabled = false
        llmButton.alpha = 0.5
        audioFilesButton?.isEnabled = true
        audioFilesButton?.alpha = 1.0

        statusLabel.text = "Ready for next participant"
        statusLabel.textColor = .systemGray

        // Start a fresh session
        do {
            let session = try SessionManager.shared.startNewSession()
            sessionId = session.id
            sessionDirectoryURL = session.directoryURL
        } catch {
            sessionId = nil
            sessionDirectoryURL = nil
        }

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
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)

        let textView = UITextView()
        textView.text = content
        textView.font = UIFont.systemFont(ofSize: 12)
        textView.isEditable = false
        textView.backgroundColor = .systemBackground
        textView.translatesAutoresizingMaskIntoConstraints = false

        alert.view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: alert.view.topAnchor, constant: 60),
            textView.leadingAnchor.constraint(equalTo: alert.view.leadingAnchor, constant: 15),
            textView.trailingAnchor.constraint(equalTo: alert.view.trailingAnchor, constant: -15),
            textView.bottomAnchor.constraint(equalTo: alert.view.bottomAnchor, constant: -60),
            textView.heightAnchor.constraint(equalToConstant: 300)
        ])

        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
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
        let alert = UIAlertController(
            title: "LLM API Settings",
            message: "Select API provider and configure API Key\n\nCurrent selection: \(LLMService.shared.currentProvider.displayName)",
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
                let exportsDirectory = try self.ensureExportsDirectory()
                let fileManager = FileManager.default
                let fileURLs = try fileManager.contentsOfDirectory(at: exportsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { $0.pathExtension.lowercased() == "json" }

                if fileURLs.isEmpty {
                    DispatchQueue.main.async {
                        self.statusLabel.text = "No historical data available"
                        self.statusLabel.textColor = .systemOrange
                        self.showMessage("No export files available for aggregation")
                        self.aggregateButton.isEnabled = true
                        self.aggregateButton.alpha = 1.0
                    }
                    return
                }

                // Group files by location
                let decoder = JSONDecoder()
                var locationData: [String: [ExportedSurvey]] = [:]

                for fileURL in fileURLs {
                    do {
                        let data = try Data(contentsOf: fileURL)
                        let exportEntry = try decoder.decode(ExportedSurvey.self, from: data)
                        let location = exportEntry.respondentInfo?.location ?? "Unknown Location"
                        locationData[location, default: []].append(exportEntry)
                    } catch {
                        print("Failed to process file \(fileURL.lastPathComponent): \(error)")
                    }
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
