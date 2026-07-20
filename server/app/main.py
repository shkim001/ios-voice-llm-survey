from __future__ import annotations

import json
import logging
import os
import hashlib
import mimetypes
import shutil
import socket
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional
from uuid import UUID, uuid4

import pymysql
from pymysql.err import IntegrityError, MySQLError, OperationalError
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

load_dotenv()

from .server_processing import (
    ServerProcessingError,
    analyze_transcript,
    build_session_package,
    clarification_requests,
    needs_clarification,
    transcribe_audio,
    validate_matches,
)

MYSQL_HOST = os.environ["MYSQL_HOST"]
MYSQL_PORT = int(os.environ.get("MYSQL_PORT", "3306"))
MYSQL_USER = os.environ["MYSQL_USER"]
MYSQL_PASSWORD = os.environ["MYSQL_PASSWORD"]
MYSQL_DATABASE = os.environ["MYSQL_DATABASE"]
API_KEY = os.environ.get("API_KEY", "").strip()
SURVEY_PACKAGE_STORAGE_DIR = Path(
    os.environ.get("SURVEY_PACKAGE_STORAGE_DIR", "survey_session_packages")
).expanduser()
AUDIO_MAX_BYTES = int(os.environ.get("AUDIO_MAX_BYTES", str(200 * 1024 * 1024)))
TRANSCRIPTION_AUDIO_MAX_BYTES = int(
    os.environ.get("TRANSCRIPTION_AUDIO_MAX_BYTES", str(25 * 1024 * 1024))
)
SESSION_JSON_MAX_BYTES = int(os.environ.get("SESSION_JSON_MAX_BYTES", str(25 * 1024 * 1024)))
PROCESSING_INPUT_MAX_BYTES = int(
    os.environ.get("PROCESSING_INPUT_MAX_BYTES", str(25 * 1024 * 1024))
)
PROCESSING_JOB_MAX_ATTEMPTS = int(os.environ.get("PROCESSING_JOB_MAX_ATTEMPTS", "5"))
PROCESSING_JOB_LEASE_SECONDS = int(os.environ.get("PROCESSING_JOB_LEASE_SECONDS", "600"))

logger = logging.getLogger(__name__)


def _mysql_errno(exc: BaseException) -> Optional[int]:
    if not getattr(exc, "args", None):
        return None
    first = exc.args[0]
    return first if isinstance(first, int) else None


def uuid_to_bytes(u: UUID) -> bytes:
    return u.bytes


def bytes_to_uuid_hex(b: bytes) -> str:
    return str(UUID(bytes=b))


def sanitize_filename(name: str) -> str:
    allowed = []
    for ch in name:
        if ch.isalnum() or ch in ("-", "_", "."):
            allowed.append(ch)
        else:
            allowed.append("_")
    sanitized = "".join(allowed).strip("._")
    return sanitized or "recording.m4a"


def safe_json_summary(data: dict) -> dict:
    respondent_info = data.get("respondent_info") if isinstance(data.get("respondent_info"), dict) else {}
    interviewer_info = data.get("interviewer_info") if isinstance(data.get("interviewer_info"), dict) else {}
    audio = data.get("audio") if isinstance(data.get("audio"), dict) else {}
    location = data.get("location") if isinstance(data.get("location"), dict) else {}
    package_location = package_location_summary(data)
    gps = data.get("recording_start_trajectory_point")
    if not isinstance(gps, dict):
        gps = location if location.get("source") == "device_gps" else {}

    matched_questions = data.get("matched_questions")
    answers = matched_questions if isinstance(matched_questions, list) else []
    transcript = data.get("transcription")
    questionnaire = questionnaire_identity(data)

    return {
        "local_session_id": data.get("local_session_id") or data.get("session_id"),
        "location_label": package_location.get("label")
        or (None if package_location.get("mode") == "none" else respondent_info.get("location")),
        "interviewer_id": interviewer_info.get("interviewer_id") or interviewer_info.get("email"),
        "interviewer_name": interviewer_info.get("name"),
        "interviewer_email": interviewer_info.get("email"),
        "gps_lat": gps.get("lat", gps.get("latitude")),
        "gps_lon": gps.get("lon", gps.get("longitude")),
        "recorded_at_ms": audio.get("recorded_at_ms"),
        "questionnaire_id": questionnaire.get("id"),
        "questionnaire_version": questionnaire.get("version"),
        "questionnaire_hash": questionnaire.get("hash"),
        "answer_count": len(answers),
        "transcript_chars": len(transcript) if isinstance(transcript, str) else None,
    }


def _nested_dict(data: dict, key: str) -> dict:
    value = data.get(key)
    return value if isinstance(value, dict) else {}


def _list_value(data: dict, *keys: str) -> list:
    for key in keys:
        value = data.get(key)
        if isinstance(value, list):
            return value
    return []


def _string_value(data: dict, *keys: str) -> str | None:
    for key in keys:
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            return value
    return None


