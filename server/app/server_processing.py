from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx


OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "").strip()
OPENAI_BASE_URL = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
OPENAI_TRANSCRIPTION_MODEL = os.environ.get(
    "OPENAI_TRANSCRIPTION_MODEL", "gpt-4o-mini-transcribe"
).strip()
OPENAI_ANALYSIS_MODEL = os.environ.get("OPENAI_ANALYSIS_MODEL", "gpt-4o-mini").strip()
OPENAI_REQUEST_TIMEOUT_SECONDS = float(os.environ.get("OPENAI_REQUEST_TIMEOUT_SECONDS", "180"))


class ServerProcessingError(RuntimeError):
    pass


def _require_openai_key() -> str:
    if not OPENAI_API_KEY:
        raise ServerProcessingError("OPENAI_API_KEY is not configured on the server")
    return OPENAI_API_KEY


def transcribe_audio(audio_path: Path) -> tuple[str, dict[str, Any]]:
    key = _require_openai_key()
    headers = {"Authorization": f"Bearer {key}"}
    with audio_path.open("rb") as audio_file, httpx.Client(
        timeout=OPENAI_REQUEST_TIMEOUT_SECONDS
    ) as client:
        response = client.post(
            f"{OPENAI_BASE_URL}/audio/transcriptions",
            headers=headers,
            data={"model": OPENAI_TRANSCRIPTION_MODEL, "response_format": "json"},
            files={"file": (audio_path.name, audio_file, "audio/mp4")},
        )
    if response.status_code < 200 or response.status_code >= 300:
        raise ServerProcessingError(
            f"OpenAI transcription failed with HTTP {response.status_code}: "
            f"{response.text[:500]}"
        )
    try:
        payload = response.json()
    except ValueError as exc:
        raise ServerProcessingError("OpenAI transcription returned invalid JSON") from exc
    transcript = payload.get("text") if isinstance(payload, dict) else None
    if not isinstance(transcript, str) or not transcript.strip():
        raise ServerProcessingError("OpenAI transcription returned an empty transcript")
    return transcript.strip(), payload


def generate_system_prompt(questions: list[dict[str, Any]]) -> str:
    questions_text = ""
    for question in questions:
        question_id = question.get("id", "")
        prompt = question.get("question", "")
        answer_type = question.get("type", "")
        questions_text += f"\nQuestion {question_id}: {prompt}\n"
        questions_text += f"Type: {answer_type}\n"
        follow_up = question.get("follow_up")
        if isinstance(follow_up, str) and follow_up:
            questions_text += f"Follow-up: {follow_up}\n"
        if str(answer_type).lower() == "multiple-choice":
            selection_mode = (
                "Choose one or more options."
                if bool(question.get("allows_multiple"))
                else "Choose exactly one option."
            )
            questions_text += f"Selection rule: {selection_mode}\n"
            options = question.get("options")
            if isinstance(options, list) and options:
                questions_text += "Options:\n"
                for option in options:
                    if not isinstance(option, dict):
                        continue
                    code = str(option.get("code", "")).upper()
                    text = option.get("text", "")
                    questions_text += f"- {code}. {text}\n"
        keywords = question.get("keywords")
        keyword_text = ", ".join(str(value) for value in keywords) if isinstance(keywords, list) else ""
        questions_text += f"Related keywords: {keyword_text}\n\n"

    # Keep this prompt behavior-aligned with LLMService.generateSystemPrompt. The
    # workflow migration intentionally does not redesign the prompt in this phase.
    return f'''You are an intelligent assistant that analyzes spoken responses about location/street assessments and maps them to survey questions.

Your goal is to:
1. Read the provided audio transcription from the user.
2. Determine which survey question(s) the response corresponds to.
3. Extract a clear, concise answer for each question that can be inferred from the response.
4. Estimate the confidence level of your extraction.
5. Output the result in a structured JSON format.

Survey Questions:
{questions_text}

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
  {{
    "matched_question_id": <question_id>,
    "matched_question": "<the question text>",
    "extracted_answer": "<user's extracted answer>",
    "selected_option_codes": ["1", "3"],
    "selected_option_labels": ["Option label for 1", "Option label for 3"],
    "confidence": "<high/medium/low>",
    "clarification_needed": <true/false>
  }},
  ...
]

Example Output (for location assessment responses):
[
  {{
    "matched_question_id": 1,
    "matched_question": "Are there places to sit?",
    "extracted_answer": "Yes, there are benches and seating areas",
    "confidence": "high",
    "clarification_needed": false
  }},
  {{
    "matched_question_id": 2,
    "matched_question": "Are there shade trees?",
    "extracted_answer": "Yes, I can see several trees providing shade",
    "confidence": "high",
    "clarification_needed": false
  }}
]'''


