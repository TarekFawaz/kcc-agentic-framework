"""Integrated scheduler pipeline controller for autobuild waves.

Plan 04, Task 7 (Integrate scheduler pipeline): this module is the single
orchestration point that wires the Plan 04 components into one pipeline --
the store (:class:`~kcc_autobuild.store.RunStore`), the pure wave
:class:`~kcc_autobuild.scheduler.Scheduler`, the fenced
:class:`~kcc_autobuild.leases.LeaseLedger` / :class:`~kcc_autobuild.leases.LeaseStore`,
the bounded :class:`~kcc_autobuild.bridge.ExecutionBridge`, the money
:class:`~kcc_autobuild.budget.BudgetLedger`, the rate
:class:`~kcc_autobuild.rate_limit.RateCapacityLedger` and the
:class:`~kcc_autobuild.tool_gate.PolicyToolGate` policy gate.

The behavioral contract is owned by
:file:`.KCC/runtime/tests/test_controller.py` (pinned to the Plan 04
Global Constraints):

- **Tick first snapshots** the run state (run record, per-task status,
  ledgers, live leases, clocks) and THEN sweeps stale leases: every
  expired/fenced lease releases its money + rate reservations, freezes the
  task time budget (consuming the elapsed time) and emits a ``task.frozen``
  event.
- The scheduler decides the next wave; the controller reserves ONLY the
  selected set (``budget.reserve`` + ``rate.reserve`` exactly once -- the
  scheduler only simulated, so there is never a double reserve), claims a
  fresh lease (per-task ``generation + 1``), unfreezes the task time
  budget, builds the bounded handoff bound to the freshly claimed KCC lease
  and emits a ``task.dispatch`` (DISPATCH) event.
- A **verified report advances**: after chain-of-custody verification the
  task becomes PASSED/FAILED/BLOCKED, its lease is fenced, its provider rate
  units are released; when the wave completes its money bookings settle via
  ``budget.reconcile`` (provider actual only gates the hard-cap breach),
  the deterministic wave-gate deviation review samples the wave's evidence
  and a ``wave.complete`` event closes the wave.
- **PAUSED is a separate path that retains the reservation**: pausing
  fences the live leases and freezes the time budgets but NEVER releases
  money/rate; resume re-dispatches the retained set with fresh lease
  generations and no new reservation (still exactly once).
- **Operations fail closed on the attempt identity**: an operation
  belongs to the task's current lease, so a lease that lapsed (or was
  fenced) refuses the operation with :class:`StaleLeaseOperation` before
  the gate evaluates or executes anything -- no lapsed-but-unswept window
  for destructive operations.
- The **wave-gate deviation review** is deterministic: 100% of declared
  deviations plus every production/destructive operation are always
  reviewed (mandatory), at least 20% of the remaining evidence is sampled
  (ceil), and a nonempty wave always yields at least one reviewed item.

Chain of custody: the handoff pack's :class:`~kcc_autobuild.bridge.TaskLease`
is rebound to the controller-minted lease before the pack is accepted
(``one KCC lease, one budget envelope, one isolated workspace, one
Execution Report`` per attempt), so a worker's report is verified against
the exact lease the controller claims.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import ROUND_CEILING, Decimal
from enum import Enum
from typing import Any, Iterable, Mapping

from kcc_autobuild.bridge import (
    AttemptBudget,
    ExecutionBridge,
    ExecutionReport,
    ExecutionStatus,
    HandoffError,
    LockedDecision,
    TaskHandoff,
    TaskLease,
)
from kcc_autobuild.budget import BudgetBreach, BudgetLedger
from kcc_autobuild.contract import CONTRACT_HASH_PATTERN, BuildContract
from kcc_autobuild.evidence import EvidenceVerifier, ReportAcceptance
from kcc_autobuild.leases import (
    Lease,
    LeaseLedger,
    LeaseStatus,
    LeaseStore,
)
from kcc_autobuild.models import (
    RUN_ID_PATTERN,
    LifecycleState,
    RunEvent,
)
from kcc_autobuild.policy import Operation
from kcc_autobuild.rate_limit import RateCapacityLedger, RateDemand
from kcc_autobuild.scheduler import Scheduler, TaskSpec
from kcc_autobuild.store import RunStore
from kcc_autobuild.tool_gate import PolicyToolGate
from kcc_autobuild.trace import TraceGraph

_PRODUCTION_OUTPUT_KINDS = frozenset(
    {"production", "production_validation", "deploy"}
)
"""``OutputInfo.kind`` values that mark a production-target output.

