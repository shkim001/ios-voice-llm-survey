import Foundation

enum APIProvider: String, CaseIterable {
    case openai = "OpenAI"
    case gemini = "Gemini"
    
    var displayName: String {
        switch self {
        case .openai:
            return "OpenAI"
        case .gemini:
            return "Gemini"
        }
    }
}

class LLMService {
    static let shared = LLMService()
    
  //  private let openaiBaseURL = "https://api.openai.com/v1"
    private let openaiBaseURLDefault = "https://api.openai.com/v1"
    private let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta"
    
    /// When set (e.g. "http://YOUR_VM_IP:8000"), OpenAI requests use this base URL instead of api.openai.com (for GCP self-hosted LLM).
    private let customLLMBaseURLKey = "LLM_Custom_Base_URL"
       
    private var openaiBaseURL: String {
           let custom = UserDefaults.standard.string(forKey: customLLMBaseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
           if let url = custom, !url.isEmpty { return url }
           return openaiBaseURLDefault
    }
    
    private let apiProviderUserDefaultsKey = "LLM_API_Provider"
    private let openaiAPIKeyUserDefaultsKey = "OpenAI_API_Key"
    private let geminiAPIKeyUserDefaultsKey = "Gemini_API_Key"
    
    private init() {}
    
    // Get current API provider
    var currentProvider: APIProvider {
        if let providerString = UserDefaults.standard.string(forKey: apiProviderUserDefaultsKey),
           let provider = APIProvider(rawValue: providerString) {
            return provider
        }
        return .openai // Default to OpenAI
    }
    
    // Set API provider
    func setAPIProvider(_ provider: APIProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: apiProviderUserDefaultsKey)
    }
    
    // Get API key from UserDefaults based on current provider
    private var apiKey: String {
        switch currentProvider {
        case .openai:
            return UserDefaults.standard.string(forKey: openaiAPIKeyUserDefaultsKey) ?? ""
        case .gemini:
            return UserDefaults.standard.string(forKey: geminiAPIKeyUserDefaultsKey) ?? ""
        }
    }
    
    // Method to set API key for specific provider
    func setAPIKey(_ key: String, for provider: APIProvider) {
        switch provider {
        case .openai:
            UserDefaults.standard.set(key, forKey: openaiAPIKeyUserDefaultsKey)
        case .gemini:
            UserDefaults.standard.set(key, forKey: geminiAPIKeyUserDefaultsKey)
        }
    }
    
    // Get API key for specific provider
    func getAPIKey(for provider: APIProvider) -> String {
        switch provider {
        case .openai:
            return UserDefaults.standard.string(forKey: openaiAPIKeyUserDefaultsKey) ?? ""
        case .gemini:
            return UserDefaults.standard.string(forKey: geminiAPIKeyUserDefaultsKey) ?? ""
        }
    }
    
    // Method to check if API key is configured for current provider
    func hasAPIKey() -> Bool {
        return !apiKey.isEmpty
    }
    
    // Method to check if API key is configured for specific provider
    func hasAPIKey(for provider: APIProvider) -> Bool {
        return !getAPIKey(for: provider).isEmpty
    }
    
    /// Custom base URL for OpenAI-style endpoint (e.g. GCP VM). When set, use "OpenAI" provider and any non-empty API key (e.g. "gcp").
    func getCustomLLMBaseURL() -> String {
        return UserDefaults.standard.string(forKey: customLLMBaseURLKey) ?? ""
    }
        
