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
    def test_match_order_preserves_transcript_order_instead_of_sorting_question_ids(self):
        questions = [
            {"id": 1, "question": "Question 1", "type": "yes-no"},
            {"id": 2, "question": "Question 2", "type": "yes-no"},
            {"id": 7, "question": "Question 7", "type": "yes-no"},
            {"id": 13, "question": "Question 13", "type": "yes-no"},
        ]
        raw_matches = [
            {"matched_question_id": 1, "extracted_answer": "Yes", "confidence": "high"},
            {"matched_question_id": 2, "extracted_answer": "No", "confidence": "high"},
            {"matched_question_id": 7, "extracted_answer": "No", "confidence": "high"},
            {"matched_question_id": 13, "extracted_answer": "Yes", "confidence": "high"},
        ]

        matches = server_processing.validate_matches(raw_matches, questions)

        self.assertEqual(
            [match["matched_question_id"] for match in matches],
            [1, 2, 7, 13],
        )

    def test_prompt_requires_structured_follow_up_in_parent_match(self):
        prompt = server_processing.generate_system_prompt(QUESTIONS)
        self.assertIn("Question 2: Are there shade trees?", prompt)
        self.assertIn("Always output **valid JSON only**", prompt)
        self.assertIn("follow-up belongs inside its parent question", prompt)
        self.assertIn('"asked_in_transcript"', prompt)
        self.assertNotIn("supporting_transcript", prompt)

    def test_spoken_follow_up_is_preserved_as_nested_result(self):
        questions = [
            {
                "id": 3,
                "question": "How often do you walk in your local neighborhood?",
                "follow_up": "What is the main purpose of your walking trips?",
                "type": "impression",
            }
        ]
        transcript = (
            "How often do you walk in your local neighborhood? Every day. "
            "What is the main purpose of your walking trips? Shopping, laundry, and visiting family."
        )
        matches = server_processing.validate_matches(
            [
                {
                    "matched_question_id": 3,
                    "matched_question": questions[0]["question"],
                    "extracted_answer": "Every day",
                    "confidence": "high",
                    "clarification_needed": False,
                    "follow_up": {
                        "question": questions[0]["follow_up"],
                        "asked_in_transcript": True,
                        "extracted_answer": "Shopping, laundry, and visiting family",
                        "confidence": "high",
                        "clarification_needed": False,
                    },
                }
            ],
            questions,
            transcript=transcript,
        )

        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0]["follow_up"]["extracted_answer"], "Shopping, laundry, and visiting family")
        self.assertFalse(server_processing.needs_clarification(matches[0]))

    def test_duplicate_parent_id_follow_up_is_merged_and_missing_answer_requires_review(self):
        questions = [
            {
                "id": 11,
                "question": "When do you feel safe walking?",
                "follow_up": "Do you feel safe walking after dark?",
                "type": "impression",
            }
        ]
        transcript = (
            "When do you feel safe walking? For the most part I feel safe. "
            "Do you feel safe walking after dark? In the summer I do."
        )
        merged = server_processing.validate_matches(
            [
                {
                    "matched_question_id": 11,
                    "matched_question": questions[0]["question"],
                    "extracted_answer": "For the most part I feel safe",
                    "confidence": "high",
                    "clarification_needed": False,
                },
                {
                    "matched_question_id": 11,
                    "matched_question": questions[0]["follow_up"],
                    "extracted_answer": "In the summer I do",
                    "confidence": "high",
                    "clarification_needed": False,
                },
            ],
            questions,
            transcript=transcript,
        )
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0]["follow_up"]["extracted_answer"], "In the summer I do")

        missing = server_processing.validate_matches(
            [
                {
                    "matched_question_id": 11,
                    "matched_question": questions[0]["question"],
                    "extracted_answer": "For the most part I feel safe",
                    "confidence": "high",
                    "clarification_needed": False,
                }
            ],
            questions,
            transcript=transcript,
        )
        self.assertTrue(server_processing.needs_clarification(missing[0]))
        requests = server_processing.clarification_requests(transcript, missing, questions)
        self.assertEqual(requests[0]["question_part"], "follow_up")
        self.assertEqual(requests[0]["question_text"], questions[0]["follow_up"])

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
