-- Run only after deploying the package-only API cleanup and confirming that no
-- external clients still call the removed answers, audio, trajectory, or
-- llm-events endpoints. Back up the database before applying this migration.

DROP TABLE IF EXISTS audio_recordings;
DROP TABLE IF EXISTS trajectory_points;
DROP TABLE IF EXISTS answers;
DROP TABLE IF EXISTS llm_events;
DROP TABLE IF EXISTS questions;
