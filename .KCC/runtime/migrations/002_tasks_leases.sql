-- Plan 04, Task 4: Fenced autobuild task leases / isolated workspace claims.
-- Adds the per-task monotonic generation counter (tasks) and the fenced
-- lease ledger (task_leases) with UNIQUE (task, generation).
--
-- Applied by kcc_autobuild.leases.LeaseStore after 001_init.sql (the
-- RunStore applies 001 on a fresh database; this migration is applied by
-- the lease store because the store is the migration's only consumer).
-- Every statement is idempotent so a partially migrated database can be
-- reopened safely.

CREATE TABLE IF NOT EXISTS tasks (
    task_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS task_leases (
    lease_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    task_id TEXT NOT NULL REFERENCES tasks(task_id) ON DELETE CASCADE,
    generation INTEGER NOT NULL CHECK (generation >= 1),
    status TEXT NOT NULL CHECK (status IN ('live', 'expired', 'fenced')),
    workspace_id TEXT NOT NULL,
    issued_at TEXT NOT NULL,
    expires_at TEXT,
    UNIQUE (task_id, generation)
);

INSERT OR IGNORE INTO schema_version(version) VALUES (2);
