"""Behavioral contract for fenced autobuild task leases / isolated workspace claims.

Owned by ``test_leases.py`` (see the KCC x Superpowers Hybrid Framework
Plan 04, Task 4: Fenced leases / isolated workspace claims, in
``.superpowers/bootstrap/plans/2026-08-27-04-scheduler-budget-rate-policy.task-contracts.md``).

Every execution attempt owns exactly one KCC lease, one budget envelope,
one isolated workspace and one Execution Report (Global Constraint), so
leases are the control plane's fence against stale workers: a lease is
live only while it is neither expired nor fenced, and a task's
generation increments monotonically with every fresh claim.

The prescribed scenario under test: an expired old lease is invalid
(``lease_is_live`` -> False) and the next claim for the same task is
valid (True) with ``generation + 1``.

Two layers are under contract:

- :class:`~kcc_autobuild.leases.LeaseLedger` -- the pure in-memory state
  machine (claim / expire / fence / liveness) with no I/O;
- :class:`~kcc_autobuild.leases.LeaseStore` -- the same semantics
  persisted through :class:`~kcc_autobuild.store.RunStore` SQLite tables
  ``tasks`` / ``task_leases`` (:file:`.KCC/runtime/migrations/002_tasks_leases.sql`),
  with a per-task monotonic ``generation`` and
  ``UNIQUE (task_id, generation)``.

All liveness assertions pass an explicit deterministic ``now`` so the
contract is exact (a lease is stale at the expiry instant; a TTL-backed
lease is never casually misread against the wall clock).
"""

from __future__ import annotations

import re
import sqlite3
from datetime import datetime, timedelta, timezone

import pytest

from kcc_autobuild.leases import (
    Lease,
    LeaseConflict,
    LeaseLedger,
    LeaseStatus,
    LeaseStore,
    mint_lease_id,
    mint_workspace_id,
)
from kcc_autobuild.models import RunRecord
from kcc_autobuild.store import RunStore

T0 = datetime(2026, 8, 28, 12, 0, 0, tzinfo=timezone.utc)
"""Fixed deterministic instant so lease timing assertions are exact."""

LEASE_ID_PATTERN = re.compile(r"^LEASE-RUN-001-T1-\d+$")
"""Controller-minted lease id shape: ``LEASE-{run_id}-{task_id}-{generation}``."""


def _make_ledger(**kwargs) -> LeaseLedger:
    return LeaseLedger(**kwargs)


def _make_store(tmp_path, **kwargs) -> tuple[RunStore, LeaseStore]:
    store = RunStore(tmp_path / "run.db")
    store.create_run(
        RunRecord(
            run_id="RUN-001",
            title="fenced lease demo",
            created_at=datetime.now(timezone.utc),
        )
    )
    return store, LeaseStore(store, **kwargs)


def _make_store_from_existing(tmp_path) -> tuple[RunStore, LeaseStore]:
    store = RunStore(tmp_path / "run.db")
    return store, LeaseStore(store)


# --- Prescribed scenario: expired old lease invalid, new lease valid ---------


def test_prescribed_expired_old_lease_invalid_and_new_lease_valid():
    ledger = _make_ledger(lease_ttl=timedelta(seconds=30))
    first = ledger.claim("RUN-001", "T1", now=T0)
    assert first.generation == 1
    assert ledger.lease_is_live(first.lease_id, "RUN-001", now=T0) is True
    # The lease goes stale by expiry; the old lease is invalid afterwards.
    expired = ledger.expire_stale(now=T0 + timedelta(seconds=31))
    assert [lease.lease_id for lease in expired] == [first.lease_id]
    assert ledger.lease_is_live(
        first.lease_id, "RUN-001", now=T0 + timedelta(seconds=31)
    ) is False
    # The next claim for the same task gets generation + 1 and is valid.
    second = ledger.claim("RUN-001", "T1", now=T0 + timedelta(seconds=31))
    assert second.generation == first.generation + 1
    assert second.generation == 2
    assert ledger.lease_is_live(
        second.lease_id, "RUN-001", now=T0 + timedelta(seconds=31)
    ) is True


