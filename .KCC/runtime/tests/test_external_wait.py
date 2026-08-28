"""Behavioral contract for EXTERNAL_WAIT polling / rejection routing.

Owned by ``test_external_wait.py`` (see the KCC x Superpowers Hybrid
Framework Plan 05, Task 5: EXTERNAL_WAIT polling / rejection routing, in
``.superpowers/bootstrap/plans/2026-08-27-05-resume-deploy-validation.task-contracts.md``).

Spec 20.2: external waiting states such as app-store review or third-party
manual approval are modeled as external waits rather than falsely reported
as completed autonomous work. Spec 19: EXTERNAL_WAIT is a side state of
the lifecycle; spec 18.1: multiple contract-external blockers are batched
into a single consolidated decision request. Spec 22: durable state is
mandatory -- the pending-review poll schedule is persisted, never kept in
conversation memory.

The behavioral contract:

* :class:`ExternalReview` is one review outcome value: ``status``
  (APPROVED / REJECTED / PENDING), ``impacts_tier1`` and ``reasons``.
  Fail closed: a Tier-1 rejection without at least one reason is rejected
  at construction, and reasons must be non-blank, unique strings.
* :func:`route_external_review` is the pure routing function:
  APPROVED => ``PRODUCTION_VALIDATED``; REJECTED without Tier-1 impact =>
  ``BUILDING``; REJECTED with Tier-1 impact => ``HALTED`` with the
  reasons batched into the single consolidated decision request
  (spec 18.1); anything else (a still-pending review) =>
  ``EXTERNAL_WAIT``.  The verdict is fail-closed: a HALTED verdict always
  carries the batch and no other route does.
* :class:`ExternalWaitState` is the durable wait state for one run:
  the review outcome, when the wait began (``waiting_since``), the next
  poll time (``next_check_at``) and the BUG attempt count captured when
  the wait began.
* :class:`ExternalWaitStore` persists that state through
  :class:`~kcc_autobuild.store.RunStore` SQLite (one row per run, created
  idempotently), so ``next_check_at`` survives process restarts.
* :class:`ExternalWaitCoordinator` is the combined route + persist
  action: it records a review outcome, persists the wait state
  (``next_check_at = now + poll_interval`` while waiting), and **never
  increments BUG attempts** -- elapsed waiting time is not a failure, so
  the count captured at wait entry is preserved across every poll.
"""

from __future__ import annotations

import itertools
import sqlite3
from datetime import datetime, timedelta, timezone

import pytest
from pydantic import ValidationError

from kcc_autobuild.external_wait import (
    DEFAULT_POLL_INTERVAL,
    ExternalReview,
    ExternalWaitCoordinator,
    ExternalWaitState,
    ExternalWaitStore,
    ExternalWaitVerdict,
    ReviewStatus,
    route_external_review,
)
from kcc_autobuild.models import LifecycleState, RunRecord
from kcc_autobuild.store import RunStore

T0 = datetime(2026, 8, 28, 12, 0, tzinfo=timezone.utc)
"""A fixed, timezone-aware reference instant (R7: night of the plan)."""


def _review(
    status: ReviewStatus = ReviewStatus.PENDING,
    impacts_tier1: bool = False,
    reasons: list[str] | None = None,
) -> ExternalReview:
    return ExternalReview(
        status=status,
        impacts_tier1=impacts_tier1,
        reasons=list(reasons) if reasons else [],
    )


_DB_COUNTER = itertools.count()
"""One fresh database file per store helper call (tmp_path is per-test)."""


def _make_store(tmp_path) -> ExternalWaitStore:
    store = RunStore(tmp_path / f"run-{next(_DB_COUNTER)}.db")
    store.create_run(
        RunRecord(
            run_id="RUN-001",
            title="external review demo",
            created_at=T0,
        )
    )
    return ExternalWaitStore(store)


def _make_coordinator(tmp_path, **kwargs) -> ExternalWaitCoordinator:
    return ExternalWaitCoordinator(_make_store(tmp_path), **kwargs)


# --- Prescribed routes: approved / rejected non-Tier1 / rejected Tier1 --------


def test_approved_review_routes_to_production_validated():
    verdict = route_external_review(_review(ReviewStatus.APPROVED))
    assert verdict.route is LifecycleState.PRODUCTION_VALIDATED
    assert verdict.batched_reasons == []


def test_rejected_review_without_tier1_impact_routes_to_building():
    verdict = route_external_review(
        _review(
            ReviewStatus.REJECTED,
            impacts_tier1=False,
            reasons=["logo palette misses the approved direction"],
        )
    )
    assert verdict.route is LifecycleState.BUILDING
    assert verdict.batched_reasons == []