def _int_or_none(value: Any) -> int | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _float_or_none(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if result == result and result not in {float("inf"), float("-inf")} else None


def package_location_summary(data: dict) -> dict[str, Any]:
    location_info = _nested_dict(data, "location_info")
    location = _nested_dict(data, "location")
    mode = _string_value(location_info, "mode")
    collection_method = _string_value(location_info, "collection_method")
    latitude = _float_or_none(location_info.get("latitude"))
    longitude = _float_or_none(location_info.get("longitude"))
    if latitude is None:
        latitude = _float_or_none(location.get("latitude", location.get("lat")))
    if longitude is None:
        longitude = _float_or_none(
            location.get("longitude", location.get("lon", location.get("lng")))
        )
    trajectory_points = _list_value(data, "trajectory_points", "trajectory", "gps", "coordinates")

    if mode == "none":
        latitude = None
        longitude = None
    elif (latitude is None or longitude is None) and trajectory_points:
        first_point = trajectory_points[0] if isinstance(trajectory_points[0], dict) else {}
        latitude = _float_or_none(first_point.get("lat", first_point.get("latitude")))
        longitude = _float_or_none(
            first_point.get("lon", first_point.get("lng", first_point.get("longitude")))
        )

    intentionally_disabled = mode == "none"
    label = None if intentionally_disabled else (
        _string_value(location_info, "location_name")
        or _string_value(location, "label")
        or _string_value(data, "location_label")
    )
    formatted_address = None if intentionally_disabled else (
        _string_value(location_info, "formatted_address")
        or _string_value(location, "formatted_address", "formattedAddress", "address")
    )
    status = _string_value(location, "status")
    if not status and intentionally_disabled:
        status = "unavailable"

    return {
        "mode": mode,
        "collection_method": collection_method,
        "label": label,
        "formatted_address": formatted_address,
        "latitude": latitude,
        "longitude": longitude,
        "source": collection_method or _string_value(location, "source"),
        "status": status,
    }


def original_package_has_location(data: dict) -> bool:
    location = package_location_summary(data)
    source = (location.get("source") or "").strip().lower()
    has_coordinates = location.get("latitude") is not None and location.get("longitude") is not None
    if location.get("mode") == "none" or source in {"none", "intentionally_not_collected"}:
        return has_coordinates
    return bool(
        location.get("label")
        or location.get("formatted_address")
        or has_coordinates
    )


def admin_location_override_from_row(row: dict) -> dict[str, Any] | None:
    latitude = _float_or_none(row.get("admin_location_lat"))
    longitude = _float_or_none(row.get("admin_location_lon"))
    if latitude is None or longitude is None:
        return None
    updated_at = row.get("admin_location_updated_at")
    return {
        "label": row.get("admin_location_label"),
        "formatted_address": row.get("admin_formatted_address"),
        "latitude": latitude,
        "longitude": longitude,
        "source": "admin_override",
        "updated_at": updated_at.isoformat() if hasattr(updated_at, "isoformat") else updated_at,
    }


def normalize_email(value: str) -> str:
    return value.strip().lower()


def validate_interviewer_email(value: str) -> str:
    email = normalize_email(value)
    parts = email.split("@")
    if len(parts) != 2 or not parts[0] or not parts[1] or "." not in parts[1]:
        raise HTTPException(status_code=400, detail="email must be a valid email address")
    return email


def questionnaire_identity(data: dict) -> dict[str, str | None]:
    metadata = _nested_dict(data, "metadata")
    questionnaire = _nested_dict(metadata, "questionnaire")
    return {
        "id": _string_value(questionnaire, "id", "questionnaire_id")
        or _string_value(metadata, "questionnaire_id"),
        "version": _string_value(questionnaire, "version", "questionnaire_version")
        or _string_value(metadata, "questionnaire_version"),
        "title": _string_value(questionnaire, "title")
        or _string_value(metadata, "questionnaire_title"),
        "hash": _string_value(questionnaire, "hash", "questionnaire_hash")
        or _string_value(metadata, "questionnaire_hash"),
    }


def canonical_questionnaire_payload(
    *,
    questionnaire_id: str,
    version: str,
    title: str,
    description: str | None,
    questions: list[dict],
) -> dict:
    return {
        "id": questionnaire_id,
        "version": version,
        "title": title,
        "description": description or "",
        "questions": [
            {
                "id": questionnaire_question_id_value(q["id"]),
                "question": q["question"],
                "type": q["type"],
                "follow_up": q.get("follow_up"),
                "keywords": q.get("keywords", []),
                "options": q.get("options", []),
                "allows_multiple": bool(q.get("allows_multiple", False)),
            }
            for q in questions
        ],
    }


def questionnaire_hash(payload: dict) -> str:
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def questionnaire_question_id_value(value: Any) -> int | str:
    text = str(value)
    return int(text) if text.isdigit() else text


def questionnaire_response(row: dict, questions: list[dict]) -> dict:
    payload = canonical_questionnaire_payload(
        questionnaire_id=row["questionnaire_id"],
        version=row["version"],
        title=row["title"],
        description=row.get("description"),
        questions=questions,
    )
    return {
        **payload,
        "status": row["status"],
        "hash": row.get("questionnaire_hash") or questionnaire_hash(payload),
        "created_at": row["created_at"].isoformat() if row.get("created_at") else None,
        "updated_at": row["updated_at"].isoformat() if row.get("updated_at") else None,
        "published_at": row["published_at"].isoformat() if row.get("published_at") else None,
        "archived_at": row["archived_at"].isoformat() if row.get("archived_at") else None,
    }


def load_questionnaire_questions(cur, questionnaire_id: str, version: str) -> list[dict]:
    cur.execute(
        """
        SELECT question_id, order_index, prompt, answer_type, follow_up, keywords_json,
               options_json, allows_multiple
        FROM questionnaire_questions
        WHERE questionnaire_id = %s AND version = %s
        ORDER BY order_index, question_id
        """,
        (questionnaire_id, version),
    )
    questions = []
    for row in cur.fetchall():
        keywords: list[str] = []
        if row.get("keywords_json"):
            try:
                decoded = json.loads(row["keywords_json"])
                if isinstance(decoded, list):
                    keywords = [str(item) for item in decoded]
            except json.JSONDecodeError:
                keywords = []
        options: list[dict[str, str]] = []
        if row.get("options_json"):
            try:
                decoded_options = json.loads(row["options_json"])
                if isinstance(decoded_options, list):
                    for item in decoded_options:
                        if isinstance(item, dict):
                            code = str(item.get("code", "")).strip().upper()
                            text = str(item.get("text", "")).strip()
                            if code and text:
                                options.append({"code": code, "text": text})
            except json.JSONDecodeError:
                options = []
        questions.append(
            {
                "id": questionnaire_question_id_value(row["question_id"]),
                "question": row["prompt"],
                "type": row["answer_type"],
                "follow_up": row.get("follow_up"),
                "keywords": keywords,
                "options": options,
                "allows_multiple": bool(row.get("allows_multiple")),
            }
        )
    return questions


def admin_json_summary(data: dict) -> dict:
    metadata = _nested_dict(data, "metadata")
    cloud = _nested_dict(metadata, "cloud")
    interviewer_info = _nested_dict(data, "interviewer_info")
    respondent_info = _nested_dict(data, "respondent_info")
    audio = _nested_dict(data, "audio")
    trajectory_points = _list_value(data, "trajectory_points", "trajectory", "gps", "coordinates")
    matched_questions = _list_value(data, "matched_questions", "answers")
    questionnaire = questionnaire_identity(data)
    location = package_location_summary(data)

    return {
        "cloud_session_id": _string_value(cloud, "session_id"),
        "local_session_id": _string_value(data, "local_session_id", "session_id")
        or _string_value(metadata, "local_session_id"),
        "export_time": _string_value(metadata, "export_time", "created_at", "uploaded_at"),
        "respondent_name": _string_value(respondent_info, "name"),
        "respondent_email": _string_value(respondent_info, "email"),
        "respondent_location": _string_value(respondent_info, "location"),
        "interviewer_id": _string_value(interviewer_info, "interviewer_id", "email"),
        "interviewer_name": _string_value(interviewer_info, "name"),
        "interviewer_email": _string_value(interviewer_info, "email"),
        "location_label": location.get("label"),
        "location_formatted_address": location.get("formatted_address"),
        "location_lat": location.get("latitude"),
        "location_lon": location.get("longitude"),
        "location_source": location.get("source"),
        "location_status": location.get("status"),
        "location_mode": location.get("mode"),
        "location_collection_method": location.get("collection_method"),
        "questionnaire_id": questionnaire.get("id"),
        "questionnaire_version": questionnaire.get("version"),
        "questionnaire_title": questionnaire.get("title") or _string_value(metadata, "questionnaire_title"),
        "questionnaire_hash": questionnaire.get("hash"),
        "answer_count": len(matched_questions),
        "trajectory_point_count": len(trajectory_points),
        "audio_filename": _string_value(audio, "file_name", "filename", "original_filename"),
    }


def read_package_json(relative_json_path: str) -> dict:
    json_path = (SURVEY_PACKAGE_STORAGE_DIR / relative_json_path).resolve()
    storage_root = SURVEY_PACKAGE_STORAGE_DIR.resolve()
    try:
        json_path.relative_to(storage_root)
    except ValueError as e:
        raise HTTPException(status_code=500, detail="stored package path is outside storage root") from e

    if not json_path.exists():
        raise HTTPException(status_code=404, detail="session.json not found on server")

    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise HTTPException(status_code=500, detail="stored session.json is invalid JSON") from e

    if not isinstance(data, dict):
        raise HTTPException(status_code=500, detail="stored session.json must be a JSON object")
    return data


def safe_package_path(relative_path: str | None) -> Path | None:
    if not relative_path:
        return None
    candidate = (SURVEY_PACKAGE_STORAGE_DIR / relative_path).resolve()
    storage_root = SURVEY_PACKAGE_STORAGE_DIR.resolve()
    try:
        candidate.relative_to(storage_root)
    except ValueError as e:
        raise HTTPException(status_code=500, detail="stored package path is outside storage root") from e
    return candidate


def delete_if_table_exists(cur, sql: str, params: tuple) -> None:
    try:
        cur.execute(sql, params)
    except Exception as e:
        if isinstance(e, MySQLError) and _mysql_errno(e) in {1054, 1146}:
            logger.warning("skipping cleanup statement because table/column is missing: %s", e)
            return
        raise


def normalize_answer_for_analysis(answer: object) -> str | None:
    if isinstance(answer, list):
        codes = [str(item).strip().lower() for item in answer if str(item).strip()]
        return ",".join(codes) if codes else None

    if not isinstance(answer, str):
        return None

    value = answer.strip().lower()
    if not value:
        return None

    compact = value.strip(" .,!?:;\"'")
    if compact in {"yes", "y", "true"} or compact.startswith("yes,") or compact.startswith("yes."):
        return "yes"
    if compact in {"no", "n", "false"} or compact.startswith("no,") or compact.startswith("no."):
        return "no"
    if compact in {"n/a", "na", "not applicable", "none"} or "not applicable" in compact:
        return "not_applicable"
    if any(term in compact for term in ("unknown", "unsure", "not sure", "can't tell", "cannot tell")):
        return "unknown"

    return None


def analysis_answer_rows(
    cur,
    *,
    session_bytes: bytes,
    respondent_bytes: bytes,
    package_data: dict,
    source_json_path: str,
) -> list[tuple]:
    raw_matches = package_data.get("matched_questions")
    if not isinstance(raw_matches, list):
        return []

    question_ids = []
    for item in raw_matches:
        if not isinstance(item, dict):
            continue
        qid = item.get("matched_question_id")
        if qid is not None:
            question_ids.append(str(qid))

    question_lookup: dict[str, dict] = {}
    identity = questionnaire_identity(package_data)
    if question_ids:
        placeholders = ", ".join(["%s"] * len(set(question_ids)))
        unique_ids = tuple(sorted(set(question_ids)))
        if identity.get("id") and identity.get("version"):
            cur.execute(
                f"""
                SELECT question_id AS id, prompt, answer_type, follow_up
                FROM questionnaire_questions
                WHERE questionnaire_id = %s
                  AND version = %s
                  AND question_id IN ({placeholders})
                """,
                (identity["id"], identity["version"], *unique_ids),
            )
            question_lookup = {str(row["id"]): row for row in cur.fetchall()}

    rows = []

    def append_analysis_row(
        *,
        question_id: str,
        item: dict,
        question_text: str | None,
        answer_type: str | None,
    ) -> None:
        extracted_answer = item.get("extracted_answer")
        final_answer = item.get("final_answer")
        selected_option_codes = item.get("selected_option_codes")
        if isinstance(selected_option_codes, list) and selected_option_codes:
            analysis_answer = ", ".join(
                str(code).strip().upper()
                for code in selected_option_codes
                if str(code).strip()
            )
        else:
            analysis_answer = (
                final_answer
                if isinstance(final_answer, str) and final_answer.strip()
                else extracted_answer
            )
        confidence = item.get("confidence")
        clarification_needed = item.get("clarification_needed")
        rows.append(
            (
                session_bytes,
                respondent_bytes,
                identity.get("id"),
                identity.get("version"),
                question_id,
                len(rows),
                question_text,
                answer_type,
                analysis_answer if isinstance(analysis_answer, str) else None,
                normalize_answer_for_analysis(analysis_answer),
                confidence if isinstance(confidence, str) else None,
                clarification_needed if isinstance(clarification_needed, bool) else None,
                json.dumps(item, ensure_ascii=False),
                source_json_path,
            )
        )

    for item in raw_matches:
        if not isinstance(item, dict):
            continue

        qid_raw = item.get("matched_question_id")
        if qid_raw is None:
            continue

        question_id = str(qid_raw)
        question = question_lookup.get(question_id, {})
        fallback_question_text = item.get("matched_question")
        question_text = question.get("prompt")
        if not isinstance(question_text, str):
            question_text = fallback_question_text if isinstance(fallback_question_text, str) else None
        answer_type = question.get("answer_type")
        if not isinstance(answer_type, str):
            answer_type = None
        append_analysis_row(
            question_id=question_id,
            item=item,
            question_text=question_text,
            answer_type=answer_type,
        )
        follow_up = item.get("follow_up")
        if isinstance(follow_up, dict) and (
            follow_up.get("asked_in_transcript")
            or follow_up.get("extracted_answer")
            or follow_up.get("final_answer")
        ):
            follow_up_text = follow_up.get("question") or question.get("follow_up")
            append_analysis_row(
                question_id=f"{question_id}:follow_up",
                item=follow_up,
                question_text=follow_up_text if isinstance(follow_up_text, str) else None,
                answer_type="follow_up",
            )

    return rows


def replace_analysis_answers(
    cur,
    *,
    session_bytes: bytes,
    respondent_bytes: bytes,
    package_data: dict,
    source_json_path: str,
) -> int:
    cur.execute("DELETE FROM analysis_answers WHERE session_id = %s", (session_bytes,))
    rows = analysis_answer_rows(
        cur,
        session_bytes=session_bytes,
        respondent_bytes=respondent_bytes,
        package_data=package_data,
        source_json_path=source_json_path,
    )
    if not rows:
        return 0

    cur.executemany(
        """
        INSERT INTO analysis_answers (
            session_id, respondent_id, questionnaire_id, questionnaire_version,
            question_id, matched_index,
            question_text, answer_type, extracted_answer, normalized_answer,
            confidence, clarification_needed, raw_match_json, source_json_path
        )
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """,
        rows,
    )
    return len(rows)


def write_upload_file(upload: UploadFile, destination: Path, max_bytes: int) -> tuple[int, str]:
    bytes_written = 0
    sha256 = hashlib.sha256()
    temporary_destination = destination.with_name(f".{destination.name}.{uuid4().hex}.uploading")
    try:
        with temporary_destination.open("xb") as out:
            while True:
                chunk = upload.file.read(1024 * 1024)
                if not chunk:
                    break
                bytes_written += len(chunk)
                if bytes_written > max_bytes:
                    raise HTTPException(status_code=413, detail=f"{upload.filename or 'file'} is too large")
                sha256.update(chunk)
                out.write(chunk)
            out.flush()
            os.fsync(out.fileno())

        if bytes_written <= 0:
            raise HTTPException(status_code=400, detail=f"{upload.filename or 'file'} is empty")

        os.replace(temporary_destination, destination)
    except HTTPException:
        temporary_destination.unlink(missing_ok=True)
        raise
    except Exception as e:
        temporary_destination.unlink(missing_ok=True)
        logger.exception("uploaded file save failed")
        raise HTTPException(status_code=500, detail="failed to save uploaded file") from e
    finally:
        upload.file.close()

    return bytes_written, sha256.hexdigest()


def write_json_atomic(destination: Path, payload: Any) -> tuple[int, str]:
    data = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
    sha256 = hashlib.sha256(data).hexdigest()
    temporary_destination = destination.with_name(f".{destination.name}.{uuid4().hex}.writing")
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        with temporary_destination.open("xb") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary_destination, destination)
    finally:
        temporary_destination.unlink(missing_ok=True)
    return len(data), sha256


