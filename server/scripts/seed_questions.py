#!/usr/bin/env python3
"""Seed the bundled questionnaire into versioned questionnaire storage.

Usage on llm-server (from `server/`):

  export $(grep -v '^#' .env | xargs)
  python3 scripts/seed_questions.py ../CounterApp/questionnaire.json

Or copy `questionnaire.json` next to this script and:

  python3 scripts/seed_questions.py questionnaire.json
"""

import json
import os
import hashlib
import sys
from pathlib import Path

import pymysql
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")


def main():
    if len(sys.argv) < 2:
        print("Usage: seed_questions.py <path-to-questionnaire.json>", file=sys.stderr)
        sys.exit(1)

    path = Path(sys.argv[1])
    data = json.loads(path.read_text(encoding="utf-8"))
    questionnaire = data["questionnaire"]
    questions = questionnaire["questions"]
    questionnaire_id = os.environ.get("QUESTIONNAIRE_ID", "street-assessment")
    version = os.environ.get("QUESTIONNAIRE_VERSION", "1")
    title = questionnaire.get("title") or "Untitled Questionnaire"
    description = questionnaire.get("description")
    canonical = {
        "id": questionnaire_id,
        "version": version,
        "title": title,
        "description": description or "",
        "questions": [
            {
                "id": str(q["id"]),
                "question": q["question"],
                "type": q.get("type", "yes-no"),
                "follow_up": q.get("follow_up"),
                "keywords": q.get("keywords", []),
                "options": q.get("options", []),
                "allows_multiple": bool(q.get("allows_multiple", False)),
            }
            for q in questions
        ],
    }
    questionnaire_hash = hashlib.sha256(
        json.dumps(canonical, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()

    conn = pymysql.connect(
        host=os.environ["MYSQL_HOST"],
        port=int(os.environ.get("MYSQL_PORT", "3306")),
        user=os.environ["MYSQL_USER"],
        password=os.environ["MYSQL_PASSWORD"],
        database=os.environ["MYSQL_DATABASE"],
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
    )
    try:
        with conn.cursor() as cur:
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
                  questionnaire_id, version, title, description, status,
                  questionnaire_hash, published_at
                )
                VALUES (%s, %s, %s, %s, 'published', %s, CURRENT_TIMESTAMP(6))
                ON DUPLICATE KEY UPDATE
                  title = VALUES(title),
                  description = VALUES(description),
                  status = 'published',
                  questionnaire_hash = VALUES(questionnaire_hash),
                  published_at = COALESCE(published_at, CURRENT_TIMESTAMP(6)),
                  archived_at = NULL,
                  updated_at = CURRENT_TIMESTAMP(6)
                """,
                (questionnaire_id, version, title, description, questionnaire_hash),
            )
            cur.execute(
                """
                DELETE FROM questionnaire_questions
                WHERE questionnaire_id = %s AND version = %s
                """,
                (questionnaire_id, version),
            )
            for index, q in enumerate(questions, start=1):
                qid = str(q["id"])
                prompt = q["question"]
                answer_type = q.get("type", "yes-no")
                options = q.get("options", []) if answer_type == "multiple-choice" else []
                allows_multiple = bool(q.get("allows_multiple", False)) if answer_type == "multiple-choice" else False
                cur.execute(
                    """
                    INSERT INTO questionnaire_questions (
                      questionnaire_id, version, question_id, order_index,
                      prompt, answer_type, follow_up, keywords_json, options_json, allows_multiple
                    )
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        questionnaire_id,
                        version,
                        qid,
                        index,
                        prompt,
                        answer_type,
                        q.get("follow_up"),
                        json.dumps(q.get("keywords", []), ensure_ascii=False),
                        json.dumps(options, ensure_ascii=False),
                        allows_multiple,
                    ),
                )
        conn.commit()
        print(
            f"Published questionnaire {questionnaire_id!r} version={version}; "
            f"saved {len(questions)} questionnaire questions."
        )
    finally:
        conn.close()


if __name__ == "__main__":
    main()
