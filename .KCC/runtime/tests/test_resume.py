"""Behavioral contract for resume reconstruction after interruption.

Owned by ``test_resume.py`` (see the KCC x Superpowers Hybrid Framework
Plan 05, Task 1: Resume reconstruction / revalidation, in
``.superpowers/bootstrap/plans/2026-08-27-05-resume-deploy-validation.task-contracts.md``).

After an interruption the controller rebuilds its view from durable state
and resumes at the first incomplete action instead of repeating completed
work: spec 22 (``Completed tasks must not be re-dispatched solely because
agent/session context was lost``) and spec 14.6 / 22 (durable state is the
source of truth; conversation memory is never authoritative).
:class:`~kcc_autobuild.resume.ResumePlanner.plan` is the *pure decision
function* for that reconstruction -- no I/O, no wall clock (lease liveness
is captured in the snapshot by the caller), byte-identical output for
identical input.

Behavior under contract:

* a **passed** task => ``REVALIDATE`` (verify its evidence still holds);
  the planner **never** blind-reexecutes passed work (``REEXECUTE`` is the
  forbidden vocabulary and the prescribed "T1 never reexecuted" invariant
  pins the whole plan, not just T1);
* a **running** task whose lease is **expired** (in-flight when the
  interruption hit, lease lapsed since) => ``RECLAIM`` (reclaim the
  execution slot with a fresh lease);
* reconstruction is **deterministic**: revalidations first, then
  reclaims, each in task id ascending order, so identical snapshots
  always plan identically;
* a running task whose lease is still live gets **no action** (the
  attempt is still accounted for; the controller waits);
* pending / failed / blocked tasks get no action here (new dispatch and
  failure classification/retry own those paths separately);
* run-level conditions take precedence and suppress task-level
  reconstruction, fail closed: ``ambiguous_target_state`` =>
  ``HALT_AMBIGUOUS`` (machine interpretation, never a guess), then
  ``rollback_in_progress`` => ``CONTINUE_ROLLBACK``, then
  ``external_wait`` => ``WAIT_EXTERNAL``.

Prescribed scenarios under test: passed T1 revalidated; expired T2
reclaimed; T1 never reexecuted -- plus the run-level routes
(WAIT_EXTERNAL, CONTINUE_ROLLBACK, HALT_AMBIGUOUS) and their precedence.
"""

from __future__ import annotations

import pytest

from kcc_autobuild.models import TaskStatus
from kcc_autobuild.resume import (
    ResumeAction,
    ResumeActionKind,
    ResumePlanner,
    ResumeSnapshot,
    TaskSnapshot,
)


def _passed(task_id: str) -> TaskSnapshot:
    return TaskSnapshot(task_id=task_id, status=TaskStatus.PASSED)


def _expired_running(task_id: str) -> TaskSnapshot:
    return TaskSnapshot(task_id=task_id, status=TaskStatus.RUNNING, lease_expired=True)


# --- Prescribed: passed T1 revalidated / expired T2 reclaimed / no reexecute --


def test_passed_task_is_revalidated():
    plan = ResumePlanner.plan(ResumeSnapshot(tasks=(_passed("T1"),)))
    assert plan == (ResumeAction(ResumeActionKind.REVALIDATE, "T1"),)


def test_expired_running_task_is_reclaimed():
    plan = ResumePlanner.plan(ResumeSnapshot(tasks=(_expired_running("T2"),)))
    assert plan == (ResumeAction(ResumeActionKind.RECLAIM, "T2"),)


def test_passed_task_is_never_reexecuted_prescribed_scenario():
    # Prescribed: passed T1 revalidated, expired T2 reclaimed, T1 never
    # reexecuted -- one plan, no blind re-execution of completed work.
    plan = ResumePlanner.plan(
        ResumeSnapshot(tasks=(_passed("T1"), _expired_running("T2")))
    )
    assert plan == (
        ResumeAction(ResumeActionKind.REVALIDATE, "T1"),
        ResumeAction(ResumeActionKind.RECLAIM, "T2"),
    )
    assert all(action.kind is not ResumeActionKind.REEXECUTE for action in plan)
    assert [action.task_id for action in plan] == ["T1", "T2"]