def write_text_atomic(destination: Path, value: str) -> None:
    data = value.encode("utf-8")
    temporary_destination = destination.with_name(f".{destination.name}.{uuid4().hex}.writing")
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        with temporary_destination.open("xb") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary_destination, destination)
    finally:
        temporary_destination.unlink(missing_ok=True)


@contextmanager
def get_conn():
    conn = pymysql.connect(
        host=MYSQL_HOST,
        port=MYSQL_PORT,
        user=MYSQL_USER,
        password=MYSQL_PASSWORD,
        database=MYSQL_DATABASE,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
    )
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def verify_api_key(x_api_key: str | None = Header(default=None, alias="X-API-Key")):
    if not API_KEY:
        return
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


app = FastAPI(title="Survey API", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health():
    return {"ok": True}


class InterviewerResolveRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=255)
    email: str = Field(..., min_length=3, max_length=255)


class InterviewerResolveResponse(BaseModel):
    interviewer_id: str
    name: str
    email: str
    identity_scope: str = "server"


class QuestionOptionPayload(BaseModel):
    code: str = Field(..., min_length=1, max_length=4)
    text: str = Field(..., min_length=1, max_length=255)


class QuestionnaireQuestionPayload(BaseModel):
    id: str | int = Field(..., description="Stable question id within this questionnaire version.")
    question: str = Field(..., min_length=1)
    type: str = Field(default="yes-no", min_length=1, max_length=64)
    follow_up: str | None = None
    keywords: list[str] = Field(default_factory=list)
    options: list[QuestionOptionPayload] = Field(default_factory=list, max_length=10)
    allows_multiple: bool = False


class QuestionnaireVersionPayload(BaseModel):
    id: str = Field(..., min_length=1, max_length=64)
    version: str = Field(..., min_length=1, max_length=64)
    title: str = Field(..., min_length=1, max_length=255)
    description: str | None = None
    questions: list[QuestionnaireQuestionPayload] = Field(..., min_length=1)


class QuestionnaireStatusChange(BaseModel):
    status: str


class AdminLocationOverridePayload(BaseModel):
    label: str = Field(..., min_length=1, max_length=255)
    formatted_address: str = Field(..., min_length=1, max_length=500)
    latitude: float = Field(..., ge=-90, le=90)
    longitude: float = Field(..., ge=-180, le=180)


def save_questionnaire_version(cur, body: QuestionnaireVersionPayload, *, require_draft: bool) -> dict:
    questionnaire_id = body.id.strip()
    version = body.version.strip()
    title = body.title.strip()
    description = body.description.strip() if isinstance(body.description, str) else None
    questions = [
        {
            "id": str(question.id).strip(),
            "question": question.question.strip(),
            "type": question.type.strip(),
            "follow_up": question.follow_up.strip() if isinstance(question.follow_up, str) else None,
            "keywords": [keyword.strip() for keyword in question.keywords if keyword.strip()],
            "options": [
                {
                    "code": option.code.strip().upper(),
                    "text": option.text.strip(),
                }
                for option in question.options
                if option.code.strip() and option.text.strip()
            ],
            "allows_multiple": bool(question.allows_multiple),
        }
        for question in body.questions
    ]

    if not questionnaire_id or not version:
        raise HTTPException(status_code=400, detail="questionnaire id and version are required")
    if len({question["id"] for question in questions}) != len(questions):
        raise HTTPException(status_code=400, detail="question ids must be unique within a version")
    for question in questions:
        if question["type"].lower() == "multiple-choice":
            if not question["options"]:
                raise HTTPException(status_code=400, detail="multiple-choice questions require at least one option")
            if len(question["options"]) > 10:
                raise HTTPException(status_code=400, detail="multiple-choice questions can have at most 10 options")
            option_codes = [option["code"] for option in question["options"]]
            if len(set(option_codes)) != len(option_codes):
                raise HTTPException(status_code=400, detail="multiple-choice option codes must be unique")
        else:
            question["options"] = []
            question["allows_multiple"] = False

    cur.execute(
        """
        SELECT status
        FROM questionnaire_versions
        WHERE questionnaire_id = %s AND version = %s
        """,
        (questionnaire_id, version),
    )
    existing = cur.fetchone()
    if require_draft and existing and existing["status"] != "draft":
        raise HTTPException(status_code=409, detail="only draft questionnaire versions can be edited")

    payload = canonical_questionnaire_payload(
        questionnaire_id=questionnaire_id,
        version=version,
        title=title,
        description=description,
        questions=questions,
    )
    payload_hash = questionnaire_hash(payload)

    cur.execute(
        """
        INSERT INTO questionnaires (id, title, description)
        VALUES (%s, %s, %s)
        ON DUPLICATE KEY UPDATE
            title = VALUES(title),
            description = VALUES(description),
            updated_at = CURRENT_TIMESTAMP(6)
        """,
        (questionnaire_id, title, description),
    )
    cur.execute(
        """
        INSERT INTO questionnaire_versions (
            questionnaire_id, version, title, description, status, questionnaire_hash
        )
        VALUES (%s, %s, %s, %s, 'draft', %s)
        ON DUPLICATE KEY UPDATE
            title = VALUES(title),
            description = VALUES(description),
            questionnaire_hash = VALUES(questionnaire_hash),
            updated_at = CURRENT_TIMESTAMP(6)
        """,
        (questionnaire_id, version, title, description, payload_hash),
    )
    cur.execute(
        """
        DELETE FROM questionnaire_questions
        WHERE questionnaire_id = %s AND version = %s
        """,
        (questionnaire_id, version),
    )
    cur.executemany(
        """
        INSERT INTO questionnaire_questions (
            questionnaire_id, version, question_id, order_index,
            prompt, answer_type, follow_up, keywords_json, options_json, allows_multiple
        )
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """,
        [
            (
                questionnaire_id,
                version,
                question["id"],
                index,
                question["question"],
                question["type"],
                question.get("follow_up"),
                json.dumps(question.get("keywords", []), ensure_ascii=False),
                json.dumps(question.get("options", []), ensure_ascii=False),
                question.get("allows_multiple", False),
            )
            for index, question in enumerate(questions, start=1)
        ],
    )

    return {
        "questionnaire_id": questionnaire_id,
        "version": version,
        "title": title,
        "description": description,
        "status": "draft",
        "questionnaire_hash": payload_hash,
    }