    func setCustomLLMBaseURL(_ url: String?) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: customLLMBaseURLKey)
    }
    
    func generateSystemPrompt(questions: [Question]) -> String {
        var questionsText = ""
        for q in questions {
            questionsText += "\nQuestion \(q.id): \(q.question)\n"
            questionsText += "Type: \(q.type)\n"
            if let followUp = q.followUp {
                questionsText += "Follow-up: \(followUp)\n"
            }
            if q.type.lowercased() == "multiple-choice" {
                let selectionMode = q.allowsMultiple ? "Choose one or more options." : "Choose exactly one option."
                questionsText += "Selection rule: \(selectionMode)\n"
                if !q.options.isEmpty {
                    questionsText += "Options:\n"
                    for option in q.options {
                        questionsText += "- \(option.code.uppercased()). \(option.text)\n"
                    }
                }
            }
            questionsText += "Related keywords: \(q.keywords.joined(separator: ", "))\n"
            questionsText += "\n"
        }
        
        return """
        You are an intelligent assistant that analyzes spoken responses about location/street assessments and maps them to survey questions.

        Your goal is to:
        1. Read the provided audio transcription from the user.
        2. Determine which survey question(s) the response corresponds to.
        3. Extract a clear, concise answer for each question that can be inferred from the response.
        4. Estimate the confidence level of your extraction.
        5. Output the result in a structured JSON format.

        Survey Questions:
        \(questionsText)

        ---

        ### Instructions
        - This is a **Location/Street Assessment Survey** focusing on facilities, safety, and impressions.
        - You may detect **multiple questions** answered within a single spoken response.
        - Each detected question should be represented as one JSON object in the output list.
        - Look for keywords related to: seating, trees, landscaping, shelter, water fountains, restrooms, transit, trash, buildings, signage, lighting, speed limits, safety, accessibility.
        - For yes/no questions, extract the clear answer (yes/no/not sure).
        - For impression questions, capture the user's assessment (safe/unsafe, appealing/unappealing, etc.).
        - For multiple-choice questions, select only from the listed option codes.
        - For multiple-choice questions with multiple selections allowed, return all selected option codes in the order the user gave them.
        - For multiple-choice questions, use both the spoken option codes/numbers and the option labels to interpret the response. For example, if option 1 is "Shade", then "1", "number one", "one", "first", and "shade" can all refer to option 1.
        - If the user gives an option code that is not listed, or if the chosen option is ambiguous, set `"clarification_needed": true` and `"confidence": "low"`.
        - If a question cannot be confidently matched, set `"clarification_needed": true` and `"confidence": "low"`.
        - Be concise, factual, and neutral in tone.
        - Avoid paraphrasing or adding opinions.
        - Always output **valid JSON only** (no markdown code blocks, no extra commentary).

        ---

        ### Output Format
        Return a single JSON array, where each element has the following structure:

        [
          {
            "matched_question_id": <question_id>,
            "matched_question": "<the question text>",
            "extracted_answer": "<user's extracted answer>",
            "selected_option_codes": ["1", "3"],
            "selected_option_labels": ["Option label for 1", "Option label for 3"],
            "confidence": "<high/medium/low>",
            "clarification_needed": <true/false>
          },
          ...
        ]

        Example Output (for location assessment responses):
        [
          {
            "matched_question_id": 1,
            "matched_question": "Are there places to sit?",
            "extracted_answer": "Yes, there are benches and seating areas",
            "confidence": "high",
            "clarification_needed": false
          },
          {
            "matched_question_id": 2,
            "matched_question": "Are there shade trees?",
            "extracted_answer": "Yes, I can see several trees providing shade",
            "confidence": "high",
            "clarification_needed": false
          }
        ]
        """
    }
    
    func analyzeTranscription(_ transcription: String, questions: [Question]) async throws -> [MatchedQuestion] {
        // Check if API key is set
        guard !apiKey.isEmpty else {
            let providerName = currentProvider == .openai ? "OpenAI" : "Gemini"
            let apiKeyURL = currentProvider == .openai ? "https://platform.openai.com/api-keys" : "https://makersuite.google.com/app/apikey"
            throw NSError(
                domain: "LLMService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "\(providerName) API key not configured. Please set your API key in Settings.\n\nGet your API key from: \(apiKeyURL)"]
            )
        }
        
        // Call appropriate API based on current provider
        switch currentProvider {
        case .openai:
            let matches = try await analyzeWithOpenAI(transcription: transcription, questions: questions)
            return validateMultipleChoiceAnswers(matches, questions: questions)
        case .gemini:
            let matches = try await analyzeWithGemini(transcription: transcription, questions: questions)
            return validateMultipleChoiceAnswers(matches, questions: questions)
        }
    }

    private func validateMultipleChoiceAnswers(_ matches: [MatchedQuestion], questions: [Question]) -> [MatchedQuestion] {
        let questionsById = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0) })

        return matches.map { match in
            guard let question = questionsById[match.matchedQuestionId],
                  question.type.lowercased() == "multiple-choice",
                  !question.options.isEmpty else {
                return match
            }

            let validCodes = Set(question.options.map { $0.code.uppercased() })
            let rawSelectedCodes = match.selectedOptionCodes ?? []
            let sourceCodes = rawSelectedCodes.isEmpty ? codesFromAnswer(match.extractedAnswer, validCodes: validCodes) : rawSelectedCodes
            let selectedCodes = sourceCodes
                .flatMap {
                    let parsedCodes = codesFromAnswer($0, validCodes: validCodes)
                    return parsedCodes.isEmpty ? [$0] : parsedCodes
                }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .filter { !$0.isEmpty }
            let uniqueCodes = Array(NSOrderedSet(array: selectedCodes)).compactMap { $0 as? String }
            let invalidCodes = uniqueCodes.filter { !validCodes.contains($0) }
            let hasTooMany = !question.allowsMultiple && uniqueCodes.count > 1
            let needsClarification = match.clarificationNeeded || uniqueCodes.isEmpty || !invalidCodes.isEmpty || hasTooMany
            let confidence = needsClarification ? "low" : match.confidence
            let labels = uniqueCodes.compactMap { code in
                question.options.first { $0.code.uppercased() == code }?.text
            }
            let extractedAnswer = uniqueCodes.isEmpty ? match.extractedAnswer : uniqueCodes.joined(separator: ", ")

            return MatchedQuestion(
                matchedQuestionId: match.matchedQuestionId,
                matchedQuestion: match.matchedQuestion,
                extractedAnswer: extractedAnswer,
                selectedOptionCodes: uniqueCodes.isEmpty ? match.selectedOptionCodes : uniqueCodes,
                selectedOptionLabels: labels.isEmpty ? match.selectedOptionLabels : labels,
                confidence: confidence,
                clarificationNeeded: needsClarification,
                finalAnswer: match.finalAnswer,
                manuallyClarified: match.manuallyClarified,
                clarificationNote: match.clarificationNote,
                answerSource: match.answerSource
            )
        }
    }

    private func codesFromAnswer(_ answer: String, validCodes: Set<String>) -> [String] {
        let aliasToCode = optionCodeAliases(for: validCodes)
        let alternatives = aliasToCode.keys
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs < rhs }
                return lhs.count > rhs.count
            }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        guard !alternatives.isEmpty else {
            return []
        }
        let pattern = "(?<![A-Za-z0-9])(?:\(alternatives))(?![A-Za-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(answer.startIndex..<answer.endIndex, in: answer)
        return regex.matches(in: answer, options: [], range: range).compactMap { match in
            guard let codeRange = Range(match.range, in: answer) else { return nil }
            let matchedText = String(answer[codeRange]).uppercased()
            return aliasToCode[matchedText]
        }
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
    
    // MARK: - OpenAI Implementation
    private func analyzeWithOpenAI(transcription: String, questions: [Question]) async throws -> [MatchedQuestion] {
        let systemPrompt = generateSystemPrompt(questions: questions)
        let userMessage = "User's spoken response: \(transcription)\n\nPlease analyze and match this response. Output only valid JSON array."
        
        // OpenAI API endpoint
        let url = URL(string: "\(openaiBaseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Local LLMs (e.g., Ollama on a VM) can take longer than OpenAI’s typical latency.
        // Must be >= FastAPI's `requests.post(..., timeout=...)` to Ollama or iOS fails first.
        request.timeoutInterval = 180.0
        
        // OpenAI API request body
        let requestBody: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": userMessage
                ]
            ],
            "temperature": 0.3
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "LLMService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
            }
            
            print("OpenAI API Response Status: \(httpResponse.statusCode)")
            
            guard httpResponse.statusCode == 200 else {
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = errorJson["error"] as? [String: Any],
                   let errorMessage = error["message"] as? String {
                    throw NSError(
                        domain: "LLMService",
                        code: httpResponse.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "OpenAI API Error: \(errorMessage)"]
                    )
                }
                throw NSError(
                    domain: "LLMService",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "OpenAI API returned HTTP \(httpResponse.statusCode)."]
                )
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw NSError(
                    domain: "LLMService",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to parse OpenAI response"]
                )
            }
            
            return try parseJSONResponse(content: content)
            
        } catch let error as NSError {
            throw error
        } catch {
            throw NSError(
                domain: "LLMService",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Network error: \(error.localizedDescription)"]
            )
        }
    }
    
    // MARK: - Gemini Implementation
    private func analyzeWithGemini(transcription: String, questions: [Question]) async throws -> [MatchedQuestion] {
        let systemPrompt = generateSystemPrompt(questions: questions)
        let userMessage = "User's spoken response: \(transcription)\n\nPlease analyze and match this response. Output only valid JSON array."
        
        // Gemini API endpoint - using gemini-2.0-flash-exp model
        let apiKey = self.apiKey
        let url = URL(string: "\(geminiBaseURL)/models/gemini-2.0-flash-exp:generateContent?key=\(apiKey)")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120.0
        
        // Gemini API request body
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "text": "\(systemPrompt)\n\n\(userMessage)"
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.3,
                "topK": 40,
                "topP": 0.95,
                "maxOutputTokens": 2048
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "LLMService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
            }
            
            print("Gemini API Response Status: \(httpResponse.statusCode)")
            
            guard httpResponse.statusCode == 200 else {
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = errorJson["error"] as? [String: Any],
                   let errorMessage = error["message"] as? String {
                    throw NSError(
                        domain: "LLMService",
                        code: httpResponse.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Gemini API Error: \(errorMessage)"]
                    )
                }
                throw NSError(
                    domain: "LLMService",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Gemini API returned HTTP \(httpResponse.statusCode)."]
                )
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let text = firstPart["text"] as? String else {
                throw NSError(
                    domain: "LLMService",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to parse Gemini response"]
                )
            }
            
            return try parseJSONResponse(content: text)
            
        } catch let error as NSError {
            throw error
        } catch {
            throw NSError(
                domain: "LLMService",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Network error: \(error.localizedDescription)"]
            )
        }
    }
    
    // MARK: - JSON Response Parsing
    private func parseJSONResponse(content: String) throws -> [MatchedQuestion] {
        // Extract JSON from response
        var jsonString = content
        // Remove markdown code blocks if present
        jsonString = jsonString.replacingOccurrences(of: "```json", with: "")
        jsonString = jsonString.replacingOccurrences(of: "```", with: "")
        jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Try to extract JSON array from the response
        if let startIndex = jsonString.firstIndex(of: "["),
           let endIndex = jsonString.lastIndex(of: "]") {
            jsonString = String(jsonString[startIndex...endIndex])
        }
        
        // Try parsing as direct JSON array
        if let jsonData = jsonString.data(using: .utf8) {
            do {
                // First try: Parse as array directly
                if let array = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                    let decoder = JSONDecoder()
                    let arrayData = try JSONSerialization.data(withJSONObject: array)
                    return try decoder.decode([MatchedQuestion].self, from: arrayData)
                }
                
                // Second try: Parse as object with "results" key
                if let jsonObject = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let results = jsonObject["results"] as? [[String: Any]] {
                    let decoder = JSONDecoder()
                    let resultsData = try JSONSerialization.data(withJSONObject: results)
                    return try decoder.decode([MatchedQuestion].self, from: resultsData)
                }
                
                // Third try: Parse as object with "data" key
                if let jsonObject = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let data = jsonObject["data"] as? [[String: Any]] {
                    let decoder = JSONDecoder()
                    let dataData = try JSONSerialization.data(withJSONObject: data)
                    return try decoder.decode([MatchedQuestion].self, from: dataData)
                }
            } catch {
                print("JSON parsing error: \(error)")
            }
        }
        
        throw NSError(
            domain: "LLMService",
            code: -4,
            userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON array from response.\n\nRaw content preview: \(content.prefix(500))\n\nPlease ensure the AI returns a valid JSON array format."]
        )
    }
}