def test_rejected_tier1_review_routes_to_halted_with_batched_reasons():
    verdict = route_external_review(
        _review(
            ReviewStatus.REJECTED,
            impacts_tier1=True,
            reasons=[
                "provider account requires identity verification",
                "requested domain is unavailable",
            ],
        )
    )
    assert verdict.route is LifecycleState.HALTED
    assert verdict.batched_reasons == [
        "provider account requires identity verification",
        "requested domain is unavailable",
    ]


def test_pending_review_keeps_the_run_in_external_wait():
    verdict = route_external_review(_review(ReviewStatus.PENDING))
    assert verdict.route is LifecycleState.EXTERNAL_WAIT
    assert verdict.batched_reasons == []


def test_route_rejects_non_review():
    with pytest.raises(TypeError):
        route_external_review("approved")  # type: ignore[arg-type]


# --- ExternalReview value object ---------------------------------------------


def test_rejected_tier1_review_requires_at_least_one_reason():
    """A Tier-1 rejection with no reasons cannot be batched (fail closed)."""
    with pytest.raises(ValidationError):
        ExternalReview(status=ReviewStatus.REJECTED, impacts_tier1=True, reasons=[])


def test_external_review_rejects_blank_reasons():
    with pytest.raises(ValidationError):
        ExternalReview(status=ReviewStatus.REJECTED, reasons=["  "])
    with pytest.raises(ValidationError):
        ExternalReview(status=ReviewStatus.PENDING, reasons=[""])


def test_external_review_rejects_duplicate_reasons():
    with pytest.raises(ValidationError):
        ExternalReview(
            status=ReviewStatus.REJECTED,
            impacts_tier1=True,
            reasons=["same blocker", "same blocker"],
        )


def test_external_review_rejects_unknown_status():
    with pytest.raises(ValidationError):
        ExternalReview(status="MAYBE")  # type: ignore[arg-type]


# --- ExternalWaitVerdict consistency -----------------------------------------


def test_verdict_halted_requires_batched_reasons():
    with pytest.raises(ValidationError):
        ExternalWaitVerdict(route=LifecycleState.HALTED, batched_reasons=[])


def test_verdict_non_halted_forbids_batched_reasons():
    with pytest.raises(ValidationError):
        ExternalWaitVerdict(route=LifecycleState.BUILDING, batched_reasons=["x"])


# --- ExternalWaitState value object ------------------------------------------


def test_external_wait_state_requires_a_review():
    with pytest.raises(ValidationError):
        ExternalWaitState(run_id="RUN-001")


def test_external_wait_state_rejects_negative_bug_attempts():
    with pytest.raises(ValidationError):
        ExternalWaitState(run_id="RUN-001", review=_review(), bug_attempts=-1)


def test_external_wait_state_rejects_naive_datetimes():
    with pytest.raises(ValidationError):
        ExternalWaitState(
            run_id="RUN-001",
            review=_review(),
            next_check_at=datetime(2026, 8, 28, 12, 0),
        )
    with pytest.raises(ValidationError):
        ExternalWaitState(
            run_id="RUN-001",
            review=_review(),
            waiting_since=datetime(2026, 8, 28, 12, 0),
        )


def test_external_wait_state_rejects_blank_run_id():
    with pytest.raises(ValidationError):
        ExternalWaitState(run_id="  ", review=_review())


# --- Durability of the wait state --------------------------------------------


def test_pending_review_persists_next_check_at_in_durable_run_state(tmp_path):
    coordinator = _make_coordinator(tmp_path)
    verdict = coordinator.record_review(
        "RUN-001", _review(ReviewStatus.PENDING), now=T0
    )
    assert verdict.route is LifecycleState.EXTERNAL_WAIT
    state = coordinator.state("RUN-001")
    assert state is not None
    assert state.review.status is ReviewStatus.PENDING
    assert state.waiting_since == T0
    assert state.next_check_at == T0 + DEFAULT_POLL_INTERVAL
    assert state.bug_attempts == 0


def test_next_check_at_survives_store_reopen(tmp_path):
    """The poll schedule is durable run state, not conversational memory."""
    db_path = tmp_path / "run.db"
    run_store = RunStore(db_path)
    run_store.create_run(
        RunRecord(run_id="RUN-001", title="external review demo", created_at=T0)
    )
    ExternalWaitCoordinator(ExternalWaitStore(run_store)).record_review(
        "RUN-001", _review(ReviewStatus.PENDING), now=T0
    )
    # A fresh store over the same database (process restart) sees it.
    reopened = ExternalWaitStore(RunStore(db_path))
    state = reopened.load("RUN-001")
    assert state is not None
    assert state.next_check_at == T0 + DEFAULT_POLL_INTERVAL
    assert state.review.status is ReviewStatus.PENDING


def test_load_unknown_run_returns_none(tmp_path):
    store = _make_store(tmp_path)
    assert store.load("RUN-999") is None
    assert store.load("RUN-001") is None