@app.get("/questionnaires/active")
def list_active_questionnaires(_: None = Depends(verify_api_key)):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                    questionnaire_id, version, title, description, status,
                    questionnaire_hash, created_at, updated_at, published_at, archived_at
                FROM questionnaire_versions
                WHERE status = 'published'
                ORDER BY title, published_at DESC, version DESC
                """
            )
            version_rows = cur.fetchall()
            questionnaires = []
            for row in version_rows:
                questions = load_questionnaire_questions(cur, row["questionnaire_id"], row["version"])
                questionnaires.append(questionnaire_response(row, questions))

    return {"questionnaires": questionnaires, "count": len(questionnaires)}


@app.get("/admin/questionnaires")
def admin_list_questionnaires(_: None = Depends(verify_api_key)):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                    questionnaire_id, version, title, description, status,
                    questionnaire_hash, created_at, updated_at, published_at, archived_at
                FROM questionnaire_versions
                ORDER BY updated_at DESC, title, version
                """
            )
            version_rows = cur.fetchall()
            questionnaires = []
            for row in version_rows:
                questions = load_questionnaire_questions(cur, row["questionnaire_id"], row["version"])
                questionnaires.append(questionnaire_response(row, questions))

    return {"questionnaires": questionnaires, "count": len(questionnaires)}


@app.post("/admin/questionnaires")
def admin_create_questionnaire(body: QuestionnaireVersionPayload, _: None = Depends(verify_api_key)):
    with get_conn() as conn:
        with conn.cursor() as cur:
            row = save_questionnaire_version(cur, body, require_draft=True)
            questions = load_questionnaire_questions(cur, row["questionnaire_id"], row["version"])
    return {"questionnaire": questionnaire_response(row, questions)}


@app.put("/admin/questionnaires/{questionnaire_id}/versions/{version}")
def admin_update_questionnaire(
    questionnaire_id: str,
    version: str,
    body: QuestionnaireVersionPayload,
    _: None = Depends(verify_api_key),
):
    if body.id != questionnaire_id or body.version != version:
        raise HTTPException(status_code=400, detail="path id/version must match request body")
    with get_conn() as conn:
        with conn.cursor() as cur:
            row = save_questionnaire_version(cur, body, require_draft=True)
            questions = load_questionnaire_questions(cur, row["questionnaire_id"], row["version"])
    return {"questionnaire": questionnaire_response(row, questions)}


@app.post("/admin/questionnaires/{questionnaire_id}/versions/{version}/publish")
def admin_publish_questionnaire(questionnaire_id: str, version: str, _: None = Depends(verify_api_key)):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT questionnaire_id, version, title, description, status, questionnaire_hash,
                       created_at, updated_at, published_at, archived_at
                FROM questionnaire_versions
                WHERE questionnaire_id = %s AND version = %s
                """,
                (questionnaire_id, version),
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="questionnaire version not found")
            if row["status"] == "archived":
                raise HTTPException(status_code=409, detail="archived versions cannot be published")

            questions = load_questionnaire_questions(cur, questionnaire_id, version)
            if not questions:
                raise HTTPException(status_code=400, detail="questionnaire version has no questions")

            cur.execute(
                """
                UPDATE questionnaire_versions
                SET status = 'published',
                    published_at = COALESCE(published_at, CURRENT_TIMESTAMP(6)),
                    archived_at = NULL
                WHERE questionnaire_id = %s AND version = %s
                """,
                (questionnaire_id, version),
            )
            cur.execute(
                """
                SELECT questionnaire_id, version, title, description, status, questionnaire_hash,
                       created_at, updated_at, published_at, archived_at
                FROM questionnaire_versions
                WHERE questionnaire_id = %s AND version = %s
                """,
                (questionnaire_id, version),
            )
            row = cur.fetchone()
    return {"questionnaire": questionnaire_response(row, questions)}


@app.post("/admin/questionnaires/{questionnaire_id}/versions/{version}/archive")
def admin_archive_questionnaire(questionnaire_id: str, version: str, _: None = Depends(verify_api_key)):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE questionnaire_versions
                SET status = 'archived',
                    archived_at = CURRENT_TIMESTAMP(6)
                WHERE questionnaire_id = %s AND version = %s
                """,
                (questionnaire_id, version),
            )
            if cur.rowcount == 0:
                raise HTTPException(status_code=404, detail="questionnaire version not found")
            cur.execute(
                """
                SELECT questionnaire_id, version, title, description, status, questionnaire_hash,
                       created_at, updated_at, published_at, archived_at
                FROM questionnaire_versions
                WHERE questionnaire_id = %s AND version = %s
                """,
                (questionnaire_id, version),
            )
            row = cur.fetchone()
            questions = load_questionnaire_questions(cur, questionnaire_id, version)
    return {"questionnaire": questionnaire_response(row, questions)}


@app.delete("/admin/questionnaires/{questionnaire_id}/versions/{version}")
def admin_delete_questionnaire_version(
    questionnaire_id: str,
    version: str,
    force: bool = False,
    _: None = Depends(verify_api_key),
):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT status
                FROM questionnaire_versions
                WHERE questionnaire_id = %s AND version = %s
                """,
                (questionnaire_id, version),
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="questionnaire version not found")
            cur.execute(
                """
                SELECT COUNT(*) AS count
                FROM session_packages
                WHERE questionnaire_id = %s AND questionnaire_version = %s
                """,
                (questionnaire_id, version),
            )
            package_count = int(cur.fetchone()["count"])
            cur.execute(
                """
                SELECT COUNT(*) AS count
                FROM analysis_answers
                WHERE questionnaire_id = %s AND questionnaire_version = %s
                """,
                (questionnaire_id, version),
            )
            analysis_count = int(cur.fetchone()["count"])
            if (package_count > 0 or analysis_count > 0) and not force:
                raise HTTPException(
                    status_code=409,
                    detail=(
                        "questionnaire version is already referenced by uploaded data; "
                        "archive it instead of deleting, or retry with force=true for test cleanup"
                    ),
                )
            if force:
                cur.execute(
                    """
                    UPDATE session_packages
                    SET questionnaire_id = NULL,
                        questionnaire_version = NULL,
                        questionnaire_hash = NULL
                    WHERE questionnaire_id = %s AND questionnaire_version = %s
                    """,
                    (questionnaire_id, version),
                )
                cur.execute(
                    """
                    UPDATE analysis_answers
                    SET questionnaire_id = NULL,
                        questionnaire_version = NULL
                    WHERE questionnaire_id = %s AND questionnaire_version = %s
                    """,
                    (questionnaire_id, version),
                )
            cur.execute(
                """
                DELETE FROM questionnaire_versions
                WHERE questionnaire_id = %s AND version = %s
                """,
                (questionnaire_id, version),
            )
    return {"deleted": True}


@app.post("/interviewers/resolve", response_model=InterviewerResolveResponse)
def resolve_interviewer(body: InterviewerResolveRequest, _: None = Depends(verify_api_key)):
    name = body.name.strip()
    email = validate_interviewer_email(body.email)

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO interviewers (email, name)
                VALUES (%s, %s)
                ON DUPLICATE KEY UPDATE
                    name = VALUES(name),
                    last_seen_at = CURRENT_TIMESTAMP(6)
                """,
                (email, name),
            )
            cur.execute(
                """
                SELECT email, name
                FROM interviewers
                WHERE email = %s
                """,
                (email,),
            )
            row = cur.fetchone()

    if not row:
        raise HTTPException(status_code=500, detail="interviewer lookup failed")

    return InterviewerResolveResponse(
        interviewer_id=row["email"],
        name=row["name"],
        email=row["email"],
    )


