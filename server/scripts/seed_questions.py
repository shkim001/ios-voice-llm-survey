#!/usr/bin/env python3
"""One-time: insert questionnaire rows into `questions` so `answers` FK succeeds.

Usage on llm-server (from `server/`):

  export $(grep -v '^#' .env | xargs)
  python3 scripts/seed_questions.py ../CounterApp/questionnaire.json

Or copy `questionnaire.json` next to this script and:

  python3 scripts/seed_questions.py questionnaire.json
"""

import json
import os
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
    questions = data["questionnaire"]["questions"]
    version = os.environ.get("QUESTIONNAIRE_VERSION", "1")

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
            for q in questions:
                qid = str(q["id"])
                prompt = q["question"]
                answer_type = "json"
                cur.execute(
                    """
                    INSERT INTO questions (id, questionnaire_version, prompt, answer_type)
                    VALUES (%s, %s, %s, %s)
                    ON DUPLICATE KEY UPDATE
                      prompt = VALUES(prompt),
                      answer_type = VALUES(answer_type)
                    """,
                    (qid, version, prompt, answer_type),
                )
        conn.commit()
        print(f"Upserted {len(questions)} questions (version={version}).")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
