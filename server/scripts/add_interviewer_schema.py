#!/usr/bin/env python3
"""Add interviewer lookup/index fields to an existing Survey API database.

Usage from `server/`:

  python3 scripts/add_interviewer_schema.py
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
                CREATE TABLE IF NOT EXISTS interviewers (
                  email VARCHAR(255) NOT NULL,
                  name VARCHAR(255) NOT NULL,
                  created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
                  updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
                  last_seen_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
                  PRIMARY KEY (email),
                  INDEX idx_interviewers_name (name)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
                """
            )

            ensure_column(cur, "session_packages", "interviewer_id", "VARCHAR(255) NULL")
            ensure_column(cur, "session_packages", "interviewer_name", "VARCHAR(255) NULL")
            ensure_column(cur, "session_packages", "interviewer_email", "VARCHAR(255) NULL")
            ensure_index(cur, "session_packages", "idx_session_packages_interviewer_uploaded", "interviewer_id, uploaded_at")

        conn.commit()
        print("Interviewer schema is ready.")
    finally:
        conn.close()


def ensure_column(cur, table_name: str, column_name: str, column_type: str):
    cur.execute(
        """
        SELECT COUNT(*) AS count
        FROM information_schema.columns
        WHERE table_schema = DATABASE()
          AND table_name = %s
          AND column_name = %s
        """,
        (table_name, column_name),
    )
    if cur.fetchone()["count"]:
        return
    cur.execute(f"ALTER TABLE {table_name} ADD COLUMN {column_name} {column_type}")


def ensure_index(cur, table_name: str, index_name: str, columns: str):
    cur.execute(
        """
        SELECT COUNT(*) AS count
        FROM information_schema.statistics
        WHERE table_schema = DATABASE()
          AND table_name = %s
          AND index_name = %s
        """,
        (table_name, index_name),
    )
    if cur.fetchone()["count"]:
        return
    cur.execute(f"CREATE INDEX {index_name} ON {table_name} ({columns})")


if __name__ == "__main__":
    main()