@app.get("/admin/sessions")
def admin_list_sessions(_: None = Depends(verify_api_key)):
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                    session_id, local_session_id, json_path, audio_original_filename,
                    recorded_at_ms, location_label, interviewer_id, interviewer_name,
                    interviewer_email, questionnaire_id, questionnaire_version,
                    questionnaire_hash, answer_count, uploaded_at,
                    admin_location_label, admin_formatted_address,
                    admin_location_lat, admin_location_lon, admin_location_updated_at
                FROM session_packages
                ORDER BY recorded_at_ms DESC, uploaded_at DESC
                LIMIT 500
                """
            )
            rows = cur.fetchall()

    sessions = []
    for row in rows:
        session_id = bytes_to_uuid_hex(row["session_id"])
        json_summary: dict[str, Any] = {}
        try:
            json_summary = admin_json_summary(read_package_json(row["json_path"]))
        except HTTPException as exc:
            logger.warning("admin session summary read failed for %s: %s", session_id, exc.detail)

        admin_location = admin_location_override_from_row(row)
        effective_location = admin_location or {
            "label": json_summary.get("location_label") or row.get("location_label"),
            "formatted_address": json_summary.get("location_formatted_address"),
            "latitude": json_summary.get("location_lat"),
            "longitude": json_summary.get("location_lon"),
            "source": json_summary.get("location_source"),
            "mode": json_summary.get("location_mode"),
            "collection_method": json_summary.get("location_collection_method"),
            "status": json_summary.get("location_status"),
        }

        sessions.append(
            {
                "session_id": session_id,
                "cloud_session_id": json_summary.get("cloud_session_id") or session_id,
                "local_session_id": json_summary.get("local_session_id") or row.get("local_session_id"),
                "created_at": json_summary.get("export_time")
                or (row["uploaded_at"].isoformat() if row.get("uploaded_at") else None),
                "export_time": json_summary.get("export_time"),
                "uploaded_at": row["uploaded_at"].isoformat() if row.get("uploaded_at") else None,
                "respondent_name": json_summary.get("respondent_name"),
                "respondent_email": json_summary.get("respondent_email"),
                "respondent_location": json_summary.get("respondent_location"),
                "interviewer_id": json_summary.get("interviewer_id") or row.get("interviewer_id"),
                "interviewer_name": json_summary.get("interviewer_name") or row.get("interviewer_name"),
                "interviewer_email": json_summary.get("interviewer_email") or row.get("interviewer_email"),
                "location_label": effective_location.get("label"),
                "location_formatted_address": effective_location.get("formatted_address"),
                "location_lat": effective_location.get("latitude"),
                "location_lon": effective_location.get("longitude"),
                "location_source": effective_location.get("source"),
                "location_mode": effective_location.get("mode"),
                "location_collection_method": effective_location.get("collection_method"),
                "location_status": effective_location.get("status"),
                "location_is_admin_override": admin_location is not None,
                "questionnaire_id": json_summary.get("questionnaire_id") or row.get("questionnaire_id"),
                "questionnaire_version": json_summary.get("questionnaire_version") or row.get("questionnaire_version"),
                "questionnaire_title": json_summary.get("questionnaire_title"),
                "questionnaire_hash": json_summary.get("questionnaire_hash") or row.get("questionnaire_hash"),
                "answer_count": json_summary.get("answer_count")
                if json_summary.get("answer_count") is not None
                else row.get("answer_count"),
                "trajectory_point_count": json_summary.get("trajectory_point_count"),
                "audio_filename": json_summary.get("audio_filename") or row.get("audio_original_filename"),
                "recorded_at_ms": _int_or_none(row.get("recorded_at_ms")),
            }
        )

    return {"sessions": sessions, "count": len(sessions)}


@app.get("/admin/sessions/{session_id}")
def admin_get_session(session_id: str, _: None = Depends(verify_api_key)):
    try:
        session_bytes = uuid_to_bytes(UUID(hex=session_id))
    except ValueError as e:
        raise HTTPException(status_code=400, detail="session_id must be a UUID") from e

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT json_path, admin_location_label, admin_formatted_address,
                       admin_location_lat, admin_location_lon, admin_location_updated_at
                FROM session_packages
                WHERE session_id = %s
                """,
                (session_bytes,),
            )
            row = cur.fetchone()

    if not row:
        raise HTTPException(status_code=404, detail="session package not found")

    package_data = read_package_json(row["json_path"])
    package_data["admin_location_override"] = admin_location_override_from_row(row)
    return package_data


@app.get("/admin/sessions/{session_id}/audio")
def admin_get_session_audio(
    session_id: str,
    download: bool = False,
    _: None = Depends(verify_api_key),
):
    try:
        session_bytes = uuid_to_bytes(UUID(hex=session_id))
    except ValueError as e:
        raise HTTPException(status_code=400, detail="session_id must be a UUID") from e

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT audio_path, audio_original_filename
                FROM session_packages
                WHERE session_id = %s
                """,
                (session_bytes,),
            )
            row = cur.fetchone()

    if not row:
        raise HTTPException(status_code=404, detail="session package not found")

    audio_path = safe_package_path(row.get("audio_path"))
    if audio_path is None or not audio_path.is_file():
        raise HTTPException(status_code=404, detail="audio file not found on server")

    original_filename = sanitize_filename(
        row.get("audio_original_filename") or audio_path.name
    )
    media_type = (
        "audio/mp4"
        if audio_path.suffix.lower() == ".m4a"
        else mimetypes.guess_type(original_filename)[0] or "application/octet-stream"
    )
    return FileResponse(
        audio_path,
        media_type=media_type,
        filename=original_filename,
        content_disposition_type="attachment" if download else "inline",
    )


@app.put("/admin/sessions/{session_id}/location")
def admin_update_session_location(
    session_id: str,
    body: AdminLocationOverridePayload,
    _: None = Depends(verify_api_key),
):
    try:
        session_bytes = uuid_to_bytes(UUID(hex=session_id))
    except ValueError as e:
        raise HTTPException(status_code=400, detail="session_id must be a UUID") from e

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT json_path, admin_location_label, admin_formatted_address,
                       admin_location_lat, admin_location_lon, admin_location_updated_at
                FROM session_packages
                WHERE session_id = %s
                FOR UPDATE
                """,
                (session_bytes,),
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="session package not found")

            has_existing_override = admin_location_override_from_row(row) is not None
            package_data = read_package_json(row["json_path"])
            if original_package_has_location(package_data) and not has_existing_override:
                raise HTTPException(
                    status_code=409,
                    detail="the original session package already contains location data",
                )

            cur.execute(
                """
                UPDATE session_packages
                SET admin_location_label = %s,
                    admin_formatted_address = %s,
                    admin_location_lat = %s,
                    admin_location_lon = %s,
                    admin_location_updated_at = CURRENT_TIMESTAMP(6)
                WHERE session_id = %s
                """,
                (
                    body.label.strip(),
                    body.formatted_address.strip(),
                    body.latitude,
                    body.longitude,
                    session_bytes,
                ),
            )
            cur.execute(
                """
                SELECT admin_location_label, admin_formatted_address,
                       admin_location_lat, admin_location_lon, admin_location_updated_at
                FROM session_packages
                WHERE session_id = %s
                """,
                (session_bytes,),
            )
            updated_row = cur.fetchone()

    return {"location": admin_location_override_from_row(updated_row)}


@app.delete("/admin/sessions/{session_id}")
def admin_delete_session(session_id: str, _: None = Depends(verify_api_key)):
    try:
        session_bytes = uuid_to_bytes(UUID(hex=session_id))
    except ValueError as e:
        raise HTTPException(status_code=400, detail="session_id must be a UUID") from e

    package_dir: Path | None = None
    deleted_db_rows = 0

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT package_dir, json_path, audio_path
                FROM session_packages
                WHERE session_id = %s
                """,
                (session_bytes,),
            )
            package_row = cur.fetchone()
            if not package_row:
                raise HTTPException(status_code=404, detail="session package not found")

            package_dir = safe_package_path(package_row.get("package_dir"))
            if package_dir is None:
                json_path = safe_package_path(package_row.get("json_path"))
                package_dir = json_path.parent if json_path else None

            cleanup_statements = [
                ("DELETE FROM analysis_answers WHERE session_id = %s", (session_bytes,)),
                ("DELETE FROM session_packages WHERE session_id = %s", (session_bytes,)),
                ("DELETE FROM survey_sessions WHERE id = %s", (session_bytes,)),
            ]
            for sql, params in cleanup_statements:
                delete_if_table_exists(cur, sql, params)
                deleted_db_rows += cur.rowcount if cur.rowcount > 0 else 0

    deleted_paths: list[str] = []
    if package_dir and package_dir.exists():
        try:
            if package_dir.is_dir():
                shutil.rmtree(package_dir)
            else:
                package_dir.unlink()
            deleted_paths.append(str(package_dir))
        except Exception as e:
            logger.exception("failed to delete session package folder")
            raise HTTPException(status_code=500, detail="database rows deleted but package folder cleanup failed") from e

    return {
        "deleted": True,
        "session_id": session_id,
        "deleted_db_rows": deleted_db_rows,
        "deleted_paths": deleted_paths,
    }


class SessionCreate(BaseModel):
    questionnaire_version: str = Field(default="1")
    questionnaire_id: str | None = Field(default=None, max_length=64)
    app_version: str | None = None
    locale: str | None = None
    respondent_id: str | None = Field(
        default=None,
        description="Optional UUID hex; if omitted a new respondent is created.",
    )
    local_session_id: str | None = Field(
        default=None,
        min_length=1,
        max_length=64,
        description="Optional durable client session ID used to make creation idempotent.",
    )


class SessionCreateResponse(BaseModel):
    respondent_id: str
    session_id: str
    questionnaire_version: str
    questionnaire_id: str | None = None


@app.post("/sessions", response_model=SessionCreateResponse)
def create_session(body: SessionCreate, _: None = Depends(verify_api_key)):
    if body.local_session_id:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT respondent_id, session_id
                    FROM session_creation_keys
                    WHERE local_session_id = %s
                    """,
                    (body.local_session_id,),
                )
                existing = cur.fetchone()
        if existing:
            return SessionCreateResponse(
                respondent_id=bytes_to_uuid_hex(existing["respondent_id"]),
                session_id=bytes_to_uuid_hex(existing["session_id"]),
                questionnaire_version=body.questionnaire_version,
                questionnaire_id=body.questionnaire_id,
            )

    if body.respondent_id:
        try:
            rid = UUID(hex=body.respondent_id)
        except ValueError as e:
            raise HTTPException(status_code=400, detail="respondent_id must be a UUID") from e
        respondent_bytes = uuid_to_bytes(rid)
    else:
        respondent_bytes = uuid_to_bytes(uuid4())

    session_id = uuid4()
    session_bytes = uuid_to_bytes(session_id)

    with get_conn() as conn:
        with conn.cursor() as cur:
            if body.local_session_id:
                cur.execute(
                    "SELECT GET_LOCK(SHA2(%s, 256), 10) AS acquired",
                    (body.local_session_id,),
                )
                if cur.fetchone()["acquired"] != 1:
                    raise HTTPException(status_code=503, detail="session creation is busy; retry safely")
                cur.execute(
                    """
                    SELECT respondent_id, session_id
                    FROM session_creation_keys
                    WHERE local_session_id = %s
                    """,
                    (body.local_session_id,),
                )
                existing = cur.fetchone()
                if existing:
                    return SessionCreateResponse(
                        respondent_id=bytes_to_uuid_hex(existing["respondent_id"]),
                        session_id=bytes_to_uuid_hex(existing["session_id"]),
                        questionnaire_version=body.questionnaire_version,
                        questionnaire_id=body.questionnaire_id,
                    )
            if not body.respondent_id:
                cur.execute(
                    """
                    INSERT INTO respondents (id, app_version, locale)
                    VALUES (%s, %s, %s)
                    """,
                    (respondent_bytes, body.app_version, body.locale),
                )
            else:
                cur.execute(
                    "SELECT id FROM respondents WHERE id = %s",
                    (respondent_bytes,),
                )
                if not cur.fetchone():
                    raise HTTPException(status_code=404, detail="respondent not found")

            cur.execute(
                """
                INSERT INTO survey_sessions (id, respondent_id, questionnaire_version, status)
                VALUES (%s, %s, %s, 'in_progress')
                """,
                (session_bytes, respondent_bytes, body.questionnaire_version),
            )
            if body.local_session_id:
                cur.execute(
                    """
                    INSERT INTO session_creation_keys (
                        local_session_id, session_id, respondent_id
                    ) VALUES (%s, %s, %s)
                    """,
                    (body.local_session_id, session_bytes, respondent_bytes),
                )

    return SessionCreateResponse(
        respondent_id=bytes_to_uuid_hex(respondent_bytes),
        session_id=str(session_id),
        questionnaire_version=body.questionnaire_version,
        questionnaire_id=body.questionnaire_id,
    )