def test_revalidation_precedes_reclaim_when_ids_swap():
    # Kind grouping is stable regardless of task ids: revalidations first.
    plan = ResumePlanner.plan(
        ResumeSnapshot(tasks=(_expired_running("T1"), _passed("T2")))
    )
    assert plan == (
        ResumeAction(ResumeActionKind.REVALIDATE, "T2"),
        ResumeAction(ResumeActionKind.RECLAIM, "T1"),
    )


def test_passed_status_dominates_a_stale_lease_flag():
    # A passed task stays revalidated even if its old lease lapsed: status
    # is what reconstruction trusts, expiry only matters for running tasks.
    snapshot = TaskSnapshot(task_id="T1", status=TaskStatus.PASSED, lease_expired=True)
    assert ResumePlanner.plan(ResumeSnapshot(tasks=(snapshot,))) == (
        ResumeAction(ResumeActionKind.REVALIDATE, "T1"),
    )


# --- Deterministic ordering --------------------------------------------------


def test_passed_tasks_revalidated_in_task_id_order():
    plan = ResumePlanner.plan(
        ResumeSnapshot(tasks=(_passed("T3"), _passed("T1"), _passed("T2")))
    )
    assert [action.kind for action in plan] == [
        ResumeActionKind.REVALIDATE,
        ResumeActionKind.REVALIDATE,
        ResumeActionKind.REVALIDATE,
    ]
    assert [action.task_id for action in plan] == ["T1", "T2", "T3"]


def test_expired_running_tasks_reclaimed_in_task_id_order():
    plan = ResumePlanner.plan(
        ResumeSnapshot(tasks=(_expired_running("T3"), _expired_running("T1")))
    )
    assert plan == (
        ResumeAction(ResumeActionKind.RECLAIM, "T1"),
        ResumeAction(ResumeActionKind.RECLAIM, "T3"),
    )


def test_plan_is_deterministic():
    snapshot = ResumeSnapshot(
        tasks=(_passed("T3"), _expired_running("T2"), _passed("T1"))
    )
    first = ResumePlanner.plan(snapshot)
    second = ResumePlanner.plan(snapshot)
    assert first == second
    assert isinstance(first, tuple)


def test_empty_snapshot_plans_nothing():
    assert ResumePlanner.plan(ResumeSnapshot()) == ()


# --- Neighboring statuses get no reconstruction action -----------------------


def test_running_task_with_live_lease_gets_no_action():
    live = TaskSnapshot(task_id="T1", status=TaskStatus.RUNNING, lease_expired=False)
    assert ResumePlanner.plan(ResumeSnapshot(tasks=(live,))) == ()


def test_pending_failed_blocked_tasks_get_no_action():
    snapshot = ResumeSnapshot(
        tasks=(
            TaskSnapshot(task_id="T1", status=TaskStatus.PENDING),
            TaskSnapshot(task_id="T2", status=TaskStatus.FAILED),
            TaskSnapshot(task_id="T3", status=TaskStatus.BLOCKED),
        )
    )
    assert ResumePlanner.plan(snapshot) == ()


# --- Run-level routes (prescribed) ------------------------------------------


def test_external_wait_yields_wait_external():
    snapshot = ResumeSnapshot(
        tasks=(_passed("T1"), _expired_running("T2")),
        external_wait=True,
    )
    assert ResumePlanner.plan(snapshot) == (ResumeAction(ResumeActionKind.WAIT_EXTERNAL),)


def test_rollback_in_progress_yields_continue_rollback():
    snapshot = ResumeSnapshot(
        tasks=(_passed("T1"), _expired_running("T2")),
        rollback_in_progress=True,
    )
    assert ResumePlanner.plan(snapshot) == (
        ResumeAction(ResumeActionKind.CONTINUE_ROLLBACK),
    )


def test_ambiguous_target_state_yields_halt_ambiguous():
    plan = ResumePlanner.plan(ResumeSnapshot(ambiguous_target_state=True))
    assert plan == (ResumeAction(ResumeActionKind.HALT_AMBIGUOUS),)


