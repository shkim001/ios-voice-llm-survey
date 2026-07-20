import unittest

from server.app import server_processing


QUESTIONS = [
    {
        "id": 2,
        "question": "Are there shade trees?",
        "type": "yes-no",
        "keywords": ["shade trees"],
    },
    {
        "id": 9,
        "question": "Which facilities are present?",
        "type": "multiple-choice",
        "keywords": ["facilities"],
        "allows_multiple": True,
        "options": [
            {"code": "1", "text": "Water fountain"},
            {"code": "2", "text": "Restroom"},
        ],
    },
]


class ServerProcessingTests(unittest.TestCase):
    def test_prompt_remains_behavior_aligned_with_existing_app_prompt(self):
        prompt = server_processing.generate_system_prompt(QUESTIONS)
        self.assertIn("Question 2: Are there shade trees?", prompt)
        self.assertIn("Always output **valid JSON only**", prompt)
        self.assertNotIn("supporting_transcript", prompt)

    def test_multiple_choice_validation_and_interviewer_checked_answer(self):
        matches = server_processing.validate_matches(
            [
                {
                    "matched_question_id": 9,
                    "matched_question": "Which facilities are present?",
                    "extracted_answer": "number one and two",
                    "confidence": "medium",
                    "clarification_needed": True,
                }
            ],
            QUESTIONS,
            {"9": ["2"]},
        )
        self.assertEqual(matches[0]["selected_option_codes"], ["2"])
        self.assertEqual(matches[0]["final_answer"], "Restroom")
        self.assertEqual(matches[0]["answer_source"], "interviewer_checked")
        self.assertFalse(server_processing.needs_clarification(matches[0]))

    def test_uncertain_answer_creates_transcript_backed_review_request(self):
        matches = [
            {
                "matched_question_id": 2,
                "matched_question": "Are there shade trees?",
                "extracted_answer": "Yes",
                "confidence": "medium",
                "clarification_needed": True,
            }
        ]
        requests = server_processing.clarification_requests(
            "There are shade trees no, and there are drinking fountains yes.",
            matches,
            QUESTIONS,
        )
        self.assertEqual(requests[0]["allowed_answers"], ["Yes", "No", "Not sure"])
        self.assertIn("shade trees no", requests[0]["transcript_segment"])

    def test_server_package_preserves_audio_and_processing_provenance(self):
        package = server_processing.build_session_package(
            {
                "local_session_id": "local-1",
                "recording_started_at": 100.25,
                "questionnaire_snapshot": {"title": "Street Survey", "questions": QUESTIONS},
                "interviewer_snapshot": {"name": "Interviewer"},
                "respondent_snapshot": {"is_anonymous": True},
                "trajectory_points": [],
            },
            cloud_session_id="11111111-1111-1111-1111-111111111111",
            cloud_respondent_id="22222222-2222-2222-2222-222222222222",
            audio_file_name="recording.m4a",
            audio_file_size=1234,
            transcript="shade trees no",
            matches=[],
            revision=2,
        )
        self.assertEqual(package["local_session_id"], "local-1")
        self.assertEqual(package["audio"]["recorded_at_ms"], 100250)
        self.assertEqual(package["metadata"]["processing"]["transcription_model"], "gpt-4o-mini-transcribe")
        self.assertEqual(package["metadata"]["processing"]["revision"], 2)


if __name__ == "__main__":
    unittest.main()
