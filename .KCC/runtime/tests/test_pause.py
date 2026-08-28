"""Behavioral contract for PAUSED drain / fence / resource-freeze semantics.

Owned by ``test_pause.py`` (see the KCC x Superpowers Hybrid Framework
Plan 05, Task 6: PAUSED drain / fence / resource-freeze semantics, in
``.superpowers/bootstrap/plans/2026-08-27-05-resume-deploy-validation.task-contracts.md``).

A pause is a *cooperative, checkpointed* stop, not a kill: new dispatch is
stopped first (the durable PAUSED transition), every running worker is
signalled to check out, a noninterruptible operation (e.g. an in-flight
rollback) is allowed to run to its stable boundary, and a worker that does
not reach a stable boundary inside the drain timeout is a hung worker and
is fenced (spec 22: durable state is authoritative; a hung attempt must
never be allowed to report against a paused run).  The pause then freezes
the task time budget (elapsed time is consumed, the clock stops), retains
the resume reservation BY DEFAULT (the booking is held so resume
re-dispatches exactly once -- no double reserve), optionally freezes
reversible resources only when the locked contract classifies them as
reversible, and persists the paused checkpoint => PAUSED.

Resume is a *light* revalidation, never a full discovery: it re-checks the
locked Tier-1 hash, the credential/evidence freshness needed for the next
tasks, provider availability and the target-state markers of those tasks,
then rebalances the reservation (any booking that no longer belongs to a
resumed task is released -- and a resumed task whose retained booking was
lost while paused is a broken ledger and fails closed), mints a fresh lease
generation per resumed task, unfreezes the time budget, enables dispatch
(PAUSED -> RESUMING -> BUILDING) and persists the resume event => BUILDING.
Revalidation failure is fail-closed: the run stays PAUSED, no lease is
minted, no clock is unfrozen, and the batched
:class:`~kcc_autobuild.pause.ResumeRevalidationError` carries the findings.

Prescribed scenarios under test:

* **hung worker fenced / clock frozen / reservation retained** -- a worker
  that never reaches a stable boundary is fenced at the drain deadline, its
  time budget is frozen at the elapsed time, and its money/rate booking is
  retained for resume;
* **rollback stable boundary** -- a noninterruptible rollback is observed
  in flight, is never fenced while it runs, and the drain completes at its
  stable boundary, keeping the reservation;
* **resume revalidates / new lease / unfreezes** -- the resumed run
  revalidates the locked contract surface, mints generation + 1, restarts
  the clock (continuing the same budget) and returns to BUILDING.

Fix-round-1 regression scenarios (review findings):

* a resume that aborts **mid-lease-mint** rolls the mutation phase back
  (fenced leases, refrozen clocks, re-frozen resources), persists
  ``run.resume_failed`` and leaves the run resumable -- a later resume
  succeeds instead of wedging on an abandoned live lease;
* a **drain adapter failure** mid-pause still persists the best-effort
  checkpoint (unresolved workers fenced as hung): never PAUSED without
  durable pause state;
* the checkpoint **pins the reservation universe** (including
  reserved-but-not-running bookings) and the resume validates BOTH the
  retained money AND rate bookings exactly (a lost or altered booking
  fails closed -- never a silent re-reserve);
* the contract-bounded resource freezer is a state machine (freeze /
  unfreeze / frozen-set observable), not a policy-only stub.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest

from kcc_autobuild import pause as pause_module
from kcc_autobuild.budget import BudgetLedger
from kcc_autobuild.contract import (
    AuthorityEnvelope,
    BuildContract,
    DestructiveAction,
    DestructiveOperationRule,
    MoneyPolicy,
    ProviderEntry,
    Tier1Invariants,
    lock_contract,
)
from kcc_autobuild.controller import TaskTimeBudget
from kcc_autobuild.leases import LeaseConflict, LeaseLedger, LeaseStatus
from kcc_autobuild.models import DependencyStatus, LifecycleState, ReadinessStatus, RunRecord
from kcc_autobuild.pause import (
    ContractResourceFreezer,
    DrainStatus,
    NotPausable,
    NotPaused,
    PauseCheckpointMissing,
    PauseCoordinator,
    PauseError,
    RevalidationCheck,
    ResumeRevalidationError,
    contract_allows_reversible_freeze,
    evaluate_light_revalidation,
)
from kcc_autobuild.rate_limit import RateCapacityLedger, RateDemand
from kcc_autobuild.readiness import EvidenceRecord, ReadinessItem, ReadinessPack
from kcc_autobuild.store import RunStore
from kcc_autobuild.trace import TraceEdge, TraceGraph, TraceNode

T0 = datetime(2026, 8, 28, 12, 0, 0, tzinfo=timezone.utc)
"""Fixed deterministic instant so drain/lease/freeze assertions are exact."""

LOCK_AT = T0 - timedelta(hours=1)
"""Lock instant: the readiness evidence is fresh at lock (age 0)."""

EVIDENCE_TTL = timedelta(hours=4)
"""Freshness window of the fixture evidence (stale only far past resume)."""

PAUSE_AT = T0
"""Pause request instant (the drain starts here)."""

DRAIN_TIMEOUT = timedelta(seconds=10)
"""Fixture drain timeout (polls at +0s, +5s, +10s with a 5s interval)."""

DRAIN_INTERVAL = timedelta(seconds=5)
"""Fixture poll interval."""

TIME_BUDGET = 600
"""Per-task time budget in the fixtures."""


# ---------------------------------------------------------------------------
# Fixtures: a minimally valid, LOCKED contract (real BuildContract, so the
# canonical Tier-1 hash and the readiness evidence are real).
# ---------------------------------------------------------------------------


def _trace() -> TraceGraph:
    """A trace where REQ-001 reaches acceptance and production validation."""
    return TraceGraph(
        nodes=[
            TraceNode(id="REQ-001", kind="requirement"),
            TraceNode(id="IMPL-01", kind="implementation"),
            TraceNode(id="AC-001", kind="acceptance"),
            TraceNode(id="PROD-001", kind="production_validation"),
        ],
        edges=[
            TraceEdge(source="REQ-001", target="IMPL-01"),
            TraceEdge(source="IMPL-01", target="AC-001"),
            TraceEdge(source="IMPL-01", target="PROD-001"),
        ],
    )


def _item(
    *,
    provider: str = "provider-a",
    checked_at: datetime = LOCK_AT,
    status: ReadinessStatus = ReadinessStatus.READY,
) -> ReadinessItem:
    """One readiness item with pass evidence checked at ``checked_at``."""
    return ReadinessItem(
        id="IT-001",
        provider=provider,
        status=status,
        required_kinds=["identity"],
        evidence=[
            EvidenceRecord(
                kind="identity",
                result="pass",
                checked_at=checked_at,
                resource_ids=["resource-1"],
                scopes=["scopes:read"],
            )
        ],
        evidence_ttl=EVIDENCE_TTL,
    )


def _contract(
    *,
    product_scope: str = "internal CLI analysis tool",
    items: list[ReadinessItem] | None = None,
    destructive_policy: list[DestructiveOperationRule] | None = None,
) -> BuildContract:
    """A lockable contract; READY provider-a evidence fresh at LOCK_AT."""
    return BuildContract(
        tier1=Tier1Invariants(
            product_scope=product_scope,
            non_goals=["no public API"],
            primary_user_journeys=["run one analysis end to end"],
            provider_whitelist=[ProviderEntry(provider="provider-a", paid=True)],
            fallback_whitelist=[],
            authority=AuthorityEnvelope(
                auto_provision_status=DependencyStatus.NOT_REQUIRED,
            ),
            money=MoneyPolicy(per_provider_caps={"provider-a": 50_000}),
            production_target="https://app.internal.example.com",
            definition_of_done=(
                "analysis output is produced end to end and validated in staging"
            ),
            definition_of_done_ids=["PROD-001"],
            destructive_policy=destructive_policy or [],
        ),
        trace=_trace(),
        readiness=ReadinessPack(items=items if items is not None else [_item()]),
    )


def _locked_contract(
    *,
    product_scope: str = "internal CLI analysis tool",
    items: list[ReadinessItem] | None = None,
    destructive_policy: list[DestructiveOperationRule] | None = None,
) -> BuildContract:
    """A locked (hash-stamped) contract for pause/resume coordination."""
    contract = _contract(
        product_scope=product_scope,
        items=items,
        destructive_policy=destructive_policy,
    )
    lock_contract(contract, now=LOCK_AT)
    return contract


# ---------------------------------------------------------------------------
# Fixtures: injected adapters (drain / probe / resource freezer) and the
# coordinator wiring.
# ---------------------------------------------------------------------------


class _ScriptedDrain:
    """CheckpointDrain stand-in: a scripted status per poll per task.

    ``signal`` records the task; ``poll`` pops the next scripted status
    (or ``default`` when the script is exhausted for that task) and
    records the exact ``(now, status)`` observation so the tests can pin
    the poll schedule and the instant a boundary was reached.
    """

    def __init__(
        self,
        script: dict[str, list[DrainStatus]] | None = None,
        default: DrainStatus = DrainStatus.UNRESPONSIVE,
    ) -> None:
        self.script: dict[str, list[DrainStatus]] = {
            task_id: list(states) for task_id, states in (script or {}).items()
        }
        self.default = default
        self.signals: list[str] = []
        self.polls: dict[str, list[tuple[datetime, DrainStatus]]] = {}

    def signal(self, task_id: str) -> None:
        self.signals.append(task_id)

    def poll(self, task_id: str, now: datetime) -> DrainStatus:
        series = self.script.get(task_id)
        status = series.pop(0) if series else self.default
        self.polls.setdefault(task_id, []).append((now, status))
        return status


class _Probe:
    """ResumeProbe stand-in: provider availability + target markers."""

    def __init__(
        self,
        *,
        provider_available: bool = True,
        markers_ok: bool = True,
    ) -> None:
        self.provider_available_value = provider_available
        self.markers_ok_value = markers_ok
        self.availability_calls: list[tuple[str, datetime]] = []
        self.marker_calls: list[tuple[str, datetime]] = []

    def provider_available(self, provider: str, now: datetime) -> bool:
        self.availability_calls.append((provider, now))
        return self.provider_available_value

    def target_markers_ok(self, task_id: str, now: datetime) -> bool:
        self.marker_calls.append((task_id, now))
        return self.markers_ok_value


class _Freezer:
    """ResourceFreezer stand-in: authorization + frozen resource ids."""

    def __init__(self, authorized: dict[str, bool] | None = None) -> None:
        self.authorized = authorized or {}
        self.frozen: list[tuple[str, tuple[str, ...]]] = []
        self.unfrozen: list[str] = []

    def freeze_authorized(self, task_id: str) -> bool:
        return self.authorized.get(task_id, False)

    def freeze(self, task_id: str) -> tuple[str, ...]:
        resources = (f"{task_id}-resource",)
        self.frozen.append((task_id, resources))
        return resources

    def unfreeze(self, task_id: str) -> None:
        self.unfrozen.append(task_id)


class _FlakyLeaseLedger(LeaseLedger):
    """LeaseLedger whose ``claim`` raises for one task until ``healed``.

    Drives the resume abort-mid-mint path: the first resumed task mints a
    live lease, the second raises, and the coordinator must clean up the
    already-minted lease and keep the run resumable.
    """

    def __init__(self, *, fail_on: str = "T2") -> None:
        super().__init__()
        self.fail_on = fail_on
        self.failing = True

    def claim(self, run_id, task_id, *, now=None, workspace_id=None):
        if self.failing and task_id == self.fail_on:
            raise LeaseConflict(
                f"simulated mint conflict on task {task_id!r}"
            )
        return super().claim(
            run_id, task_id, now=now, workspace_id=workspace_id
        )


class _ExplodingDrain:
    """CheckpointDrain whose ``signal`` or ``poll`` raises (adapter failure).

    ``explode_on_signal`` raises on the first signal; otherwise
    ``explode_at_poll`` raises once that many polls happened (0 = first
    poll), so a test can break the drain before any stable observation.
    """

    def __init__(
        self,
        *,
        explode_on_signal: bool = False,
        explode_at_poll: int | None = None,
    ) -> None:
        self.explode_on_signal = explode_on_signal
        self.explode_at_poll = explode_at_poll
        self.signals: list[str] = []
        self.poll_count = 0

    def signal(self, task_id: str) -> None:
        if self.explode_on_signal:
            raise RuntimeError("signal adapter exploded")
        self.signals.append(task_id)

    def poll(self, task_id: str, now: datetime) -> DrainStatus:
        if self.explode_at_poll is not None and self.poll_count >= self.explode_at_poll:
            raise RuntimeError("poll adapter exploded")
        self.poll_count += 1
        return DrainStatus.STABLE


def _make_store(tmp_path, *, state: LifecycleState = LifecycleState.BUILDING) -> RunStore:
    store = RunStore(tmp_path / "run.db")
    store.create_run(
        RunRecord(
            run_id="RUN-001",
            title="pause drain demo",
            created_at=T0,
            state=state,
        )
    )
    return store


def _make_coordinator(
    store: RunStore,
    contract: BuildContract,
    drain: _ScriptedDrain,
    *,
    probe: _Probe | None = None,
    clocks: dict[str, TaskTimeBudget] | None = None,
    leases: LeaseLedger | None = None,
    freezer: _Freezer | None = None,
    task_providers: dict[str, tuple[str, ...]] | None = None,
) -> PauseCoordinator:
    """A fully wired pause coordinator for the fixture run/tasks."""
    return PauseCoordinator(
        run_id="RUN-001",
        store=store,
        leases=leases if leases is not None else LeaseLedger(),
        budget=BudgetLedger(Decimal("10.00")),
        rate=RateCapacityLedger({"api": 2}),
        clocks=clocks if clocks is not None else {"T1": TaskTimeBudget("T1", TIME_BUDGET)},
        contract=contract,
        drain=drain,
        probe=probe if probe is not None else _Probe(),
        resources=freezer,
        task_providers=task_providers or {"T1": ("provider-a",)},
        poll_interval=DRAIN_INTERVAL,
    )


def _start_running(
    coordinator: PauseCoordinator,
    *,
    task_id: str = "T1",
    started_at: datetime = T0,
    budget_amount: Decimal = Decimal("3.00"),
    rate_demand: RateDemand = RateDemand("api"),
) -> None:
    """Drive one task into a reserved, leased, clock-running attempt."""
    coordinator.budget.reserve(task_id, budget_amount)
    coordinator.rate.reserve(task_id, rate_demand)
    coordinator.leases.claim("RUN-001", task_id, now=started_at)
    coordinator.clocks[task_id].start(started_at)


# ---------------------------------------------------------------------------
# Prescribed scenario: hung worker fenced / clock frozen / reservation
# retained -- plus the stop-new-dispatch and persist-checkpoint discipline.
# ---------------------------------------------------------------------------


def test_pause_hung_worker_fenced_clock_frozen_reservation_retained(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.UNRESPONSIVE)
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    _start_running(coordinator, started_at=T0)
    lease = coordinator.leases.current_lease("T1")

    outcome = coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    # Every running worker is signalled (a cooperative pause, not a kill).
    assert drain.signals == ["T1"]
    # The pause drains to the deadline and fences the hung worker.
    assert outcome.fenced == ("T1",)
    assert outcome.released == ()
    task = outcome.checkpoint.tasks[0]
    assert task.drained is False
    assert task.hung is True
    assert task.boundary_waited is False
    assert task.fenced is True
    # The time budget is frozen: the deadline stretch is consumed, then stopped.
    assert task.elapsed_seconds == 10.0
    assert task.time_remaining == 590.0
    assert coordinator.clocks["T1"].frozen
    # The resume reservation is RETAINED by default (no release on pause).
    assert task.reservation_retained is True
    assert coordinator.budget.reservations == {"T1": Decimal("3.00")}
    assert coordinator.rate.reservations == {"T1": RateDemand("api")}
    assert coordinator.budget.reserved == Decimal("3.00")
    # The lease is fenced: the hung attempt can never report again.
    assert not coordinator.leases.lease_is_live(lease.lease_id, "RUN-001", now=PAUSE_AT)
    assert coordinator.leases.lease_status(lease.lease_id) is LeaseStatus.FENCED
    # New dispatch is stopped by the durable PAUSED transition (first event),
    # and the paused checkpoint is persisted => PAUSED.
    assert store.load_run("RUN-001").state is LifecycleState.PAUSED
    events = store.list_events("RUN-001")
    assert [event.kind for event in events] == [
        "run.created",
        "state.transition",
        "run.paused",
    ]
    assert events[1].payload["to"] == "PAUSED"
    assert events[1].payload["from"] == "BUILDING"
    # The checkpoint is reloadable from durable run state (spec 22).
    checkpoint = coordinator.checkpoint()
    assert checkpoint is not None
    assert checkpoint.run_id == "RUN-001"
    assert checkpoint.contract_hash == coordinator.contract.contract_hash
    assert checkpoint.tasks == outcome.checkpoint.tasks
    assert checkpoint.paused_at == PAUSE_AT


def test_pause_signals_every_running_task_and_leaves_untouched_tasks_alone(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.STABLE)
    coordinator = _make_coordinator(
        store,
        _locked_contract(),
        drain,
        clocks={
            "T1": TaskTimeBudget("T1", TIME_BUDGET),
            "T2": TaskTimeBudget("T2", TIME_BUDGET),
        },
        task_providers={"T1": ("provider-a",), "T2": ("provider-a",)},
    )
    _start_running(coordinator, task_id="T1", started_at=T0)
    _start_running(coordinator, task_id="T2", started_at=T0)
    # A pending task has no lease: it is never signalled or checkpointed.
    coordinator.budget.reserve("T3", Decimal("3.00"))

    outcome = coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    assert drain.signals == ["T1", "T2"]
    assert [task.task_id for task in outcome.checkpoint.tasks] == ["T1", "T2"]
    assert outcome.fenced == ("T1", "T2")
    assert coordinator.budget.reservations == {
        "T1": Decimal("3.00"),
        "T2": Decimal("3.00"),
        "T3": Decimal("3.00"),
    }


# ---------------------------------------------------------------------------
# Prescribed scenario: a noninterruptible operation runs to its stable
# boundary -- never fenced while it runs; fenced at the deadline otherwise.
# ---------------------------------------------------------------------------


def test_pause_noninterruptible_rollback_runs_to_stable_boundary(tmp_path):
    store = _make_store(tmp_path, state=LifecycleState.ROLLING_BACK)
    drain = _ScriptedDrain(
        script={
            "T1": [
                DrainStatus.NONINTERRUPTIBLE_IN_PROGRESS,
                DrainStatus.NONINTERRUPTIBLE_IN_PROGRESS,
                DrainStatus.STABLE,
            ]
        }
    )
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    _start_running(coordinator, started_at=T0)
    lease = coordinator.leases.current_lease("T1")

    outcome = coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    # The drain polled the running rollback until it reached its boundary.
    assert drain.polls["T1"] == [
        (PAUSE_AT, DrainStatus.NONINTERRUPTIBLE_IN_PROGRESS),
        (PAUSE_AT + timedelta(seconds=5), DrainStatus.NONINTERRUPTIBLE_IN_PROGRESS),
        (PAUSE_AT + timedelta(seconds=10), DrainStatus.STABLE),
    ]
    task = outcome.checkpoint.tasks[0]
    assert task.boundary_waited is True
    assert task.drained is True
    assert task.hung is False
    # The lease is fenced only AFTER the stable boundary (the attempt is
    # closed at the boundary, never mid-operation).
    assert coordinator.leases.lease_status(lease.lease_id) is LeaseStatus.FENCED
    assert task.elapsed_seconds == 10.0
    assert task.time_remaining == 590.0
    assert task.reservation_retained is True
    assert coordinator.budget.reservations == {"T1": Decimal("3.00")}
    assert outcome.fenced == ("T1",)
    # The pause is legal from ROLLING_BACK (state machine allows it) and is
    # durable before the checkpoint is persisted.
    assert store.load_run("RUN-001").state is LifecycleState.PAUSED
    events = store.list_events("RUN-001")
    assert events[1].payload["from"] == "ROLLING_BACK"
    assert events[1].payload["to"] == "PAUSED"
    assert events[2].kind == "run.paused"


def test_pause_fences_when_noninterruptible_operation_never_reaches_boundary(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(
        script={
            "T1": [DrainStatus.NONINTERRUPTIBLE_IN_PROGRESS] * 3
        }
    )
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    _start_running(coordinator, started_at=T0)

    outcome = coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    task = outcome.checkpoint.tasks[0]
    assert task.boundary_waited is True
    assert task.drained is False
    assert task.hung is True
    assert task.reservation_retained is True
    assert coordinator.budget.reservations == {"T1": Decimal("3.00")}


def test_pause_mixed_drain_outcomes_are_recorded_per_task(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(
        script={
            "T1": [DrainStatus.STABLE],
            "T2": [
                DrainStatus.NONINTERRUPTIBLE_IN_PROGRESS,
                DrainStatus.NONINTERRUPTIBLE_IN_PROGRESS,
                DrainStatus.STABLE,
            ],
        },
        default=DrainStatus.UNRESPONSIVE,
    )
    coordinator = _make_coordinator(
        store,
        _locked_contract(),
        drain,
        clocks={
            "T1": TaskTimeBudget("T1", TIME_BUDGET),
            "T2": TaskTimeBudget("T2", TIME_BUDGET),
        },
        task_providers={"T1": ("provider-a",), "T2": ("provider-a",)},
    )
    _start_running(coordinator, task_id="T1", started_at=T0)
    _start_running(coordinator, task_id="T2", started_at=T0)

    outcome = coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    states = {task.task_id: task for task in outcome.checkpoint.tasks}
    assert states["T1"].drained is True
    assert states["T1"].elapsed_seconds == 0.0
    assert states["T2"].drained is True
    assert states["T2"].boundary_waited is True
    assert states["T2"].elapsed_seconds == 10.0
    # A different poll schedule per task: the worker that checked out first
    # is frozen at its boundary, not at the deadline.
    assert coordinator.clocks["T1"].remaining(PAUSE_AT) == TIME_BUDGET
    assert coordinator.clocks["T2"].remaining(PAUSE_AT) == TIME_BUDGET - 10


# ---------------------------------------------------------------------------
# Reservation retention is the default; a time-budget exhaustion is the only
# exception (the task is terminal, so its retained booking must not leak).
# ---------------------------------------------------------------------------


def test_pause_exhausted_time_budget_releases_terminal_retained_booking(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.UNRESPONSIVE)
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    # The clock was already running 595 s before the pause; with a 10 s drain
    # the attempt consumes 605 s of a 600 s budget: it is terminal.
    _start_running(
        coordinator,
        started_at=T0 - timedelta(seconds=595),
        budget_amount=Decimal("3.00"),
    )

    outcome = coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    task = outcome.checkpoint.tasks[0]
    assert task.terminal is True
    assert task.reservation_retained is False
    assert outcome.released == ("T1",)
    assert coordinator.budget.reservations == {}
    assert coordinator.rate.reservations == {}
    assert coordinator.budget.reserved == Decimal("0.00")


# ---------------------------------------------------------------------------
# Reversible resource freeze: optional, and only when the contract allows.
# ---------------------------------------------------------------------------


def test_contract_allows_reversible_freeze_only_for_reversible_operations():
    contract = _contract(
        destructive_policy=[
            DestructiveOperationRule(
                operation="suspend-staging",
                classification=DestructiveAction.REVERSIBLE_AUTONOMOUS,
            ),
            DestructiveOperationRule(
                operation="table-drop",
                classification=DestructiveAction.REVERSIBLE_WITH_ROLLBACK_REQUIRED,
                rollback_path="restore-from-snapshot",
            ),
            DestructiveOperationRule(
                operation="delete-production",
                classification=DestructiveAction.IRREVERSIBLE_NOT_AUTHORIZED,
            ),
        ]
    )
    assert contract_allows_reversible_freeze(contract, ["suspend-staging"])
    assert contract_allows_reversible_freeze(contract, ["table-drop"])
    assert not contract_allows_reversible_freeze(contract, ["delete-production"])
    assert not contract_allows_reversible_freeze(
        contract, ["suspend-staging", "delete-production"]
    )
    assert not contract_allows_reversible_freeze(contract, [])


def test_pause_freezes_reversible_resources_only_when_authorized(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.STABLE)
    freezer = _Freezer(authorized={"T1": True})
    coordinator = _make_coordinator(
        store, _locked_contract(), drain, freezer=freezer
    )
    _start_running(coordinator, started_at=T0)

    outcome = coordinator.pause(
        now=PAUSE_AT,
        drain_timeout=DRAIN_TIMEOUT,
        freeze_reversible_resources=True,
    )

    assert freezer.frozen == [("T1", ("T1-resource",))]
    assert outcome.checkpoint.tasks[0].resources_frozen == ["T1-resource"]


def test_pause_skips_freezing_when_contract_does_not_authorize(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.STABLE)
    freezer = _Freezer(authorized={"T1": False})
    coordinator = _make_coordinator(
        store, _locked_contract(), drain, freezer=freezer
    )
    _start_running(coordinator, started_at=T0)

    outcome = coordinator.pause(
        now=PAUSE_AT,
        drain_timeout=DRAIN_TIMEOUT,
        freeze_reversible_resources=True,
    )

    assert freezer.frozen == []
    assert outcome.checkpoint.tasks[0].resources_frozen == []


def test_pause_requesting_freeze_without_a_freezer_fails_closed(tmp_path):
    store = _make_store(tmp_path)
    coordinator = _make_coordinator(store, _locked_contract(), _ScriptedDrain())
    _start_running(coordinator, started_at=T0)
    with pytest.raises(PauseError, match="freeze_reversible_resources"):
        coordinator.pause(
            now=PAUSE_AT,
            drain_timeout=DRAIN_TIMEOUT,
            freeze_reversible_resources=True,
        )


def test_contract_resource_freezer_honours_tier1_destructive_policy():
    contract = _contract(
        destructive_policy=[
            DestructiveOperationRule(
                operation="suspend-staging",
                classification=DestructiveAction.REVERSIBLE_AUTONOMOUS,
            ),
            DestructiveOperationRule(
                operation="delete-staging",
                classification=DestructiveAction.IRREVERSIBLE_NOT_AUTHORIZED,
            ),
        ]
    )
    freezer = ContractResourceFreezer(
        contract, {"T1": ("suspend-staging",), "T2": ("delete-staging",)}
    )
    assert freezer.freeze_authorized("T1")
    assert freezer.freeze("T1") == ("suspend-staging",)
    assert not freezer.freeze_authorized("T2")


# ---------------------------------------------------------------------------
# Pause is only legal from dispatchable/authorized-recovery states.
# ---------------------------------------------------------------------------


def test_pause_requires_dispatchable_state(tmp_path):
    store = _make_store(tmp_path, state=LifecycleState.DEPLOYED)
    coordinator = _make_coordinator(store, _locked_contract(), _ScriptedDrain())
    with pytest.raises(NotPausable):
        coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)


def test_negative_drain_timeout_rejected(tmp_path):
    store = _make_store(tmp_path)
    coordinator = _make_coordinator(store, _locked_contract(), _ScriptedDrain())
    _start_running(coordinator, started_at=T0)
    with pytest.raises(ValueError):
        coordinator.pause(
            now=PAUSE_AT, drain_timeout=timedelta(seconds=0)
        )


# ---------------------------------------------------------------------------
# Prescribed scenario: resume revalidates / mints a fresh lease / unfreezes.
# ---------------------------------------------------------------------------


def test_resume_revalidates_mints_fresh_lease_and_unfreezes(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.UNRESPONSIVE)
    probe = _Probe(provider_available=True, markers_ok=True)
    coordinator = _make_coordinator(
        store, _locked_contract(), drain, probe=probe
    )
    _start_running(coordinator, started_at=T0)
    coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)
    assert coordinator.leases.current_generation("T1") == 1

    resume_at = PAUSE_AT + timedelta(hours=1)
    outcome = coordinator.resume(now=resume_at)

    # Light revalidation: all four checks ran and passed (no full discovery).
    assert outcome.revalidation.ok is True
    assert [f.check for f in outcome.revalidation.findings] == [
        RevalidationCheck.TIER1_HASH,
        RevalidationCheck.CREDENTIAL_FRESHNESS,
        RevalidationCheck.PROVIDER_AVAILABILITY,
        RevalidationCheck.TARGET_MARKERS,
    ]
    assert all(f.ok for f in outcome.revalidation.findings)
    assert probe.availability_calls == [("provider-a", resume_at)]
    assert probe.marker_calls == [("T1", resume_at)]
    # A fresh lease generation is minted (one lease per attempt).
    assert outcome.fresh_leases[0].lease_id == "LEASE-RUN-001-T1-2"
    assert outcome.fresh_leases[0].generation == 2
    assert coordinator.leases.current_generation("T1") == 2
    assert coordinator.leases.lease_is_live(
        "LEASE-RUN-001-T1-2", "RUN-001", now=resume_at
    )
    # The time budget is unfrozen and CONTINUES the same clock: 600 - 10 s
    # consumed at pause, 60 s more at the assertion instant.
    clock = coordinator.clocks["T1"]
    assert not clock.frozen
    assert clock.started_at == resume_at
    assert clock.remaining(resume_at + timedelta(seconds=60)) == 530.0
    # The retained reservation was rebalanced (kept exactly once) -- no double
    # reserve, no release.
    assert outcome.released == ()
    assert outcome.resumed == ("T1",)
    assert coordinator.budget.reservations == {"T1": Decimal("3.00")}
    assert coordinator.rate.reservations == {"T1": RateDemand("api")}
    # Dispatch is enabled: PAUSED -> RESUMING -> BUILDING, and the resume
    # event is persisted.
    assert store.load_run("RUN-001").state is LifecycleState.BUILDING
    events = store.list_events("RUN-001")
    transitions = [
        (event.payload["from"], event.payload["to"])
        for event in events
        if event.kind == "state.transition"
    ]
    assert transitions[-2:] == [("PAUSED", "RESUMING"), ("RESUMING", "BUILDING")]
    resume_event = [event for event in events if event.kind == "run.resumed"][-1]
    assert resume_event.payload["resumed_tasks"] == ["T1"]
    assert resume_event.payload["fresh_leases"] == ["LEASE-RUN-001-T1-2"]
    assert resume_event.payload["revalidation_ok"] is True


def test_resume_unfreezes_resources_frozen_at_pause(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.STABLE)
    freezer = _Freezer(authorized={"T1": True})
    coordinator = _make_coordinator(
        store, _locked_contract(), drain, freezer=freezer
    )
    _start_running(coordinator, started_at=T0)
    coordinator.pause(
        now=PAUSE_AT,
        drain_timeout=DRAIN_TIMEOUT,
        freeze_reversible_resources=True,
    )
    assert freezer.unfrozen == []

    coordinator.resume(now=PAUSE_AT + timedelta(hours=1))

    assert freezer.unfrozen == ["T1"]
    assert store.load_run("RUN-001").state is LifecycleState.BUILDING


def test_resume_rejected_when_resuming_without_a_paused_checkpoint(tmp_path):
    # The run is PAUSED (dispatch is stopped) but no checkpoint was ever
    # persisted: resuming without durable pause state is impossible (spec 22).
    store = _make_store(tmp_path, state=LifecycleState.PAUSED)
    coordinator = _make_coordinator(store, _locked_contract(), _ScriptedDrain())
    with pytest.raises(PauseCheckpointMissing):
        coordinator.resume(now=PAUSE_AT)


def test_resume_requires_paused_state(tmp_path):
    store = _make_store(tmp_path)
    coordinator = _make_coordinator(store, _locked_contract(), _ScriptedDrain())
    with pytest.raises(NotPaused):
        coordinator.resume(now=PAUSE_AT)


# ---------------------------------------------------------------------------
# Resume is fail-closed when light revalidation fails: no lease, no clock,
# no dispatch -- the run stays PAUSED with the batched findings persisted.
# ---------------------------------------------------------------------------


def test_resume_rejected_on_stale_credentials_leaves_run_paused(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.UNRESPONSIVE)
    # Evidence was fresh at lock (age 0) but is stale by resume time.
    contract = _locked_contract()
    coordinator = _make_coordinator(store, contract, drain)
    _start_running(coordinator, started_at=T0)
    coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    resume_at = PAUSE_AT + timedelta(hours=30)  # age 31 h > 4 h TTL
    with pytest.raises(ResumeRevalidationError) as excinfo:
        coordinator.resume(now=resume_at)

    revalidation = excinfo.value.revalidation
    assert revalidation.ok is False
    by_check = {f.check: f for f in revalidation.findings}
    assert by_check[RevalidationCheck.CREDENTIAL_FRESHNESS].ok is False
    assert by_check[RevalidationCheck.TIER1_HASH].ok is True
    # Fail closed: still PAUSED, no fresh lease, clock still frozen.
    assert store.load_run("RUN-001").state is LifecycleState.PAUSED
    assert coordinator.leases.current_generation("T1") == 1
    assert coordinator.clocks["T1"].frozen
    # The batched findings are persisted (spec 18.1-style consolidated view).
    events = store.list_events("RUN-001")
    rejected = [event for event in events if event.kind == "run.resume_rejected"][-1]
    assert rejected.payload["revalidation_ok"] is False
    assert rejected.payload["findings"] == [
        {
            "check": "tier1_hash",
            "ok": True,
            "detail": by_check[RevalidationCheck.TIER1_HASH].detail,
        },
        {
            "check": "credential_freshness",
            "ok": False,
            "detail": by_check[RevalidationCheck.CREDENTIAL_FRESHNESS].detail,
        },
        {
            "check": "provider_availability",
            "ok": True,
            "detail": by_check[RevalidationCheck.PROVIDER_AVAILABILITY].detail,
        },
        {
            "check": "target_markers",
            "ok": True,
            "detail": by_check[RevalidationCheck.TARGET_MARKERS].detail,
        },
    ]


def test_resume_rejected_when_provider_unavailable(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.UNRESPONSIVE)
    coordinator = _make_coordinator(
        store,
        _locked_contract(),
        drain,
        probe=_Probe(provider_available=False, markers_ok=True),
    )
    _start_running(coordinator, started_at=T0)
    coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    with pytest.raises(ResumeRevalidationError) as excinfo:
        coordinator.resume(now=PAUSE_AT + timedelta(hours=1))

    by_check = {f.check: f for f in excinfo.value.revalidation.findings}
    assert by_check[RevalidationCheck.PROVIDER_AVAILABILITY].ok is False
    assert by_check[RevalidationCheck.TARGET_MARKERS].ok is True
    assert store.load_run("RUN-001").state is LifecycleState.PAUSED


def test_resume_rejected_when_target_markers_missing(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.UNRESPONSIVE)
    coordinator = _make_coordinator(
        store,
        _locked_contract(),
        drain,
        probe=_Probe(provider_available=True, markers_ok=False),
    )
    _start_running(coordinator, started_at=T0)
    coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    with pytest.raises(ResumeRevalidationError) as excinfo:
        coordinator.resume(now=PAUSE_AT + timedelta(hours=1))

    by_check = {f.check: f for f in excinfo.value.revalidation.findings}
    assert by_check[RevalidationCheck.TARGET_MARKERS].ok is False
    assert by_check[RevalidationCheck.PROVIDER_AVAILABILITY].ok is True


def test_resume_rejected_on_tier1_hash_drift(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.UNRESPONSIVE)
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    _start_running(coordinator, started_at=T0)
    coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    # The controller rebuilds with a DIFFERENT locked contract: the check is
    # against the hash stored in the paused checkpoint -- the pause-time
    # Tier-1 lock must still be the one being resumed.
    drifted = _make_coordinator(
        store,
        _locked_contract(product_scope="different locked scope"),
        drain,
    )
    with pytest.raises(ResumeRevalidationError) as excinfo:
        drifted.resume(now=PAUSE_AT + timedelta(hours=1))

    by_check = {f.check: f for f in excinfo.value.revalidation.findings}
    assert by_check[RevalidationCheck.TIER1_HASH].ok is False
    assert store.load_run("RUN-001").state is LifecycleState.PAUSED


# ---------------------------------------------------------------------------
# Reservation rebalance: bookings outside the resumed set are released; a
# resumed task whose retained booking was lost is a broken ledger (fail
# closed -- never a silent re-reserve).
# ---------------------------------------------------------------------------


def test_resume_rebalances_reservation_to_the_resumed_set(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.STABLE)
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    _start_running(coordinator, started_at=T0)
    coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)
    # Ledger drift while paused: a stale booking not belonging to the
    # resumed set (the rebalance must reconcile it, never double-reserve).
    coordinator.budget.reserve("T-ORPHAN", Decimal("1.50"))
    coordinator.rate.reserve("T-ORPHAN", RateDemand("api"))

    outcome = coordinator.resume(now=PAUSE_AT + timedelta(hours=1))

    assert outcome.released == ("T-ORPHAN",)
    assert coordinator.budget.reservations == {"T1": Decimal("3.00")}
    assert coordinator.rate.reservations == {"T1": RateDemand("api")}
    # Revalidating the orphan set is impossible by construction, so the
    # rebalance ran before lease minting.
    assert coordinator.leases.current_generation("T-ORPHAN") == 0


def test_resume_fails_closed_when_retained_reservation_was_lost(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.UNRESPONSIVE)
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    _start_running(coordinator, started_at=T0)
    coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)
    # The booking disappeared while paused: resuming must not silently
    # re-reserve (exactly once is a hard invariant).
    coordinator.budget.release("T1")
    coordinator.rate.release("T1")

    with pytest.raises(PauseError, match="retained reservation"):
        coordinator.resume(now=PAUSE_AT + timedelta(hours=1))
    assert store.load_run("RUN-001").state is LifecycleState.PAUSED
    assert coordinator.leases.current_generation("T1") == 1


def test_resume_after_terminal_exhaustion_resumes_nothing_and_rebalances(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.UNRESPONSIVE)
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    _start_running(
        coordinator,
        started_at=T0 - timedelta(seconds=595),
        budget_amount=Decimal("3.00"),
    )
    outcome = coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)
    assert outcome.checkpoint.tasks[0].terminal is True

    resumed = coordinator.resume(now=PAUSE_AT + timedelta(hours=1))

    assert resumed.resumed == ()
    assert resumed.released == ()
    assert resumed.fresh_leases == ()
    assert coordinator.budget.reservations == {}
    assert coordinator.leases.current_generation("T1") == 1
    assert store.load_run("RUN-001").state is LifecycleState.BUILDING


# ---------------------------------------------------------------------------
# The pure light-revalidation function is deterministic and fail-closed
# (a missing observation never passes a check).
# ---------------------------------------------------------------------------


def test_evaluate_light_revalidation_missing_observations_fail_closed():
    contract = _locked_contract()
    revalidation = evaluate_light_revalidation(
        contract,
        task_ids=["T1"],
        task_providers={"T1": ("provider-a",)},
        providers_available={},  # nothing observed => unavailable
        markers_ok={"T1": False},  # marker not at target-state
        locked_hash=contract.contract_hash,
        now=LOCK_AT + timedelta(hours=1),
    )
    assert revalidation.ok is False
    by_check = {f.check: f for f in revalidation.findings}
    assert by_check[RevalidationCheck.PROVIDER_AVAILABILITY].ok is False
    assert by_check[RevalidationCheck.TARGET_MARKERS].ok is False
    # Identical input => identical verdict (determinism).
    assert evaluate_light_revalidation(
        contract,
        task_ids=("T1",),
        task_providers={"T1": ("provider-a",)},
        providers_available={},
        markers_ok={"T1": False},
        locked_hash=contract.contract_hash,
        now=LOCK_AT + timedelta(hours=1),
    ) == revalidation


# ---------------------------------------------------------------------------
# Fix round 1: a resume that aborts INSIDE its guarded mutation phase (e.g.
# mid-lease-mint) must not leak live leases, must persist a durable failure
# event, and must leave the run resumable -- a later resume succeeds instead
# of wedging on the abandoned lease (review Important finding).
# ---------------------------------------------------------------------------


def test_resume_abort_mid_lease_mint_cleans_up_and_later_resume_succeeds(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.STABLE)
    leases = _FlakyLeaseLedger(fail_on="T2")
    leases.failing = False  # setup claims work; the resume mint is flaky
    coordinator = _make_coordinator(
        store,
        _locked_contract(),
        drain,
        leases=leases,
        clocks={
            "T1": TaskTimeBudget("T1", TIME_BUDGET),
            "T2": TaskTimeBudget("T2", TIME_BUDGET),
        },
        task_providers={"T1": ("provider-a",), "T2": ("provider-a",)},
    )
    _start_running(coordinator, task_id="T1", started_at=T0)
    _start_running(coordinator, task_id="T2", started_at=T0)
    coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)
    resume_at = PAUSE_AT + timedelta(hours=1)
    leases.failing = True

    # The SECOND lease mint fails: T1's fresh lease is LIVE, then the
    # mutation phase aborts -- the coordinator must roll it back.
    with pytest.raises(pause_module.ResumeMutationError) as excinfo:
        coordinator.resume(now=resume_at)
    assert "LEASE-RUN-001-T1-2" in str(excinfo.value.cleanup["fenced_lease_ids"])

    # No live lease survives the abort (the abandoned T1 lease is fenced),
    # so a later resume does not wedge on a lease conflict.
    assert not coordinator.leases.lease_is_live(
        "LEASE-RUN-001-T1-2", "RUN-001", now=resume_at
    )
    assert (
        coordinator.leases.lease_status("LEASE-RUN-001-T1-2")
        is LeaseStatus.FENCED
    )
    # No clock was left running: the budget stays frozen until resume.
    assert coordinator.clocks["T1"].frozen
    assert coordinator.clocks["T2"].frozen
    # Fail closed: the run is still PAUSED and a durable failure event was
    # persisted (the controller sees the abort, not silence).
    assert store.load_run("RUN-001").state is LifecycleState.PAUSED
    assert "run.resumed" not in [e.kind for e in store.list_events("RUN-001")]
    failed = [e for e in store.list_events("RUN-001") if e.kind == "run.resume_failed"]
    assert len(failed) == 1
    assert failed[0].payload["phase"] == "mutation"
    assert "LeaseConflict" in failed[0].payload["error"]
    assert failed[0].payload["minted_lease_ids"] == ["LEASE-RUN-001-T1-2"]
    assert failed[0].payload["fenced_lease_ids"] == ["LEASE-RUN-001-T1-2"]
    assert failed[0].payload["refrozen_clocks"] == []

    # Once the ledger heals, the SAME paused run resumes cleanly: fresh
    # generations (T1 gen 3 -- the abandoned gen 2 is fenced, never reused),
    # no reservation re-reserve, and BUILDING.
    leases.failing = False
    outcome = coordinator.resume(now=resume_at)
    assert outcome.resumed == ("T1", "T2")
    assert outcome.fresh_leases[0].lease_id == "LEASE-RUN-001-T1-3"
    assert outcome.fresh_leases[1].lease_id == "LEASE-RUN-001-T2-2"
    assert store.load_run("RUN-001").state is LifecycleState.BUILDING
    assert coordinator.budget.reservations == {
        "T1": Decimal("3.00"),
        "T2": Decimal("3.00"),
    }


# ---------------------------------------------------------------------------
# Fix round 1: an adapter failure DURING the drain must not strand the run
# PAUSED without a persisted checkpoint (review minor finding). The pause
# stops dispatch durably first; the unresolved workers are fenced fail-closed
# and the best-effort checkpoint is still persisted.
# ---------------------------------------------------------------------------


def test_pause_drain_adapter_failure_still_persists_checkpoint(tmp_path):
    store = _make_store(tmp_path)
    drain = _ExplodingDrain(explode_at_poll=0)
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    _start_running(coordinator, started_at=T0)
    lease = coordinator.leases.current_lease("T1")

    with pytest.raises(pause_module.PauseDrainAdapterError) as excinfo:
        coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    # The durable PAUSED transition happened FIRST and the best-effort
    # checkpoint IS persisted: never PAUSED without durable pause state.
    assert store.load_run("RUN-001").state is LifecycleState.PAUSED
    checkpoint = excinfo.value.checkpoint
    assert checkpoint is not None
    assert coordinator.checkpoint() == checkpoint
    task = checkpoint.tasks[0]
    assert task.hung is True  # unobserved => fenced fail-closed
    assert task.fenced is True
    assert task.reservation_retained is True
    assert coordinator.leases.lease_status(lease.lease_id) is LeaseStatus.FENCED
    assert coordinator.clocks["T1"].frozen

    # Healed drain: the paused run resumes (not stuck Paused-without-resume).
    resumed = PauseCoordinator(
        run_id="RUN-001",
        store=store,
        leases=coordinator.leases,
        budget=coordinator.budget,
        rate=coordinator.rate,
        clocks=coordinator.clocks,
        contract=coordinator.contract,
        drain=_ScriptedDrain(default=DrainStatus.STABLE),
        probe=_Probe(),
        resources=None,
        task_providers={"T1": ("provider-a",)},
        poll_interval=DRAIN_INTERVAL,
    ).resume(now=PAUSE_AT + timedelta(hours=1))
    assert resumed.resumed == ("T1",)
    assert store.load_run("RUN-001").state is LifecycleState.BUILDING


def test_pause_signal_adapter_failure_still_persists_checkpoint(tmp_path):
    store = _make_store(tmp_path)
    drain = _ExplodingDrain(explode_on_signal=True)
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    _start_running(coordinator, started_at=T0)

    with pytest.raises(pause_module.PauseDrainAdapterError):
        coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    assert store.load_run("RUN-001").state is LifecycleState.PAUSED
    assert coordinator.checkpoint() is not None
    assert coordinator.checkpoint().tasks[0].hung is True


# ---------------------------------------------------------------------------
# Fix round 1: the pause checkpoint PINS the reservation universe (including
# reserved-but-not-running bookings) so the resume rebalance reconciles a
# deterministic set instead of silently releasing an unpinned booking
# (review minor finding).
# ---------------------------------------------------------------------------


def test_pause_checkpoint_pins_reservation_universe_for_resume_rebalance(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.STABLE)
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    _start_running(coordinator, started_at=T0)
    # Reserved but NOT running at pause: the booking is retained by default
    # and the checkpoint must pin it for the resume rebalance.
    coordinator.budget.reserve("T2", Decimal("2.00"))
    coordinator.rate.reserve("T2", RateDemand("api"))

    outcome = coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)

    assert outcome.checkpoint.reserved_task_ids == ["T1", "T2"]
    # The retained bookings are pinned per ledger (amount + demand), and
    # the pins survive a reload from durable run state (spec 22).
    task = outcome.checkpoint.tasks[0]
    assert task.reserved_money == "3.00"
    assert task.reserved_rate.provider_key == "api"
    assert task.reserved_rate.units == 1
    reloaded = coordinator.checkpoint()
    assert reloaded.reserved_task_ids == ["T1", "T2"]
    assert reloaded.tasks[0].reserved_money == "3.00"
    assert reloaded.tasks[0].reserved_rate.provider_key == "api"
    # A booking that appeared while paused (ledger drift) is reconciled too.
    coordinator.budget.reserve("T-ORPHAN", Decimal("1.50"))
    resumed = coordinator.resume(now=PAUSE_AT + timedelta(hours=1))
    assert resumed.released == ("T-ORPHAN", "T2")
    assert coordinator.budget.reservations == {"T1": Decimal("3.00")}
    assert coordinator.rate.reservations == {"T1": RateDemand("api")}


# ---------------------------------------------------------------------------
# Fix round 1: resume validates the RETAINED rate booking too -- a lost rate
# reservation is as broken a ledger as a lost money one (exactly once), and
# must fail closed instead of resuming without capacity (review minor).
# ---------------------------------------------------------------------------


def test_resume_fails_closed_when_rate_booking_was_lost(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.UNRESPONSIVE)
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    _start_running(coordinator, started_at=T0)
    coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)
    # The rate booking disappears while paused (money booking kept).
    coordinator.rate.release("T1")

    with pytest.raises(PauseError, match="rate reservation"):
        coordinator.resume(now=PAUSE_AT + timedelta(hours=1))

    assert store.load_run("RUN-001").state is LifecycleState.PAUSED
    assert coordinator.leases.current_generation("T1") == 1
    assert coordinator.clocks["T1"].frozen


def test_resume_fails_closed_when_money_booking_amount_changed(tmp_path):
    store = _make_store(tmp_path)
    drain = _ScriptedDrain(default=DrainStatus.UNRESPONSIVE)
    coordinator = _make_coordinator(store, _locked_contract(), drain)
    _start_running(coordinator, started_at=T0)
    coordinator.pause(now=PAUSE_AT, drain_timeout=DRAIN_TIMEOUT)
    # The booking was re-created with a DIFFERENT amount while paused: the
    # pin records what the pause retained, so the ledger must match exactly.
    coordinator.budget.release("T1")
    coordinator.budget.reserve("T1", Decimal("7.00"))

    with pytest.raises(PauseError, match="retained reservation"):
        coordinator.resume(now=PAUSE_AT + timedelta(hours=1))

    assert store.load_run("RUN-001").state is LifecycleState.PAUSED


# ---------------------------------------------------------------------------
# Fix round 1: the contract-bounded resource freezer is a state machine, not
# a policy stub -- freeze records the frozen resource set, unfreeze restores
# it, and the frozen set is observable (review minor finding).
# ---------------------------------------------------------------------------


def test_contract_resource_freezer_tracks_frozen_state():
    contract = _contract(
        destructive_policy=[
            DestructiveOperationRule(
                operation="suspend-staging",
                classification=DestructiveAction.REVERSIBLE_AUTONOMOUS,
            ),
        ]
    )
    freezer = ContractResourceFreezer(contract, {"T1": ("suspend-staging",)})
    assert not freezer.is_frozen("T1")
    assert freezer.frozen_resources("T1") == ()

    assert freezer.freeze("T1") == ("suspend-staging",)
    assert freezer.is_frozen("T1")
    assert freezer.frozen_resources("T1") == ("suspend-staging",)

    freezer.unfreeze("T1")
    assert not freezer.is_frozen("T1")
    assert freezer.frozen_resources("T1") == ()