def test_prescribed_scenario_persisted_through_runstore(tmp_path):
    store, leases = _make_store(tmp_path, lease_ttl=timedelta(seconds=30))
    first = leases.claim("RUN-001", "T1", now=T0)
    assert leases.lease_is_live(first.lease_id, "RUN-001", now=T0) is True
    expired = leases.expire_stale(now=T0 + timedelta(seconds=31))
    # The sweep returns the newly expired leases already marked EXPIRED
    # (the release-exactly-once contract: a status-guarded controller
    # release must fire for every returned lease).
    assert [lease.lease_id for lease in expired] == [first.lease_id]
    assert expired[0].status is LeaseStatus.EXPIRED
    assert leases.lease_is_live(
        first.lease_id, "RUN-001", now=T0 + timedelta(seconds=31)
    ) is False
    second = leases.claim("RUN-001", "T1", now=T0 + timedelta(seconds=31))
    assert second.generation == first.generation + 1
    assert leases.lease_is_live(
        second.lease_id, "RUN-001", now=T0 + timedelta(seconds=31)
    ) is True
    # The fenced generation is durable: a fresh store over the same DB
    # (fresh connection) sees the same liveness and same generation.
    _, reopened = _make_store_from_existing(tmp_path)
    assert reopened.lease_is_live(
        first.lease_id, "RUN-001", now=T0 + timedelta(seconds=31)
    ) is False
    assert reopened.lease_is_live(
        second.lease_id, "RUN-001", now=T0 + timedelta(seconds=31)
    ) is True
    assert reopened.current_generation("T1") == 2


# --- Controller-minted lease ids and isolated workspace claims ---------------


def test_controller_mints_lease_ids_deterministically():
    ledger = _make_ledger()
    first = ledger.claim("RUN-001", "T1", now=T0)
    assert first.lease_id == "LEASE-RUN-001-T1-1"
    assert LEASE_ID_PATTERN.fullmatch(first.lease_id)
    assert first.workspace_id == "WS-RUN-001-T1-1"
    ledger.fence(first.lease_id)
    second = ledger.claim("RUN-001", "T1", now=T0 + timedelta(seconds=1))
    assert second.lease_id == "LEASE-RUN-001-T1-2"
    assert LEASE_ID_PATTERN.fullmatch(second.lease_id)
    # Every claim claims its own isolated workspace (one lease, one
    # isolated workspace per execution attempt).
    assert second.workspace_id == "WS-RUN-001-T1-2"
    assert second.workspace_id != first.workspace_id


def test_mint_helpers_always_agree_with_the_claim():
    ledger = _make_ledger()
    lease = ledger.claim("RUN-001", "T1", now=T0)
    assert mint_lease_id("RUN-001", "T1", lease.generation) == lease.lease_id
    assert mint_workspace_id("RUN-001", "T1", lease.generation) == lease.workspace_id


# --- Monotonic per-task generation -------------------------------------------


def test_monotonic_generation_increments_per_task_only():
    ledger = _make_ledger()
    a1 = ledger.claim("RUN-001", "T1", now=T0)
    b1 = ledger.claim("RUN-001", "T2", now=T0)
    assert a1.generation == 1
    assert b1.generation == 1  # generations are per-task, not global
    ledger.fence(a1.lease_id)
    a2 = ledger.claim("RUN-001", "T1", now=T0 + timedelta(seconds=1))
    assert a2.generation == 2
    assert ledger.current_generation("T1") == 2
    assert ledger.current_generation("T2") == 1
    assert ledger.current_generation("T3") == 0  # never claimed
    assert b1.generation == 1  # T2 untouched by T1's advance


def test_fence_invalidates_the_old_lease_and_next_claim_advances():
    ledger = _make_ledger()
    first = ledger.claim("RUN-001", "T1", now=T0)
    fenced = ledger.fence(first.lease_id)
    assert fenced.status is LeaseStatus.FENCED
    assert ledger.lease_is_live(first.lease_id, "RUN-001", now=T0) is False
    second = ledger.claim("RUN-001", "T1", now=T0 + timedelta(seconds=1))
    assert second.generation == first.generation + 1
    assert ledger.lease_is_live(second.lease_id, "RUN-001", now=T0) is True


def test_fence_of_unknown_lease_raises():
    ledger = _make_ledger()
    with pytest.raises(KeyError):
        ledger.fence("LEASE-RUN-001-T1-99")