def test_save_requires_an_existing_run(tmp_path):
    """Wait state is per-run: an unknown run fails closed (FK)."""
    store = _make_store(tmp_path)
    with pytest.raises(sqlite3.IntegrityError):
        store.save(ExternalWaitState(run_id="RUN-999", review=_review()), now=T0)


# --- The coordinator: waiting time never increments BUG attempts -------------


def test_waiting_time_does_not_increment_bug_attempts(tmp_path):
    coordinator = _make_coordinator(tmp_path)
    coordinator.record_review(
        "RUN-001", _review(ReviewStatus.PENDING), now=T0, bug_attempts=2
    )
    # A poll three days later is not a BUG attempt: elapsed waiting time
    # never increments the count captured when the wait began.
    coordinator.record_review(
        "RUN-001",
        _review(ReviewStatus.PENDING),
        now=T0 + timedelta(days=3),
        bug_attempts=7,
    )
    state = coordinator.state("RUN-001")
    assert state.bug_attempts == 2
    assert state.waiting_since == T0
    assert state.next_check_at == T0 + timedelta(days=3) + DEFAULT_POLL_INTERVAL


def test_approved_review_resolves_the_wait_and_clears_next_check_at(tmp_path):
    coordinator = _make_coordinator(tmp_path)
    coordinator.record_review("RUN-001", _review(ReviewStatus.PENDING), now=T0)
    verdict = coordinator.record_review(
        "RUN-001", _review(ReviewStatus.APPROVED), now=T0 + timedelta(hours=6)
    )
    assert verdict.route is LifecycleState.PRODUCTION_VALIDATED
    state = coordinator.state("RUN-001")
    assert state.review.status is ReviewStatus.APPROVED
    assert state.next_check_at is None
    # The wait history stays: when the wait began is preserved.
    assert state.waiting_since == T0
    assert state.bug_attempts == 0


def test_rejected_tier1_persists_batched_reasons_and_halts(tmp_path):
    coordinator = _make_coordinator(tmp_path)
    coordinator.record_review("RUN-001", _review(ReviewStatus.PENDING), now=T0)
    verdict = coordinator.record_review(
        "RUN-001",
        _review(
            ReviewStatus.REJECTED,
            impacts_tier1=True,
            reasons=["identity verification is required"],
        ),
        now=T0 + timedelta(hours=6),
    )
    assert verdict.route is LifecycleState.HALTED
    assert verdict.batched_reasons == ["identity verification is required"]
    state = coordinator.state("RUN-001")
    assert state.review.impacts_tier1 is True
    assert state.next_check_at is None


def test_resolved_wait_reentered_recaptures_bug_attempts(tmp_path):
    """A new review wait after the build resumed is a new wait: the count
    at its entry is captured afresh."""
    coordinator = _make_coordinator(tmp_path)
    coordinator.record_review(
        "RUN-001", _review(ReviewStatus.PENDING), now=T0, bug_attempts=1
    )
    coordinator.record_review(
        "RUN-001",
        _review(
            ReviewStatus.REJECTED,
            impacts_tier1=False,
            reasons=["copy tweak"],
        ),
        now=T0 + timedelta(hours=1),
    )
    coordinator.record_review(
        "RUN-001",
        _review(ReviewStatus.PENDING),
        now=T0 + timedelta(hours=2),
        bug_attempts=4,
    )
    state = coordinator.state("RUN-001")
    assert state.bug_attempts == 4
    assert state.waiting_since == T0 + timedelta(hours=2)


def test_record_review_rejects_non_review(tmp_path):
    coordinator = _make_coordinator(tmp_path)
    with pytest.raises(TypeError):
        coordinator.record_review("RUN-001", "approved", now=T0)  # type: ignore[arg-type]


def test_record_review_rejects_naive_now(tmp_path):
    coordinator = _make_coordinator(tmp_path)
    with pytest.raises(ValueError):
        coordinator.record_review(
            "RUN-001",
            _review(ReviewStatus.PENDING),
            now=datetime(2026, 8, 28, 12, 0),
        )


def test_record_review_rejects_bad_bug_attempts(tmp_path):
    coordinator = _make_coordinator(tmp_path)
    with pytest.raises(ValidationError):
        coordinator.record_review(
            "RUN-001",
            _review(ReviewStatus.PENDING),
            now=T0,
            bug_attempts=-3,
        )


def test_poll_interval_must_be_positive(tmp_path):
    with pytest.raises(ValueError):
        ExternalWaitCoordinator(_make_store(tmp_path), poll_interval=timedelta(0))
    with pytest.raises(TypeError):
        ExternalWaitCoordinator(_make_store(tmp_path), poll_interval=3600)  # type: ignore[arg-type]
