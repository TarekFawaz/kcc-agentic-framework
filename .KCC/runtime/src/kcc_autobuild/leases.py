"""Fenced autobuild task leases / isolated workspace claims.

Plan 04, Task 4 (Fenced leases / isolated workspace claims): every
execution attempt owns exactly one KCC lease, one budget envelope, one
isolated workspace and one Execution Report (Global Constraint), and a
stale (expired or fenced) lease must be invalid so a hung worker can
never report against a lease the controller has already moved past.

The behavioral contract is owned by :file:`.KCC/runtime/tests/test_leases.py`:

- :class:`Lease` is an immutable controller-minted lease: ``lease_id``
  (``LEASE-{run_id}-{task_id}-{generation}``), bound to its run and task,
  with a strictly positive, per-task monotonic ``generation`` and an
  ``workspace_id`` claiming one isolated workspace for the attempt.
- :class:`LeaseLedger` is the pure in-memory state machine: ``claim``
  mints the next generation for the task (``generation + 1``; the first
  claim is generation 1) and fail-closed refuses to claim over a still
  live lease (:class:`LeaseConflict` -- one live lease per task);
  ``expire_stale`` and ``fence`` invalidate the old lease; a lease is
  live only while it is neither expired nor fenced and its TTL has not
  lapsed (``lease_is_live``). No I/O, no wall clock unless handed one.
- :class:`LeaseStore` persists the same semantics through
  :class:`~kcc_autobuild.store.RunStore` SQLite: the ``tasks`` table
  keeps the per-task monotonic generation and ``task_leases`` the fenced
  lease ledger with ``UNIQUE (task_id, generation)``
  (:file:`.KCC/runtime/migrations/002_tasks_leases.sql`). It implements
  :class:`kcc_autobuild.evidence.LeaseVerifier`'s shape
  (``lease_is_live(lease_id, run_id)``) so a rejected report can never
  ride a stale lease (fail-closed).
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
from enum import Enum
from pathlib import Path

from kcc_autobuild.store import RunStore

MIGRATION_002 = (
    Path(__file__).resolve().parents[2] / "migrations" / "002_tasks_leases.sql"
)
"""Migration creating ``tasks`` / ``task_leases`` on the RunStore database."""


class LeaseStatus(str, Enum):
    """Lifecycle of one minted lease.

    ``live`` -> the attempt is accounted for; ``expired`` -> the lease
    was issued with a TTL and lapsed (stale); ``fenced`` -> the lease was
    revoked explicitly (hung/fenced worker, pause drain, deviation).
    """

    LIVE = "live"
    EXPIRED = "expired"
    FENCED = "fenced"


class LeaseConflict(ValueError):
    """Raised when a task is claimed while it still holds a live lease.

    One live lease per task (one KCC lease per execution attempt):
    claiming over a live lease is a controller bug, not a retry.
    """


def _require_nonempty(value: str, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{name} must be a non-empty string")
    return value


def _as_utc(value: datetime, name: str) -> datetime:
    """Require timezone-aware input and normalize to UTC (R7 discipline)."""
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError(f"{name} must be timezone-aware")
    return value.astimezone(timezone.utc)


def mint_lease_id(run_id: str, task_id: str, generation: int) -> str:
    """Controller-minted deterministic lease id (one per generation)."""
    return f"LEASE-{run_id}-{task_id}-{generation}"


def mint_workspace_id(run_id: str, task_id: str, generation: int) -> str:
    """Deterministic isolated workspace id claimed by one lease."""
    return f"WS-{run_id}-{task_id}-{generation}"


def _lapsed(lease: Lease, now: datetime) -> bool:
    return lease.expires_at is not None and lease.expires_at <= now


@dataclass(frozen=True)
class Lease:
    """One controller-minted task lease (isolated workspace claim).

    ``generation`` is strictly positive and monotonic per task; the lease
    is bound to its run (``lease_is_live`` refuses cross-run checks) and
    ``workspace_id`` is the isolated workspace claimed for exactly this
    attempt. Timestamps are timezone-aware and normalized to UTC.
    """

    lease_id: str
    run_id: str
    task_id: str
    generation: int
    workspace_id: str
    issued_at: datetime
    expires_at: datetime | None = None
    status: LeaseStatus = LeaseStatus.LIVE

    def __post_init__(self) -> None:
        _require_nonempty(self.lease_id, "lease_id")
        _require_nonempty(self.run_id, "run_id")
        _require_nonempty(self.task_id, "task_id")
        _require_nonempty(self.workspace_id, "workspace_id")
        if (
            not isinstance(self.generation, int)
            or isinstance(self.generation, bool)
            or self.generation < 1
        ):
            raise ValueError(
                f"generation must be a positive int, got {self.generation!r}"
            )
        object.__setattr__(self, "issued_at", _as_utc(self.issued_at, "issued_at"))
        if self.expires_at is not None:
            expires_at = _as_utc(self.expires_at, "expires_at")
            if expires_at <= self.issued_at:
                raise ValueError("expires_at must be later than issued_at")
            object.__setattr__(self, "expires_at", expires_at)
        object.__setattr__(self, "status", LeaseStatus(self.status))


class LeaseLedger:
    """Pure in-memory fenced-lease state machine (no I/O).

    The controller's single point of truth for "is this attempt still
    accounted for": ``claim`` mints the next per-task generation,
    ``expire_stale`` / ``fence`` invalidate the old lease so the *next*
    claim gets ``generation + 1``, and ``lease_is_live`` is False for
    expired, fenced, unknown or cross-run leases. A lease with a TTL is
    stale at its expiry instant even before any sweep runs.
    """

    def __init__(self, lease_ttl: timedelta | None = None) -> None:
        if lease_ttl is not None and lease_ttl <= timedelta(0):
            raise ValueError("lease_ttl must be positive when set")
        self.lease_ttl = lease_ttl
        self._leases: dict[str, Lease] = {}
        self._current: dict[str, str] = {}
        self._generations: dict[str, int] = {}

    def claim(
        self,
        run_id: str,
        task_id: str,
        *,
        now: datetime | None = None,
        workspace_id: str | None = None,
    ) -> Lease:
        """Mint one live lease for the task at ``generation + 1``.

        Fail-closed: a task that still holds a live (not expired, not
        fenced) lease cannot be claimed again -- :class:`LeaseConflict`
        -- because one KCC lease corresponds to one execution attempt.
        A previous lease that lapsed is marked expired (self-healing
        without requiring a sweep) and the claim proceeds.
        """
        run_id = _require_nonempty(run_id, "run_id")
        task_id = _require_nonempty(task_id, "task_id")
        now = _as_utc(now if now is not None else datetime.now(timezone.utc), "now")
        current_id = self._current.get(task_id)
        if current_id is not None:
            current = self._leases[current_id]
            if current.status is LeaseStatus.LIVE and not _lapsed(current, now):
                raise LeaseConflict(
                    f"task {task_id!r} still holds a live lease "
                    f"{current.lease_id!r} (one live lease per task)"
                )
            if current.status is LeaseStatus.LIVE and _lapsed(current, now):
                self._leases[current_id] = replace(
                    current, status=LeaseStatus.EXPIRED
                )
        generation = self._generations.get(task_id, 0) + 1
        lease = Lease(
            lease_id=mint_lease_id(run_id, task_id, generation),
            run_id=run_id,
            task_id=task_id,
            generation=generation,
            workspace_id=(
                workspace_id
                if workspace_id is not None
                else mint_workspace_id(run_id, task_id, generation)
            ),
            issued_at=now,
            expires_at=(now + self.lease_ttl) if self.lease_ttl is not None else None,
            status=LeaseStatus.LIVE,
        )
        self._leases[lease.lease_id] = lease
        self._current[task_id] = lease.lease_id
        self._generations[task_id] = generation
        return lease

    def lease_is_live(
        self,
        lease_id: str,
        run_id: str | None = None,
        *,
        now: datetime | None = None,
    ) -> bool:
        """Whether ``lease_id`` still accounts for its execution attempt.

        False for unknown leases, foreign-run leases, fenced or expired
        leases, and leases whose TTL has lapsed (checked even before a
        ``expire_stale`` sweep). ``now`` defaults to the wall clock; the
        exact expiry instant is stale.
        """
        lease = self._leases.get(lease_id)
        if lease is None:
            return False
        if run_id is not None and lease.run_id != run_id:
            return False
        now = _as_utc(now if now is not None else datetime.now(timezone.utc), "now")
        return lease.status is LeaseStatus.LIVE and not _lapsed(lease, now)

    def lease_status(self, lease_id: str) -> LeaseStatus:
        """Persisted lifecycle status of one lease (``KeyError`` unknown)."""
        try:
            return self._leases[lease_id].status
        except KeyError:
            raise KeyError(lease_id) from None

    def expire_stale(self, now: datetime | None = None) -> tuple[Lease, ...]:
        """Sweep every live lease whose TTL has lapsed (stale expiry).

        Returns the newly expired :class:`Lease` objects in deterministic
        (lease id ascending) order so the controller can release their
        money/rate reservations exactly once.
        """
        now = _as_utc(now if now is not None else datetime.now(timezone.utc), "now")
        swept: list[Lease] = []
        for lease_id in sorted(self._leases):
            lease = self._leases[lease_id]
            if lease.status is LeaseStatus.LIVE and _lapsed(lease, now):
                updated = replace(lease, status=LeaseStatus.EXPIRED)
                self._leases[lease_id] = updated
                swept.append(updated)
        return tuple(swept)

    def fence(self, lease_id: str) -> Lease:
        """Explicitly revoke one lease (hung worker, pause drain, deviation).

        Returns the fenced :class:`Lease`; unknown leases raise
        :class:`KeyError` (fencing a lease that does not exist is a bug).
        """
        lease = self._leases.get(lease_id)
        if lease is None:
            raise KeyError(lease_id)
        updated = replace(lease, status=LeaseStatus.FENCED)
        self._leases[lease_id] = updated
        return updated

    def current_lease(self, task_id: str) -> Lease | None:
        """The latest claimed :class:`Lease` for ``task_id`` (or None)."""
        current_id = self._current.get(task_id)
        return self._leases.get(current_id) if current_id is not None else None

    def current_generation(self, task_id: str) -> int:
        """Latest minted generation for ``task_id`` (0 if never claimed)."""
        return self._generations.get(task_id, 0)


class LeaseStore:
    """The same fenced-lease semantics persisted through RunStore/SQLite.

    Applies :file:`002_tasks_leases.sql` (idempotently) to the
    :class:`~kcc_autobuild.store.RunStore`'s database: per-task monotonic
    generation in ``tasks``, the full fenced lease ledger in
    ``task_leases`` with ``UNIQUE (task_id, generation)`` and the
    ``live`` / ``expired`` / ``fenced`` status. Claims are written
    atomically (``BEGIN IMMEDIATE``) so two controllers cannot mint the
    same generation; every status transition is durable across store
    instances and processes. The store satisfies
    :class:`kcc_autobuild.evidence.LeaseVerifier`.
    """

    def __init__(self, store: RunStore, lease_ttl: timedelta | None = None) -> None:
        if lease_ttl is not None and lease_ttl <= timedelta(0):
            raise ValueError("lease_ttl must be positive when set")
        self.lease_ttl = lease_ttl
        self._store = store
        self._conn = store.conn
        self._ensure_migrations()

    def _ensure_migrations(self) -> None:
        """Apply migration 002 once (idempotent) on this database."""
        exists = self._conn.execute(
            "SELECT name FROM sqlite_master"
            " WHERE type = 'table' AND name = 'tasks'"
        ).fetchone()
        if exists is None:
            self._conn.executescript(MIGRATION_002.read_text(encoding="utf-8"))

    @staticmethod
    def _parse(value: str | None) -> datetime | None:
        return datetime.fromisoformat(value) if value is not None else None

    def _load(self, row: sqlite3.Row) -> Lease:
        return Lease(
            lease_id=row["lease_id"],
            run_id=row["run_id"],
            task_id=row["task_id"],
            generation=row["generation"],
            workspace_id=row["workspace_id"],
            issued_at=datetime.fromisoformat(row["issued_at"]),
            expires_at=self._parse(row["expires_at"]),
            status=LeaseStatus(row["status"]),
        )

    def claim(
        self,
        run_id: str,
        task_id: str,
        *,
        now: datetime | None = None,
        workspace_id: str | None = None,
    ) -> Lease:
        """Mint and persist the next generation lease for the task.

        Same fail-closed semantics as
        :meth:`LeaseLedger.claim`: a still-live previous lease raises
        :class:`LeaseConflict`; a lapsed one is persisted as expired and
        the claim proceeds. ``UNIQUE (task_id, generation)`` is the
        database's final guard against a double mint.
        """
        run_id = _require_nonempty(run_id, "run_id")
        task_id = _require_nonempty(task_id, "task_id")
        now = _as_utc(now if now is not None else datetime.now(timezone.utc), "now")
        self._conn.execute("BEGIN IMMEDIATE")
        try:
            previous = self._conn.execute(
                "SELECT lease_id, status, expires_at FROM task_leases"
                " WHERE task_id = ? ORDER BY generation DESC LIMIT 1",
                (task_id,),
            ).fetchone()
            if previous is not None:
                previous_expiry = self._parse(previous["expires_at"])
                if (
                    previous["status"] == LeaseStatus.LIVE.value
                    and (previous_expiry is None or previous_expiry > now)
                ):
                    raise LeaseConflict(
                        f"task {task_id!r} still holds a live lease "
                        f"{previous['lease_id']!r} (one live lease per task)"
                    )
                if (
                    previous["status"] == LeaseStatus.LIVE.value
                    and previous_expiry is not None
                    and previous_expiry <= now
                ):
                    self._conn.execute(
                        "UPDATE task_leases SET status = ? WHERE lease_id = ?",
                        (LeaseStatus.EXPIRED.value, previous["lease_id"]),
                    )
            generation_row = self._conn.execute(
                "SELECT generation FROM tasks WHERE task_id = ?", (task_id,)
            ).fetchone()
            generation = (generation_row["generation"] + 1) if generation_row else 1
            lease = Lease(
                lease_id=mint_lease_id(run_id, task_id, generation),
                run_id=run_id,
                task_id=task_id,
                generation=generation,
                workspace_id=(
                    workspace_id
                    if workspace_id is not None
                    else mint_workspace_id(run_id, task_id, generation)
                ),
                issued_at=now,
                expires_at=(
                    (now + self.lease_ttl) if self.lease_ttl is not None else None
                ),
                status=LeaseStatus.LIVE,
            )
            now_iso = now.isoformat()
            expires_iso = (
                lease.expires_at.isoformat() if lease.expires_at is not None else None
            )
            self._conn.execute(
                "INSERT INTO tasks (task_id, run_id, generation, created_at)"
                " VALUES (?, ?, ?, ?)"
                " ON CONFLICT(task_id) DO UPDATE SET"
                " run_id = excluded.run_id, generation = excluded.generation",
                (task_id, run_id, generation, now_iso),
            )
            self._conn.execute(
                "INSERT INTO task_leases"
                " (lease_id, run_id, task_id, generation, status,"
                "  workspace_id, issued_at, expires_at)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    lease.lease_id,
                    run_id,
                    task_id,
                    generation,
                    LeaseStatus.LIVE.value,
                    lease.workspace_id,
                    now_iso,
                    expires_iso,
                ),
            )
            self._conn.commit()
        except Exception:
            self._conn.rollback()
            raise
        return lease

    def lease_is_live(
        self,
        lease_id: str,
        run_id: str | None = None,
        *,
        now: datetime | None = None,
    ) -> bool:
        """Persisted liveness (``False`` stale/expired/fenced/unknown)."""
        now = _as_utc(now if now is not None else datetime.now(timezone.utc), "now")
        if run_id is None:
            row = self._conn.execute(
                "SELECT status, expires_at FROM task_leases"
                " WHERE lease_id = ?",
                (lease_id,),
            ).fetchone()
        else:
            row = self._conn.execute(
                "SELECT status, expires_at FROM task_leases"
                " WHERE lease_id = ? AND run_id = ?",
                (lease_id, run_id),
            ).fetchone()
        if row is None or row["status"] != LeaseStatus.LIVE.value:
            return False
        expires_at = self._parse(row["expires_at"])
        return expires_at is None or expires_at > now

    def lease_status(self, lease_id: str) -> LeaseStatus:
        """Persisted lifecycle status of one lease (``KeyError`` unknown)."""
        row = self._conn.execute(
            "SELECT status FROM task_leases WHERE lease_id = ?", (lease_id,)
        ).fetchone()
        if row is None:
            raise KeyError(lease_id)
        return LeaseStatus(row["status"])

    def expire_stale(self, now: datetime | None = None) -> tuple[Lease, ...]:
        """Persistently sweep live leases whose TTL has lapsed.

        Returns the newly expired :class:`Lease` objects in lease id
        order so the controller can release their reservations exactly
        once; the expired status is durable.
        """
        now = _as_utc(now if now is not None else datetime.now(timezone.utc), "now")
        rows = self._conn.execute(
            "SELECT lease_id, run_id, task_id, generation, status,"
            " workspace_id, issued_at, expires_at"
            " FROM task_leases"
            " WHERE status = ? AND expires_at IS NOT NULL AND expires_at <= ?"
            " ORDER BY lease_id",
            (LeaseStatus.LIVE.value, now.isoformat()),
        ).fetchall()
        if not rows:
            return ()
        with self._conn:
            for row in rows:
                self._conn.execute(
                    "UPDATE task_leases SET status = ? WHERE lease_id = ?",
                    (LeaseStatus.EXPIRED.value, row["lease_id"]),
                )
        return tuple(self._load(row) for row in rows)

    def fence(self, lease_id: str) -> Lease:
        """Persistently revoke one lease (``KeyError`` unknown)."""
        with self._conn:
            cursor = self._conn.execute(
                "UPDATE task_leases SET status = ? WHERE lease_id = ?",
                (LeaseStatus.FENCED.value, lease_id),
            )
            if cursor.rowcount == 0:
                raise KeyError(lease_id)
        row = self._conn.execute(
            "SELECT lease_id, run_id, task_id, generation, status,"
            " workspace_id, issued_at, expires_at"
            " FROM task_leases WHERE lease_id = ?",
            (lease_id,),
        ).fetchone()
        return self._load(row)

    def current_lease(self, task_id: str) -> Lease | None:
        """The latest claimed :class:`Lease` for ``task_id`` (or None)."""
        row = self._conn.execute(
            "SELECT lease_id, run_id, task_id, generation, status,"
            " workspace_id, issued_at, expires_at"
            " FROM task_leases WHERE task_id = ?"
            " ORDER BY generation DESC LIMIT 1",
            (task_id,),
        ).fetchone()
        return self._load(row) if row is not None else None

    def current_generation(self, task_id: str) -> int:
        """Latest minted generation for ``task_id`` (0 if never claimed)."""
        row = self._conn.execute(
            "SELECT generation FROM tasks WHERE task_id = ?", (task_id,)
        ).fetchone()
        return row["generation"] if row is not None else 0
