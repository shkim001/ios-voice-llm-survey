import Foundation

// MARK: - Questionnaire Models
struct QuestionnaireData: Codable {
    let questionnaire: Questionnaire
}

struct Questionnaire: Codable {
    let id: String?
    let version: String?
    let title: String
    let description: String
    let status: String?
    let hash: String?
    let questions: [Question]

    enum CodingKeys: String, CodingKey {
        case id
        case version
        case title
        case description
        case status
        case hash
        case questions
    }
}

struct Question: Codable {
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

    init(
        id: Int,
        question: String,
        type: String,
        followUp: String?,
        keywords: [String],
        options: [QuestionOption] = [],
        allowsMultiple: Bool = false
    ) {
        self.id = id
        self.question = question
        self.type = type
        self.followUp = followUp
        self.keywords = keywords
        self.options = options
        self.allowsMultiple = allowsMultiple
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let numericId = try? container.decode(Int.self, forKey: .id) {
            id = numericId
        } else {
            let stringId = try container.decode(String.self, forKey: .id)
            guard let numericId = Int(stringId) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .id,
                    in: container,
                    debugDescription: "Question id must be numeric for the iOS app."
                )
            }
            id = numericId
        }
        question = try container.decode(String.self, forKey: .question)
        type = try container.decode(String.self, forKey: .type)
        followUp = try container.decodeIfPresent(String.self, forKey: .followUp)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        options = try container.decodeIfPresent([QuestionOption].self, forKey: .options) ?? []
        allowsMultiple = try container.decodeIfPresent(Bool.self, forKey: .allowsMultiple) ?? false
    }
}

struct QuestionOption: Codable {
    let code: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case code
        case text
    }

    init(code: String, text: String) {
        self.code = code
        self.text = text
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            code = try container.decode(String.self, forKey: .code)
            text = try container.decode(String.self, forKey: .text)
        } else {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            code = value
            text = value
        }
    }
}

struct QuestionnaireListResponse: Codable {
    let questionnaires: [Questionnaire]
    let count: Int
}

final class QuestionnaireStore {
    static let shared = QuestionnaireStore()

    private enum DefaultsKeys {
        static let cachedQuestionnaires = "SurveyAPI_Cached_Questionnaires"
        static let selectedQuestionnaireId = "SurveyAPI_Selected_Questionnaire_ID"
        static let selectedQuestionnaireVersion = "SurveyAPI_Selected_Questionnaire_Version"
    }

    private init() {}

    func loadBundledQuestionnaire() throws -> QuestionnaireData {
        guard let url = Bundle.main.url(forResource: "questionnaire", withExtension: "json") else {
            throw NSError(
                domain: "QuestionnaireStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "questionnaire.json not found in app bundle"]
            )
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(QuestionnaireData.self, from: data)
    }

    func cachedQuestionnaires() -> [Questionnaire] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKeys.cachedQuestionnaires),
              let decoded = try? JSONDecoder().decode([Questionnaire].self, from: data) else {
            return []
        }
        return decoded
    }

    func saveCachedQuestionnaires(_ questionnaires: [Questionnaire]) {
        guard let data = try? JSONEncoder().encode(questionnaires) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKeys.cachedQuestionnaires)
    }

    func selectedQuestionnaire(from available: [Questionnaire], fallback: Questionnaire) -> Questionnaire {
        let selectedId = UserDefaults.standard.string(forKey: DefaultsKeys.selectedQuestionnaireId)
        let selectedVersion = UserDefaults.standard.string(forKey: DefaultsKeys.selectedQuestionnaireVersion)
        if let selected = available.first(where: { $0.id == selectedId && $0.version == selectedVersion }) {
            return selected
        }
        return available.first ?? fallback
    }

    func saveSelectedQuestionnaire(_ questionnaire: Questionnaire) {
        UserDefaults.standard.set(questionnaire.id, forKey: DefaultsKeys.selectedQuestionnaireId)
        UserDefaults.standard.set(questionnaire.version, forKey: DefaultsKeys.selectedQuestionnaireVersion)
    }
}

// MARK: - Respondent Information Models
struct RespondentInfo: Codable {
    let isAnonymous: Bool
    let name: String?
    let age: Int?
    let ageRange: String?
    let gender: String
    let race: String?
    let email: String?
    let location: String

    enum CodingKeys: String, CodingKey {
        case isAnonymous = "is_anonymous"
        case name
        case age
        case ageRange = "age_range"
        case gender
        case race
        case email
        case location
    }

    init(
        isAnonymous: Bool,
        name: String?,
        age: Int?,
        ageRange: String?,
        gender: String,
        race: String?,
        email: String?,
        location: String
    ) {
        self.isAnonymous = isAnonymous
        self.name = name
        self.age = age
        self.ageRange = ageRange
        self.gender = gender
        self.race = race
        self.email = email
        self.location = location
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAnonymous = try container.decodeIfPresent(Bool.self, forKey: .isAnonymous) ?? false
        name = try container.decodeIfPresent(String.self, forKey: .name)
        age = try container.decodeIfPresent(Int.self, forKey: .age)
        ageRange = try container.decodeIfPresent(String.self, forKey: .ageRange)
            ?? age.flatMap(Self.standardAgeRangeLabel(for:))
        gender = try container.decodeIfPresent(String.self, forKey: .gender) ?? "Unknown"
        race = try container.decodeIfPresent(String.self, forKey: .race)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? "Unknown Location"
    }

    private static func standardAgeRangeLabel(for age: Int) -> String? {
        switch age {
        case ..<18:
            return "Under 18"
        case 18...24:
            return "18-24"
        case 25...34:
            return "25-34"
        case 35...44:
            return "35-44"
        case 45...54:
            return "45-54"
        case 55...64:
            return "55-64"
        default:
            return "65+"
        }
    }
}