def test_expired_lease_is_invalid_before_any_sweep():
    ledger = _make_ledger(lease_ttl=timedelta(seconds=10))
    lease = ledger.claim("RUN-001", "T1", now=T0)
    assert ledger.lease_is_live(
        lease.lease_id, "RUN-001", now=T0 + timedelta(seconds=11)
    ) is False
    # One second before expiry the lease is still live; at the exact
    # expiry instant it is stale.
    assert ledger.lease_is_live(
        lease.lease_id, "RUN-001", now=T0 + timedelta(seconds=9)
    ) is True
    assert ledger.lease_is_live(
        lease.lease_id, "RUN-001", now=T0 + timedelta(seconds=10)
    ) is False


def test_claim_after_lapse_advances_generation_without_explicit_sweep():
    ledger = _make_ledger(lease_ttl=timedelta(seconds=10))
    first = ledger.claim("RUN-001", "T1", now=T0)
    second = ledger.claim("RUN-001", "T1", now=T0 + timedelta(seconds=11))
    assert second.generation == first.generation + 1
    assert ledger.lease_status(first.lease_id) is LeaseStatus.EXPIRED
    assert ledger.lease_is_live(first.lease_id, "RUN-001", now=T0) is False


def test_claim_while_previous_lease_is_still_live_raises_fail_closed():
    ledger = _make_ledger(lease_ttl=timedelta(seconds=30))
    first = ledger.claim("RUN-001", "T1", now=T0)
    with pytest.raises(LeaseConflict):
        ledger.claim("RUN-001", "T1", now=T0 + timedelta(seconds=1))
    # The rejected claim consumed no generation and invalidated nothing.
    assert ledger.current_generation("T1") == 1
    assert ledger.lease_is_live(first.lease_id, "RUN-001", now=T0 + timedelta(seconds=1)) is True


def test_unknown_lease_is_never_live():
    ledger = _make_ledger()
    assert ledger.lease_is_live("LEASE-RUN-001-T9-1", "RUN-001", now=T0) is False
    assert ledger.lease_is_live("LEASE-RUN-001-T1-99", "RUN-001", now=T0) is False


def test_live_lease_is_bound_to_its_run():
    ledger = _make_ledger()
    lease = ledger.claim("RUN-001", "T1", now=T0)
    assert ledger.lease_is_live(lease.lease_id, "RUN-001", now=T0) is True
    # A lease issued for one run is never live for another run.
    assert ledger.lease_is_live(lease.lease_id, "RUN-002", now=T0) is False


def test_expire_stale_only_touches_live_expired_leases():
    ledger = _make_ledger(lease_ttl=timedelta(seconds=10))
    l1 = ledger.claim("RUN-001", "T1", now=T0)
    l2 = ledger.claim("RUN-001", "T2", now=T0)
    ledger.fence(l2.lease_id)
    l3 = ledger.claim("RUN-001", "T3", now=T0 + timedelta(seconds=5))
    expired = ledger.expire_stale(now=T0 + timedelta(seconds=11))
    # T1 lapsed (issued at T0); fenced T2 stays fenced; T3 (issued later,
    # still inside its TTL) is untouched. Deterministic order by lease id,
    # and the returned leases carry the persisted (EXPIRED) status.
    assert [lease.lease_id for lease in expired] == [l1.lease_id]
    assert expired[0].status is LeaseStatus.EXPIRED
    assert ledger.lease_status(l1.lease_id) is LeaseStatus.EXPIRED
    assert ledger.lease_status(l2.lease_id) is LeaseStatus.FENCED
    assert ledger.lease_status(l3.lease_id) is LeaseStatus.LIVE
    assert ledger.lease_is_live(l1.lease_id, "RUN-001", now=T0 + timedelta(seconds=11)) is False
    assert ledger.lease_is_live(l3.lease_id, "RUN-001", now=T0 + timedelta(seconds=11)) is True
    # A second sweep inside l3's TTL has nothing left to expire.
    assert ledger.expire_stale(now=T0 + timedelta(seconds=12)) == ()


def test_lease_status_mirrors_the_claim_lifecycle():
    ledger = _make_ledger(lease_ttl=timedelta(seconds=10))
    lease = ledger.claim("RUN-001", "T1", now=T0)
    assert ledger.lease_status(lease.lease_id) is LeaseStatus.LIVE
    ledger.expire_stale(now=T0 + timedelta(seconds=11))
    assert ledger.lease_status(lease.lease_id) is LeaseStatus.EXPIRED
    with pytest.raises(KeyError):
        ledger.lease_status("LEASE-RUN-001-T9-1")


