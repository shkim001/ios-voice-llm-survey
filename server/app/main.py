from __future__ import annotations

import json
import logging
import os
from contextlib import contextmanager
from typing import Optional
from uuid import UUID, uuid4

import pymysql
from pymysql.err import IntegrityError, OperationalError
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

load_dotenv()

MYSQL_HOST = os.environ["MYSQL_HOST"]
MYSQL_PORT = int(os.environ.get("MYSQL_PORT", "3306"))
MYSQL_USER = os.environ["MYSQL_USER"]
MYSQL_PASSWORD = os.environ["MYSQL_PASSWORD"]
MYSQL_DATABASE = os.environ["MYSQL_DATABASE"]
API_KEY = os.environ.get("API_KEY", "").strip()

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