@app.post("/sessions/{session_id}/package")
def upload_session_package(
    session_id: str,
    session_json: UploadFile = File(...),
    audio: UploadFile | None = File(default=None),
    local_session_id: str | None = Form(default=None),
    _: None = Depends(verify_api_key),
):
    try:
        sid = UUID(hex=session_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail="session_id must be a UUID") from e
    session_bytes = uuid_to_bytes(sid)

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, respondent_id FROM survey_sessions WHERE id = %s",
                (session_bytes,),
            )
            session_row = cur.fetchone()
            if not session_row:
                raise HTTPException(status_code=404, detail="session not found")
            respondent_bytes = session_row["respondent_id"]

    session_dir = SURVEY_PACKAGE_STORAGE_DIR / session_id
    session_dir.mkdir(parents=True, exist_ok=True)

    json_path = session_dir / "session.json"
    json_bytes, json_sha256 = write_upload_file(session_json, json_path, SESSION_JSON_MAX_BYTES)

    try:
        package_data = json.loads(json_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        json_path.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail="session_json must be valid JSON") from e

    if not isinstance(package_data, dict):
        json_path.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail="session_json must be a JSON object")

    summary = safe_json_summary(package_data)
    if not local_session_id:
        local_session_id = summary.get("local_session_id")

    audio_relative_path = None
    audio_original_filename = None
    audio_bytes = None
    audio_sha256 = None
    if audio is not None:
        audio_original_filename = sanitize_filename(audio.filename or "recording.m4a")
        audio_path = session_dir / audio_original_filename
        try:
            audio_bytes, audio_sha256 = write_upload_file(audio, audio_path, AUDIO_MAX_BYTES)
        except Exception:
            json_path.unlink(missing_ok=True)
            raise
        audio_relative_path = str(Path(session_id) / audio_path.name)

    json_relative_path = str(Path(session_id) / "session.json")
    package_dir_relative_path = session_id
    analysis_answer_count = 0

    try:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO session_packages (
                        session_id, respondent_id, local_session_id, package_dir,
                        json_path, json_file_size_bytes, json_sha256,
                        audio_path, audio_original_filename, audio_file_size_bytes, audio_sha256,
                        recorded_at_ms, location_label, interviewer_id, interviewer_name,
                        interviewer_email, questionnaire_id, questionnaire_version, questionnaire_hash,
                        gps_lat, gps_lon,
                        answer_count, transcript_chars
                    )
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    ON DUPLICATE KEY UPDATE
                        local_session_id = VALUES(local_session_id),
                        package_dir = VALUES(package_dir),
                        json_path = VALUES(json_path),
                        json_file_size_bytes = VALUES(json_file_size_bytes),
                        json_sha256 = VALUES(json_sha256),
                        audio_path = VALUES(audio_path),
                        audio_original_filename = VALUES(audio_original_filename),
                        audio_file_size_bytes = VALUES(audio_file_size_bytes),
                        audio_sha256 = VALUES(audio_sha256),
                        recorded_at_ms = VALUES(recorded_at_ms),
                        location_label = VALUES(location_label),
                        interviewer_id = VALUES(interviewer_id),
                        interviewer_name = VALUES(interviewer_name),
                        interviewer_email = VALUES(interviewer_email),
                        questionnaire_id = VALUES(questionnaire_id),
                        questionnaire_version = VALUES(questionnaire_version),
                        questionnaire_hash = VALUES(questionnaire_hash),
                        gps_lat = VALUES(gps_lat),
                        gps_lon = VALUES(gps_lon),
                        answer_count = VALUES(answer_count),
                        transcript_chars = VALUES(transcript_chars),
                        uploaded_at = CURRENT_TIMESTAMP(6)
                    """,
                    (
                        session_bytes,
                        respondent_bytes,
                        local_session_id,
                        package_dir_relative_path,
                        json_relative_path,
                        json_bytes,
                        json_sha256,
                        audio_relative_path,
                        audio_original_filename,
                        audio_bytes,
                        audio_sha256,
                        summary.get("recorded_at_ms"),
                        summary.get("location_label"),
                        summary.get("interviewer_id"),
                        summary.get("interviewer_name"),
                        summary.get("interviewer_email"),
                        summary.get("questionnaire_id"),
                        summary.get("questionnaire_version"),
                        summary.get("questionnaire_hash"),
                        summary.get("gps_lat"),
                        summary.get("gps_lon"),
                        summary.get("answer_count"),
                        summary.get("transcript_chars"),
                    ),
                )
                analysis_answer_count = replace_analysis_answers(
                    cur,
                    session_bytes=session_bytes,
                    respondent_bytes=respondent_bytes,
                    package_data=package_data,
                    source_json_path=json_relative_path,
                )
    except Exception as e:
        if audio_relative_path:
            (session_dir / Path(audio_relative_path).name).unlink(missing_ok=True)
        json_path.unlink(missing_ok=True)
        if isinstance(e, (IntegrityError, OperationalError)):
            logger.exception("session package index upsert failed")
            raise HTTPException(
                status_code=500,
                detail="session package index failed; did you apply server/schema.sql?",
            ) from e
        logger.exception("session package processing failed")
        raise HTTPException(status_code=500, detail="session package processing failed") from e

    return {
        "session_id": session_id,
        "respondent_id": bytes_to_uuid_hex(respondent_bytes),
        "package_dir": package_dir_relative_path,
        "json_path": json_relative_path,
        "audio_path": audio_relative_path,
        "json_file_size_bytes": json_bytes,
        "audio_file_size_bytes": audio_bytes,
        "json_sha256": json_sha256,
        "audio_sha256": audio_sha256,
        "analysis_answer_count": analysis_answer_count,
    }


class ClarificationAnswerPayload(BaseModel):
    clarification_id: str = Field(min_length=1, max_length=64)
    matched_index: int = Field(ge=0)
    final_answer: str = Field(min_length=1, max_length=4000)
    note: str | None = Field(default=None, max_length=4000)
    selected_option_codes: list[str] | None = None
    selected_option_labels: list[str] | None = None
    use_original_answer: bool = False


class ClarificationSubmissionPayload(BaseModel):
    expected_revision: int = Field(ge=1)
    answers: list[ClarificationAnswerPayload] = Field(min_length=1)


def _processing_job_row(session_bytes: bytes) -> dict[str, Any] | None:
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM processing_jobs WHERE session_id = %s", (session_bytes,))
            return cur.fetchone()


def _processing_job_payload(row: dict[str, Any]) -> dict[str, Any]:
    status = str(row.get("status") or "queued")
    payload: dict[str, Any] = {
        "session_id": bytes_to_uuid_hex(row["session_id"]),
        "respondent_id": bytes_to_uuid_hex(row["respondent_id"]),
        "local_session_id": row.get("local_session_id"),
        "status": status,
        "revision": int(row.get("revision") or 1),
        "attempt_count": int(row.get("attempt_count") or 0),
        "updated_at": row.get("updated_at").isoformat() if row.get("updated_at") else None,
        "completed_at": row.get("completed_at").isoformat() if row.get("completed_at") else None,
        "error_category": row.get("error_category"),
        "error_message": row.get("error_message"),
        "result_available": bool(row.get("result_json_path")),
        "clarifications": [],
    }
    if status == "needs_review" and row.get("draft_analysis_path"):
        draft_path = safe_package_path(row["draft_analysis_path"])
        if draft_path and draft_path.is_file():
            draft = json.loads(draft_path.read_text(encoding="utf-8"))
            payload["clarifications"] = clarification_requests(
                str(draft.get("transcript") or ""),
                draft.get("matches") if isinstance(draft.get("matches"), list) else [],
                draft.get("questions") if isinstance(draft.get("questions"), list) else [],
            )
    return payload


@app.post("/sessions/{session_id}/processing-input", status_code=202)
def upload_processing_input(
    session_id: str,
    input_manifest: UploadFile = File(...),
    audio: UploadFile = File(...),
    local_session_id: str | None = Form(default=None),
    _: None = Depends(verify_api_key),
):
    try:
        sid = UUID(hex=session_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="session_id must be a UUID") from exc
    session_bytes = uuid_to_bytes(sid)
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT id, respondent_id FROM survey_sessions WHERE id = %s", (session_bytes,)
            )
            session_row = cur.fetchone()
    if not session_row:
        raise HTTPException(status_code=404, detail="session not found")

    session_dir = SURVEY_PACKAGE_STORAGE_DIR / session_id
    session_dir.mkdir(parents=True, exist_ok=True)
    incoming_manifest = session_dir / f".processing_input.{uuid4().hex}.json"
    incoming_audio = session_dir / f".processing_audio.{uuid4().hex}.m4a"
    try:
        manifest_bytes, manifest_sha256 = write_upload_file(
            input_manifest, incoming_manifest, PROCESSING_INPUT_MAX_BYTES
        )
        try:
            manifest_data = json.loads(incoming_manifest.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise HTTPException(status_code=400, detail="input_manifest must be valid JSON") from exc
        if not isinstance(manifest_data, dict):
            raise HTTPException(status_code=400, detail="input_manifest must be a JSON object")
        manifest_local_id = manifest_data.get("local_session_id")
        if not local_session_id:
            local_session_id = manifest_local_id
        if not isinstance(local_session_id, str) or not local_session_id.strip():
            raise HTTPException(status_code=400, detail="local_session_id is required")
        if manifest_local_id and manifest_local_id != local_session_id:
            raise HTTPException(status_code=409, detail="local_session_id does not match input_manifest")

        audio_bytes, audio_sha256 = write_upload_file(
            audio, incoming_audio, min(AUDIO_MAX_BYTES, TRANSCRIPTION_AUDIO_MAX_BYTES)
        )
        existing = _processing_job_row(session_bytes)
        if existing:
            same_input = (
                existing.get("input_manifest_sha256") == manifest_sha256
                and existing.get("audio_sha256") == audio_sha256
                and existing.get("local_session_id") == local_session_id
            )
            if not same_input:
                raise HTTPException(
                    status_code=409,
                    detail="this session already has different processing input",
                )
            return _processing_job_payload(existing)

        canonical_manifest = session_dir / "processing_input.json"
        audio_filename = sanitize_filename(audio.filename or "recording.m4a")
        canonical_audio = session_dir / audio_filename
        os.replace(incoming_manifest, canonical_manifest)
        os.replace(incoming_audio, canonical_audio)
        manifest_relative = str(Path(session_id) / canonical_manifest.name)
        audio_relative = str(Path(session_id) / canonical_audio.name)
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO processing_jobs (
                        session_id, respondent_id, local_session_id, status,
                        input_manifest_path, input_manifest_sha256,
                        audio_path, audio_original_filename, audio_file_size_bytes, audio_sha256
                    ) VALUES (%s, %s, %s, 'queued', %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        session_bytes,
                        session_row["respondent_id"],
                        local_session_id,
                        manifest_relative,
                        manifest_sha256,
                        audio_relative,
                        audio_filename,
                        audio_bytes,
                        audio_sha256,
                    ),
                )
        row = _processing_job_row(session_bytes)
        if not row:
            raise HTTPException(status_code=500, detail="processing job was not persisted")
        return _processing_job_payload(row)
    except HTTPException:
        raise
    except (IntegrityError, OperationalError) as exc:
        logger.exception("processing input could not be indexed")
        raise HTTPException(
            status_code=500,
            detail="processing job index failed; apply the server processing schema",
        ) from exc
    finally:
        incoming_manifest.unlink(missing_ok=True)
        incoming_audio.unlink(missing_ok=True)


@app.get("/processing-jobs/{session_id}")
def get_processing_job(session_id: str, _: None = Depends(verify_api_key)):
    try:
        session_bytes = uuid_to_bytes(UUID(hex=session_id))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="session_id must be a UUID") from exc
    row = _processing_job_row(session_bytes)
    if not row:
        raise HTTPException(status_code=404, detail="processing job not found")
    return _processing_job_payload(row)


@app.get("/processing-jobs/{session_id}/result")
def get_processing_result(session_id: str, _: None = Depends(verify_api_key)):
    try:
        session_bytes = uuid_to_bytes(UUID(hex=session_id))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="session_id must be a UUID") from exc
    row = _processing_job_row(session_bytes)
    if not row:
        raise HTTPException(status_code=404, detail="processing job not found")
    if row.get("status") != "completed" or not row.get("result_json_path"):
        raise HTTPException(status_code=409, detail="processing result is not ready")
    return read_package_json(row["result_json_path"])


@app.post("/processing-jobs/{session_id}/retry", status_code=202)
def retry_processing_job(session_id: str, _: None = Depends(verify_api_key)):
    try:
        session_bytes = uuid_to_bytes(UUID(hex=session_id))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="session_id must be a UUID") from exc
    row = _processing_job_row(session_bytes)
    if not row:
        raise HTTPException(status_code=404, detail="processing job not found")
    if row.get("status") not in {"failed_retryable", "failed_terminal"}:
        return _processing_job_payload(row)
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE processing_jobs
                SET status = 'queued', attempt_count = 0, next_attempt_at = NULL,
                    lease_owner = NULL, lease_expires_at = NULL,
                    error_category = NULL, error_message = NULL
                WHERE session_id = %s
                """,
                (session_bytes,),
            )
    return _processing_job_payload(_processing_job_row(session_bytes))


