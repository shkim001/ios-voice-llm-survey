-- Schema additions for VM-local interview packages.
-- Assumes existing tables:
--   respondents(id BINARY(16) PRIMARY KEY, ...)
--   survey_sessions(id BINARY(16) PRIMARY KEY, respondent_id BINARY(16) NOT NULL, ...)
--
-- Apply to your Cloud SQL / MySQL database:
--   mysql -h $MYSQL_HOST -u $MYSQL_USER -p $MYSQL_DATABASE < schema.sql

CREATE TABLE IF NOT EXISTS interviewers (
  email VARCHAR(255) NOT NULL,
  name VARCHAR(255) NOT NULL,
  created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  last_seen_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

  PRIMARY KEY (email),
  INDEX idx_interviewers_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS questionnaires (
  id VARCHAR(64) NOT NULL,
  title VARCHAR(255) NOT NULL,
  description TEXT NULL,
  status ENUM('active', 'archived') NOT NULL DEFAULT 'active',
  created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),

  PRIMARY KEY (id),
  INDEX idx_questionnaires_status_title (status, title)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS questionnaire_versions (
  questionnaire_id VARCHAR(64) NOT NULL,
  version VARCHAR(64) NOT NULL,
  title VARCHAR(255) NOT NULL,
  description TEXT NULL,
  status ENUM('draft', 'published', 'archived') NOT NULL DEFAULT 'draft',
  questionnaire_hash CHAR(64) NOT NULL,
  created_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  published_at TIMESTAMP(6) NULL,
  archived_at TIMESTAMP(6) NULL,

  PRIMARY KEY (questionnaire_id, version),
  INDEX idx_questionnaire_versions_status (status, updated_at),

  CONSTRAINT fk_questionnaire_versions_questionnaire
    FOREIGN KEY (questionnaire_id) REFERENCES questionnaires(id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS questionnaire_questions (
  questionnaire_id VARCHAR(64) NOT NULL,
  version VARCHAR(64) NOT NULL,
  question_id VARCHAR(64) NOT NULL,
  order_index INT UNSIGNED NOT NULL,
  prompt TEXT NOT NULL,
  answer_type VARCHAR(64) NOT NULL,
  follow_up TEXT NULL,
  keywords_json TEXT NULL,
  options_json TEXT NULL,
  allows_multiple BOOLEAN NOT NULL DEFAULT FALSE,

  PRIMARY KEY (questionnaire_id, version, question_id),
  INDEX idx_questionnaire_questions_order (questionnaire_id, version, order_index),

  CONSTRAINT fk_questionnaire_questions_version
    FOREIGN KEY (questionnaire_id, version)
    REFERENCES questionnaire_versions(questionnaire_id, version)
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
  interviewer_id VARCHAR(255) NULL,
  interviewer_name VARCHAR(255) NULL,
  interviewer_email VARCHAR(255) NULL,
  questionnaire_id VARCHAR(64) NULL,
  questionnaire_version VARCHAR(64) NULL,
  questionnaire_hash CHAR(64) NULL,
  gps_lat DOUBLE NULL,
  gps_lon DOUBLE NULL,
  answer_count INT UNSIGNED NULL,
  transcript_chars INT UNSIGNED NULL,

  uploaded_at TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

  PRIMARY KEY (session_id),
  INDEX idx_session_packages_respondent_uploaded (respondent_id, uploaded_at),
  INDEX idx_session_packages_location_uploaded (location_label, uploaded_at),
  INDEX idx_session_packages_interviewer_uploaded (interviewer_id, uploaded_at),
  INDEX idx_session_packages_questionnaire (questionnaire_id, questionnaire_version),

  CONSTRAINT fk_session_packages_session
    FOREIGN KEY (session_id) REFERENCES survey_sessions(id)
    ON DELETE CASCADE,

  CONSTRAINT fk_session_packages_respondent
    FOREIGN KEY (respondent_id) REFERENCES respondents(id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Idempotency mapping for POST /sessions. Existing clients may omit the key.
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS analysis_answers (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  session_id BINARY(16) NOT NULL,
  respondent_id BINARY(16) NOT NULL,

  question_id VARCHAR(64) NOT NULL,
  questionnaire_id VARCHAR(64) NULL,
  questionnaire_version VARCHAR(64) NULL,
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
  INDEX idx_analysis_answers_questionnaire (questionnaire_id, questionnaire_version, question_id),
  INDEX idx_analysis_answers_session_question (session_id, question_id),
  INDEX idx_analysis_answers_respondent_question (respondent_id, question_id),

  CONSTRAINT fk_analysis_answers_session
    FOREIGN KEY (session_id) REFERENCES survey_sessions(id)
    ON DELETE CASCADE,

  CONSTRAINT fk_analysis_answers_respondent
    FOREIGN KEY (respondent_id) REFERENCES respondents(id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