A production-declared output is always reviewable evidence (the wave gate
reviews 100% of production operations/evidence).
"""


class ControllerError(ValueError):
    """Base class for rejected controller operations (fail closed)."""


class UnknownTask(ControllerError):
    """Raised when a report names a task the controller does not own."""


class StaleLeaseReport(ControllerError):
    """Raised when a report does not ride a live, current KCC lease.

    A stale/fenced/expired lease is never a retry: the attempt is no longer
    accounted for, so the report cannot advance (fail closed).
    """


class StaleLeaseOperation(ControllerError):
    """Raised when an operation targets a task whose lease is not live.

    A lease whose TTL has lapsed (or that was fenced) is no longer
    accounted for even before the tick sweep runs: the destructive
    operation is refused (fail closed) instead of executing inside the
    lapsed-but-unswept window, and only the sweep may release the attempt
    reservation.
    """


class ReportMismatch(ControllerError):
    """Raised when a report is malformed for the attempt identity.

    Covers known-but-not-in-flight tasks, wrong lease generation or a
    workspace that does not match the claimed lease.
    """


class UnverifiedReport(ControllerError):
    """Raised when a report has no chain-of-custody verification.

    Neither an explicit acceptance nor an injected
    :class:`~kcc_autobuild.evidence.EvidenceVerifier` is available, so the
    claim is untrusted and must not advance anything.
    """


class NotBuilding(ControllerError):
    """Raised when an action requires the run to be in ``BUILDING``."""


class BrokenTaskGraph(ValueError):
    """Raised when the task universe is not dependency-closed."""


class ControllerMismatch(RuntimeError):
    """Controller bug signal: handoff lease diverged from the claimed lease.

    Raised instead of dispatching a pack bound to the wrong KCC lease -- the
    chain of custody must never silently drift.
    """


class TaskState(str, Enum):
    """Controller-level per-task lifecycle.

    ``PENDING`` never dispatched; ``RUNNING`` holds a live lease;
    ``FROZEN`` time budget frozen (stale lease or paused run) and awaiting
    a fresh claim; ``PASSED``/``FAILED``/``BLOCKED`` terminal.
    """

    PENDING = "PENDING"
    RUNNING = "RUNNING"
    FROZEN = "FROZEN"
    PASSED = "PASSED"
    FAILED = "FAILED"
    BLOCKED = "BLOCKED"


_TERMINAL = frozenset(
    {TaskState.PASSED, TaskState.FAILED, TaskState.BLOCKED}
)


class TaskTimeBudget:
    """The per-task attempt clock: running, or frozen while stale/paused.

    ``start`` begins (or resumes) the clock at a deterministic ``now``;
    ``freeze`` consumes the elapsed running time into ``used_seconds`` and
    stops the clock so a fenced/expired/paused attempt cannot burn budget
    while it is not being worked. Time is only ever read with an explicit
    ``now`` (no wall clock), and freezing is idempotent: a frozen budget
    simply stays frozen. The clock never goes backwards -- ``now`` before
    ``started_at`` is a caller bug and raises.
    """

    def __init__(self, task_id: str, total_seconds: int) -> None:
        if not isinstance(task_id, str) or not task_id.strip():
            raise ValueError("task_id must be a non-empty string")
        if isinstance(total_seconds, bool) or not isinstance(total_seconds, int):
            raise TypeError(f"total_seconds must be an int, got {type(total_seconds).__name__}")
        if total_seconds < 1:
            raise ValueError(f"total_seconds must be positive, got {total_seconds}")
        self.task_id = task_id
        self.total_seconds = total_seconds
        self.used_seconds = 0.0
        self.started_at: datetime | None = None

    @staticmethod
    def _utc(value: datetime, name: str) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError(f"{name} must be timezone-aware")
        return value.astimezone(timezone.utc)

    @property
    def frozen(self) -> bool:
        """Whether the clock is stopped (``used_seconds`` is settled)."""
        return self.started_at is None

    def start(self, now: datetime) -> None:
        """Begin or resume the clock at ``now`` (idempotent when running)."""
        now = self._utc(now, "now")
        if self.started_at is not None:
            return  # already running: unfreezing an unfrozen budget is a no-op
        self.started_at = now

    def freeze(self, now: datetime) -> float:
        """Stop the clock, consuming elapsed time; returns elapsed seconds."""
        now = self._utc(now, "now")
        if self.started_at is None:
            return 0.0  # already frozen (idempotent)
        if now < self.started_at:
            raise ValueError("freeze must not precede the clock start")
        elapsed = (now - self.started_at).total_seconds()
        self.used_seconds += elapsed
        self.started_at = None
        return elapsed

    def elapsed(self, now: datetime) -> float:
        """Seconds consumed so far, including the running stretch."""
        now = self._utc(now, "now")
        consumed = self.used_seconds
        if self.started_at is not None:
            if now < self.started_at:
                raise ValueError("now must not precede the clock start")
            consumed += (now - self.started_at).total_seconds()
        return consumed

    def remaining(self, now: datetime) -> float:
        """Seconds left in the time budget (0.0 or less means exhausted)."""
        return self.total_seconds - self.elapsed(now)


@dataclass(frozen=True)
class TaskPlan:
    """One task's controller configuration (reserved money + handoff scope).

    Combines the scheduler's :class:`TaskSpec` content (``id``,
    ``depends_on``, ``budget_ceiling``, ``rate_demands``) with the time
    budget and the bounded-handoff scope (the requirement/acceptance/Test
    IDs, providers, locked decisions, the trace graph and the policy anchor)
    so the controller can both schedule and dispatch it.

    Fail-closed validation: the handoff scope must be provable (a trace
    graph with the acceptance/Test IDs, and either a locked contract or an
    explicit canonical ``policy_bundle_hash``), the money ceiling must be
    positive and the time budget positive.
    """

    id: str
    budget_ceiling: Decimal
    requirement_ids: tuple[str, ...]
    acceptance_ids: tuple[str, ...]
    test_ids: tuple[str, ...]
    attempt_budget: AttemptBudget
    time_budget_seconds: int = 3600
    depends_on: tuple[str, ...] = ()
    rate_demands: tuple[RateDemand, ...] = ()
    providers: tuple[str, ...] = ()
    trace: TraceGraph | None = None
    contract: BuildContract | None = None
    locked_decisions: tuple[LockedDecision, ...] = ()
    policy_bundle_hash: str | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.id, str) or not self.id:
            raise ValueError("id must be a non-empty string")
        ceiling = Decimal(self.budget_ceiling)
        if ceiling <= 0:
            raise ValueError(f"budget_ceiling must be positive, got {ceiling}")
        object.__setattr__(self, "budget_ceiling", ceiling)
        if (
            isinstance(self.time_budget_seconds, bool)
            or not isinstance(self.time_budget_seconds, int)
        ):
            raise TypeError("time_budget_seconds must be an int")
        if self.time_budget_seconds < 1:
            raise ValueError(
                f"time_budget_seconds must be positive, got {self.time_budget_seconds}"
            )
        object.__setattr__(self, "depends_on", _as_tuple(self.depends_on, "depends_on"))
        object.__setattr__(self, "requirement_ids", _as_tuple(self.requirement_ids, "requirement_ids"))
        object.__setattr__(self, "acceptance_ids", _as_tuple(self.acceptance_ids, "acceptance_ids"))
        object.__setattr__(self, "test_ids", _as_tuple(self.test_ids, "test_ids"))
        object.__setattr__(self, "providers", _as_tuple(self.providers, "providers"))
        if not self.requirement_ids:
            raise ValueError("requirement_ids must not be empty")
        if not self.acceptance_ids:
            raise ValueError("acceptance_ids must not be empty")
        if not self.test_ids:
            raise ValueError("test_ids must not be empty")
        if not isinstance(self.attempt_budget, AttemptBudget):
            raise TypeError(
                "attempt_budget must be an AttemptBudget, "
                f"got {type(self.attempt_budget).__name__}"
            )
        if self.trace is not None and not isinstance(self.trace, TraceGraph):
            raise TypeError(
                f"trace must be a TraceGraph, got {type(self.trace).__name__}"
            )
        if self.contract is not None and not isinstance(self.contract, BuildContract):
            raise TypeError(
                f"contract must be a BuildContract, got {type(self.contract).__name__}"
            )
        for decision in self.locked_decisions:
            if not isinstance(decision, LockedDecision):
                raise TypeError(
                    "locked_decisions entries must be LockedDecision, "
                    f"got {type(decision).__name__}"
                )
        object.__setattr__(self, "locked_decisions", tuple(self.locked_decisions))
        demands: list[RateDemand] = []
        seen: set[str] = set()
        for demand in self.rate_demands:
            if not isinstance(demand, RateDemand):
                raise TypeError(
                    f"rate_demands entries must be RateDemand, got {type(demand).__name__}"
                )
            if demand.provider_key in seen:
                raise ValueError(
                    f"duplicate rate demand for provider {demand.provider_key!r}"
                )
            seen.add(demand.provider_key)
            demands.append(demand)
        object.__setattr__(self, "rate_demands", tuple(demands))
        self._validate_scope()

    def _validate_scope(self) -> None:
        """The handoff scope must be provable (fail closed, never silent)."""
        trace = self.trace if self.trace is not None else (
            self.contract.trace if self.contract is not None else None
        )
        if trace is None:
            raise ValueError(
                "trace graph is required to scope the handoff "
                "(pass the task's trace context or the locked contract)"
            )
        self._validate_trace_references(trace)
        if self.contract is not None:
            if self.contract.contract_hash is None:
                raise ValueError(
                    "contract must be locked before a handoff can be anchored to it"
                )
            return
        if self.policy_bundle_hash is None:
            raise ValueError(
                "policy_bundle_hash is required when no locked contract is "
                "supplied (the handoff must be anchored to the canonical "
                "policy bundle hash)"
            )
        if not isinstance(self.policy_bundle_hash, str) or re.fullmatch(
            CONTRACT_HASH_PATTERN, self.policy_bundle_hash
        ) is None:
            raise ValueError("policy_bundle_hash must be a canonical 64-hex hash")

    def _validate_trace_references(self, trace: TraceGraph) -> None:
        """The trace references must resolve NOW (fail fast, never late).

        Mirrors the bridge's pack scoping: every requirement must be a
        requirement node of the trace, and every acceptance/Test id must be
        forward-reachable from the requirements with the right node kind.
        A plan with broken references is rejected at construction instead of
        failing when the handoff is built (or, worse, dispatching a
        mis-scoped pack).
        """
        kind_by_id = {node.id: node.kind for node in trace.nodes}
        for requirement_id in self.requirement_ids:
            if kind_by_id.get(requirement_id) != "requirement":
                raise ValueError(
                    f"requirement {requirement_id!r} is not a requirement "
                    "node of the trace graph"
                )
        reachable = self._forward_reachable(trace, self.requirement_ids)
        for acceptance_id in self.acceptance_ids:
            if acceptance_id not in reachable:
                raise ValueError(
                    f"acceptance {acceptance_id!r} is not reachable from "
                    "the task requirements in the trace graph"
                )
            if kind_by_id.get(acceptance_id) != "acceptance":
                raise ValueError(
                    f"{acceptance_id!r} is not an acceptance node of the "
                    "trace graph"
                )
        for test_id in self.test_ids:
            if test_id not in reachable:
                raise ValueError(
                    f"test {test_id!r} is not reachable from the task "
                    "requirements in the trace graph"
                )
            if kind_by_id.get(test_id) != "test":
                raise ValueError(
                    f"{test_id!r} is not a test node of the trace graph"
                )

    @staticmethod
    def _forward_reachable(
        trace: TraceGraph, roots: Iterable[str]
    ) -> set[str]:
        """Forward-reachable node ids from ``roots`` (deterministic DFS)."""
        adjacency: dict[str, list[str]] = {}
        for edge in trace.edges:
            adjacency.setdefault(edge.source, []).append(edge.target)
        seen: set[str] = set()
        stack = list(roots)
        while stack:
            node_id = stack.pop()
            if node_id in seen:
                continue
            seen.add(node_id)
            stack.extend(adjacency.get(node_id, ()))
        return seen

    def to_spec(self) -> TaskSpec:
        """The scheduler's view of this task (pure simulation input)."""
        return TaskSpec(
            id=self.id,
            depends_on=self.depends_on,
            budget_ceiling=self.budget_ceiling,
            rate_demands=self.rate_demands,
        )


