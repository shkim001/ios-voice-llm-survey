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
    
    enum CodingKeys: String, CodingKey {
        case id
        case question
        case type
        case followUp = "follow_up"
        case keywords
    }

    init(
        id: Int,
        question: String,
        type: String,
        followUp: String?,
        keywords: [String]
    ) {
        self.id = id
        self.question = question
        self.type = type
        self.followUp = followUp
        self.keywords = keywords
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
    let name: String
    let age: Int
    let gender: String
    let phone: String
    let location: String
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

    enum CodingKeys: String, CodingKey {
        case localSessionId = "local_session_id"
    }
}

struct ExportedMatchedQuestion: Decodable {
    let matchedQuestionId: Int
    let matchedQuestion: String
    let extractedAnswer: String?
    let finalAnswer: String?
    
    enum CodingKeys: String, CodingKey {
        case matchedQuestionId = "matched_question_id"
        case matchedQuestion = "matched_question"
        case extractedAnswer = "extracted_answer"
        case finalAnswer = "final_answer"
    }
}

struct ExportedRespondentInfo: Decodable {
    let name: String?
    let age: Int?
    let gender: String?
    let phone: String?
    let location: String?
}

// MARK: - POE API Response Models
struct MatchedQuestion: Codable {
    let matchedQuestionId: Int
    let matchedQuestion: String
    let extractedAnswer: String
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
        self.confidence = confidence
        self.clarificationNeeded = clarificationNeeded
        self.finalAnswer = finalAnswer
        self.manuallyClarified = manuallyClarified
        self.clarificationNote = clarificationNote
        self.answerSource = answerSource
    }

    func withManualClarification(finalAnswer: String?, note: String?) -> MatchedQuestion {
        let cleanedAnswer = finalAnswer?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)

        return MatchedQuestion(
            matchedQuestionId: matchedQuestionId,
            matchedQuestion: matchedQuestion,
            extractedAnswer: extractedAnswer,
            confidence: confidence,
            clarificationNeeded: clarificationNeeded,
            finalAnswer: cleanedAnswer?.isEmpty == false ? cleanedAnswer : nil,
            manuallyClarified: true,
            clarificationNote: cleanedNote?.isEmpty == false ? cleanedNote : nil,
            answerSource: "manual_clarification"
        )
    }
}
