"""SQLite-backed persistence of autobuild run state and events.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_store.py`
(see the KCC x Superpowers Hybrid Framework Plan 01, Task 3).

Transitions are optimistic: an update is only applied when the stored
run state still equals the caller's expected state. On any mismatch or
failure the whole transaction is rolled back so no partial state or
event is persisted.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from kcc_autobuild.models import LifecycleState, RunEvent, RunRecord
from kcc_autobuild.state_machine import assert_transition


class ConcurrentStateChange(RuntimeError):
    """Raised when the stored run state conflicts with the expected state."""


class RunStore:
    """Persist autobuild run records and lifecycle events in SQLite."""

    def __init__(self, db_path: str | Path) -> None:
        self._path = Path(db_path)
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(self._path)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA foreign_keys = ON")
        self._migration = (
            Path(__file__).resolve().parents[2] / "migrations" / "001_init.sql"
        )
        exists = self.conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'runs'"
        ).fetchone()
        if exists is None:
            self.conn.executescript(self._migration.read_text(encoding="utf-8"))

    def create_run(self, record: RunRecord) -> None:
        with self.conn:
            self.conn.execute(
                "INSERT INTO runs (run_id, title, created_at, state, contract_hash)"
                " VALUES (?, ?, ?, ?, ?)",
                (
                    record.run_id,
                    record.title,
                    record.created_at.isoformat(),
                    record.state.value,
                    record.contract_hash,
                ),
            )
            self._append_event_locked(
                RunEvent(
                    run_id=record.run_id,
                    kind="run.created",
                    at=record.created_at,
                    payload={"state": record.state.value},
                )
            )

    def _append_event_locked(self, event: RunEvent) -> None:
        """Insert an event row. Caller must hold the write transaction."""
        self.conn.execute(
            "INSERT INTO events (run_id, kind, at, payload_json)"
            " VALUES (?, ?, ?, ?)",
            (
                event.run_id,
                event.kind,
                event.at.isoformat(),
                json.dumps(event.payload, sort_keys=True),
            ),
        )

    def load_run(self, run_id: str) -> RunRecord:
        row = self.conn.execute(
            "SELECT run_id, title, created_at, state, contract_hash"
            " FROM runs WHERE run_id = ?",
            (run_id,),
        ).fetchone()
        if row is None:
            raise KeyError(run_id)
        return RunRecord(
            run_id=row["run_id"],
            title=row["title"],
            created_at=datetime.fromisoformat(row["created_at"]),
            state=LifecycleState(row["state"]),
            contract_hash=row["contract_hash"],
        )

    def transition(
        self,
        run_id: str,
        expected: LifecycleState,
        target: LifecycleState,
        reason: str,
    ) -> None:
        try:
            self.conn.execute("BEGIN IMMEDIATE")
            row = self.conn.execute(
                "SELECT state FROM runs WHERE run_id = ?", (run_id,)
            ).fetchone()
            if row is None or LifecycleState(row["state"]) != expected:
                raise ConcurrentStateChange(f"expected {expected.value}")
            assert_transition(expected, target)
            self.conn.execute(
                "UPDATE runs SET state = ? WHERE run_id = ?",
                (target.value, run_id),
            )
            self._append_event_locked(
                RunEvent(
                    run_id=run_id,
                    kind="state.transition",
                    at=datetime.now(timezone.utc),
                    payload={
                        "from": expected.value,
                        "to": target.value,
                        "reason": reason,
                    },
                )
            )
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise

    def list_events(self, run_id: str) -> list[RunEvent]:
        rows = self.conn.execute(
            "SELECT id, run_id, kind, at, payload_json FROM events"
            " WHERE run_id = ? ORDER BY id",
            (run_id,),
        ).fetchall()
        return [
            RunEvent(
                run_id=row["run_id"],
                kind=row["kind"],
                at=datetime.fromisoformat(row["at"]),
                payload=json.loads(row["payload_json"]),
            )
            for row in rows
        ]

    def close(self) -> None:
        self.conn.close()
