-- Schema additions for VM-local interview packages and legacy upload tables.
-- Assumes existing tables:
--   respondents(id BINARY(16) PRIMARY KEY, ...)
--   survey_sessions(id BINARY(16) PRIMARY KEY, respondent_id BINARY(16) NOT NULL, ...)
--
-- Apply to your Cloud SQL / MySQL database:
--   mysql -h $MYSQL_HOST -u $MYSQL_USER -p $MYSQL_DATABASE < schema.sql

CREATE TABLE IF NOT EXISTS trajectory_points (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  respondent_id BINARY(16) NOT NULL,
  session_id BINARY(16) NULL,

  -- client timestamp in unix milliseconds
  ts_ms BIGINT NOT NULL,

  lat DOUBLE NOT NULL,
  lon DOUBLE NOT NULL,
  accuracy_m FLOAT NULL,
  speed_mps FLOAT NULL,
  course_deg FLOAT NULL,

  -- e.g. "gps", "significant-change", "visit"
  provider VARCHAR(32) NULL,
  is_background BOOLEAN NULL,

  created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

  PRIMARY KEY (id),
  INDEX idx_trajectory_resp_ts (respondent_id, ts_ms),
  INDEX idx_trajectory_sess_ts (session_id, ts_ms),

  CONSTRAINT fk_trajectory_respondent
    FOREIGN KEY (respondent_id) REFERENCES respondents(id)
    ON DELETE CASCADE,

  CONSTRAINT fk_trajectory_session
    FOREIGN KEY (session_id) REFERENCES survey_sessions(id)
    ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS audio_recordings (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  session_id BINARY(16) NOT NULL,
  respondent_id BINARY(16) NOT NULL,

  original_filename VARCHAR(255) NOT NULL,
  storage_path VARCHAR(1024) NOT NULL,
  content_type VARCHAR(128) NULL,
  file_size_bytes BIGINT UNSIGNED NOT NULL,
  sha256 CHAR(64) NOT NULL,

  recorded_at_ms BIGINT NULL,
  local_session_id VARCHAR(64) NULL,
  uploaded_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

  PRIMARY KEY (id),
  INDEX idx_audio_session_uploaded (session_id, uploaded_at),
  INDEX idx_audio_respondent_uploaded (respondent_id, uploaded_at),

  CONSTRAINT fk_audio_session
    FOREIGN KEY (session_id) REFERENCES survey_sessions(id)
    ON DELETE CASCADE,

  CONSTRAINT fk_audio_respondent
    FOREIGN KEY (respondent_id) REFERENCES respondents(id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS session_packages (
  session_id BINARY(16) NOT NULL,
  respondent_id BINARY(16) NOT NULL,

  local_session_id VARCHAR(64) NULL,
  package_dir VARCHAR(1024) NOT NULL,

  json_path VARCHAR(1024) NOT NULL,
  json_file_size_bytes BIGINT UNSIGNED NOT NULL,
  json_sha256 CHAR(64) NOT NULL,

  audio_path VARCHAR(1024) NULL,
  audio_original_filename VARCHAR(255) NULL,
  audio_file_size_bytes BIGINT UNSIGNED NULL,
  audio_sha256 CHAR(64) NULL,

  recorded_at_ms BIGINT NULL,
  location_label VARCHAR(255) NULL,
  gps_lat DOUBLE NULL,
  gps_lon DOUBLE NULL,
  answer_count INT UNSIGNED NULL,
  transcript_chars INT UNSIGNED NULL,

  uploaded_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

  PRIMARY KEY (session_id),
  INDEX idx_session_packages_respondent_uploaded (respondent_id, uploaded_at),
  INDEX idx_session_packages_location_uploaded (location_label, uploaded_at),

  CONSTRAINT fk_session_packages_session
    FOREIGN KEY (session_id) REFERENCES survey_sessions(id)
    ON DELETE CASCADE,

  CONSTRAINT fk_session_packages_respondent
    FOREIGN KEY (respondent_id) REFERENCES respondents(id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS analysis_answers (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  session_id BINARY(16) NOT NULL,
  respondent_id BINARY(16) NOT NULL,

  question_id VARCHAR(64) NOT NULL,
  matched_index INT UNSIGNED NOT NULL,
  question_text TEXT NULL,
  answer_type VARCHAR(64) NULL,

  extracted_answer TEXT NULL,
  normalized_answer VARCHAR(64) NULL,
  confidence VARCHAR(32) NULL,
  clarification_needed BOOLEAN NULL,

  raw_match_json LONGTEXT NULL,
  source_json_path VARCHAR(1024) NOT NULL,

  created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),

  PRIMARY KEY (id),
  UNIQUE KEY uniq_analysis_answers_session_match (session_id, matched_index),
  INDEX idx_analysis_answers_question_normalized (question_id, normalized_answer),
  INDEX idx_analysis_answers_session_question (session_id, question_id),
  INDEX idx_analysis_answers_respondent_question (respondent_id, question_id),

  CONSTRAINT fk_analysis_answers_session
    FOREIGN KEY (session_id) REFERENCES survey_sessions(id)
    ON DELETE CASCADE,

  CONSTRAINT fk_analysis_answers_respondent
    FOREIGN KEY (respondent_id) REFERENCES respondents(id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