def test_lease_without_ttl_stays_live_until_fenced():
    ledger = _make_ledger()
    lease = ledger.claim("RUN-001", "T1", now=T0)
    assert lease.expires_at is None
    assert ledger.lease_is_live(
        lease.lease_id, "RUN-001", now=T0 + timedelta(days=365)
    ) is True
    ledger.fence(lease.lease_id)
    assert ledger.lease_is_live(
        lease.lease_id, "RUN-001", now=T0 + timedelta(days=365)
    ) is False


# --- Lease value object -------------------------------------------------------


def test_lease_rejects_invalid_fields():
    with pytest.raises(ValueError):
        Lease(
            lease_id="", run_id="RUN-001", task_id="T1", generation=1,
            workspace_id="WS-1", issued_at=T0,
        )
    with pytest.raises(ValueError):
        Lease(
            lease_id="L", run_id="", task_id="T1", generation=1,
            workspace_id="WS-1", issued_at=T0,
        )
    with pytest.raises(ValueError):
        Lease(
            lease_id="L", run_id="RUN-001", task_id="", generation=1,
            workspace_id="WS-1", issued_at=T0,
        )
    with pytest.raises(ValueError):
        Lease(
            lease_id="L", run_id="RUN-001", task_id="T1", generation=0,
            workspace_id="WS-1", issued_at=T0,
        )
    with pytest.raises(ValueError):
        Lease(
            lease_id="L", run_id="RUN-001", task_id="T1", generation=1,
            workspace_id="", issued_at=T0,
        )


def test_lease_requires_timezone_aware_timestamps():
    naive = datetime(2026, 8, 28, 12, 0, 0)
    with pytest.raises(ValueError):
        Lease(
            lease_id="L", run_id="RUN-001", task_id="T1", generation=1,
            workspace_id="WS-1", issued_at=naive,
        )
    with pytest.raises(ValueError):
        Lease(
            lease_id="L", run_id="RUN-001", task_id="T1", generation=1,
            workspace_id="WS-1", issued_at=T0, expires_at=T0,  # must be later
        )
    with pytest.raises(ValueError):
        Lease(
            lease_id="L", run_id="RUN-001", task_id="T1", generation=1,
            workspace_id="WS-1", issued_at=T0,
            expires_at=T0 - timedelta(seconds=1),
        )


def test_lease_is_immutable():
    lease = Lease(
        lease_id="L", run_id="RUN-001", task_id="T1", generation=1,
        workspace_id="WS-1", issued_at=T0,
    )
    with pytest.raises(AttributeError):
        lease.lease_id = "OTHER"  # type: ignore[misc]


# --- Persistence: tasks / task_leases tables (migration 002) -----------------


def test_migration_creates_tasks_and_task_leases_tables(tmp_path):
    store, leases = _make_store(tmp_path)
    tables = {
        row["name"]
        for row in store.conn.execute(
            "SELECT name FROM sqlite_master"
            " WHERE type = 'table' AND name IN ('tasks', 'task_leases')"
        )
    }
    assert tables == {"tasks", "task_leases"}
    assert store.conn.execute(
        "SELECT MAX(version) FROM schema_version"
    ).fetchone()[0] == 2


def test_unique_task_generation_is_enforced_at_the_database(tmp_path):
    store, leases = _make_store(tmp_path)
    leases.claim("RUN-001", "T1", now=T0)
    row = store.conn.execute(
        "SELECT generation FROM tasks WHERE task_id = 'T1'"
    ).fetchone()
    assert row["generation"] == 1
    # Inserting a second lease for the same (task, generation) must be
    # rejected by the UNIQUE (task_id, generation) constraint.
    with pytest.raises(sqlite3.IntegrityError):
        store.conn.execute(
            "INSERT INTO task_leases"
            " (lease_id, run_id, task_id, generation, status,"
            "  workspace_id, issued_at, expires_at)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (
                "LEASE-RUN-001-T1-1",
                "RUN-001",
                "T1",
                1,
                "live",
                "WS-RUN-001-T1-1",
                T0.isoformat(),
                None,
            ),
        )


