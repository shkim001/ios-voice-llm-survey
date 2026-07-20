#!/usr/bin/env python3
"""Add the durable server transcription/analysis queue to an existing database."""

import os
from pathlib import Path

import pymysql
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")


CREATE_PROCESSING_JOBS = """
CREATE TABLE IF NOT EXISTS processing_jobs (
  session_id BINARY(16) NOT NULL,
  respondent_id BINARY(16) NOT NULL,
  local_session_id VARCHAR(64) NOT NULL,
  status VARCHAR(32) NOT NULL DEFAULT 'queued',
  revision INT UNSIGNED NOT NULL DEFAULT 1,
  attempt_count INT UNSIGNED NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMP(6) NULL,
  lease_owner VARCHAR(128) NULL,
  lease_expires_at TIMESTAMP(6) NULL,
  input_manifest_path VARCHAR(1024) NOT NULL,
  input_manifest_sha256 CHAR(64) NOT NULL,
  audio_path VARCHAR(1024) NOT NULL,
  audio_original_filename VARCHAR(255) NOT NULL,
  audio_file_size_bytes BIGINT UNSIGNED NOT NULL,
  audio_sha256 CHAR(64) NOT NULL,
  transcript_path VARCHAR(1024) NULL,
  raw_transcription_path VARCHAR(1024) NULL,
  raw_analysis_path VARCHAR(1024) NULL,
  draft_analysis_path VARCHAR(1024) NULL,
  result_json_path VARCHAR(1024) NULL,
  result_json_sha256 CHAR(64) NULL,
  error_category VARCHAR(64) NULL,
  error_message TEXT NULL,
  created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  completed_at TIMESTAMP(6) NULL,
  PRIMARY KEY (session_id),
  UNIQUE KEY uq_processing_jobs_local_session (local_session_id),
  INDEX idx_processing_jobs_claim (status, next_attempt_at, lease_expires_at, created_at),
  CONSTRAINT fk_processing_jobs_session
    FOREIGN KEY (session_id) REFERENCES survey_sessions(id)
    ON DELETE CASCADE,
  CONSTRAINT fk_processing_jobs_respondent
    FOREIGN KEY (respondent_id) REFERENCES respondents(id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
"""


def main():
    conn = pymysql.connect(
        host=os.environ["MYSQL_HOST"],
        port=int(os.environ.get("MYSQL_PORT", "3306")),
        user=os.environ["MYSQL_USER"],
        password=os.environ["MYSQL_PASSWORD"],
        database=os.environ["MYSQL_DATABASE"],
        charset="utf8mb4",
    )
    try:
        with conn.cursor() as cur:
            cur.execute(CREATE_PROCESSING_JOBS)
        conn.commit()
        print("Server processing schema is ready.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
