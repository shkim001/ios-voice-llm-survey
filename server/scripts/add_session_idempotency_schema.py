#!/usr/bin/env python3
"""Add the durable local-session idempotency mapping to an existing database.

Usage from ``server/``:

  python3 scripts/add_session_idempotency_schema.py
"""

import os
from pathlib import Path

import pymysql
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")


def main():
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
                CREATE TABLE IF NOT EXISTS session_creation_keys (
                  local_session_id VARCHAR(64) NOT NULL,
                  session_id BINARY(16) NOT NULL,
                  respondent_id BINARY(16) NOT NULL,
                  created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
                  PRIMARY KEY (local_session_id),
                  UNIQUE KEY uq_session_creation_keys_session (session_id),
                  CONSTRAINT fk_session_creation_keys_session
                    FOREIGN KEY (session_id) REFERENCES survey_sessions(id)
                    ON DELETE CASCADE,
                  CONSTRAINT fk_session_creation_keys_respondent
                    FOREIGN KEY (respondent_id) REFERENCES respondents(id)
                    ON DELETE CASCADE
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """
            )
        conn.commit()
        print("Session creation idempotency schema is ready.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