def test_persisted_generation_is_monotonic(tmp_path):
    store, leases = _make_store(tmp_path)
    first = leases.claim("RUN-001", "T1", now=T0)
    leases.fence(first.lease_id)
    second = leases.claim("RUN-001", "T1", now=T0 + timedelta(seconds=1))
    assert second.generation == first.generation + 1
    row = store.conn.execute(
        "SELECT generation FROM tasks WHERE task_id = 'T1'"
    ).fetchone()
    assert row["generation"] == 2
    rows = store.conn.execute(
        "SELECT generation FROM task_leases WHERE task_id = 'T1'"
        " ORDER BY generation"
    ).fetchall()
    assert [row["generation"] for row in rows] == [1, 2]


def test_persisted_fence_is_durable_across_store_instances(tmp_path):
    store, leases = _make_store(tmp_path)
    first = leases.claim("RUN-001", "T1", now=T0)
    assert leases.lease_is_live(first.lease_id, "RUN-001", now=T0) is True
    leases.fence(first.lease_id)
    reopened_store, reopened = _make_store_from_existing(tmp_path)
    assert reopened.lease_is_live(first.lease_id, "RUN-001", now=T0) is False
    assert reopened.lease_status(first.lease_id) is LeaseStatus.FENCED
    # The next claim through the reopened store gets generation + 1.
    second = reopened.claim("RUN-001", "T1", now=T0 + timedelta(seconds=1))
    assert second.generation == first.generation + 1
    assert reopened.lease_is_live(second.lease_id, "RUN-001", now=T0) is True
    reopened_store.close()
    store.close()


def test_persisted_expiry_is_durable(tmp_path):
    store, leases = _make_store(tmp_path, lease_ttl=timedelta(seconds=30))
    first = leases.claim("RUN-001", "T1", now=T0)
    leases.expire_stale(now=T0 + timedelta(seconds=31))
    reopened_store, reopened = _make_store_from_existing(tmp_path)
    # The expired status is persisted: not live even when asked about a
    # moment before the lease lapsed.
    assert reopened.lease_is_live(first.lease_id, "RUN-001", now=T0) is False
    assert reopened.lease_status(first.lease_id) is LeaseStatus.EXPIRED
    second = reopened.claim("RUN-001", "T1", now=T0 + timedelta(seconds=31))
    assert second.generation == first.generation + 1
    reopened_store.close()
    store.close()


def test_expire_stale_returns_expired_status_from_the_store(tmp_path):
    store, leases = _make_store(tmp_path, lease_ttl=timedelta(seconds=30))
    first = leases.claim("RUN-001", "T1", now=T0)
    other = leases.claim("RUN-001", "T2", now=T0)
    leases.fence(other.lease_id)
    expired = leases.expire_stale(now=T0 + timedelta(seconds=31))
    # Every returned lease is the just-persisted EXPIRED lease (never a
    # stale LIVE snapshot): a status-guarded release fires exactly once.
    assert [lease.lease_id for lease in expired] == [first.lease_id]
    assert expired[0].status is LeaseStatus.EXPIRED
    assert expired[0].status == leases.lease_status(first.lease_id)
    # A second sweep returns nothing (no double release).
    assert leases.expire_stale(now=T0 + timedelta(seconds=32)) == ()
    store.close()


def test_partial_migration_heal_recreates_the_missing_lease_table(tmp_path):
    store, leases = _make_store(tmp_path)
    # Simulate a migration 002 crash between its two CREATE TABLEs: only
    # the tasks table survived.
    store.conn.execute("DROP TABLE task_leases")
    store.conn.commit()
    reopened_store = RunStore(tmp_path / "run.db")
    healed = LeaseStore(reopened_store)
    tables = {
        row["name"]
        for row in reopened_store.conn.execute(
            "SELECT name FROM sqlite_master"
            " WHERE type = 'table' AND name IN ('tasks', 'task_leases')"
        )
    }
    assert tables == {"tasks", "task_leases"}
    # Claims work end to end through the healed database.
    lease = healed.claim("RUN-001", "T1", now=T0)
    assert healed.lease_is_live(lease.lease_id, "RUN-001", now=T0) is True
    reopened_store.close()
    store.close()


def test_persisted_current_lease_reflects_the_latest_generation(tmp_path):
    store, leases = _make_store(tmp_path)
    first = leases.claim("RUN-001", "T1", now=T0)
    assert leases.current_lease("T1").lease_id == first.lease_id
    leases.fence(first.lease_id)
    second = leases.claim("RUN-001", "T1", now=T0 + timedelta(seconds=1))
    assert leases.current_lease("T1").lease_id == second.lease_id
    assert leases.current_generation("T1") == 2
    assert leases.current_lease("T9") is None