def _index_generated_package(
    *,
    cur,
    session_bytes: bytes,
    respondent_bytes: bytes,
    package_data: dict[str, Any],
    package_dir_relative: str,
    json_relative: str,
    json_bytes: int,
    json_sha256: str,
    audio_relative: str,
    audio_filename: str,
    audio_bytes: int,
    audio_sha256: str,
) -> int:
    summary = safe_json_summary(package_data)
    cur.execute(
        """
        INSERT INTO session_packages (
            session_id, respondent_id, local_session_id, package_dir,
            json_path, json_file_size_bytes, json_sha256,
            audio_path, audio_original_filename, audio_file_size_bytes, audio_sha256,
            recorded_at_ms, location_label, interviewer_id, interviewer_name,
            interviewer_email, questionnaire_id, questionnaire_version, questionnaire_hash,
            gps_lat, gps_lon, answer_count, transcript_chars
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        ON DUPLICATE KEY UPDATE
            local_session_id = VALUES(local_session_id), package_dir = VALUES(package_dir),
            json_path = VALUES(json_path), json_file_size_bytes = VALUES(json_file_size_bytes),
            json_sha256 = VALUES(json_sha256), audio_path = VALUES(audio_path),
            audio_original_filename = VALUES(audio_original_filename),
            audio_file_size_bytes = VALUES(audio_file_size_bytes), audio_sha256 = VALUES(audio_sha256),
            recorded_at_ms = VALUES(recorded_at_ms), location_label = VALUES(location_label),
            interviewer_id = VALUES(interviewer_id), interviewer_name = VALUES(interviewer_name),
            interviewer_email = VALUES(interviewer_email), questionnaire_id = VALUES(questionnaire_id),
            questionnaire_version = VALUES(questionnaire_version), questionnaire_hash = VALUES(questionnaire_hash),
            gps_lat = VALUES(gps_lat), gps_lon = VALUES(gps_lon), answer_count = VALUES(answer_count),
            transcript_chars = VALUES(transcript_chars), uploaded_at = CURRENT_TIMESTAMP(6)
        """,
        (
            session_bytes,
            respondent_bytes,
            summary.get("local_session_id"),
            package_dir_relative,
            json_relative,
            json_bytes,
            json_sha256,
            audio_relative,
            audio_filename,
            audio_bytes,
            audio_sha256,
            summary.get("recorded_at_ms"),
            summary.get("location_label"),
            summary.get("interviewer_id"),
            summary.get("interviewer_name"),
            summary.get("interviewer_email"),
            summary.get("questionnaire_id"),
            summary.get("questionnaire_version"),
            summary.get("questionnaire_hash"),
            summary.get("gps_lat"),
            summary.get("gps_lon"),
            summary.get("answer_count"),
            summary.get("transcript_chars"),
        ),
    )
    return replace_analysis_answers(
        cur,
        session_bytes=session_bytes,
        respondent_bytes=respondent_bytes,
        package_data=package_data,
        source_json_path=json_relative,
    )


def _finalize_processing_job(row: dict[str, Any], draft: dict[str, Any], revision: int) -> None:
    session_id = bytes_to_uuid_hex(row["session_id"])
    session_dir = SURVEY_PACKAGE_STORAGE_DIR / session_id
    audio_path = safe_package_path(row["audio_path"])
    if not audio_path or not audio_path.is_file():
        raise ServerProcessingError("stored processing audio is missing")
    package = build_session_package(
        draft["input_manifest"],
        cloud_session_id=session_id,
        cloud_respondent_id=bytes_to_uuid_hex(row["respondent_id"]),
        audio_file_name=row["audio_original_filename"],
        audio_file_size=int(row["audio_file_size_bytes"]),
        transcript=draft["transcript"],
        matches=draft["matches"],
        revision=revision,
    )
    result_path = session_dir / "session.json"
    json_bytes, json_sha256 = write_json_atomic(result_path, package)
    json_relative = str(Path(session_id) / "session.json")
    with get_conn() as conn:
        with conn.cursor() as cur:
            _index_generated_package(
                cur=cur,
                session_bytes=row["session_id"],
                respondent_bytes=row["respondent_id"],
                package_data=package,
                package_dir_relative=session_id,
                json_relative=json_relative,
                json_bytes=json_bytes,
                json_sha256=json_sha256,
                audio_relative=row["audio_path"],
                audio_filename=row["audio_original_filename"],
                audio_bytes=int(row["audio_file_size_bytes"]),
                audio_sha256=row["audio_sha256"],
            )
            cur.execute(
                """
                UPDATE processing_jobs
                SET status = 'completed', revision = %s, result_json_path = %s,
                    result_json_sha256 = %s, completed_at = CURRENT_TIMESTAMP(6),
                    lease_owner = NULL, lease_expires_at = NULL,
                    error_category = NULL, error_message = NULL
                WHERE session_id = %s
                """,
                (revision, json_relative, json_sha256, row["session_id"]),
            )
            cur.execute(
                "UPDATE survey_sessions SET status = 'completed' WHERE id = %s",
                (row["session_id"],),
            )


