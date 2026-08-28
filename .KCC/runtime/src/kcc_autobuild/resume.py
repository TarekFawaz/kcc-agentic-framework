"""Reconstruct autobuild runs after interruption (resume planner).

Plan 05, Task 1 (Resume reconstruction / revalidation): after an
interruption the controller rebuilds its view from durable state and
resumes at the first incomplete action instead of repeating completed
work (spec 22: completed tasks must not be re-dispatched solely because
agent/session context was lost; spec 14.6: durable state -- lifecycle
state, task status, completed commits, evidence -- is the source of
truth over conversational memory). This module is the *pure decision
function* for that reconstruction: no I/O, no wall clock unless a clock
already shaped the snapshot, byte-identical output for identical input.

The behavioral contract is owned by :file:`.KCC/runtime/tests/test_resume.py`:

- :class:`ResumeAction` is one reconstruction decision: a canonical
  :class:`ResumeActionKind` plus the ``task_id`` it applies to (empty for
  run-level kinds).
- :class:`TaskSnapshot` is one task's durable view: its
  :class:`~kcc_autobuild.models.TaskStatus` and whether its running lease
  has lapsed (``lease_expired`` -- the caller computes liveness against
  the lease TTL at snapshot time).
- :class:`ResumeSnapshot` is the durable run view the controller feeds to
  the planner: the task set plus the run-level flags ``external_wait`` /
  ``rollback_in_progress`` / ``ambiguous_target_state``.
- :meth:`ResumePlanner.plan` returns the ordered reconstruction plan:
  - **sorted passed => REVALIDATE**: a passed task's evidence is
    re-verified; completed work is NEVER re-executed (``REEXECUTE``
    exists in the canonical vocabulary precisely so the invariant is
    auditable -- the planner never emits it);
  - **expired running => RECLAIM**: a task that was in flight when the
    interruption hit and whose lease has since lapsed reclaims its
    execution slot with a fresh lease;
  - revalidations come first, then reclaims, each in task id ascending
    order (deterministic, byte-identical for identical input);
  - a running task whose lease is still live gets no action (the attempt
    is still accounted for); pending/failed/blocked tasks get no action
    here (new-wave dispatch and failure classification/retry own those
    paths);
  - run-level conditions take precedence and suppress task-level
    reconstruction, fail closed: ``ambiguous_target_state`` =>
    ``HALT_AMBIGUOUS`` (the target state cannot be disambiguated: raise
    back to KCC machine interpretation, never a guess), then
    ``rollback_in_progress`` => ``CONTINUE_ROLLBACK`` (the authorized
    recovery action is executing; nothing else may be dispatched
    concurrently), then ``external_wait`` => ``WAIT_EXTERNAL`` (no
    reconstruction while an external review is pending).
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Iterable

from kcc_autobuild.models import TaskStatus

# Kinds the planner may return. ``REEXECUTE`` is the canonical vocabulary
# for the forbidden "blind re-execution of completed work" path -- it is
# defined (and pinned by the tests) so the invariant "a passed task is
# never reexecuted" is auditable, but the planner never emits it.


class ResumeActionKind(str, Enum):
    """What the controller should do for one resumed task/run.

    ``REVALIDATE`` -- a passed task: re-verify its evidence before
    continuing (never redo). ``RECLAIM`` -- a running task whose lease
    lapsed: reclaim the execution slot with a fresh lease. ``REEXECUTE``
    -- the forbidden blind re-execution of completed work; defined in the
    vocabulary but never planned. ``WAIT_EXTERNAL`` /
    ``CONTINUE_ROLLBACK`` / ``HALT_AMBIGUOUS`` -- run-level routes for
    external review waiting, an in-flight rollback, and an ambiguous
    target state.
    """

    REVALIDATE = "REVALIDATE"
    RECLAIM = "RECLAIM"
    REEXECUTE = "REEXECUTE"
    WAIT_EXTERNAL = "WAIT_EXTERNAL"
    CONTINUE_ROLLBACK = "CONTINUE_ROLLBACK"
    HALT_AMBIGUOUS = "HALT_AMBIGUOUS"


_TASK_KINDS = frozenset(
    {ResumeActionKind.REVALIDATE, ResumeActionKind.RECLAIM, ResumeActionKind.REEXECUTE}
)
"""Kinds that address one task (they require a non-empty ``task_id``)."""


def _require_task_id(task_id: str, name: str = "task_id") -> str:
    if not isinstance(task_id, str):
        raise TypeError(f"{name} must be a str, got {type(task_id).__name__}")
    if not task_id.strip():
        raise ValueError(f"{name} must be a non-empty string")
    return task_id


def _require_bool(value: bool, name: str) -> None:
    if not isinstance(value, bool):
        raise TypeError(f"{name} must be a bool, got {type(value).__name__}")


@dataclass(frozen=True)
class ResumeAction:
    """One reconstruction decision for the resumed run.

    ``kind`` selects the action; ``task_id`` names the task it applies to
    -- required (non-empty) for task-level kinds and forbidden (must be
    empty) for run-level kinds, so a misaddressed action fails closed at
    construction instead of being executed against the wrong task.
    """

    kind: ResumeActionKind
    task_id: str = ""

    def __post_init__(self) -> None:
        if not isinstance(self.kind, ResumeActionKind):
            raise TypeError(
                f"kind must be a ResumeActionKind, got {type(self.kind).__name__}"
            )
        if self.kind in _TASK_KINDS:
            object.__setattr__(self, "task_id", _require_task_id(self.task_id))
        else:
            if not isinstance(self.task_id, str):
                raise TypeError(
                    f"task_id must be a str, got {type(self.task_id).__name__}"
                )
            if self.task_id:
                raise ValueError(
                    f"run-level action {self.kind.value} cannot address a task "
                    f"({self.task_id!r})"
                )


@dataclass(frozen=True)
class TaskSnapshot:
    """One task's durable view at resume time.

    ``status`` is the persisted :class:`~kcc_autobuild.models.TaskStatus`;
    ``lease_expired`` says whether the task's running lease has lapsed
    (the caller computes liveness against the lease TTL at snapshot time
    -- this module never reads a clock). For passed tasks the flag is
    irrelevant: status dominates reconstruction.
    """

    task_id: str
    status: TaskStatus
    lease_expired: bool = False

    def __post_init__(self) -> None:
        object.__setattr__(self, "task_id", _require_task_id(self.task_id))
        if not isinstance(self.status, TaskStatus):
            raise TypeError(
                f"status must be a TaskStatus, got {type(self.status).__name__}"
            )
        _require_bool(self.lease_expired, "lease_expired")


@dataclass(frozen=True)
class ResumeSnapshot:
    """The durable run view the planner reconstructs from.

    ``tasks`` are the run's tasks (normalized to a tuple, duplicate ids
    rejected -- a snapshot naming one task twice is untrustworthy);
    ``external_wait`` / ``rollback_in_progress`` /
    ``ambiguous_target_state`` are the run-level conditions that, when
    set, take precedence over task-level reconstruction.
    """

    tasks: tuple[TaskSnapshot, ...] = ()
    external_wait: bool = False
    rollback_in_progress: bool = False
    ambiguous_target_state: bool = False

    def __post_init__(self) -> None:
        parsed: list[TaskSnapshot] = []
        seen: set[str] = set()
        for item in self.tasks:
            if not isinstance(item, TaskSnapshot):
                raise TypeError(
                    f"tasks entries must be TaskSnapshot, got {type(item).__name__}"
                )
            if item.task_id in seen:
                raise ValueError(f"duplicate task {item.task_id!r} in snapshot")
            seen.add(item.task_id)
            parsed.append(item)
        object.__setattr__(self, "tasks", tuple(parsed))
        _require_bool(self.external_wait, "external_wait")
        _require_bool(self.rollback_in_progress, "rollback_in_progress")
        _require_bool(self.ambiguous_target_state, "ambiguous_target_state")


class ResumePlanner:
    """Stateless, pure reconstruction planner for interrupted runs.

    Never reads I/O or the wall clock; every decision derives from the
    :class:`ResumeSnapshot` the controller loaded from durable state.
    """

    @staticmethod
    def plan(snapshot: ResumeSnapshot) -> tuple[ResumeAction, ...]:
        """Reconstruct the ordered resume plan for one durable snapshot.

        Run-level conditions win first (fail closed): ambiguous target
        state halts for machine interpretation; an in-flight rollback
        continues; an external wait waits. Otherwise passed tasks are
        revalidated (sorted) and expired running tasks reclaimed
        (sorted) -- revalidations before reclaims -- and passed work is
        never blind-reexecuted.
        """
        if not isinstance(snapshot, ResumeSnapshot):
            raise TypeError(
                f"snapshot must be a ResumeSnapshot, got {type(snapshot).__name__}"
            )

        if snapshot.ambiguous_target_state:
            return (ResumeAction(ResumeActionKind.HALT_AMBIGUOUS),)
        if snapshot.rollback_in_progress:
            return (ResumeAction(ResumeActionKind.CONTINUE_ROLLBACK),)
        if snapshot.external_wait:
            return (ResumeAction(ResumeActionKind.WAIT_EXTERNAL),)

        passed = sorted(
            task.task_id
            for task in snapshot.tasks
            if task.status is TaskStatus.PASSED
        )
        expired_running = sorted(
            task.task_id
            for task in snapshot.tasks
            if task.status is TaskStatus.RUNNING and task.lease_expired
        )
        plan: list[ResumeAction] = [
            ResumeAction(ResumeActionKind.REVALIDATE, task_id)
            for task_id in passed
        ]
        plan.extend(
            ResumeAction(ResumeActionKind.RECLAIM, task_id)
            for task_id in expired_running
        )
        return tuple(plan)
