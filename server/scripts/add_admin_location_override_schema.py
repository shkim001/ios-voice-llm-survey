#!/usr/bin/env python3
"""Add admin location override fields to an existing package index.

Usage from ``server/``:

  python3 scripts/add_admin_location_override_schema.py
"""

import os
from pathlib import Path

import pymysql
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")


def ensure_column(cur, column_name: str, column_type: str):
    cur.execute(
        """
        SELECT COUNT(*) AS count
        FROM information_schema.columns
        WHERE table_schema = DATABASE()
          AND table_name = 'session_packages'
          AND column_name = %s
        """,
        (column_name,),
    )
    if cur.fetchone()["count"]:
        return
    cur.execute(f"ALTER TABLE session_packages ADD COLUMN {column_name} {column_type}")


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
            ensure_column(cur, "admin_location_label", "VARCHAR(255) NULL")
            ensure_column(cur, "admin_formatted_address", "VARCHAR(500) NULL")
            ensure_column(cur, "admin_location_lat", "DOUBLE NULL")
            ensure_column(cur, "admin_location_lon", "DOUBLE NULL")
            ensure_column(cur, "admin_location_updated_at", "TIMESTAMP(6) NULL")
        conn.commit()
        print("Admin location override schema is ready.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