def test_run_level_routes_suppress_task_reconstruction():
    # While an external wait is pending the run does NOT revalidate or
    # reclaim anything: reconstruction waits for the review.
    plan = ResumePlanner.plan(
        ResumeSnapshot(
            tasks=(_passed("T1"), _expired_running("T2")), external_wait=True
        )
    )
    assert plan == (ResumeAction(ResumeActionKind.WAIT_EXTERNAL),)


def test_ambiguous_target_state_beats_rollback_and_external_wait():
    # Fail closed: an ambiguous target is never resolved by guessing --
    # not even by continuing an in-flight rollback or waiting externally.
    plan = ResumePlanner.plan(
        ResumeSnapshot(
            tasks=(_passed("T1"),),
            external_wait=True,
            rollback_in_progress=True,
            ambiguous_target_state=True,
        )
    )
    assert plan == (ResumeAction(ResumeActionKind.HALT_AMBIGUOUS),)


def test_rollback_beats_external_wait():
    plan = ResumePlanner.plan(
        ResumeSnapshot(external_wait=True, rollback_in_progress=True)
    )
    assert plan == (ResumeAction(ResumeActionKind.CONTINUE_ROLLBACK),)


# --- Value validation (fail closed) ------------------------------------------


def test_plan_rejects_non_snapshot():
    for bad in (None, {}, [], object(), "snapshot"):
        with pytest.raises(TypeError):
            ResumePlanner.plan(bad)  # type: ignore[arg-type]


def test_resume_action_validates_kind():
    with pytest.raises(TypeError):
        ResumeAction(kind="REVALIDATE", task_id="T1")  # type: ignore[arg-type]


def test_resume_action_task_level_requires_a_task_id():
    for kind in (
        ResumeActionKind.REVALIDATE,
        ResumeActionKind.RECLAIM,
        ResumeActionKind.REEXECUTE,
    ):
        with pytest.raises(ValueError):
            ResumeAction(kind=kind, task_id="")


def test_resume_action_run_level_rejects_a_task_id():
    for kind in (
        ResumeActionKind.WAIT_EXTERNAL,
        ResumeActionKind.CONTINUE_ROLLBACK,
        ResumeActionKind.HALT_AMBIGUOUS,
    ):
        with pytest.raises(ValueError):
            ResumeAction(kind=kind, task_id="T1")


def test_resume_action_rejects_non_string_task_id():
    with pytest.raises(TypeError):
        ResumeAction(kind=ResumeActionKind.REVALIDATE, task_id=1)  # type: ignore[arg-type]


def test_resume_action_is_immutable():
    action = ResumeAction(ResumeActionKind.RECLAIM, "T2")
    with pytest.raises(AttributeError):
        action.task_id = "T1"  # type: ignore[misc]


def test_task_snapshot_validates_values():
    with pytest.raises(ValueError):
        TaskSnapshot(task_id="", status=TaskStatus.PASSED)
    with pytest.raises(TypeError):
        TaskSnapshot(task_id="T1", status="PASSED")  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        TaskSnapshot(task_id="T1", status=TaskStatus.RUNNING, lease_expired=1)  # type: ignore[arg-type]


def test_resume_snapshot_validates_values():
    with pytest.raises(TypeError):
        ResumeSnapshot(tasks=("T1",))  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        ResumeSnapshot(tasks=(), external_wait=1)  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        ResumeSnapshot(tasks=(), rollback_in_progress="yes")  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        ResumeSnapshot(tasks=(), ambiguous_target_state=None)  # type: ignore[arg-type]


def test_resume_snapshot_rejects_duplicate_task_ids():
    # A snapshot naming one task twice is untrustworthy: fail closed.
    with pytest.raises(ValueError):
        ResumeSnapshot(tasks=(_passed("T1"), _expired_running("T1")))


def test_resume_snapshot_normalizes_tasks_to_a_tuple():
    snapshot = ResumeSnapshot(tasks=[_passed("T1")])
    assert isinstance(snapshot.tasks, tuple)
    assert snapshot.tasks == (_passed("T1"),)
