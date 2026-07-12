from __future__ import annotations

import json
import logging
import os
import hashlib
import shutil
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Optional
from uuid import UUID, uuid4

import pymysql
from pymysql.err import IntegrityError, MySQLError, OperationalError
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

load_dotenv()

MYSQL_HOST = os.environ["MYSQL_HOST"]
MYSQL_PORT = int(os.environ.get("MYSQL_PORT", "3306"))
MYSQL_USER = os.environ["MYSQL_USER"]
MYSQL_PASSWORD = os.environ["MYSQL_PASSWORD"]
MYSQL_DATABASE = os.environ["MYSQL_DATABASE"]
API_KEY = os.environ.get("API_KEY", "").strip()
AUDIO_STORAGE_DIR = Path(os.environ.get("AUDIO_STORAGE_DIR", "uploaded_audio")).expanduser()
SURVEY_PACKAGE_STORAGE_DIR = Path(
    os.environ.get("SURVEY_PACKAGE_STORAGE_DIR", "survey_session_packages")
).expanduser()
AUDIO_MAX_BYTES = int(os.environ.get("AUDIO_MAX_BYTES", str(200 * 1024 * 1024)))
SESSION_JSON_MAX_BYTES = int(os.environ.get("SESSION_JSON_MAX_BYTES", str(25 * 1024 * 1024)))

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
    gps = data.get("recording_start_trajectory_point")
    if not isinstance(gps, dict):
        location = data.get("location")
        gps = location if isinstance(location, dict) else {}

    matched_questions = data.get("matched_questions")
    answers = matched_questions if isinstance(matched_questions, list) else []
    transcript = data.get("transcription")
    questionnaire = questionnaire_identity(data)

    return {
        "local_session_id": data.get("local_session_id") or data.get("session_id"),
        "location_label": respondent_info.get("location") or data.get("location_label"),
        "interviewer_id": interviewer_info.get("interviewer_id") or interviewer_info.get("email"),
        "interviewer_name": interviewer_info.get("name"),
        "interviewer_email": interviewer_info.get("email"),
        "gps_lat": gps.get("lat"),
        "gps_lon": gps.get("lon"),
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
        SELECT question_id, order_index, prompt, answer_type, follow_up, keywords_json
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
        questions.append(
            {
                "id": questionnaire_question_id_value(row["question_id"]),
                "question": row["prompt"],
                "type": row["answer_type"],
                "follow_up": row.get("follow_up"),
                "keywords": keywords,
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

    return {
        "cloud_session_id": _string_value(cloud, "session_id"),
        "local_session_id": _string_value(data, "local_session_id", "session_id")
        or _string_value(metadata, "local_session_id"),
        "export_time": _string_value(metadata, "export_time", "created_at", "uploaded_at"),
        "respondent_name": _string_value(respondent_info, "name"),
        "respondent_location": _string_value(respondent_info, "location"),
        "interviewer_id": _string_value(interviewer_info, "interviewer_id", "email"),
        "interviewer_name": _string_value(interviewer_info, "name"),
        "interviewer_email": _string_value(interviewer_info, "email"),
        "location_label": _string_value(data, "location_label"),
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
                SELECT question_id AS id, prompt, answer_type
                FROM questionnaire_questions
                WHERE questionnaire_id = %s
                  AND version = %s
                  AND question_id IN ({placeholders})
                """,
                (identity["id"], identity["version"], *unique_ids),
            )
            question_lookup = {str(row["id"]): row for row in cur.fetchall()}
        if len(question_lookup) < len(unique_ids):
            cur.execute(
                f"""
                SELECT id, prompt, answer_type
                FROM questions
                WHERE id IN ({placeholders})
                """,
                unique_ids,
            )
            question_lookup.update({str(row["id"]): row for row in cur.fetchall()})

    rows = []
    for index, item in enumerate(raw_matches):
        if not isinstance(item, dict):
            continue

        qid_raw = item.get("matched_question_id")
        if qid_raw is None:
            continue

        question_id = str(qid_raw)
        question = question_lookup.get(question_id, {})
        extracted_answer = item.get("extracted_answer")
        final_answer = item.get("final_answer")
        analysis_answer = final_answer if isinstance(final_answer, str) and final_answer.strip() else extracted_answer
        confidence = item.get("confidence")
        clarification_needed = item.get("clarification_needed")
        fallback_question_text = item.get("matched_question")
        question_text = question.get("prompt")
        if not isinstance(question_text, str):
            question_text = fallback_question_text if isinstance(fallback_question_text, str) else None
        answer_type = question.get("answer_type")
        if not isinstance(answer_type, str):
            answer_type = None

        rows.append(
            (
                session_bytes,
                respondent_bytes,
                identity.get("id"),
                identity.get("version"),
                question_id,
                index,
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
    try:
        with destination.open("wb") as out:
            while True:
                chunk = upload.file.read(1024 * 1024)
                if not chunk:
                    break
                bytes_written += len(chunk)
                if bytes_written > max_bytes:
                    out.close()
                    destination.unlink(missing_ok=True)
                    raise HTTPException(status_code=413, detail=f"{upload.filename or 'file'} is too large")
                sha256.update(chunk)
                out.write(chunk)
    except HTTPException:
        raise
    except Exception as e:
        destination.unlink(missing_ok=True)
        logger.exception("uploaded file save failed")
        raise HTTPException(status_code=500, detail="failed to save uploaded file") from e
    finally:
        upload.file.close()

    if bytes_written <= 0:
        destination.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail=f"{upload.filename or 'file'} is empty")

    return bytes_written, sha256.hexdigest()


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


class QuestionnaireQuestionPayload(BaseModel):
    id: str | int = Field(..., description="Stable question id within this questionnaire version.")
    question: str = Field(..., min_length=1)
    type: str = Field(default="yes-no", min_length=1, max_length=64)
    follow_up: str | None = None
    keywords: list[str] = Field(default_factory=list)


class QuestionnaireVersionPayload(BaseModel):
    id: str = Field(..., min_length=1, max_length=64)
    version: str = Field(..., min_length=1, max_length=64)
    title: str = Field(..., min_length=1, max_length=255)
    description: str | None = None
    questions: list[QuestionnaireQuestionPayload] = Field(..., min_length=1)


class QuestionnaireStatusChange(BaseModel):
    status: str


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
        }
        for question in body.questions
    ]

    if not questionnaire_id or not version:
        raise HTTPException(status_code=400, detail="questionnaire id and version are required")
    if len({question["id"] for question in questions}) != len(questions):
        raise HTTPException(status_code=400, detail="question ids must be unique within a version")

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
            prompt, answer_type, follow_up, keywords_json
        )
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
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
            cur.executemany(
                """
                INSERT INTO questions (id, questionnaire_version, prompt, answer_type)
                VALUES (%s, %s, %s, %s)
                ON DUPLICATE KEY UPDATE
                  questionnaire_version = VALUES(questionnaire_version),
                  prompt = VALUES(prompt),
                  answer_type = VALUES(answer_type)
                """,
                [
                    (question["id"], version, question["question"], question["type"])
                    for question in questions
                ],
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
                    questionnaire_hash, answer_count, uploaded_at
                FROM session_packages
                ORDER BY uploaded_at DESC
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
                "respondent_location": json_summary.get("respondent_location"),
                "interviewer_id": json_summary.get("interviewer_id") or row.get("interviewer_id"),
                "interviewer_name": json_summary.get("interviewer_name") or row.get("interviewer_name"),
                "interviewer_email": json_summary.get("interviewer_email") or row.get("interviewer_email"),
                "location_label": json_summary.get("location_label") or row.get("location_label"),
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
                SELECT json_path
                FROM session_packages
                WHERE session_id = %s
                """,
                (session_bytes,),
            )
            row = cur.fetchone()

    if not row:
        raise HTTPException(status_code=404, detail="session package not found")

    return read_package_json(row["json_path"])


@app.delete("/admin/sessions/{session_id}")
def admin_delete_session(session_id: str, _: None = Depends(verify_api_key)):
    try:
        session_bytes = uuid_to_bytes(UUID(hex=session_id))
    except ValueError as e:
        raise HTTPException(status_code=400, detail="session_id must be a UUID") from e

    package_dir: Path | None = None
    legacy_audio_paths: list[Path] = []
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

            try:
                cur.execute(
                    """
                    SELECT storage_path
                    FROM audio_recordings
                    WHERE session_id = %s
                    """,
                    (session_bytes,),
                )
                audio_rows = cur.fetchall()
            except MySQLError as e:
                if _mysql_errno(e) != 1146:
                    raise
                logger.warning("audio_recordings table missing during session cleanup")
                audio_rows = []

            for row in audio_rows:
                storage_path = row.get("storage_path")
                if not storage_path:
                    continue
                audio_path = (AUDIO_STORAGE_DIR / storage_path).resolve()
                audio_root = AUDIO_STORAGE_DIR.resolve()
                try:
                    audio_path.relative_to(audio_root)
                except ValueError:
                    logger.warning("skipping audio path outside storage root: %s", audio_path)
                    continue
                legacy_audio_paths.append(audio_path)

            cleanup_statements = [
                ("DELETE FROM analysis_answers WHERE session_id = %s", (session_bytes,)),
                ("DELETE FROM session_packages WHERE session_id = %s", (session_bytes,)),
                ("DELETE FROM audio_recordings WHERE session_id = %s", (session_bytes,)),
                ("DELETE FROM trajectory_points WHERE session_id = %s", (session_bytes,)),
                ("DELETE FROM answers WHERE session_id = %s", (session_bytes,)),
                ("DELETE FROM llm_events WHERE session_id = %s", (session_bytes,)),
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

    for audio_path in legacy_audio_paths:
        try:
            if audio_path.exists():
                audio_path.unlink()
                deleted_paths.append(str(audio_path))
                parent = audio_path.parent
                if parent != AUDIO_STORAGE_DIR.resolve() and parent.exists() and not any(parent.iterdir()):
                    parent.rmdir()
        except Exception:
            logger.warning("failed to delete legacy audio path: %s", audio_path, exc_info=True)

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


class SessionCreateResponse(BaseModel):
    respondent_id: str
    session_id: str
    questionnaire_version: str
    questionnaire_id: str | None = None


@app.post("/sessions", response_model=SessionCreateResponse)
def create_session(body: SessionCreate, _: None = Depends(verify_api_key)):
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

    return SessionCreateResponse(
        respondent_id=bytes_to_uuid_hex(respondent_bytes),
        session_id=str(session_id),
        questionnaire_version=body.questionnaire_version,
        questionnaire_id=body.questionnaire_id,
    )


class AnswerItem(BaseModel):
    question_id: str = Field(..., min_length=1, max_length=64)
    value: dict = Field(default_factory=dict)


class AnswersBatch(BaseModel):
    answers: list[AnswerItem]


@app.post("/sessions/{session_id}/answers")
def post_answers(
    session_id: str,
    body: AnswersBatch,
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
                "SELECT id FROM survey_sessions WHERE id = %s",
                (session_bytes,),
            )
            if not cur.fetchone():
                raise HTTPException(status_code=404, detail="session not found")

            for item in body.answers:
                payload = json.dumps(item.value, ensure_ascii=False)
                try:
                    # Plain JSON text bind; avoids CAST(%s AS JSON) issues with some drivers.
                    cur.execute(
                        """
                        INSERT INTO answers (session_id, question_id, value_json)
                        VALUES (%s, %s, %s)
                        """,
                        (session_bytes, item.question_id, payload),
                    )
                except Exception as e:
                    if (
                        isinstance(e, (IntegrityError, OperationalError))
                        and _mysql_errno(e) == 1452
                    ):
                        raise HTTPException(
                            status_code=400,
                            detail=(
                                f"Foreign key failed for question_id={item.question_id!r}. "
                                "Run scripts/seed_questions.py so `questions` rows exist, "
                                "or remove the FK on `answers.question_id`."
                            ),
                        ) from e
                    logger.exception("answers insert failed")
                    raise

    return {"inserted": len(body.answers)}


@app.post("/sessions/{session_id}/audio")
def upload_session_audio(
    session_id: str,
    file: UploadFile = File(...),
    recorded_at_ms: int | None = Form(default=None),
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

    original_filename = sanitize_filename(file.filename or "recording.m4a")
    extension = Path(original_filename).suffix.lower() or ".m4a"
    storage_name = f"{session_id}_{uuid4().hex}{extension}"
    session_dir = AUDIO_STORAGE_DIR / session_id
    session_dir.mkdir(parents=True, exist_ok=True)
    storage_path = session_dir / storage_name
    relative_path = str(Path(session_id) / storage_name)

    bytes_written = 0
    try:
        with storage_path.open("wb") as out:
            while True:
                chunk = file.file.read(1024 * 1024)
                if not chunk:
                    break
                bytes_written += len(chunk)
                if bytes_written > AUDIO_MAX_BYTES:
                    out.close()
                    storage_path.unlink(missing_ok=True)
                    raise HTTPException(status_code=413, detail="audio file is too large")
                out.write(chunk)
    except HTTPException:
        raise
    except Exception as e:
        storage_path.unlink(missing_ok=True)
        logger.exception("audio file save failed")
        raise HTTPException(status_code=500, detail="failed to save audio file") from e
    finally:
        file.file.close()

    if bytes_written <= 0:
        storage_path.unlink(missing_ok=True)
        raise HTTPException(status_code=400, detail="audio file is empty")

    try:
        import hashlib

        sha256 = hashlib.sha256()
        with storage_path.open("rb") as saved:
            for chunk in iter(lambda: saved.read(1024 * 1024), b""):
                sha256.update(chunk)
        sha256_hex = sha256.hexdigest()

        with get_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO audio_recordings (
                        session_id, respondent_id, original_filename, storage_path,
                        content_type, file_size_bytes, sha256, recorded_at_ms, local_session_id
                    )
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        session_bytes,
                        respondent_bytes,
                        original_filename,
                        relative_path,
                        file.content_type,
                        bytes_written,
                        sha256_hex,
                        recorded_at_ms,
                        local_session_id,
                    ),
                )
                audio_id = cur.lastrowid
    except Exception as e:
        storage_path.unlink(missing_ok=True)
        if isinstance(e, (IntegrityError, OperationalError)):
            logger.exception("audio metadata insert failed")
            raise HTTPException(
                status_code=500,
                detail="audio metadata insert failed; did you apply server/schema.sql?",
            ) from e
        logger.exception("audio metadata processing failed")
        raise HTTPException(status_code=500, detail="audio metadata processing failed") from e

    return {
        "id": audio_id,
        "session_id": session_id,
        "filename": original_filename,
        "storage_path": relative_path,
        "file_size_bytes": bytes_written,
        "sha256": sha256_hex,
    }


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


class LLMEventCreate(BaseModel):
    session_id: str | None = None
    question_id: str | None = Field(default=None, max_length=64)
    model: str
    latency_ms: int | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    success: bool = True
    error_message: str | None = None
    request_gcs_uri: str | None = None
    response_gcs_uri: str | None = None


@app.post("/llm-events")
def create_llm_event(body: LLMEventCreate, _: None = Depends(verify_api_key)):
    session_bytes = None
    if body.session_id:
        try:
            session_bytes = uuid_to_bytes(UUID(hex=body.session_id))
        except ValueError as e:
            raise HTTPException(status_code=400, detail="session_id must be a UUID") from e

    with get_conn() as conn:
        with conn.cursor() as cur:
            if session_bytes:
                cur.execute(
                    "SELECT id FROM survey_sessions WHERE id = %s",
                    (session_bytes,),
                )
                if not cur.fetchone():
                    raise HTTPException(status_code=404, detail="session not found")

            cur.execute(
                """
                INSERT INTO llm_events (
                    session_id, question_id, model, latency_ms,
                    prompt_tokens, completion_tokens, success, error_message,
                    request_gcs_uri, response_gcs_uri
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    session_bytes,
                    body.question_id,
                    body.model,
                    body.latency_ms,
                    body.prompt_tokens,
                    body.completion_tokens,
                    body.success,
                    body.error_message,
                    body.request_gcs_uri,
                    body.response_gcs_uri,
                ),
            )
            eid = cur.lastrowid

    return {"id": eid}


class TrajectoryPointCreate(BaseModel):
    ts_ms: int = Field(..., ge=0, description="Unix epoch milliseconds (UTC).")
    lat: float
    lon: float
    accuracy_m: float | None = None
    speed_mps: float | None = None
    course_deg: float | None = None
    provider: str | None = Field(default=None, max_length=32)
    is_background: bool | None = None
    session_id: str | None = Field(
        default=None,
        description="Optional UUID hex of the survey_session to link this point to.",
    )


class TrajectoryBatch(BaseModel):
    points: list[TrajectoryPointCreate]


@app.post("/respondents/{respondent_id}/trajectory")
def post_trajectory(
    respondent_id: str,
    body: TrajectoryBatch,
    _: None = Depends(verify_api_key),
):
    try:
        rid = UUID(hex=respondent_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail="respondent_id must be a UUID") from e
    respondent_bytes = uuid_to_bytes(rid)

    if not body.points:
        return {"inserted": 0}

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM respondents WHERE id = %s", (respondent_bytes,))
            if not cur.fetchone():
                raise HTTPException(status_code=404, detail="respondent not found")

            # Validate any session_ids (must exist and belong to this respondent)
            session_bytes_by_hex: dict[str, bytes] = {}
            unique_session_hex = {p.session_id for p in body.points if p.session_id}
            for sid_hex in unique_session_hex:
                try:
                    sb = uuid_to_bytes(UUID(hex=sid_hex))
                except ValueError as e:
                    raise HTTPException(status_code=400, detail="session_id must be a UUID") from e
                cur.execute(
                    "SELECT id FROM survey_sessions WHERE id = %s AND respondent_id = %s",
                    (sb, respondent_bytes),
                )
                if not cur.fetchone():
                    raise HTTPException(
                        status_code=404,
                        detail=f"session not found for respondent (session_id={sid_hex})",
                    )
                session_bytes_by_hex[sid_hex] = sb

            rows = []
            for p in body.points:
                rows.append(
                    (
                        respondent_bytes,
                        session_bytes_by_hex.get(p.session_id) if p.session_id else None,
                        int(p.ts_ms),
                        float(p.lat),
                        float(p.lon),
                        p.accuracy_m,
                        p.speed_mps,
                        p.course_deg,
                        p.provider,
                        p.is_background,
                    )
                )

            cur.executemany(
                """
                INSERT INTO trajectory_points (
                    respondent_id, session_id, ts_ms,
                    lat, lon, accuracy_m, speed_mps, course_deg,
                    provider, is_background
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                rows,
            )

    return {"inserted": len(body.points)}


@app.get("/respondents/{respondent_id}/trajectory")
def get_trajectory(
    respondent_id: str,
    since_ms: int | None = None,
    limit: int = 5000,
    _: None = Depends(verify_api_key),
):
    try:
        rid = UUID(hex=respondent_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail="respondent_id must be a UUID") from e
    respondent_bytes = uuid_to_bytes(rid)
    limit = max(1, min(int(limit), 20000))

    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM respondents WHERE id = %s", (respondent_bytes,))
            if not cur.fetchone():
                raise HTTPException(status_code=404, detail="respondent not found")

            if since_ms is None:
                cur.execute(
                    """
                    SELECT ts_ms, lat, lon, accuracy_m, speed_mps, course_deg, provider, is_background,
                           session_id
                    FROM trajectory_points
                    WHERE respondent_id = %s
                    ORDER BY ts_ms ASC
                    LIMIT %s
                    """,
                    (respondent_bytes, limit),
                )
            else:
                cur.execute(
                    """
                    SELECT ts_ms, lat, lon, accuracy_m, speed_mps, course_deg, provider, is_background,
                           session_id
                    FROM trajectory_points
                    WHERE respondent_id = %s AND ts_ms >= %s
                    ORDER BY ts_ms ASC
                    LIMIT %s
                    """,
                    (respondent_bytes, int(since_ms), limit),
                )

            rows = cur.fetchall()

    # Convert session_id bytes (if present) to UUID string
    out = []
    for r in rows:
        sid = r.get("session_id")
        out.append(
            {
                "ts_ms": int(r["ts_ms"]),
                "lat": float(r["lat"]),
                "lon": float(r["lon"]),
                "accuracy_m": r.get("accuracy_m"),
                "speed_mps": r.get("speed_mps"),
                "course_deg": r.get("course_deg"),
                "provider": r.get("provider"),
                "is_background": r.get("is_background"),
                "session_id": bytes_to_uuid_hex(sid) if sid else None,
            }
        )

    return {"points": out, "count": len(out)}