@app.post("/processing-jobs/{session_id}/clarifications")
def submit_processing_clarifications(
    session_id: str,
    body: ClarificationSubmissionPayload,
    _: None = Depends(verify_api_key),
):
    try:
        session_bytes = uuid_to_bytes(UUID(hex=session_id))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="session_id must be a UUID") from exc
    row = _processing_job_row(session_bytes)
    if not row:
        raise HTTPException(status_code=404, detail="processing job not found")
    if row.get("status") != "needs_review":
        raise HTTPException(status_code=409, detail="processing job is not awaiting clarification")
    if int(row.get("revision") or 1) != body.expected_revision:
        raise HTTPException(status_code=409, detail="processing result revision changed; refresh first")
    draft_path = safe_package_path(row.get("draft_analysis_path"))
    if not draft_path or not draft_path.is_file():
        raise HTTPException(status_code=500, detail="clarification draft is missing")
    draft = json.loads(draft_path.read_text(encoding="utf-8"))
    matches = draft.get("matches")
    if not isinstance(matches, list):
        raise HTTPException(status_code=500, detail="clarification draft is invalid")
    for answer in body.answers:
        if answer.matched_index >= len(matches):
            raise HTTPException(status_code=400, detail="clarification matched_index is invalid")
        match = matches[answer.matched_index]
        if not isinstance(match, dict):
            raise HTTPException(status_code=500, detail="clarification match is invalid")
        is_follow_up = answer.clarification_id == f"match-{answer.matched_index}-follow-up"
        expected_main_id = f"match-{answer.matched_index}"
        if not is_follow_up and answer.clarification_id != expected_main_id:
            raise HTTPException(status_code=400, detail="clarification_id does not match matched_index")
        target = match.get("follow_up") if is_follow_up else match
        if not isinstance(target, dict):
            raise HTTPException(status_code=400, detail="clarification target is missing")
        original_answer = target.get("extracted_answer")
        if answer.use_original_answer:
            if not isinstance(original_answer, str) or not original_answer.strip():
                raise HTTPException(status_code=400, detail="clarification has no original answer to accept")
            target["final_answer"] = original_answer.strip()
        else:
            target["final_answer"] = answer.final_answer.strip()
        target["manually_clarified"] = True
        target["clarification_needed"] = False
        target["clarification_note"] = answer.note.strip() if answer.note else None
        target["answer_source"] = "accepted_model_answer" if answer.use_original_answer else "manual_clarification"
        if not is_follow_up:
            if answer.selected_option_codes is not None:
                target["selected_option_codes"] = answer.selected_option_codes
            if answer.selected_option_labels is not None:
                target["selected_option_labels"] = answer.selected_option_labels
    next_revision = body.expected_revision + 1
    draft["matches"] = matches
    write_json_atomic(draft_path, draft)
    unresolved = any(needs_clarification(match) for match in matches if isinstance(match, dict))
    if unresolved:
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE processing_jobs SET revision = %s WHERE session_id = %s",
                    (next_revision, session_bytes),
                )
    else:
        row["revision"] = next_revision
        _finalize_processing_job(row, draft, next_revision)
    refreshed = _processing_job_row(session_bytes)
    return _processing_job_payload(refreshed)


def claim_next_processing_job(worker_id: str | None = None) -> dict[str, Any] | None:
    worker_id = worker_id or f"{socket.gethostname()}-{os.getpid()}"
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    lease_until = now + timedelta(seconds=PROCESSING_JOB_LEASE_SECONDS)
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT * FROM processing_jobs
                WHERE (
                    status IN ('queued', 'failed_retryable')
                    OR (status IN ('transcribing', 'analyzing') AND lease_expires_at < %s)
                )
                  AND (next_attempt_at IS NULL OR next_attempt_at <= %s)
                  AND attempt_count < %s
                ORDER BY created_at
                LIMIT 1
                FOR UPDATE SKIP LOCKED
                """,
                (now, now, PROCESSING_JOB_MAX_ATTEMPTS),
            )
            row = cur.fetchone()
            if not row:
                return None
            cur.execute(
                """
                UPDATE processing_jobs
                SET status = 'transcribing', lease_owner = %s, lease_expires_at = %s,
                    attempt_count = attempt_count + 1, error_category = NULL, error_message = NULL
                WHERE session_id = %s
                """,
                (worker_id, lease_until, row["session_id"]),
            )
            row["lease_owner"] = worker_id
            row["attempt_count"] = int(row.get("attempt_count") or 0) + 1
            return row


def process_claimed_job(row: dict[str, Any]) -> None:
    session_id = bytes_to_uuid_hex(row["session_id"])
    session_dir = SURVEY_PACKAGE_STORAGE_DIR / session_id
    manifest_path = safe_package_path(row["input_manifest_path"])
    audio_path = safe_package_path(row["audio_path"])
    if not manifest_path or not manifest_path.is_file() or not audio_path or not audio_path.is_file():
        raise ServerProcessingError("stored processing input is missing")
    input_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    questionnaire = input_manifest.get("questionnaire_snapshot")
    questions = questionnaire.get("questions") if isinstance(questionnaire, dict) else None
    if not isinstance(questions, list) or not questions:
        raise ServerProcessingError("processing input has no questionnaire questions")

    transcript_path = session_dir / "transcript.txt"
    raw_transcription_path = session_dir / "raw_transcription_response.json"
    if transcript_path.is_file() and transcript_path.stat().st_size > 0:
        transcript = transcript_path.read_text(encoding="utf-8").strip()
    else:
        transcript, raw_transcription = transcribe_audio(audio_path)
        write_text_atomic(transcript_path, transcript)
        write_json_atomic(raw_transcription_path, raw_transcription)

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE processing_jobs
                SET status = 'analyzing', transcript_path = %s, raw_transcription_path = %s,
                    lease_expires_at = %s
                WHERE session_id = %s
                """,
                (
                    str(Path(session_id) / transcript_path.name),
                    str(Path(session_id) / raw_transcription_path.name),
                    datetime.now(timezone.utc).replace(tzinfo=None)
                    + timedelta(seconds=PROCESSING_JOB_LEASE_SECONDS),
                    row["session_id"],
                ),
            )

    raw_analysis_path = session_dir / "raw_analysis_response.json"
    draft_path = session_dir / "draft_analysis.json"
    if draft_path.is_file() and draft_path.stat().st_size > 0:
        draft = json.loads(draft_path.read_text(encoding="utf-8"))
    else:
        raw_matches, raw_analysis = analyze_transcript(transcript, questions)
        matches = validate_matches(
            raw_matches,
            questions,
            input_manifest.get("interviewer_checked_option_codes_by_question_id")
            if isinstance(input_manifest.get("interviewer_checked_option_codes_by_question_id"), dict)
            else {},
            transcript=transcript,
        )
        draft = {
            "input_manifest": input_manifest,
            "transcript": transcript,
            "questions": questions,
            "matches": matches,
        }
        write_json_atomic(raw_analysis_path, raw_analysis)
        write_json_atomic(draft_path, draft)

    relative_raw_analysis = str(Path(session_id) / raw_analysis_path.name)
    relative_draft = str(Path(session_id) / draft_path.name)
    if any(needs_clarification(match) for match in draft["matches"]):
        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE processing_jobs
                    SET status = 'needs_review', raw_analysis_path = %s,
                        draft_analysis_path = %s, lease_owner = NULL, lease_expires_at = NULL
                    WHERE session_id = %s
                    """,
                    (relative_raw_analysis, relative_draft, row["session_id"]),
                )
        return
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE processing_jobs SET raw_analysis_path = %s, draft_analysis_path = %s WHERE session_id = %s",
                (relative_raw_analysis, relative_draft, row["session_id"]),
            )
    row["draft_analysis_path"] = relative_draft
    _finalize_processing_job(row, draft, int(row.get("revision") or 1))


def fail_processing_job(row: dict[str, Any], error: Exception) -> None:
    attempts = int(row.get("attempt_count") or 1)
    terminal = attempts >= PROCESSING_JOB_MAX_ATTEMPTS
    status = "failed_terminal" if terminal else "failed_retryable"
    delay_seconds = min(7200, 30 * (2 ** max(0, attempts - 1)))
    next_attempt = None if terminal else (
        datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(seconds=delay_seconds)
    )
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE processing_jobs
                SET status = %s, next_attempt_at = %s, lease_owner = NULL,
                    lease_expires_at = NULL, error_category = %s, error_message = %s
                WHERE session_id = %s
                """,
                (
                    status,
                    next_attempt,
                    error.__class__.__name__[:64],
                    str(error)[:4000],
                    row["session_id"],
                ),
            )
