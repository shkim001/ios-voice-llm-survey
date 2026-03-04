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
    private var clearButton: UIButton?  // Created programmatically
    
    // Recording state
    private var isRecording = false
    private var recordedData: String?
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingURL: URL?
    
    // Questionnaire and analysis
    private var questionnaireData: QuestionnaireData?
    private var transcription: String?
    private var matchedQuestions: [MatchedQuestion] = []
    private var respondentInfo: RespondentInfo?
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        loadQuestionnaire()
        requestSpeechPermission()
        setupUI()
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
        
        // Add constraints for clear button - positioned below aggregate button
        NSLayoutConstraint.activate([
            clearBtn.topAnchor.constraint(equalTo: aggregateButton.bottomAnchor, constant: 16),
            clearBtn.leadingAnchor.constraint(equalTo: aggregateButton.leadingAnchor),
            clearBtn.trailingAnchor.constraint(equalTo: aggregateButton.trailingAnchor),
            clearBtn.heightAnchor.constraint(equalToConstant: 50)
        ])
        
        // Initial state: play, LLM and export buttons disabled
        playButton.isEnabled = false
        llmButton.isEnabled = false
        exportButton.isEnabled = false
        playButton.alpha = 0.5
        llmButton.alpha = 0.5
        exportButton.alpha = 0.5
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
        // If not recording, show info form first
        if !isRecording {
            // Clear previous respondent info when starting new recording
            respondentInfo = nil
            transcription = nil
            matchedQuestions = []
            
            // Disable LLM and export buttons until new analysis is done
            llmButton.isEnabled = true  // Can start LLM analysis after recording
            exportButton.isEnabled = false
            llmButton.alpha = 1.0
            exportButton.alpha = 0.5
            
            showRespondentInfoForm { [weak self] info in
                self?.respondentInfo = info
                // Start recording after info is submitted
                self?.isRecording = true
                self?.startRecording()
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
        guard let transcription = transcription, !matchedQuestions.isEmpty else {
            showMessage("No analysis data to export")
            return
        }
        
        guard let respondentInfo = respondentInfo else {
            showMessage("Missing respondent information")
            return
        }
        
        // Create comprehensive JSON data
        let timestamp = Date().timeIntervalSince1970
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestampString = dateFormatter.string(from: Date())
        
        var exportData: [String: Any] = [
            "export_info": [
                "export_time": timestampString,
                "total_responses": 1,
                "questionnaire_title": questionnaireData?.questionnaire.title ?? "Unknown"
            ],
            "timestamp": timestamp,
            "respondent_info": [
                "name": respondentInfo.name,
                "age": respondentInfo.age,
                "gender": respondentInfo.gender,
                "phone": respondentInfo.phone,
                "location": respondentInfo.location
            ],
            "transcription": transcription,
            "matched_questions": matchedQuestions.map { matched in
                [
                    "matched_question_id": matched.matchedQuestionId,
                    "matched_question": matched.matchedQuestion,
                    "extracted_answer": matched.extractedAnswer,
                    "confidence": matched.confidence,
                    "clarification_needed": matched.clarificationNeeded
                ]
            }
        ]
        
        // Add questionnaire if available
        if let questionnaire = questionnaireData {
            exportData["questionnaire"] = [
                "title": questionnaire.questionnaire.title,
                "description": questionnaire.questionnaire.description
            ]
        }
        
        // Convert to JSON data
        guard let jsonData = try? JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted) else {
            showMessage("JSON conversion failed")
            return
        }
        
        // Save to app-specific directory
        let fileName = "survey_results_\(Date().timeIntervalSince1970).json"
        
        guard let exportsDirectory = try? ensureExportsDirectory() else {
            statusLabel.text = "Failed to create directory"
            statusLabel.textColor = .systemRed
            showMessage("Unable to create or access the export directory")
            animateButton(sender)
            return
        }
        
        let fileURL = exportsDirectory.appendingPathComponent(fileName)
        
        do {
            try jsonData.write(to: fileURL)
            
            // Show export success
            statusLabel.text = "JSON exported successfully!\nSaved to App Folder"
            statusLabel.textColor = .systemGreen
            
            // Show success message with file location
            let alert = UIAlertController(
                title: "Export Successful",
                message: "File saved to:\n\(fileName)\n\nLocation: App Folder/SurveyExports\n\nYou can access it via Files app or iTunes File Sharing.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "View JSON", style: .default) { _ in
                // Show JSON content in a scrollable view
                self.showJSONContent(String(data: jsonData, encoding: .utf8) ?? "")
            })
            alert.addAction(UIAlertAction(title: "Share", style: .default) { _ in
                // Show share sheet
                self.shareFile(url: fileURL)
            })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(alert, animated: true)
            
            // Also print file path for debugging
            print("File saved to: \(fileURL.path)")
            
        } catch {
            statusLabel.text = "Export failed"
            statusLabel.textColor = .systemRed
            showMessage("Failed to save file: \(error.localizedDescription)")
        }
        
        animateButton(sender)
    }
    
    @IBAction func aggregateButtonTapped(_ sender: UIButton) {
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
    
    private func startRecording() {
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default)
            try audioSession.setActive(true)
        } catch {
            showMessage("Audio session setup failed: \(error.localizedDescription)")
            return
        }
        
        let fileName = "recording_\(Date().timeIntervalSince1970).m4a"
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documentsPath.appendingPathComponent(fileName)
        recordingURL = url
        
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
        } catch {
            showMessage("Recording failed to start: \(error.localizedDescription)")
        }
    }
    
    private func stopRecording() {
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
        
        recordedData = "Recording data - Timestamp: \(Date().timeIntervalSince1970)"
    }
    
    // MARK: - Speech Recognition
    private func transcribeAudio(url: URL, completion: @escaping (String?) -> Void) {
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


