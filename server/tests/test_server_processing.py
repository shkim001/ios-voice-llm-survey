import unittest
from unittest.mock import patch

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
        self.assertIn("perform a second completeness pass", prompt)
        self.assertIn("supporting_transcript", prompt)
        self.assertIn("respondent_unsure", prompt)

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

    def test_yes_no_answer_contradicting_transcript_forces_clarification(self):
        matches = server_processing.validate_matches(
            [
                {
                    "matched_question_id": 2,
                    "matched_question": "Are there shade trees?",
                    "extracted_answer": "Yes",
                    "confidence": "high",
                    "clarification_needed": False,
                }
            ],
            QUESTIONS,
            transcript=(
                "Are there shade trees no is there grass flowers and landscaping yes "
                "are there drinking fountains yes"
            ),
        )

        self.assertEqual(matches[0]["validation_issue"], "yes_no_answer_evidence_contradiction")
        self.assertEqual(matches[0]["confidence"], "low")
        self.assertTrue(server_processing.needs_clarification(matches[0]))

    def test_clarification_segment_starts_at_question_and_stops_before_next_question(self):
        questions = [
            {
                "id": 1,
                "question": "How do sidewalks affect your walking experience?",
                "type": "impression",
            },
            {
                "id": 6,
                "question": (
                    "What additional public services, ramps, pedestrian plazas, crossing buttons, "
                    "do you think could help pedestrian comfort or safety?"
                ),
                "type": "impression",
            },
            {
                "id": 7,
                "question": "What public services should be more accessible?",
                "type": "impression",
            },
        ]
        transcript = (
            "How do sidewalks affect your walking experience? Broken sidewalks make walking hard. "
            "What additional public services ramps pedestrian plazas crossing buttons do you think "
            "could help pedestrian comfort or safety? I do not quite know about it to be honest. "
            "What public services should be more accessible? Bikes, I would say."
        )
        segment = server_processing.transcript_snippet(
            transcript,
            {
                "matched_question_id": 6,
                "matched_question": questions[1]["question"],
                "extracted_answer": "I do not quite know",
            },
            questions,
        )

        self.assertTrue(segment.startswith("What additional public services"))
        self.assertIn("I do not quite know about it", segment)
        self.assertNotIn("Broken sidewalks", segment)
        self.assertNotIn("Bikes, I would say", segment)

    def test_missing_spoken_questions_receive_targeted_recovery_or_clarification(self):
        questions = [
            {
                "id": 3,
                "question": "What is something you don't like about public areas such as bus stops?",
                "type": "impression",
            },
            {
                "id": 6,
                "question": "What additional public services could help pedestrian safety?",
                "type": "impression",
            },
            {
                "id": 7,
                "question": "What public services should be more accessible?",
                "type": "impression",
            },
            {
                "id": 8,
                "question": "Should e-bikes and e-scooters have more regulations?",
                "type": "impression",
            },
            {
                "id": 9,
                "question": "Do you think intersections make it difficult to walk?",
                "type": "impression",
            },
        ]
        transcript = (
            "What is something you don't like about public areas such as bus stops? They are dirty. "
            "What additional public services could help pedestrian safety? I don't quite know about it. "
            "What public services should be more accessible? Bikes, I would say. "
            "Should e-bikes and e-scooters have more regulations? Yes, they move too fast. "
            "Do you think intersections make it difficult to walk? A little bit, especially for slow walkers."
        )
        initial = server_processing.validate_matches(
            [
                {
                    "matched_question_id": 8,
                    "matched_question": questions[3]["question"],
                    "extracted_answer": "Yes, they move too fast",
                    "confidence": "high",
                    "clarification_needed": False,
                }
            ],
            questions,
            transcript=transcript,
        )
        recovery_response = {"id": "recovery-response"}
        with patch.object(
            server_processing,
            "analyze_transcript",
            return_value=(
                [
                    {
                        "matched_question_id": 3,
                        "extracted_answer": "They are dirty",
                        "confidence": "high",
                    },
                    {
                        "matched_question_id": 6,
                        "extracted_answer": "I don't quite know about it",
                        "confidence": "high",
                    },
                    {
                        "matched_question_id": 7,
                        "extracted_answer": "Bikes",
                        "confidence": "high",
                    },
                ],
                recovery_response,
            ),
        ):
            recovered, raw_recovery, audit = (
                server_processing.recover_omitted_question_matches(
                    transcript,
                    questions,
                    initial,
                )
            )

        self.assertEqual([str(item["matched_question_id"]) for item in recovered], ["3", "6", "7", "8", "9"])
        self.assertEqual(audit["initially_missing_question_ids"], ["3", "6", "7", "9"])
        self.assertEqual(audit["pipeline_version"], 2)
        self.assertEqual(raw_recovery, recovery_response)
        question_six = next(item for item in recovered if str(item["matched_question_id"]) == "6")
        self.assertEqual(question_six["response_status"], "respondent_unsure")
        self.assertFalse(server_processing.needs_clarification(question_six))
        self.assertIn("I don't quite know about it", question_six["supporting_transcript"])
        question_nine = next(item for item in recovered if str(item["matched_question_id"]) == "9")
        self.assertEqual(question_nine["completeness_issue"], "spoken_question_missing_after_targeted_retry")
        self.assertTrue(server_processing.needs_clarification(question_nine))

    def test_parenthetical_free_bus_lane_question_is_recovered(self):
        questions = [
            {
                "id": 10,
                "question": "Do you think crosswalk time should be longer?",
                "type": "impression",
            },
            {
                "id": 11,
                "question": "Do we need more bus-exclusive lanes (where only buses can run)?",
                "type": "impression",
            },
            {
                "id": 12,
                "question": "What do you think about congestion pricing?",
                "type": "impression",
            },
        ]
        transcript = (
            "Do you think crosswalk time should be longer? It depends. "
            "So do we need more bus exclusive lanes? I think so, yeah. It can decrease delays. "
            "What do you think about congestion pricing? I think it is ridiculous."
        )
        initial = server_processing.validate_matches(
            [
                {"matched_question_id": 10, "extracted_answer": "It depends", "confidence": "high"},
                {
                    "matched_question_id": 12,
                    "extracted_answer": "I think it is ridiculous",
                    "confidence": "high",
                },
            ],
            questions,
            transcript=transcript,
        )
        with patch.object(
            server_processing,
            "analyze_transcript",
            return_value=(
                [
                    {
                        "matched_question_id": 11,
                        "extracted_answer": "I think so, yeah. It can decrease delays.",
                        "supporting_transcript": (
                            "So do we need more bus exclusive lanes? I think so, yeah. "
                            "It can decrease delays."
                        ),
                        "confidence": "high",
                    }
                ],
                {"id": "bus-lane-recovery"},
            ),
        ):
            recovered, _, audit = server_processing.recover_omitted_question_matches(
                transcript,
                questions,
                initial,
            )

        self.assertEqual([item["matched_question_id"] for item in recovered], [10, 11, 12])
        self.assertEqual(audit["deterministically_located_question_ids"], ["11"])
        self.assertEqual(audit["recovered_question_ids"], ["11"])
        self.assertEqual(audit["unasked_question_ids"], [])
        bus_lane = recovered[1]
        self.assertTrue(bus_lane["recovered_after_completeness_check"])
        self.assertIn("bus exclusive lanes", bus_lane["supporting_transcript"])
        self.assertNotIn("congestion pricing", bus_lane["supporting_transcript"])

    def test_unasked_question_does_not_trigger_completeness_recovery(self):
        questions = [
            {
                "id": 6,
                "question": "What additional public services could help pedestrian safety?",
                "type": "impression",
            },
            {
                "id": 7,
                "question": "What public services should be more accessible?",
                "type": "impression",
            },
        ]
        transcript = "What public services should be more accessible? Bikes, I would say."
        matches = server_processing.validate_matches(
            [
                {
                    "matched_question_id": 7,
                    "extracted_answer": "Bikes",
                    "confidence": "high",
                }
            ],
            questions,
            transcript=transcript,
        )

        self.assertEqual(
            server_processing.spoken_questions_missing_from_matches(
                transcript,
                questions,
                matches,
            ),
            [],
        )

        with patch.object(
            server_processing,
            "analyze_transcript",
            return_value=([], {"id": "unasked-audit"}),
        ) as analyze:
            recovered, _, audit = server_processing.recover_omitted_question_matches(
                transcript,
                questions,
                matches,
            )

        analyze.assert_called_once_with(transcript, [questions[0]])
        self.assertEqual([item["matched_question_id"] for item in recovered], [7])
        self.assertEqual(audit["unasked_question_ids"], ["6"])
        self.assertEqual(audit["deterministically_located_question_ids"], [])

    def test_unverified_completeness_answer_cannot_create_false_match(self):
        questions = [
            {
                "id": 6,
                "question": "What additional public services could help pedestrian safety?",
                "type": "impression",
            }
        ]
        transcript = "The weather is pleasant and the buildings look clean."
        with patch.object(
            server_processing,
            "analyze_transcript",
            return_value=(
                [
                    {
                        "matched_question_id": 6,
                        "extracted_answer": "More crossing buttons",
                        "supporting_transcript": "The weather is pleasant",
                        "confidence": "high",
                    }
                ],
                {"id": "hallucinated-audit"},
            ),
        ):
            recovered, _, audit = server_processing.recover_omitted_question_matches(
                transcript,
                questions,
                [],
            )

        self.assertEqual(recovered, [])
        self.assertEqual(audit["unasked_question_ids"], ["6"])
        self.assertEqual(audit["rejected_unverified_question_ids"], ["6"])

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
        self.assertEqual(package["metadata"]["processing"]["analysis_model"], "gpt-4o")
        self.assertEqual(package["metadata"]["processing"]["analysis_pipeline_version"], 2)
        self.assertEqual(package["completeness_check"]["pipeline_version"], 2)
        self.assertEqual(package["metadata"]["processing"]["revision"], 2)


if __name__ == "__main__":
    unittest.main()
