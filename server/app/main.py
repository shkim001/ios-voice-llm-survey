from __future__ import annotations

import json
import logging
import os
import hashlib
from contextlib import contextmanager
from pathlib import Path
from typing import Optional
from uuid import UUID, uuid4

import pymysql
from pymysql.err import IntegrityError, OperationalError
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
    audio = data.get("audio") if isinstance(data.get("audio"), dict) else {}
    gps = data.get("recording_start_trajectory_point")
    if not isinstance(gps, dict):
        location = data.get("location")
        gps = location if isinstance(location, dict) else {}

    matched_questions = data.get("matched_questions")
    answers = matched_questions if isinstance(matched_questions, list) else []
    transcript = data.get("transcription")

    return {
        "local_session_id": data.get("local_session_id") or data.get("session_id"),
        "location_label": respondent_info.get("location") or data.get("location_label"),
        "gps_lat": gps.get("lat"),
        "gps_lon": gps.get("lon"),
        "recorded_at_ms": audio.get("recorded_at_ms"),
        "answer_count": len(answers),
        "transcript_chars": len(transcript) if isinstance(transcript, str) else None,
    }


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
    if question_ids:
        placeholders = ", ".join(["%s"] * len(set(question_ids)))
        cur.execute(
            f"""
            SELECT id, prompt, answer_type
            FROM questions
            WHERE id IN ({placeholders})
            """,
            tuple(sorted(set(question_ids))),
        )
        question_lookup = {str(row["id"]): row for row in cur.fetchall()}

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
                question_id,
                index,
                question_text,
                answer_type,
                extracted_answer if isinstance(extracted_answer, str) else None,
                normalize_answer_for_analysis(extracted_answer),
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
            session_id, respondent_id, question_id, matched_index,
            question_text, answer_type, extracted_answer, normalized_answer,
            confidence, clarification_needed, raw_match_json, source_json_path
        )
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
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


class SessionCreate(BaseModel):
    questionnaire_version: str = Field(default="1")
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
                        recorded_at_ms, location_label, gps_lat, gps_lon,
                        answer_count, transcript_chars
                    )
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
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
