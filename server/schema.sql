-- Minimal schema additions for trajectory storage.
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