def _as_tuple(items: Iterable[str], what: str) -> tuple[str, ...]:
    parsed: list[str] = []
    for item in items:
        if not isinstance(item, str) or not item:
            raise ValueError(f"{what} entries must be non-empty strings")
        parsed.append(item)
    if len(parsed) != len(set(parsed)):
        raise ValueError(f"{what} must not contain duplicates")
    return tuple(parsed)


def _as_utc(value: datetime, name: str) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError(f"{name} must be timezone-aware")
    return value.astimezone(timezone.utc)


# ---------------------------------------------------------------------------
# Deterministic wave-gate deviation review (spec 16.4 gate-level review)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class WaveEvidenceItem:
    """One reviewable piece of wave evidence.

    ``deviation`` marks a material declared deviation, ``destructive`` a
    policy-classified destructive operation and ``production`` a
    production-target output/operation -- all three are always reviewed.
    ``detail`` is an optional deterministic note (e.g. the policy decision).
    """

    id: str
    kind: str
    deviation: bool = False
    destructive: bool = False
    production: bool = False
    detail: str = ""

    def __post_init__(self) -> None:
        if not isinstance(self.id, str) or not self.id:
            raise ValueError("id must be a non-empty string")
        if not isinstance(self.kind, str) or not self.kind:
            raise ValueError("kind must be a non-empty string")
        for flag in ("deviation", "destructive", "production"):
            if not isinstance(getattr(self, flag), bool):
                raise TypeError(f"{flag} must be a bool")
        if not isinstance(self.detail, str):
            raise TypeError(f"detail must be a str, got {type(self.detail).__name__}")


@dataclass(frozen=True)
class WaveGateReview:
    """Result of the deterministic wave-gate deviation review.

    ``mandatory`` carries every item that must be reviewed (100% of declared
    deviations plus all production/destructive operations),
    ``pool`` the remaining evidence items and ``sampled`` the deterministic
    >= ``ratio`` (default 20%) sample of that pool -- ceiling-rounded, with
    at least ``minimum`` (default 1) sample per nonempty wave.
    ``reviewed`` is the union (mandatory first, then the sample) in
    deterministic order.
    """

    wave_id: str
    items: tuple[WaveEvidenceItem, ...] = ()
    mandatory: tuple[WaveEvidenceItem, ...] = ()
    pool: tuple[WaveEvidenceItem, ...] = ()
    sampled: tuple[WaveEvidenceItem, ...] = ()
    ratio: Decimal = Decimal("0.20")
    minimum: int = 1

    @property
    def reviewed(self) -> tuple[WaveEvidenceItem, ...]:
        """The full review set: mandatory plus the sampled pool."""
        return self.mandatory + self.sampled

    @property
    def sample_size(self) -> int:
        return len(self.sampled)

    @property
    def pool_size(self) -> int:
        return len(self.pool)

    @staticmethod
    def _selection_key(wave_id: str, item_id: str) -> str:
        """Stable cross-platform selection key (no hash randomization)."""
        return hashlib.sha256(f"{wave_id}\x1f{item_id}".encode("utf-8")).hexdigest()

    @classmethod
    def sample(
        cls,
        wave_id: str,
        items: Iterable[WaveEvidenceItem],
        *,
        ratio: Decimal = Decimal("0.20"),
        minimum: int = 1,
    ) -> WaveGateReview:
        """Deterministically review one wave's evidence.

        Returns a review whose ``mandatory`` set is exactly the declared
        deviations plus all production/destructive evidence, whose pool is
        the remaining evidence and whose sample covers at least ``ratio``
        (default 20%) of the pool -- ceiling-rounded, minimum 1 per
        nonempty wave. Identical inputs always produce an identical review:
        the sample is selected by a stable SHA-256 key of
        ``wave_id + item id``, never by map iteration or wall clock.
        """
        if not isinstance(wave_id, str) or not wave_id:
            raise ValueError("wave_id must be a non-empty string")
        ratio = Decimal(ratio)
        if ratio <= 0 or ratio > 1:
            raise ValueError(f"ratio must be in (0, 1], got {ratio}")
        if isinstance(minimum, bool) or not isinstance(minimum, int):
            raise TypeError(f"minimum must be an int, got {type(minimum).__name__}")
        if minimum < 1:
            raise ValueError(f"minimum must be positive, got {minimum}")
        parsed = tuple(items)
        for item in parsed:
            if not isinstance(item, WaveEvidenceItem):
                raise TypeError(
                    f"wave evidence items must be WaveEvidenceItem, "
                    f"got {type(item).__name__}"
                )
        # Canonical input order so a review is value-equal for any input
        # order (determinism, not map-iteration order).
        parsed = tuple(
            sorted(
                parsed,
                key=lambda item: (
                    item.id,
                    item.kind,
                    item.deviation,
                    item.destructive,
                    item.production,
                    item.detail,
                ),
            )
        )
        mandatory = tuple(
            sorted(
                (
                    item
                    for item in parsed
                    if item.deviation or item.destructive or item.production
                ),
                key=lambda item: item.id,
            )
        )
        mandatory_ids = {item.id for item in mandatory}
        pool = tuple(
            sorted(
                (item for item in parsed if item.id not in mandatory_ids),
                key=lambda item: item.id,
            )
        )
        if not pool:
            sampled: tuple[WaveEvidenceItem, ...] = ()
        else:
            keyed = sorted(
                pool,
                key=lambda item: (
                    cls._selection_key(wave_id, item.id),
                    item.id,
                ),
            )
            requested = max(
                int((ratio * Decimal(len(pool))).to_integral_value(rounding=ROUND_CEILING)),
                minimum,
            )
            sampled = tuple(keyed[: min(requested, len(pool))])
        return cls(
            wave_id=wave_id,
            items=parsed,
            mandatory=mandatory,
            pool=pool,
            sampled=sampled,
            ratio=ratio,
            minimum=minimum,
        )


