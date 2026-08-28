-- Plan 05, Task 5: EXTERNAL_WAIT polling / rejection routing.
-- Adds the durable per-run external-review wait state
-- (external_wait_state): the recorded review outcome, when the wait
-- began, the next poll time (next_check_at) and the BUG attempt count
-- captured when the wait began. The pending-review poll schedule is
-- durable run state -- kept on disk, never in conversational memory
-- (spec 22) -- so it survives process restarts.
--
-- Applied by kcc_autobuild.external_wait.ExternalWaitStore after
-- 001_init.sql / 002_tasks_leases.sql (the store is the migration's only
-- consumer). Every statement is idempotent so a partially migrated
-- database can be reopened safely.

CREATE TABLE IF NOT EXISTS external_wait_state (
    run_id TEXT PRIMARY KEY REFERENCES runs(run_id) ON DELETE CASCADE,
    review_json TEXT NOT NULL,
    waiting_since TEXT,
    next_check_at TEXT,
    bug_attempts INTEGER NOT NULL DEFAULT 0 CHECK (bug_attempts >= 0),
    updated_at TEXT NOT NULL
);

INSERT OR IGNORE INTO schema_version(version) VALUES (3);
