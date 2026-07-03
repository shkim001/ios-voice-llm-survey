#!/usr/bin/env python3
"""Populate `analysis_answers` from stored session package JSON files.

Usage from `server/`:

  python3 scripts/backfill_analysis_answers.py

Optionally pass a package root:

  python3 scripts/backfill_analysis_answers.py /var/lib/ios-voice-llm-survey/session-packages
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.main import (  # noqa: E402
    SURVEY_PACKAGE_STORAGE_DIR,
    get_conn,
    replace_analysis_answers,
    uuid_to_bytes,
)


def main() -> int:
    package_root = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else SURVEY_PACKAGE_STORAGE_DIR
    if not package_root.exists():
        print(f"Package root does not exist: {package_root}", file=sys.stderr)
        return 1

    processed = 0
    inserted = 0
    skipped = 0

    with get_conn() as conn:
        with conn.cursor() as cur:
            for json_path in sorted(package_root.glob("*/session.json")):
                session_id = json_path.parent.name
                try:
                    session_bytes = uuid_to_bytes(UUID(hex=session_id))
                except ValueError:
                    print(f"Skipping non-UUID package directory: {json_path.parent}")
                    skipped += 1
                    continue

                cur.execute(
                    "SELECT respondent_id FROM survey_sessions WHERE id = %s",
                    (session_bytes,),
                )
                session_row = cur.fetchone()
                if not session_row:
                    print(f"Skipping package without survey_sessions row: {session_id}")
                    skipped += 1
                    continue

                try:
                    package_data = json.loads(json_path.read_text(encoding="utf-8"))
                except json.JSONDecodeError as e:
                    print(f"Skipping invalid JSON {json_path}: {e}")
                    skipped += 1
                    continue

                if not isinstance(package_data, dict):
                    print(f"Skipping non-object JSON: {json_path}")
                    skipped += 1
                    continue

                count = replace_analysis_answers(
                    cur,
                    session_bytes=session_bytes,
                    respondent_bytes=session_row["respondent_id"],
                    package_data=package_data,
                    source_json_path=str(Path(session_id) / "session.json"),
                )
                processed += 1
                inserted += count
                print(f"{session_id}: {count} analysis answer rows")

    print(f"Processed {processed} packages, inserted {inserted} rows, skipped {skipped}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