// MARK: - Exported Survey Models
struct ExportedSurvey: Decodable {
    let matchedQuestions: [ExportedMatchedQuestion]
    let respondentInfo: ExportedRespondentInfo?
    let metadata: ExportedSurveyMetadata?
    let localSessionId: String?
    
    enum CodingKeys: String, CodingKey {
        case matchedQuestions = "matched_questions"
        case respondentInfo = "respondent_info"
        case metadata
        case localSessionId = "local_session_id"
    }
}

struct ExportedSurveyMetadata: Decodable {
    let localSessionId: String?
    let questionnaireTitle: String?
    let questionnaire: ExportedQuestionnaire?

    enum CodingKeys: String, CodingKey {
        case localSessionId = "local_session_id"
        case questionnaireTitle = "questionnaire_title"
        case questionnaire
    }
}

struct ExportedQuestionnaire: Decodable {
    let id: String?
    let version: String?
    let title: String?
    let description: String?
    let hash: String?
    let questions: [Question]?
}

struct ExportedMatchedQuestion: Decodable {
    let matchedQuestionId: Int
    let matchedQuestion: String
    let extractedAnswer: String?
    let finalAnswer: String?
    let selectedOptionCodes: [String]?
    let selectedOptionLabels: [String]?
    
    enum CodingKeys: String, CodingKey {
        case matchedQuestionId = "matched_question_id"
        case matchedQuestion = "matched_question"
        case extractedAnswer = "extracted_answer"
        case finalAnswer = "final_answer"
        case selectedOptionCodes = "selected_option_codes"
        case selectedOptionLabels = "selected_option_labels"
    }
}

struct ExportedRespondentInfo: Decodable {
    let name: String?
    let age: Int?
    let ageRange: String?
    let gender: String?
    let race: String?
    let email: String?
    let location: String?

    enum CodingKeys: String, CodingKey {
        case name
        case age
        case ageRange = "age_range"
        case gender
        case race
        case email
        case location
    }
}

// MARK: - POE API Response Models
struct MatchedQuestion: Codable {
    let matchedQuestionId: Int
    let matchedQuestion: String
    let extractedAnswer: String
    let selectedOptionCodes: [String]?
    let selectedOptionLabels: [String]?
    let confidence: String
    let clarificationNeeded: Bool
    let finalAnswer: String?
    let manuallyClarified: Bool?
    let clarificationNote: String?
    let answerSource: String?
    
    enum CodingKeys: String, CodingKey {
        case matchedQuestionId = "matched_question_id"
        case matchedQuestion = "matched_question"
        case extractedAnswer = "extracted_answer"
        case selectedOptionCodes = "selected_option_codes"
        case selectedOptionLabels = "selected_option_labels"
        case confidence
        case clarificationNeeded = "clarification_needed"
        case finalAnswer = "final_answer"
        case manuallyClarified = "manually_clarified"
        case clarificationNote = "clarification_note"
        case answerSource = "answer_source"
    }

    init(
        matchedQuestionId: Int,
        matchedQuestion: String,
        extractedAnswer: String,
        selectedOptionCodes: [String]? = nil,
        selectedOptionLabels: [String]? = nil,
        confidence: String,
        clarificationNeeded: Bool,
        finalAnswer: String? = nil,
        manuallyClarified: Bool? = nil,
        clarificationNote: String? = nil,
        answerSource: String? = nil
    ) {
        self.matchedQuestionId = matchedQuestionId
        self.matchedQuestion = matchedQuestion
        self.extractedAnswer = extractedAnswer
        self.selectedOptionCodes = selectedOptionCodes
        self.selectedOptionLabels = selectedOptionLabels
        self.confidence = confidence
        self.clarificationNeeded = clarificationNeeded
        self.finalAnswer = finalAnswer
        self.manuallyClarified = manuallyClarified
        self.clarificationNote = clarificationNote
        self.answerSource = answerSource
    }

    func withManualClarification(
        finalAnswer: String?,
        note: String?,
        selectedOptionCodes: [String]? = nil,
        selectedOptionLabels: [String]? = nil
    ) -> MatchedQuestion {
        let cleanedAnswer = finalAnswer?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)

        return MatchedQuestion(
            matchedQuestionId: matchedQuestionId,
            matchedQuestion: matchedQuestion,
            extractedAnswer: extractedAnswer,
            selectedOptionCodes: selectedOptionCodes ?? self.selectedOptionCodes,
            selectedOptionLabels: selectedOptionLabels ?? self.selectedOptionLabels,
            confidence: confidence,
            clarificationNeeded: clarificationNeeded,
            finalAnswer: cleanedAnswer?.isEmpty == false ? cleanedAnswer : nil,
            manuallyClarified: true,
            clarificationNote: cleanedNote?.isEmpty == false ? cleanedNote : nil,
            answerSource: "manual_clarification"
        )
    }

    func withAcceptedOriginalAnswer(note: String?) -> MatchedQuestion {
        let cleanedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)

        return MatchedQuestion(
            matchedQuestionId: matchedQuestionId,
            matchedQuestion: matchedQuestion,
            extractedAnswer: extractedAnswer,
            selectedOptionCodes: selectedOptionCodes,
            selectedOptionLabels: selectedOptionLabels,
            confidence: confidence,
            clarificationNeeded: clarificationNeeded,
            finalAnswer: extractedAnswer,
            manuallyClarified: true,
            clarificationNote: cleanedNote?.isEmpty == false ? cleanedNote : nil,
            answerSource: "accepted_model_answer"
        )
    }
}