def _extract_json_array(content: str) -> list[dict[str, Any]]:
    cleaned = content.replace("```json", "").replace("```", "").strip()
    start = cleaned.find("[")
    end = cleaned.rfind("]")
    if start >= 0 and end >= start:
        cleaned = cleaned[start : end + 1]
    try:
        payload = json.loads(cleaned)
    except json.JSONDecodeError as exc:
        raise ServerProcessingError("OpenAI analysis returned invalid JSON") from exc
    if isinstance(payload, dict):
        payload = payload.get("results", payload.get("data"))
    if not isinstance(payload, list) or not all(isinstance(item, dict) for item in payload):
        raise ServerProcessingError("OpenAI analysis did not return a JSON array")
    return payload


def analyze_transcript(
    transcript: str, questions: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    key = _require_openai_key()
    request_body = {
        "model": OPENAI_ANALYSIS_MODEL,
        "messages": [
            {"role": "system", "content": generate_system_prompt(questions)},
            {
                "role": "user",
                "content": (
                    f"User's spoken response: {transcript}\n\n"
                    "Please analyze and match this response. Output only valid JSON array."
                ),
            },
        ],
        "temperature": 0.3,
    }
    with httpx.Client(timeout=OPENAI_REQUEST_TIMEOUT_SECONDS) as client:
        response = client.post(
            f"{OPENAI_BASE_URL}/chat/completions",
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
            json=request_body,
        )
    if response.status_code < 200 or response.status_code >= 300:
        raise ServerProcessingError(
            f"OpenAI analysis failed with HTTP {response.status_code}: {response.text[:500]}"
        )
    try:
        payload = response.json()
        content = payload["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        raise ServerProcessingError("OpenAI analysis response was missing message content") from exc
    if not isinstance(content, str):
        raise ServerProcessingError("OpenAI analysis response content was not text")
    return _extract_json_array(content), payload


def _spoken_code_aliases(code: str) -> set[str]:
    aliases = {
        "1": {"one", "number one", "first"},
        "2": {"two", "to", "too", "number two", "second"},
        "3": {"three", "number three", "third"},
        "4": {"four", "for", "number four", "fourth"},
        "5": {"five", "number five", "fifth"},
        "6": {"six", "number six", "sixth"},
        "7": {"seven", "number seven", "seventh"},
        "8": {"eight", "ate", "number eight", "eighth"},
        "9": {"nine", "number nine", "ninth"},
        "10": {"ten", "number ten", "tenth"},
    }
    return {code.lower(), *aliases.get(code, set())}


def _codes_from_answer(answer: str, valid_codes: set[str]) -> list[str]:
    found: list[tuple[int, str]] = []
    lower = answer.lower()
    for code in valid_codes:
        for alias in _spoken_code_aliases(code.lower()):
            match = re.search(rf"(?<![a-z0-9]){re.escape(alias)}(?![a-z0-9])", lower)
            if match:
                found.append((match.start(), code))
                break
    return list(dict.fromkeys(code for _, code in sorted(found)))


def validate_matches(
    matches: list[dict[str, Any]],
    questions: list[dict[str, Any]],
    checked_codes_by_question_id: dict[str, list[str]] | None = None,
) -> list[dict[str, Any]]:
    questions_by_id = {str(question.get("id")): question for question in questions}
    normalized: list[dict[str, Any]] = []
    for raw in matches:
        match = dict(raw)
        question_id = str(match.get("matched_question_id", ""))
        question = questions_by_id.get(question_id)
        if question is None:
            continue
        try:
            match["matched_question_id"] = int(question_id)
        except ValueError:
            match["matched_question_id"] = question_id
        match["matched_question"] = str(match.get("matched_question") or question.get("question") or "")
        match["extracted_answer"] = str(match.get("extracted_answer") or "")
        match["confidence"] = str(match.get("confidence") or "low").lower()
        match["clarification_needed"] = bool(match.get("clarification_needed"))

        if str(question.get("type", "")).lower() == "multiple-choice":
            options = [item for item in question.get("options", []) if isinstance(item, dict)]
            option_by_code = {str(item.get("code", "")).upper(): str(item.get("text", "")) for item in options}
            raw_codes = match.get("selected_option_codes")
            codes = [str(code).strip().upper() for code in raw_codes] if isinstance(raw_codes, list) else []
            if not codes:
                codes = _codes_from_answer(match["extracted_answer"], set(option_by_code))
            codes = list(dict.fromkeys(code for code in codes if code))
            invalid = [code for code in codes if code not in option_by_code]
            too_many = not bool(question.get("allows_multiple")) and len(codes) > 1
            if not codes or invalid or too_many:
                match["clarification_needed"] = True
                match["confidence"] = "low"
            match["selected_option_codes"] = codes
            match["selected_option_labels"] = [option_by_code[code] for code in codes if code in option_by_code]
            if codes:
                match["extracted_answer"] = ", ".join(codes)
        normalized.append(match)

    checked = checked_codes_by_question_id or {}
    by_id = {str(match.get("matched_question_id")): match for match in normalized}
    for question_id, raw_codes in checked.items():
        question = questions_by_id.get(str(question_id))
        if not question or str(question.get("type", "")).lower() != "multiple-choice":
            continue
        options = [item for item in question.get("options", []) if isinstance(item, dict)]
        option_by_code = {str(item.get("code", "")).upper(): str(item.get("text", "")) for item in options}
        codes = [str(code).upper() for code in raw_codes if str(code).upper() in option_by_code]
        codes = [code for code in option_by_code if code in codes]
        if not codes:
            continue
        labels = [option_by_code[code] for code in codes]
        existing = by_id.get(str(question_id))
        original_answer = existing.get("extracted_answer") if existing else None
        answer = ", ".join(labels) if labels else ", ".join(codes)
        updated = {
            **(existing or {}),
            "matched_question_id": int(question_id) if str(question_id).isdigit() else question_id,
            "matched_question": question.get("question", ""),
            "extracted_answer": answer,
            "selected_option_codes": codes,
            "selected_option_labels": labels,
            "confidence": "high",
            "clarification_needed": False,
            "final_answer": answer,
            "manually_clarified": False,
            "clarification_note": (
                "Interviewer checked choices used as primary answer; voice transcript retained as "
                f"supporting evidence. LLM transcript answer: {original_answer}"
                if original_answer
                else "Interviewer checked choices used as primary answer; voice transcript retained as supporting evidence."
            ),
            "answer_source": "interviewer_checked",
        }
        if existing:
            normalized[normalized.index(existing)] = updated
        else:
            normalized.append(updated)
        by_id[str(question_id)] = updated
    return sorted(normalized, key=lambda item: str(item.get("matched_question_id", "")))


def needs_clarification(match: dict[str, Any]) -> bool:
    if match.get("manually_clarified") is True or match.get("answer_source") == "interviewer_checked":
        return False
    return bool(match.get("clarification_needed")) or str(match.get("confidence", "")).lower() != "high"


def transcript_snippet(
    transcript: str, match: dict[str, Any], questions: list[dict[str, Any]], radius: int = 120
) -> str:
    question_id = str(match.get("matched_question_id", ""))
    question = next((item for item in questions if str(item.get("id")) == question_id), {})
    terms = [str(value) for value in question.get("keywords", []) if str(value).strip()]
    terms.extend(str(question.get("question", "")).replace("?", "").split())
    lower = transcript.lower()
    positions = [lower.find(term.lower()) for term in terms if len(term) > 2 and lower.find(term.lower()) >= 0]
    if not positions:
        return transcript[:240] + ("..." if len(transcript) > 240 else "")
    position = min(positions)
    start = max(0, position - radius)
    end = min(len(transcript), position + radius)
    return transcript[start:end].strip()


def clarification_requests(
    transcript: str, matches: list[dict[str, Any]], questions: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    questions_by_id = {str(question.get("id")): question for question in questions}
    requests: list[dict[str, Any]] = []
    for index, match in enumerate(matches):
        if not needs_clarification(match):
            continue
        question = questions_by_id.get(str(match.get("matched_question_id")), {})
        answer_type = str(question.get("type", ""))
        allowed_answers: list[str] = []
        if answer_type.lower() == "yes-no":
            allowed_answers = ["Yes", "No", "Not sure"]
        elif answer_type.lower() == "multiple-choice":
            allowed_answers = [
                f"{option.get('code')}. {option.get('text')}"
                for option in question.get("options", [])
                if isinstance(option, dict)
            ]
        requests.append(
            {
                "clarification_id": f"match-{index}",
                "matched_index": index,
                "question_id": match.get("matched_question_id"),
                "question_text": match.get("matched_question") or question.get("question"),
                "answer_type": answer_type,
                "model_answer": match.get("extracted_answer"),
                "confidence": match.get("confidence"),
                "transcript_segment": transcript_snippet(transcript, match, questions),
                "allowed_answers": allowed_answers,
                "allows_multiple": bool(question.get("allows_multiple")),
            }
        )
    return requests


def build_session_package(
    input_manifest: dict[str, Any],
    *,
    cloud_session_id: str,
    cloud_respondent_id: str,
    audio_file_name: str,
    audio_file_size: int,
    transcript: str,
    matches: list[dict[str, Any]],
    revision: int,
) -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    timestamp = now.timestamp()
    local_session_id = str(input_manifest.get("local_session_id") or cloud_session_id)
    questionnaire = input_manifest.get("questionnaire_snapshot")
    if not isinstance(questionnaire, dict):
        questionnaire = None
    location_info = input_manifest.get("location_info")
    location_info = location_info if isinstance(location_info, dict) else None
    place = input_manifest.get("place_snapshot")
    place = place if isinstance(place, dict) else {}
    coordinates = input_manifest.get("location_coordinates")
    coordinates = coordinates if isinstance(coordinates, dict) else {}
    location_label = place.get("display_label") or input_manifest.get("location_label")
    respondent = input_manifest.get("respondent_snapshot")
    if not location_label and isinstance(respondent, dict):
        location_label = respondent.get("location")
    location = {
        "status": input_manifest.get("location_status", "pending"),
        "source": input_manifest.get("location_source", "none"),
        "quality": input_manifest.get("location_quality", "unknown"),
        "label": location_label,
        "formatted_address": place.get("formatted_address"),
        "latitude": coordinates.get("latitude"),
        "longitude": coordinates.get("longitude"),
        "horizontal_accuracy_m": input_manifest.get("location_horizontal_accuracy_m"),
    }
    recording_started_at = input_manifest.get("recording_started_at")
    recorded_at_ms = int(float(recording_started_at) * 1000) if recording_started_at else None
    trajectory = input_manifest.get("trajectory_points")
    trajectory = trajectory if isinstance(trajectory, list) else []
    recording_start = input_manifest.get("location_point")
    if input_manifest.get("location_source") != "device_gps" or not isinstance(recording_start, dict):
        recording_start = None
    package = {
        "metadata": {
            "schema_version": 3,
            "export_time": now.astimezone().strftime("%Y-%m-%d %H:%M:%S"),
            "timestamp": timestamp,
            "local_session_id": local_session_id,
            "questionnaire_title": questionnaire.get("title", "Unknown") if questionnaire else "Unknown",
            "total_responses": 1,
            "questionnaire": questionnaire,
            "cloud": {"session_id": cloud_session_id, "respondent_id": cloud_respondent_id},
            "processing": {
                "revision": revision,
                "transcription_model": OPENAI_TRANSCRIPTION_MODEL,
                "analysis_model": OPENAI_ANALYSIS_MODEL,
                "processed_on": "server",
            },
        },
        "schema_version": 3,
        "timestamp": timestamp,
        "session_id": local_session_id,
        "local_session_id": local_session_id,
        "interviewer_info": input_manifest.get("interviewer_snapshot"),
        "respondent_info": respondent,
        "location_label": location_label,
        "location_info": location_info,
        "location": location,
        "audio": {
            "file_name": audio_file_name,
            "local_session_id": local_session_id,
            "recorded_at_ms": recorded_at_ms,
            "file_size_bytes": audio_file_size,
        },
        "recording_start_trajectory_point": recording_start,
        "trajectory_points": trajectory,
        "transcription": transcript,
        "matched_questions": matches,
    }
    return package