# ---------------------------------------------------------------------------
# Controller views
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ControllerSnapshot:
    """A consistent view of the run taken at one deterministic instant."""

    run_id: str
    run_state: LifecycleState
    task_state: tuple[tuple[str, str], ...]
    passed: tuple[str, ...]
    running: tuple[str, ...]
    pending: tuple[str, ...]
    frozen: tuple[str, ...]
    terminal: tuple[str, ...]
    open_wave: str | None
    money_available: Decimal
    money_reserved: Decimal
    money_actual: Decimal
    rate_available: tuple[tuple[str, int], ...]
    live_leases: tuple[tuple[str, str], ...]
    time_remaining: tuple[tuple[str, float], ...]


@dataclass(frozen=True)
class TickResult:
    """Outcome of one controller tick (the pre-tick snapshot first)."""

    snapshot: ControllerSnapshot
    dispatched: tuple[TaskHandoff, ...] = ()
    frozen: tuple[str, ...] = ()
    released: tuple[str, ...] = ()
    events: tuple[RunEvent, ...] = ()


class AutobuildController:
    """The integrated scheduler pipeline controller (one run).

    All components are injected (store / scheduler / leases / bridge /
    budget / rate / policy) so the pipeline is testable and the ledgers/
    leases stay the single authority on money, rate and attempt identity.
    No wall clock is read unless one is handed in; every ``now`` is
    normalized to UTC (R7 discipline).
    """

    def __init__(
        self,
        *,
        run_id: str,
        store: RunStore,
        scheduler: Scheduler,
        leases: LeaseLedger | LeaseStore,
        bridge: ExecutionBridge,
        budget: BudgetLedger,
        rate: RateCapacityLedger,
        policy: PolicyToolGate,
        tasks: Mapping[str, TaskPlan],
        verifier: EvidenceVerifier | None = None,
    ) -> None:
        if not isinstance(run_id, str) or re.fullmatch(RUN_ID_PATTERN, run_id) is None:
            raise ValueError(f"run_id must match {RUN_ID_PATTERN}, got {run_id!r}")
        if not isinstance(store, RunStore):
            raise TypeError(f"store must be a RunStore, got {type(store).__name__}")
        if not isinstance(scheduler, Scheduler):
            raise TypeError(f"scheduler must be a Scheduler, got {type(scheduler).__name__}")
        if not isinstance(leases, (LeaseLedger, LeaseStore)):
            raise TypeError(
                "leases must be a LeaseLedger or LeaseStore, "
                f"got {type(leases).__name__}"
            )
        if not isinstance(bridge, ExecutionBridge):
            raise TypeError(f"bridge must be an ExecutionBridge, got {type(bridge).__name__}")
        if not isinstance(budget, BudgetLedger):
            raise TypeError(f"budget must be a BudgetLedger, got {type(budget).__name__}")
        if not isinstance(rate, RateCapacityLedger):
            raise TypeError(
                f"rate must be a RateCapacityLedger, got {type(rate).__name__}"
            )
        if not isinstance(policy, PolicyToolGate):
            raise TypeError(f"policy must be a PolicyToolGate, got {type(policy).__name__}")
        if verifier is not None and not isinstance(verifier, EvidenceVerifier):
            raise TypeError(
                f"verifier must be an EvidenceVerifier, got {type(verifier).__name__}"
            )
        # The run must exist before leases/events can reference it (FKs).
        store.load_run(run_id)
        plans: dict[str, TaskPlan] = {}
        for plan in tasks.values():
            if not isinstance(plan, TaskPlan):
                raise TypeError(
                    f"tasks values must be TaskPlan, got {type(plan).__name__}"
                )
            if plan.id in plans:
                raise ValueError(f"duplicate task plan {plan.id!r}")
            plans[plan.id] = plan
        for key, plan in tasks.items():
            if key != plan.id:
                raise ValueError(
                    f"task mapping key {key!r} does not match plan id {plan.id!r}"
                )
        unknown = sorted(
            {
                dependency
                for plan in plans.values()
                for dependency in plan.depends_on
                if dependency not in plans
            }
        )
        if unknown:
            raise BrokenTaskGraph(
                f"tasks depend on unknown tasks: {unknown}"
            )
        # Provider references must resolve NOW: a rate demand for a provider
        # with no configured capacity is a broken run contract (the
        # scheduler refuses to guess and would raise a raw KeyError at tick
        # time), so the controller is rejected at construction (fail fast).
        unconfigured = sorted(
            {
                demand.provider_key
                for plan in plans.values()
                for demand in plan.rate_demands
                if demand.provider_key not in rate.limits
            }
        )
        if unconfigured:
            raise ControllerError(
                f"task rate demands reference unconfigured providers: "
                f"{unconfigured}"
            )
        self.run_id = run_id
        self.store = store
        self.scheduler = scheduler
        self.leases = leases
        self.bridge = bridge
        self.budget = budget
        self.rate = rate
        self.policy = policy
        self._verifier = verifier
        self._plans = plans
        self._status: dict[str, TaskState] = {
            task_id: TaskState.PENDING for task_id in sorted(plans)
        }
        self._clocks = {
            task_id: TaskTimeBudget(task_id, plan.time_budget_seconds)
            for task_id, plan in plans.items()
        }
        self._paused: set[str] = set()
        self._wave_counter = 0
        self._open_wave: str | None = None
        self._waves: dict[str, list[str]] = {}
        self._wave_reports: dict[str, dict[str, ExecutionReport]] = {}
        self._wave_usage: dict[str, dict[str, Decimal]] = {}
        self._operations: dict[str, list[WaveEvidenceItem]] = {}
        self._reviews: dict[str, WaveGateReview] = {}
        self._events: list[RunEvent] = []
        self._handoffs: list[TaskHandoff] = []
        self._released: list[str] = []
        self._frozen: list[str] = []

    # -- public views ---------------------------------------------------------

    def time_budget(self, task_id: str) -> TaskTimeBudget:
        """The task's :class:`TaskTimeBudget` (``KeyError`` unknown)."""
        try:
            return self._clocks[task_id]
        except KeyError:
            raise KeyError(task_id) from None

    def snapshot(self, now: datetime | None = None) -> ControllerSnapshot:
        """A consistent view of the run at one deterministic instant."""
        now = _as_utc(
            now if now is not None else datetime.now(timezone.utc), "now"
        )
        record = self.store.load_run(self.run_id)
        task_state = tuple(
            (task_id, self._status[task_id].value)
            for task_id in sorted(self._status)
        )
        live_leases: list[tuple[str, str]] = []
        time_remaining: list[tuple[str, float]] = []
        for task_id in sorted(self._plans):
            current = self.leases.current_lease(task_id)
            if current is not None and self.leases.lease_is_live(
                current.lease_id, self.run_id, now=now
            ):
                live_leases.append((task_id, current.lease_id))
            time_remaining.append(
                (task_id, self._clocks[task_id].remaining(now))
            )
        return ControllerSnapshot(
            run_id=self.run_id,
            run_state=record.state,
            task_state=task_state,
            passed=self._by_state(TaskState.PASSED),
            running=self._by_state(TaskState.RUNNING),
            pending=self._by_state(TaskState.PENDING),
            frozen=self._by_state(TaskState.FROZEN),
            terminal=self._by_terminal(),
            open_wave=self._open_wave,
            money_available=self.budget.available,
            money_reserved=self.budget.reserved,
            money_actual=self.budget.actual,
            rate_available=tuple(
                (
                    provider_key,
                    self.rate.effective_limit(provider_key)
                    - self.rate.used(provider_key),
                )
                for provider_key in sorted(self.rate.limits)
            ),
            live_leases=tuple(live_leases),
            time_remaining=tuple(time_remaining),
        )

    # -- tick ----------------------------------------------------------------

    def tick(self, now: datetime | None = None) -> TickResult:
        """Run one deterministic pipeline cycle.

        Order (pinned by the plan): snapshot; sweep stale leases (expire ->
        release money + rate, freeze the task time budget, emit
        ``task.frozen``); relaunch frozen tasks into the open wave (fresh
        lease, unfrozen clock, DISPATCH) and ask the scheduler for a new
        wave only when none is open; close the wave when every task of it is
        terminal. Nothing dispatches while the run is PAUSED (the pause path
        retains reservations; resume re-dispatches them).
        """
        now = _as_utc(
            now if now is not None else datetime.now(timezone.utc), "now"
        )
        snapshot = self.snapshot(now=now)
        events_start = len(self._events)
        self._handoffs = []
        self._frozen = []
        self._released = []

        # 1) Stale lease sweep: expired leases are no longer accounted for.
        # A (possibly shared) LeaseStore sweeps the whole database, so the
        # controller only releases/freezes leases of its OWN run: another
        # run's lapsed lease never touches this run's clocks/ledgers.
        for lease in self.leases.expire_stale(now):
            if lease.run_id != self.run_id:
                continue
            self._stale(lease, now=now, reason="lease.expired")
            self._frozen.append(lease.task_id)
            if lease.task_id not in self._paused:
                self._released.append(lease.task_id)

        run_state = self.store.load_run(self.run_id).state
        if run_state is LifecycleState.BUILDING:
            # 2a) Relaunch every frozen task into the still-open wave: a
            # stale-released task re-reserves, a paused-retained task does
            # not (the booking was held; no double reserve).
            for task_id in sorted(self._status):
                if self._status[task_id] is TaskState.FROZEN:
                    wave_id = (
                        self._open_wave
                        if self._open_wave is not None
                        else self._begin_wave()
                    )
                    self._launch(
                        task_id,
                        now=now,
                        wave_id=wave_id,
                        retained=task_id in self.budget.reservations,
                    )
            # 2b) The scheduler decides only when no wave is in flight
            # (one open wave at a time keeps the money accounting exact).
            if self._open_wave is None:
                self._schedule_next_wave(now)

        self._maybe_complete_wave(now)
        return TickResult(
            snapshot=snapshot,
            dispatched=tuple(self._handoffs),
            frozen=tuple(self._frozen),
            released=tuple(self._released),
            events=tuple(self._events[events_start:]),
        )

    # -- pause / resume (separate path: retain the reservation) ---------------

    def pause(self, now: datetime | None = None) -> ControllerSnapshot:
        """Pause the run: fence leases, freeze clocks, RETAIN reservations.

        The PAUSED path never releases money/rate (contract: no release on
        pause); the bookings stay held so the resume re-dispatches the same
        set without double-reserving. The run state moves BUILDING -> PAUSED
        (durable transition).
        """
        now = _as_utc(
            now if now is not None else datetime.now(timezone.utc), "now"
        )
        record = self.store.load_run(self.run_id)
        if record.state is not LifecycleState.BUILDING:
            raise NotBuilding(
                f"only a BUILDING run can pause, run is {record.state.value}"
            )
        running = sorted(
            task_id
            for task_id, state in self._status.items()
            if state is TaskState.RUNNING
        )
        self._paused.update(running)
        self.store.transition(
            self.run_id, LifecycleState.BUILDING, LifecycleState.PAUSED,
            "autopilot paused (reservations retained)",
        )
        for task_id in running:
            current = self.leases.current_lease(task_id)
            if current is None or not self.leases.lease_is_live(
                current.lease_id, self.run_id, now=now
            ):
                continue
            fenced = self.leases.fence(current.lease_id)
            self._stale(fenced, now=now, reason="run.paused")
        return self.snapshot(now=now)

    def resume(self, now: datetime | None = None) -> ControllerSnapshot:
        """Resume a paused run (PAUSED -> RESUMING -> BUILDING).

        The retained reservations stay exactly once; the next tick
        re-dispatches the frozen tasks with fresh lease generations.
        """
        now = _as_utc(
            now if now is not None else datetime.now(timezone.utc), "now"
        )
        record = self.store.load_run(self.run_id)
        if record.state is not LifecycleState.PAUSED:
            raise NotBuilding(
                f"only a PAUSED run can resume, run is {record.state.value}"
            )
        self.store.transition(
            self.run_id, LifecycleState.PAUSED, LifecycleState.RESUMING,
            "autopilot resuming",
        )
        self.store.transition(
            self.run_id, LifecycleState.RESUMING, LifecycleState.BUILDING,
            "autopilot resumed",
        )
        self._paused.clear()
        return self.snapshot(now=now)

    # -- fenced stale lease (hung worker) --------------------------------------

    def fence_task(
        self, task_id: str, *, reason: str = "fenced", now: datetime | None = None
    ) -> None:
        """Fence a task's live lease (hung worker / deviation drain).

        Releases its money + rate reservations and freezes the task time
        budget -- the same stale-lease semantics as an expiry, so a fenced
        attempt can never report against the controller again.
        """
        now = _as_utc(
            now if now is not None else datetime.now(timezone.utc), "now"
        )
        if task_id not in self._plans:
            raise UnknownTask(task_id)
        current = self.leases.current_lease(task_id)
        if current is None:
            raise ControllerError(
                f"task {task_id!r} holds no lease to fence"
            )
        if self.leases.lease_status(current.lease_id) is not LeaseStatus.LIVE:
            raise ControllerError(
                f"task {task_id!r} lease {current.lease_id!r} is not live"
            )
        fenced = self.leases.fence(current.lease_id)
        self._stale(fenced, now=now, reason=reason)

    # -- execution ------------------------------------------------------------

    def execute_operation(
        self,
        operation: Operation,
        *,
        task_id: str,
        production: bool = False,
        now: datetime | None = None,
    ) -> Any:
        """Run one policy-classified operation through the injected gate.

        The operation is recorded as destructive wave evidence (always
        reviewed) before the gate executes it; ALLOWED executes once, DENIED
        raises :class:`~kcc_autobuild.tool_gate.PolicyDenied` and AMBIGUOUS
        raises :class:`~kcc_autobuild.tool_gate.AmbiguousPolicy` back to KCC
        machine interpretation (never a direct user prompt).

        Fail closed on the attempt identity first: the operation belongs to
        the task's current lease, and a lease that lapsed (or was fenced)
        is no longer accounted for even before the tick sweep runs, so the
        operation is refused with :class:`StaleLeaseOperation` before the
        gate evaluates or executes anything (no lapsed-but-unswept window
        for destructive operations).
        """
        if task_id not in self._plans:
            raise UnknownTask(task_id)
        if self._status[task_id] is not TaskState.RUNNING:
            raise ControllerError(
                f"task {task_id!r} is not running; operations belong to an attempt"
            )
        now = _as_utc(
            now if now is not None else datetime.now(timezone.utc), "now"
        )
        current = self.leases.current_lease(task_id)
        if current is None or not self.leases.lease_is_live(
            current.lease_id, self.run_id, now=now
        ):
            raise StaleLeaseOperation(
                f"task {task_id!r} lease "
                f"{current.lease_id if current is not None else None!r} is not"
                " live -- the attempt is no longer accounted for; the"
                " operation is refused until a fresh lease is claimed"
            )
        # The gate is the ONLY evaluator+executor: one evaluation per
        # operation (never double-evaluate for the audit) and the evidence
        # record is written only AFTER an ALLOWED execution -- a DENIED or
        # AMBIGUOUS operation executes nothing, so it leaves no destructive
        # evidence behind (a unique audit decision token is on the gate).
        result = self.policy.execute(operation)
        decision = self.policy.audits[-1].decision
        index = len(self._operations.get(task_id, []))
        self._operations.setdefault(task_id, []).append(
            WaveEvidenceItem(
                id=f"{task_id}:operation:{index}",
                kind="operation",
                destructive=True,
                production=bool(production),
                detail=decision.value,
            )
        )
        return result

    # -- reports ---------------------------------------------------------------

    def accept_report(
        self,
        report: ExecutionReport,
        *,
        acceptance: ReportAcceptance | None = None,
        now: datetime | None = None,
    ) -> ReportAcceptance:
        """Accept a verified Execution Report and advance the run.

        Fail-closed guards (in order): the report belongs to this run and
        names an owned task; its lease is the task's current lease, still
        live, with matching generation and workspace; the task is in flight;
        the run is BUILDING. Verification then either comes from an explicit
        ``acceptance`` or the injected
        :class:`~kcc_autobuild.evidence.EvidenceVerifier` (neither -> the
        claim stays untrusted).

        A rejected report always counts as a failed attempt: the task is
        FAILED, its attempt reservation is released and the lease fenced. A
        verified report closes the attempt (lease fenced, provider rate
        released) and marks the task PASSED/FAILED/BLOCKED; when the wave
        completes, its money bookings settle and the deterministic wave-gate
        review samples the wave.
        """
        now = _as_utc(
            now if now is not None else datetime.now(timezone.utc), "now"
        )
        if not isinstance(report, ExecutionReport):
            raise TypeError(
                f"report must be an ExecutionReport, got {type(report).__name__}"
            )
        if report.run_id != self.run_id:
            raise ReportMismatch(
                f"report run_id {report.run_id!r} does not match {self.run_id!r}"
            )
        if report.task_id not in self._plans:
            raise UnknownTask(report.task_id)
        task_id = report.task_id
        current = self.leases.current_lease(task_id)
        if current is None:
            raise ReportMismatch(f"task {task_id!r} is not in flight")
        if current.lease_id != report.lease_id:
            raise StaleLeaseReport(
                f"report lease {report.lease_id!r} is not the current lease "
                f"{current.lease_id!r}"
            )
        if not self.leases.lease_is_live(report.lease_id, self.run_id, now=now):
            raise StaleLeaseReport(
                f"report lease {report.lease_id!r} is stale (expired, fenced "
                "or unknown) -- the attempt is no longer accounted for"
            )
        if self._status[task_id] is not TaskState.RUNNING:
            raise ReportMismatch(f"task {task_id!r} is not in flight")
        if report.attempt != current.generation:
            raise ReportMismatch(
                f"report attempt {report.attempt} does not match lease "
                f"generation {current.generation}"
            )
        if report.workspace_id != current.workspace_id:
            raise ReportMismatch(
                f"report workspace {report.workspace_id!r} does not match "
                f"the lease workspace {current.workspace_id!r}"
            )
        run_state = self.store.load_run(self.run_id).state
        if run_state is not LifecycleState.BUILDING:
            raise NotBuilding(
                f"a {run_state.value} run does not accept reports"
            )
        if acceptance is None:
            if self._verifier is None:
                raise UnverifiedReport(
                    "no acceptance supplied and no verifier injected -- "
                    "Execution Report claims are never trusted implicitly"
                )
            acceptance = self._verifier.verify(report)
        elif not isinstance(acceptance, ReportAcceptance):
            raise TypeError(
                "acceptance must be a ReportAcceptance, "
                f"got {type(acceptance).__name__}"
            )

        if not acceptance.accepted:
            self._reject_attempt(task_id, current, report, acceptance, now)
            return acceptance

        if self._open_wave is None:
            raise ControllerMismatch("a running task exists outside any wave")
        wave_id = self._open_wave
        self._wave_reports.setdefault(wave_id, {})[task_id] = report
        self._wave_usage.setdefault(wave_id, {})[task_id] = Decimal(
            str(report.usage.cost_usd)
        )
        self.leases.fence(current.lease_id)
        if task_id in self.rate.reservations:
            self.rate.release(task_id)
        status = self._status_for_report(report)
        previous = self._status[task_id]
        self._status[task_id] = status
        if status is TaskState.PASSED:
            self._emit(
                "task.passed",
                {
                    "task_id": task_id,
                    "lease_id": report.lease_id,
                    "generation": current.generation,
                    "attempt": report.attempt,
                    "from_status": previous.value,
                    "usage_cost": str(Decimal(str(report.usage.cost_usd))),
                },
                now,
            )
        else:
            self._emit(
                "task.failed" if status is TaskState.FAILED else "task.blocked",
                {
                    "task_id": task_id,
                    "lease_id": report.lease_id,
                    "generation": current.generation,
                    "attempt": report.attempt,
                    "from_status": previous.value,
                    "failure_class": report.failure.cls.value
                    if report.failure is not None
                    else None,
                },
                now,
            )
            # A terminal-non-passed task blocks its PENDING dependents
            # (E7/E8-style) so the scheduler is never shown a broken
            # universe -- and the run wedges on nothing.
            self._block_for_failed_dependencies(now)
        self._maybe_complete_wave(now)
        return acceptance

    # -- internals -------------------------------------------------------------

    @staticmethod
    def _status_for_report(report: ExecutionReport) -> TaskState:
        if report.status is ExecutionStatus.PASSED:
            return TaskState.PASSED
        if report.status is ExecutionStatus.BLOCKED:
            return TaskState.BLOCKED
        return TaskState.FAILED

    def _reject_attempt(self, task_id: str, lease: Lease, report: ExecutionReport, acceptance: ReportAcceptance, now: datetime) -> None:
        """An unverified report: the attempt is void -- release, fence, fail."""
        released_money: str | None = None
        released_rate: list[dict[str, Any]] | None = None
        if task_id in self.budget.reservations:
            released_money = str(self.budget.release(task_id))
        if task_id in self.rate.reservations:
            demand = self.rate.release(task_id)
            released_rate = [
                {"provider_key": demand.provider_key, "units": demand.units}
            ]
        self._status[task_id] = TaskState.FAILED
        self.leases.fence(lease.lease_id)
        self._emit(
            "report.rejected",
            {
                "task_id": task_id,
                "lease_id": lease.lease_id,
                "attempt": report.attempt,
                "counts_as_failed_attempt": acceptance.counts_as_failed_attempt,
                "reasons": list(acceptance.reasons),
                "released_money": released_money,
                "released_rate": released_rate,
            },
            now,
        )
        self._emit(
            "task.failed",
            {
                "task_id": task_id,
                "lease_id": lease.lease_id,
                "generation": lease.generation,
                "attempt": report.attempt,
                "from_status": TaskState.RUNNING.value,
                "reason": "report evidence rejected",
            },
            now,
        )
        self._block_for_failed_dependencies(now)
        self._maybe_complete_wave(now)

    def _stale(self, lease: Lease, *, now: datetime, reason: str) -> None:
        """Release/freeze one stale lease (expired, fenced or paused).

        Releases the money + rate reservations unless the task is paused
        (the PAUSED path retains the booking; only a time-budget exhaustion
        releases a retained booking, because the task is then terminal).
        Freezes the task time budget at the elapsed time and emits the
        ``task.frozen`` event. A budget that is exhausted fails the task
        instead of scheduling another attempt.
        """
        task_id = lease.task_id
        clock = self._clocks[task_id]
        elapsed = clock.freeze(now)
        retained = task_id in self._paused
        released_money: str | None = None
        released_rate: list[dict[str, Any]] | None = None
        release = not retained
        if release:
            if task_id in self.budget.reservations:
                released_money = str(self.budget.release(task_id))
            if task_id in self.rate.reservations:
                demand = self.rate.release(task_id)
                released_rate = [
                    {"provider_key": demand.provider_key, "units": demand.units}
                ]
        remaining = clock.remaining(now)
        previous = self._status[task_id]
        if remaining <= 0 and self._status[task_id] in (
            TaskState.RUNNING,
            TaskState.FROZEN,
        ):
            # The retained booking is released now: the task is terminal and
            # would otherwise leak money/rate through the pause.
            if task_id in self.budget.reservations:
                released_money = str(self.budget.release(task_id))
            if task_id in self.rate.reservations:
                demand = self.rate.release(task_id)
                released_rate = [
                    {"provider_key": demand.provider_key, "units": demand.units}
                ]
            self._status[task_id] = TaskState.FAILED
            self._emit(
                "task.frozen",
                {
                    "task_id": task_id,
                    "lease_id": lease.lease_id,
                    "generation": lease.generation,
                    "reason": reason,
                    "released_money": released_money,
                    "released_rate": released_rate,
                    "elapsed_seconds": elapsed,
                    "time_remaining": float(remaining),
                    "retained": retained,
                },
                now,
            )
            self._emit(
                "task.failed",
                {
                    "task_id": task_id,
                    "lease_id": lease.lease_id,
                    "generation": lease.generation,
                    "attempt": lease.generation,
                    "from_status": previous.value,
                    "reason": "time budget exhausted",
                },
                now,
            )
            self._block_for_failed_dependencies(now)
            return
        self._status[task_id] = TaskState.FROZEN
        self._emit(
            "task.frozen",
            {
                "task_id": task_id,
                "lease_id": lease.lease_id,
                "generation": lease.generation,
                "reason": reason,
                "released_money": released_money,
                "released_rate": released_rate,
                "elapsed_seconds": elapsed,
                "time_remaining": float(remaining),
                "retained": retained,
            },
            now,
        )

    def _block_for_failed_dependencies(self, now: datetime) -> None:
        """Block every PENDING task whose dependency chain hit a terminal-
        non-passed task (FAILED/BLOCKED), transitively.

        Graceful dependent-blocking (E7/E8-style): a dependent of a task
        that can never pass is itself impossible, so it is BLOCKED with a
        deterministic ``task.blocked`` event instead of the scheduler ever
        seeing a universe with a terminal-non-passed dependency (which it
        refuses as a broken contract -- raw :class:`KeyError`). The sweep
        is idempotent and processes tasks in ascending id order, so the
        event order is identical for identical inputs; a blocked task never
        carried a lease or reservation (it was never dispatched), so no
        accounting changes.
        """
        while True:
            blocked: list[tuple[str, str, TaskState]] = []
            for task_id in sorted(self._status):
                if self._status[task_id] is not TaskState.PENDING:
                    continue
                for dependency in self._plans[task_id].depends_on:
                    dep_state = self._status[dependency]
                    if dep_state in _TERMINAL and dep_state is not TaskState.PASSED:
                        blocked.append((task_id, dependency, dep_state))
                        break
            if not blocked:
                return
            for task_id, dependency, dep_state in blocked:
                previous = self._status[task_id]
                generation = self.leases.current_generation(task_id)
                self._status[task_id] = TaskState.BLOCKED
                self._emit(
                    "task.blocked",
                    {
                        "task_id": task_id,
                        "wave_id": None,
                        "lease_id": None,
                        "generation": generation,
                        "attempt": generation,
                        "from_status": previous.value,
                        "reason": (
                            "dependency failed"
                            if dep_state is TaskState.FAILED
                            else "dependency blocked"
                        ),
                        "dependency_id": dependency,
                        "dependency_status": dep_state.value,
                    },
                    now,
                )

    def _schedule_next_wave(self, now: datetime) -> None:
        """Ask the scheduler and dispatch its selected set (reserve once).

        The scheduler is a pure decision function over a dependency-closed
        universe: it raises :class:`KeyError` when a pending task depends
        on a task that is neither passed nor pending. This controller never
        presents it such a universe -- every terminal-non-passed task first
        blocks its PENDING dependents (graceful E7/E8-style dependent
        blocking) -- so the guard below is idempotent belt-and-braces for
        any future terminalization path.
        """
        self._block_for_failed_dependencies(now)
        passed = self._by_state(TaskState.PASSED)
        active = [
            self._plans[task_id].to_spec()
            for task_id in sorted(self._plans)
            if self._status[task_id] is TaskState.PENDING
            and self._clocks[task_id].remaining(now) > 0
        ]
        decision = self.scheduler.next_dispatch_set(
            passed, active, self.budget, self.rate
        )
        if not decision.task_ids:
            return
        wave_id = self._begin_wave()
        for task_id in decision.task_ids:
            self._launch(task_id, now=now, wave_id=wave_id, retained=False)

    def _begin_wave(self) -> str:
        self._wave_counter += 1
        wave_id = f"wave-{self._wave_counter}"
        self._open_wave = wave_id
        self._waves[wave_id] = []
        return wave_id

    def _launch(
        self, task_id: str, *, now: datetime, wave_id: str, retained: bool
    ) -> TaskHandoff | None:
        """Reserve (once), claim, unfreeze, build the handoff, DISPATCH.

        ``retained`` marks the PAUSED-resume path: the booking was held
        through the pause, so no new reservation is made (exactly once). A
        task whose time budget is exhausted fails instead of dispatching.
        """
        plan = self._plans[task_id]
        clock = self._clocks[task_id]
        # Register wave membership up front: an attempted launch that fails
        # (time budget exhausted, unbuildable pack) is still part of the
        # wave, so the wave can complete and close instead of wedging open
        # with an empty membership. Idempotent: a stale/paused task that
        # relaunches into the SAME open wave is never duplicated.
        if task_id not in self._waves[wave_id]:
            self._waves[wave_id].append(task_id)
        if clock.remaining(now) <= 0:
            if task_id in self.budget.reservations:
                self.budget.release(task_id)
            if task_id in self.rate.reservations:
                self.rate.release(task_id)
            previous = self._status[task_id]
            self._status[task_id] = TaskState.FAILED
            self._emit(
                "task.failed",
                {
                    "task_id": task_id,
                    "lease_id": None,
                    "generation": self.leases.current_generation(task_id),
                    "attempt": self.leases.current_generation(task_id),
                    "from_status": previous.value,
                    "reason": "time budget exhausted",
                },
                now,
            )
            self._block_for_failed_dependencies(now)
            return None
        if not retained:
            self.budget.reserve(task_id, plan.budget_ceiling)
            for demand in plan.rate_demands:
                self.rate.reserve(task_id, demand)
        else:
            if task_id not in self.budget.reservations:
                raise ControllerMismatch(
                    f"task {task_id!r} resumed without its retained reservation"
                )
        lease = self.leases.claim(self.run_id, task_id, now=now)
        clock.start(now)  # unfreeze: the fresh attempt continues the budget
        previous = self._status[task_id]
        self._status[task_id] = TaskState.RUNNING
        handoff = self._build_handoff(task_id, lease, now)
        if handoff is None:
            # A pack that cannot be built is a blocked task: close the claim,
            # return the booking and freeze the clock (no silent dispatch).
            self.leases.fence(lease.lease_id)
            if task_id in self.budget.reservations:
                self.budget.release(task_id)
            if task_id in self.rate.reservations:
                self.rate.release(task_id)
            clock.freeze(now)
            self._status[task_id] = TaskState.BLOCKED
            self._emit(
                "task.blocked",
                {
                    "task_id": task_id,
                    "lease_id": lease.lease_id,
                    "generation": lease.generation,
                    "attempt": lease.generation,
                    "from_status": previous.value,
                    "reason": "handoff build failed or oversized",
                },
                now,
            )
            self._block_for_failed_dependencies(now)
            return None
        if handoff.lease.lease_id != lease.lease_id or handoff.lease.generation != lease.generation:
            raise ControllerMismatch(
                f"handoff lease {handoff.lease.lease_id!r} does not match "
                f"the claimed KCC lease {lease.lease_id!r}"
            )
        self._handoffs.append(handoff)
        self._emit(
            "task.dispatch",
            {
                "wave_id": wave_id,
                "task_id": task_id,
                "from_status": previous.value,
                "lease_id": lease.lease_id,
                "generation": lease.generation,
                "workspace_id": lease.workspace_id,
                "money_reserved": str(plan.budget_ceiling),
                "rate_reserved": [
                    {"provider_key": demand.provider_key, "units": demand.units}
                    for demand in sorted(
                        plan.rate_demands, key=lambda demand: demand.provider_key
                    )
                ],
                "remaining_money": str(self.budget.available),
                "remaining_rate": {
                    provider_key: self.rate.effective_limit(provider_key)
                    - self.rate.used(provider_key)
                    for provider_key in sorted(self.rate.limits)
                },
                "handoff_bytes": len(handoff.pack()),
                "resumed": retained,
            },
            now,
        )
        return handoff

    def _build_handoff(
        self, task_id: str, lease: Lease, now: datetime
    ) -> TaskHandoff | None:
        """Build the bounded handoff and bind it to the claimed KCC lease.

        ``None`` means the pack could not be built or exceeded the bridge
        byte budget -- the caller blocks the task rather than dispatching an
        unscoped or oversized pack.
        """
        plan = self._plans[task_id]
        try:
            handoff = self.bridge.build_handoff(
                run_id=self.run_id,
                task_id=task_id,
                requirement_ids=list(plan.requirement_ids),
                acceptance_ids=list(plan.acceptance_ids),
                test_ids=list(plan.test_ids),
                providers=list(plan.providers) if plan.providers else None,
                trace=plan.trace,
                contract=plan.contract,
                locked_decisions=list(plan.locked_decisions),
                attempt_budget=plan.attempt_budget,
                policy_bundle_hash=plan.policy_bundle_hash,
            )
        except HandoffError:
            return None
        # Rebind the pack to the controller-minted lease: one KCC lease per
        # execution attempt, and the worker's report references exactly it.
        handoff.lease = TaskLease(
            lease_id=lease.lease_id,
            run_id=lease.run_id,
            task_id=lease.task_id,
            generation=lease.generation,
        )
        if len(handoff.pack()) > self.bridge.max_handoff_bytes:
            return None
        return handoff

    def _maybe_complete_wave(self, now: datetime) -> None:
        if self._open_wave is None:
            return
        task_ids = self._waves.get(self._open_wave, [])
        if not task_ids:
            return
        if not all(
            self._status[task_id] in _TERMINAL for task_id in task_ids
        ):
            return
        self._complete_wave(self._open_wave, now)

    def _complete_wave(self, wave_id: str, now: datetime) -> None:
        """Settle the wave: reconcile money, review evidence, close it.

        The reported usage total only gates the hard-cap breach (E3): on a
        breach the run halts to BLOCKED after the books settle (settlement
        first, so a retry never double-charges).
        """
        task_ids = tuple(sorted(self._waves[wave_id]))
        reports = self._wave_reports.get(wave_id, {})
        usage = self._wave_usage.get(wave_id, {})
        reported_actual = Decimal("0")
        for amount in usage.values():
            reported_actual += amount
        try:
            settled = self.budget.reconcile(reported_actual)
        except BudgetBreach as breach:
            self._emit(
                "budget.breach",
                {
                    "wave_id": wave_id,
                    "provider_actual": str(breach.provider_actual),
                    "hard_cap": str(breach.hard_cap),
                },
                now,
            )
            self._halt_e3(breach, now)
            raise
        items = self._wave_items(wave_id, task_ids)
        review = WaveGateReview.sample(wave_id, items)
        self._reviews[wave_id] = review
        self._emit(
            "wave.review",
            {
                "wave_id": wave_id,
                "pool_size": review.pool_size,
                "sample_size": review.sample_size,
                "ratio": str(review.ratio),
                "mandatory_ids": [item.id for item in review.mandatory],
                "sampled_ids": [item.id for item in review.sampled],
                "reviewed_ids": [item.id for item in review.reviewed],
            },
            now,
        )
        self._emit(
            "wave.complete",
            {
                "wave_id": wave_id,
                "task_ids": list(task_ids),
                "reported_actual": str(reported_actual),
                "settled": str(settled),
                "reviewed_items": len(review.reviewed),
            },
            now,
        )
        self._open_wave = None

    def _halt_e3(self, breach: BudgetBreach, now: datetime) -> None:
        """E3: hard budget cap would be exceeded -- transition to BLOCKED."""
        record = self.store.load_run(self.run_id)
        if record.state is LifecycleState.BUILDING:
            self.store.transition(
                self.run_id,
                LifecycleState.BUILDING,
                LifecycleState.BLOCKED,
                f"E3 hard budget cap would be exceeded ({breach.provider_actual} > {breach.hard_cap})",
            )

    def _wave_items(
        self, wave_id: str, task_ids: tuple[str, ...]
    ) -> list[WaveEvidenceItem]:
        """Deterministic wave evidence: outputs, deviations, operations."""
        items: list[WaveEvidenceItem] = []
        reports = self._wave_reports.get(wave_id, {})
        for task_id in task_ids:
            report = reports.get(task_id)
            if report is not None:
                for index, output in enumerate(report.outputs):
                    items.append(
                        WaveEvidenceItem(
                            id=f"{task_id}:output:{index}",
                            kind="output",
                            production=output.kind in _PRODUCTION_OUTPUT_KINDS,
                            detail=output.kind,
                        )
                    )
                for index, deviation in enumerate(report.deviations):
                    items.append(
                        WaveEvidenceItem(
                            id=f"{task_id}:deviation:{index}",
                            kind="deviation",
                            deviation=True,
                            detail=deviation,
                        )
                    )
            items.extend(self._operations.get(task_id, []))
        return items

    def _emit(self, kind: str, payload: dict[str, Any], at: datetime) -> None:
        """Emit one durable run event (events table + this session's log)."""
        event = RunEvent(run_id=self.run_id, kind=kind, at=at, payload=payload)
        self._events.append(event)
        with self.store.conn:
            self.store.conn.execute(
                "INSERT INTO events (run_id, kind, at, payload_json)"
                " VALUES (?, ?, ?, ?)",
                (
                    event.run_id,
                    event.kind,
                    event.at.isoformat(),
                    json.dumps(event.payload, sort_keys=True),
                ),
            )

    def _by_state(self, state: TaskState) -> tuple[str, ...]:
        return tuple(
            task_id
            for task_id in sorted(self._status)
            if self._status[task_id] is state
        )

    def _by_terminal(self) -> tuple[str, ...]:
        return tuple(
            task_id
            for task_id in sorted(self._status)
            if self._status[task_id] in _TERMINAL
        )
