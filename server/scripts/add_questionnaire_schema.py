#!/usr/bin/env python3
"""Add questionnaire-version metadata columns to existing package/analysis tables.

Run from `server/` after applying `schema.sql`:

  python3 scripts/add_questionnaire_schema.py
"""

import os
from pathlib import Path

import pymysql
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")


def column_exists(cur, table: str, column: str) -> bool:
    cur.execute(
        """
        SELECT 1
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s AND COLUMN_NAME = %s
        LIMIT 1
        """,
        (os.environ["MYSQL_DATABASE"], table, column),
    )
    return cur.fetchone() is not None


def index_exists(cur, table: str, index_name: str) -> bool:
    cur.execute(
        """
        SELECT 1
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = %s AND TABLE_NAME = %s AND INDEX_NAME = %s
        LIMIT 1
        """,
        (os.environ["MYSQL_DATABASE"], table, index_name),
    )
    return cur.fetchone() is not None


def add_column(cur, table: str, column: str, definition: str):
    if column_exists(cur, table, column):
        print(f"{table}.{column} already exists")
        return
    cur.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")
    print(f"Added {table}.{column}")


def add_index(cur, table: str, index_name: str, definition: str):
    if index_exists(cur, table, index_name):
        print(f"{table}.{index_name} already exists")
        return
    cur.execute(f"ALTER TABLE {table} ADD INDEX {index_name} {definition}")
    print(f"Added {table}.{index_name}")


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
            add_column(cur, "session_packages", "questionnaire_id", "VARCHAR(64) NULL")
            add_column(cur, "session_packages", "questionnaire_version", "VARCHAR(64) NULL")
            add_column(cur, "session_packages", "questionnaire_hash", "CHAR(64) NULL")
            add_index(
                cur,
                "session_packages",
                "idx_session_packages_questionnaire",
                "(questionnaire_id, questionnaire_version)",
            )

            add_column(cur, "analysis_answers", "questionnaire_id", "VARCHAR(64) NULL")
            add_column(cur, "analysis_answers", "questionnaire_version", "VARCHAR(64) NULL")
            add_index(
                cur,
                "analysis_answers",
                "idx_analysis_answers_questionnaire",
                "(questionnaire_id, questionnaire_version, question_id)",
            )

            add_column(cur, "questionnaire_questions", "options_json", "TEXT NULL")
            add_column(
                cur,
                "questionnaire_questions",
                "allows_multiple",
                "BOOLEAN NOT NULL DEFAULT FALSE",
            )
        conn.commit()
    finally:
        conn.close()


if __name__ == "__main__":
    main()
