import UIKit

class LocationAggregationViewController: UIViewController {
    
    // MARK: - Properties
    var locationData: [String: [ExportedSurvey]] = [:]
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
        var allQuestionKeys = Set<String>()
        var statistics: [String: [String: Int]] = [:]
        var answerDisplayNames: [String: [String: String]] = [:]
        var questionTexts: [String: String] = [:]
        var questionIds: [String: Int] = [:]
        var questionnaireNames: [String: String] = [:]
        
        // Process responses
        for survey in surveys {
            let questionnaireKey = aggregationQuestionnaireKey(for: survey)
            questionnaireNames[questionnaireKey] = aggregationQuestionnaireName(for: survey)
            let expectedQuestionKeys = expectedAggregationQuestionKeys(
                for: survey,
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

            var currentResponseQuestionKeys: Set<String> = []
            
            for item in survey.matchedQuestions {
                let questionKey = aggregationQuestionKey(
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
                
                statistics[questionKey, default: [:]][answerType, default: 0] += 1
                
                if answerDisplayNames[questionKey] == nil {
                    answerDisplayNames[questionKey] = [:]
                }
                
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
            
            // Mark unanswered questions
            for questionKey in expectedQuestionKeys {
                if !currentResponseQuestionKeys.contains(questionKey) {
                    statistics[questionKey, default: [:]]["unanswered", default: 0] += 1
                }
            }
        }
        
        // Generate summary
        var summary = "Location: \(location)\n"
        summary += "Total Surveys: \(surveys.count)\n\n"
        
        let sortedQuestionKeys = sortedAggregationQuestionKeys(
            Array(allQuestionKeys),
            questionIds: questionIds,
            questionnaireNames: questionnaireNames
        )
        var currentQuestionnaireName: String?
        for questionKey in sortedQuestionKeys {
            let questionnaireName = questionnaireNames[questionnaireKey(from: questionKey)] ?? "Unknown Questionnaire"
            if questionnaireName != currentQuestionnaireName {
                summary += "Questionnaire: \(questionnaireName)\n"
                currentQuestionnaireName = questionnaireName
            }
            let questionId = questionIds[questionKey] ?? 0
            let questionTitle = questionTexts[questionKey] ?? "Question \(questionId)"
            summary += "Question \(questionId): \(questionTitle)\n"
            
            let answerCounts = statistics[questionKey] ?? [:]
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
                let displayText = answerDisplayNames[questionKey]?[answerKey] ?? answerKey
                summary += "  - \(displayText): \(count)\n"
            }
            
            summary += "\n"
        }
        
        return AggregationResult(
            summary: summary,
            statistics: statistics,
            answerDisplayNames: answerDisplayNames,
            questionTexts: questionTexts,
            questionIds: questionIds,
            questionnaireNames: questionnaireNames,
            processedFiles: surveys.count
        )
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
                "questionnaire_titles": Array(Set(result.questionnaireNames.values)).sorted()
            ],
            "aggregation_summary": result.summary,
            "statistics": [:],
            "raw_data": surveys.map { survey in
                var surveyDict: [String: Any] = [
                    "matched_questions": survey.matchedQuestions.map { item in
                        [
                            "matched_question_id": item.matchedQuestionId,
                            "matched_question": item.matchedQuestion,
                            "extracted_answer": item.extractedAnswer ?? "",
                            "selected_option_codes": item.selectedOptionCodes ?? [],
                            "selected_option_labels": item.selectedOptionLabels ?? []
                        ]
                    }
                ]
                
                if let respondentInfo = survey.respondentInfo {
                    surveyDict["respondent_info"] = [
                        "name": respondentInfo.name ?? "",
                        "age": respondentInfo.age ?? 0,
                        "age_range": respondentInfo.ageRange ?? "",
                        "gender": respondentInfo.gender ?? "",
                        "race": respondentInfo.race ?? "",
                        "phone": respondentInfo.phone ?? "",
                        "location": respondentInfo.location ?? ""
                    ]
                }
                
                return surveyDict
            }
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
            showAlert(message: "JSON conversion failed")
            return
        }
        
        // Save to file
        let sanitizedLocation = location.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
        let fileName = "location_\(sanitizedLocation)_\(Date().timeIntervalSince1970).json"
        let fileURL = exportsDirectory.appendingPathComponent(fileName)
        
        do {
            try jsonDataEncoded.write(to: fileURL, options: [.atomic])
            
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
    let statistics: [String: [String: Int]]
    let answerDisplayNames: [String: [String: String]]
    let questionTexts: [String: String]
    let questionIds: [String: Int]
    let questionnaireNames: [String: String]
    let processedFiles: Int
}
