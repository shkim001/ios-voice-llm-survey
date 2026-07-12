import UIKit

class LocationAggregationViewController: UIViewController {
    
    // MARK: - Properties
    var locationData: [String: [ExportedSurvey]] = [:]
    var questionnaireData: QuestionnaireData?
    var exportsDirectory: URL?
    
    // MARK: - UI Elements
    private let tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        return tableView
    }()
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    // MARK: - UI Setup
    private func setupUI() {
        view.backgroundColor = .systemBackground
        title = "Grouped by Location"
        
        // Add close button
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeButtonTapped)
        )
        
        // Setup table view
        view.addSubview(tableView)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "LocationCell")
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    // MARK: - Actions
    @objc private func closeButtonTapped() {
        dismiss(animated: true)
    }
    
    // MARK: - Aggregation Helpers
    private func aggregateForLocation(_ location: String, surveys: [ExportedSurvey]) -> AggregationResult {
        // Get all question IDs
        let allQuestionIds: Set<Int>
        if let questions = questionnaireData?.questionnaire.questions {
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
        
        if let questions = questionnaireData?.questionnaire.questions {
            for question in questions {
                questionTexts[question.id] = question.question
            }
        }
        
        // Process responses
        for survey in surveys {
            var currentResponseQuestionIds: Set<Int> = []
            
            for item in survey.matchedQuestions {
                currentResponseQuestionIds.insert(item.matchedQuestionId)
                
                let preferredAnswer = item.finalAnswer ?? item.extractedAnswer
                guard let answer = preferredAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
                    continue
                }
                
                // Classify answer type
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
                    answerType = normalizedAnswer
                }
                
                statistics[item.matchedQuestionId, default: [:]][answerType, default: 0] += 1
                
                if answerDisplayNames[item.matchedQuestionId] == nil {
                    answerDisplayNames[item.matchedQuestionId] = [:]
                }
                
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
            
            // Mark unanswered questions
            for questionId in allQuestionIds {
                if !currentResponseQuestionIds.contains(questionId) {
                    statistics[questionId, default: [:]]["unanswered", default: 0] += 1
                }
            }
        }
        
        // Generate summary
        var summary = "Location: \(location)\n"
        summary += "Total Surveys: \(surveys.count)\n\n"
        
        let sortedQuestionIds = allQuestionIds.sorted()
        for questionId in sortedQuestionIds {
            let questionTitle = questionTexts[questionId] ?? "Question \(questionId)"
            summary += "Question \(questionId): \(questionTitle)\n"
            
            let answerCounts = statistics[questionId] ?? [:]
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
            
            let otherAnswers = answerCounts.filter { $0.key != "yes" && $0.key != "no" && $0.key != "unanswered" }
            for (answerKey, count) in otherAnswers.sorted(by: { $0.value > $1.value }) {
                let displayText = answerDisplayNames[questionId]?[answerKey] ?? answerKey
                summary += "  - \(displayText): \(count)\n"
            }
            
            summary += "\n"
        }
        
        return AggregationResult(
            summary: summary,
            statistics: statistics,
            answerDisplayNames: answerDisplayNames,
            questionTexts: questionTexts,
            processedFiles: surveys.count
        )
    }
    
    private func exportLocationData(_ location: String, surveys: [ExportedSurvey], result: AggregationResult) {
        guard let exportsDirectory = exportsDirectory else {
            showAlert(message: "Unable to access export directory")
            return
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestampString = dateFormatter.string(from: Date())
        
        // Build JSON data structure
        var jsonData: [String: Any] = [
            "export_info": [
                "export_time": timestampString,
                "location": location,
                "total_responses": surveys.count,
                "questionnaire_title": questionnaireData?.questionnaire.title ?? "Unknown"
            ],
            "aggregation_summary": result.summary,
            "statistics": [:],
            "raw_data": surveys.map { survey in
                var surveyDict: [String: Any] = [
                    "matched_questions": survey.matchedQuestions.map { item in
                        [
                            "matched_question_id": item.matchedQuestionId,
                            "matched_question": item.matchedQuestion,
                            "extracted_answer": item.extractedAnswer ?? ""
                        ]
                    }
                ]
                
                if let respondentInfo = survey.respondentInfo {
                    surveyDict["respondent_info"] = [
                        "name": respondentInfo.name ?? "",
                        "age": respondentInfo.age ?? 0,
                        "gender": respondentInfo.gender ?? "",
                        "phone": respondentInfo.phone ?? "",
                        "location": respondentInfo.location ?? ""
                    ]
                }
                
                return surveyDict
            }
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
            showAlert(message: "JSON conversion failed")
            return
        }
        
        // Save to file
        let sanitizedLocation = location.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
        let fileName = "location_\(sanitizedLocation)_\(Date().timeIntervalSince1970).json"
        let fileURL = exportsDirectory.appendingPathComponent(fileName)
        
        do {
            try jsonDataEncoded.write(to: fileURL)
            
            // Show share sheet
            let activityViewController = UIActivityViewController(
                activityItems: [fileURL],
                applicationActivities: nil
            )
            
            if let popover = activityViewController.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            }
            
            present(activityViewController, animated: true)
        } catch {
            showAlert(message: "Failed to save file: \(error.localizedDescription)")
        }
    }
    
    private func showAlert(message: String) {
        let alert = UIAlertController(title: "Alert", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDataSource
extension LocationAggregationViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return locationData.keys.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "LocationCell", for: indexPath)
        let locations = Array(locationData.keys.sorted())
        let location = locations[indexPath.row]
        let count = locationData[location]?.count ?? 0
        
        cell.textLabel?.text = location
        cell.detailTextLabel?.text = "\(count) survey(s)"
        cell.accessoryType = .disclosureIndicator
        
        return cell
    }
}

// MARK: - UITableViewDelegate
extension LocationAggregationViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let locations = Array(locationData.keys.sorted())
        let location = locations[indexPath.row]
        guard let surveys = locationData[location] else { return }
        
        // Show action sheet
        let alert = UIAlertController(
            title: location,
            message: "Total: \(surveys.count) survey(s)",
            preferredStyle: .actionSheet
        )
        
        alert.addAction(UIAlertAction(title: "View Statistics", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let result = self.aggregateForLocation(location, surveys: surveys)
            self.showScrollableContent(title: "\(location) - Statistics", content: result.summary)
        })
        
        alert.addAction(UIAlertAction(title: "Export JSON", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let result = self.aggregateForLocation(location, surveys: surveys)
            self.exportLocationData(location, surveys: surveys, result: result)
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            if let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            }
        }
        
        present(alert, animated: true)
    }
    
    private func showScrollableContent(title: String, content: String) {
        let viewController = AggregationTextViewController(title: title, content: content)
        viewController.modalPresentationStyle = .formSheet
        present(viewController, animated: true)
    }
}

// MARK: - AggregationResult
private struct AggregationResult {
    let summary: String
    let statistics: [Int: [String: Int]]
    let answerDisplayNames: [Int: [String: String]]
    let questionTexts: [Int: String]
    let processedFiles: Int
}
