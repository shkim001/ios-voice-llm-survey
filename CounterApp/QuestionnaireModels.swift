import Foundation

// MARK: - Questionnaire Models
struct QuestionnaireData: Codable {
    let questionnaire: Questionnaire
}

struct Questionnaire: Codable {
    let title: String
    let description: String
    let questions: [Question]
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
