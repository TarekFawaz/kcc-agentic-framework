"""Behavioral contract for the integrated scheduler pipeline controller.

Owned by ``test_controller.py`` (see the KCC x Superpowers Hybrid Framework
Plan 04, Task 7: Integrate scheduler pipeline, in
``.superpowers/bootstrap/plans/2026-08-27-04-scheduler-budget-rate-policy.task-contracts.md``).

The controller (:class:`~kcc_autobuild.controller.AutobuildController`) is
the single orchestration point of the pipeline: it injects the store /
scheduler / leases / bridge / budget / rate / policy components, ticks the
run, and owns the reservation semantics of the plan Global Constraints
(the controller reserves money/rate for the selected wave set exactly once
-- the scheduler only simulates, so there is *no double reserve* -- and
stale leases release their reservations and freeze the task time budget).

Behaviors under contract:

* **tick snapshots** the run state first, then sweeps stale (expired /
  fenced) leases: releases their money + rate reservations, freezes the
  task time budget (consuming the elapsed time) and emits an event;
* the scheduler decides the next wave; the controller reserves ONLY the
  selected set, claims a fresh lease (next generation), unfreezes the time
  budget, builds the bounded handoff bound to the freshly claimed lease and
  emits a DISPATCH event -- no double reserve, ever;
* a verified report advances the run: the task is PASSED (or FAILED /
  BLOCKED), its lease is fenced, provider rate is released, and when the
  wave completes its money reservations settle (reconcile) and a
  deterministic wave-gate deviation review samples the wave evidence;
* PAUSED keeps a separate path that retains the reservation (no release on
  pause): leases are fenced and time budgets are frozen, but money/rate
  bookings stay held; resume re-dispatches the retained set without
  double-reserving;
* the wave-gate deviation review is deterministic: 100% of declared
  deviations plus all production/destructive operations are always
  reviewed, at least 20% of the remaining evidence is sampled, and a
  nonempty wave always yields at least one reviewed item.

Prescribed scenarios under test: dispatch/advance; an expired lease
releases its reservations and freezes the time budget; deviation sampling.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest

from kcc_autobuild.bridge import (
    AcceptanceEvidence,
    AttemptBudget,
    ExecutionBridge,
    ExecutionReport,
    ExecutionStatus,
    FailureInfo,
    OutputInfo,
    UsageInfo,
)
from kcc_autobuild.budget import BudgetLedger
from kcc_autobuild.controller import (
    AutobuildController,
    NotBuilding,
    ReportMismatch,
    StaleLeaseReport,
    TaskPlan,
    TaskTimeBudget,
    UnknownTask,
    UnverifiedReport,
    WaveEvidenceItem,
    WaveGateReview,
)
from kcc_autobuild.evidence import EvidenceVerifier, ReportAcceptance
from kcc_autobuild.leases import Lease, LeaseLedger, LeaseStatus
from kcc_autobuild.models import FailureClass, LifecycleState, RunRecord
from kcc_autobuild.policy import (
    Operation,
    PolicyDecision,
    PolicyEvaluator,
    PolicyRule,
    sign_policy_bundle,
)
from kcc_autobuild.rate_limit import RateCapacityLedger, RateDemand
from kcc_autobuild.scheduler import Scheduler
from kcc_autobuild.store import RunStore
from kcc_autobuild.tool_gate import PolicyToolGate
from kcc_autobuild.trace import TraceEdge, TraceGraph, TraceNode

T0 = datetime(2026, 8, 28, 12, 0, 0, tzinfo=timezone.utc)
"""Fixed deterministic instant so tick/lease timing assertions are exact."""

POLICY_HASH = "a" * 64
"""Canonical 64-hex policy bundle anchor for handoffs without a contract."""

POLICY_SECRET = "controller-test-secret"
"""HMAC key for the signed destructive-action policy bundle."""


def _trace() -> TraceGraph:
    """One requirement cluster per task (T1/T2/T3), each with AC and Test."""
    nodes: list[TraceNode] = []
    edges: list[TraceEdge] = []
    for i in (1, 2, 3):
        nodes += [
            TraceNode(id=f"REQ-00{i}", kind="requirement"),
            TraceNode(id=f"IMPL-00{i}", kind="implementation"),
            TraceNode(id=f"AC-00{i}", kind="acceptance"),
            TraceNode(id=f"T-00{i}", kind="test"),
        ]
        edges += [
            TraceEdge(source=f"REQ-00{i}", target=f"IMPL-00{i}"),
            TraceEdge(source=f"IMPL-00{i}", target=f"AC-00{i}"),
            TraceEdge(source=f"IMPL-00{i}", target=f"T-00{i}"),
        ]
    return TraceGraph(run_id="RUN-001", nodes=nodes, edges=edges)


def _attempt_budget() -> AttemptBudget:
    return AttemptBudget(
        max_attempts=3,
        time_budget_minutes=240,
        token_budget=250_000,
        cost_budget_minor=5_000,
        escalation_tier=1,
    )


def _plans() -> dict[str, TaskPlan]:
    """T1/T3 are independent; T2 depends on T1 (dependency-closed waves)."""
    return {
        "T1": TaskPlan(
            id="T1",
            budget_ceiling=Decimal("3.00"),
            requirement_ids=("REQ-001",),
            acceptance_ids=("AC-001",),
            test_ids=("T-001",),
            attempt_budget=_attempt_budget(),
            time_budget_seconds=600,
            rate_demands=(RateDemand("api"),),
            trace=_trace(),
            policy_bundle_hash=POLICY_HASH,
        ),
        "T2": TaskPlan(
            id="T2",
            budget_ceiling=Decimal("3.00"),
            requirement_ids=("REQ-002",),
            acceptance_ids=("AC-002",),
            test_ids=("T-002",),
            attempt_budget=_attempt_budget(),
            time_budget_seconds=600,
            depends_on=("T1",),
            rate_demands=(RateDemand("api"),),
            trace=_trace(),
            policy_bundle_hash=POLICY_HASH,
        ),
        "T3": TaskPlan(
            id="T3",
            budget_ceiling=Decimal("3.00"),
            requirement_ids=("REQ-003",),
            acceptance_ids=("AC-003",),
            test_ids=("T-003",),
            attempt_budget=_attempt_budget(),
            time_budget_seconds=600,
            rate_demands=(RateDemand("api"),),
            trace=_trace(),
            policy_bundle_hash=POLICY_HASH,
        ),
    }


def _policy_gate() -> PolicyToolGate:
    bundle = sign_policy_bundle(
        (
            PolicyRule(
                operation="deploy",
                resource="prod/analysis",
                data_class="public",
                decision=PolicyDecision.ALLOWED,
            ),
        ),
        POLICY_SECRET,
    )
    evaluator = PolicyEvaluator(bundle, POLICY_SECRET)
    return PolicyToolGate(
        evaluator, executor=lambda operation, token: f"executed:{token}"
    )


def _make_store(tmp_path) -> RunStore:
    store = RunStore(tmp_path / "run.db")
    store.create_run(
        RunRecord(
            run_id="RUN-001",
            title="scheduler pipeline demo",
            created_at=T0,
            state=LifecycleState.BUILDING,
        )
    )
    return store


class _LeaseCheck:
    """Adapter so the controller's lease source satisfies the verifier."""

    def __init__(self, leases: LeaseLedger, clock: list) -> None:
        self._leases = leases
        self._clock = clock

    def lease_is_live(self, lease_id: str, run_id: str) -> bool:
        return self._leases.lease_is_live(lease_id, run_id, now=self._clock[0])


class _AlwaysTrueVerifier:
    def commit_exists(self, commit_id: str) -> bool:
        return True

    def ci_run_passed(self, ci_run_ref: str) -> bool:
        return True

    def usage_reconciles(self, usage: UsageInfo) -> bool:
        return True


def _make_controller(
    store: RunStore,
    *,
    tasks: dict[str, TaskPlan] | None = None,
    leases: LeaseLedger | None = None,
    lease_ttl: timedelta | None = None,
    verifier: EvidenceVerifier | None = None,
) -> AutobuildController:
    """Build a fully wired controller for the prescribed pipeline fixtures.

    Without an injected verifier, reports must be handed an explicit
    acceptance (fail-closed: claims are never trusted implicitly).
    """
    return AutobuildController(
        run_id="RUN-001",
        store=store,
        scheduler=Scheduler(),
        leases=leases if leases is not None else LeaseLedger(lease_ttl=lease_ttl),
        bridge=ExecutionBridge(),
        budget=BudgetLedger(Decimal("10.00")),
        rate=RateCapacityLedger({"api": 2}),
        policy=_policy_gate(),
        tasks=_plans() if tasks is None else tasks,
        verifier=verifier,
    )


def _verifier_for_clock(leases: LeaseLedger, clock: list) -> EvidenceVerifier:
    """Deterministic chain-of-custody verifier on the controller's leases."""
    return EvidenceVerifier(
        lease=_LeaseCheck(leases, clock),
        commits=_AlwaysTrueVerifier(),
        ci=_AlwaysTrueVerifier(),
        usage=_AlwaysTrueVerifier(),
    )


def _accepted() -> ReportAcceptance:
    return ReportAcceptance(
        accepted=True, counts_as_failed_attempt=False, reasons=[]
    )


def _report_for(
    task_id: str,
    lease,
    *,
    status: ExecutionStatus = ExecutionStatus.PASSED,
    outputs: list[OutputInfo] | None = None,
    deviations: list[str] | None = None,
    cost: str = "2.50",
) -> ExecutionReport:
    return ExecutionReport(
        run_id="RUN-001",
        task_id=task_id,
        attempt=lease.generation,
        status=status,
        lease_id=lease.lease_id,
        workspace_id=lease.workspace_id,
        acceptance_evidence=(
            [
                AcceptanceEvidence(
                    acceptance_id=f"AC-00{task_id[-1]}",
                    test_ids=[f"T-00{task_id[-1]}"],
                    evidence_refs=[".KCC/runtime/tests/test_controller.py"],
                )
            ]
            if status is ExecutionStatus.PASSED
            else []
        ),
        failure=(
            None
            if status is ExecutionStatus.PASSED
            else FailureInfo(
                cls=FailureClass.BUG, message="deterministic assertion defect"
            )
        ),
        usage=UsageInfo(cost_usd=float(cost), tokens=100, provider_calls=1),
        outputs=[] if outputs is None else outputs,
        deviations=[] if deviations is None else deviations,
    )


def _stale_lease(task_id: str) -> Lease:
    """A lease id that was never claimed by the controller (stale report)."""
    return Lease(
        lease_id=f"LEASE-RUN-001-{task_id}-99",
        run_id="RUN-001",
        task_id=task_id,
        generation=99,
        workspace_id=f"WS-RUN-001-{task_id}-99",
        issued_at=T0,
    )


def _commit(ref: str) -> OutputInfo:
    return OutputInfo(kind="commit", ref=ref)


# ---------------------------------------------------------------------------
# TaskTimeBudget -- the frozen/running per-task clock
# ---------------------------------------------------------------------------


def test_time_budget_freezes_elapsed_and_resumes_without_losing_remaining():
    clock = TaskTimeBudget("T1", total_seconds=600)
    clock.start(T0)
    assert not clock.frozen
    assert clock.remaining(T0) == 600
    assert clock.remaining(T0 + timedelta(seconds=60)) == 540
    elapsed = clock.freeze(T0 + timedelta(seconds=120))
    assert elapsed == 120.0
    assert clock.frozen
    assert clock.remaining(T0 + timedelta(seconds=999)) == 480  # clock stopped
    clock.start(T0 + timedelta(seconds=300))  # unfreeze continues the budget
    assert not clock.frozen
    assert clock.remaining(T0 + timedelta(seconds=301)) == 479
    assert clock.remaining(T0 + timedelta(seconds=480)) == 300


def test_time_budget_needs_an_aware_positive_budget():
    with pytest.raises(ValueError):
        TaskTimeBudget("T1", 0)
    with pytest.raises(ValueError):
        TaskTimeBudget("T1", -5)
    clock = TaskTimeBudget("T1", 60)
    with pytest.raises(ValueError):
        clock.start(datetime(2026, 8, 28, 12, 0, 0))  # naive


# ---------------------------------------------------------------------------
# Prescribed scenario 1: dispatch / advance
# ---------------------------------------------------------------------------


def test_tick_dispatches_the_dependency_ready_wave_and_reserves_exactly_once(tmp_path):
    store = _make_store(tmp_path)
    controller = _make_controller(store)

    result = controller.tick(T0)
    snapshot = result.snapshot

    # The snapshot is the pre-tick view: nothing in flight yet.
    assert snapshot.run_id == "RUN-001"
    assert snapshot.run_state is LifecycleState.BUILDING
    assert snapshot.open_wave is None
    assert snapshot.pending == ("T1", "T2", "T3")
    assert snapshot.passed == ()
    assert snapshot.money_available == Decimal("10.00")

    # Only the dependency-ready set (T1 + T3) is dispatched; T2 waits for T1.
    assert [handoff.task_id for handoff in result.dispatched] == ["T1", "T3"]
    assert result.dispatched[0].lease.lease_id == "LEASE-RUN-001-T1-1"
    assert result.dispatched[0].lease.generation == 1
    assert result.dispatched[1].lease.lease_id == "LEASE-RUN-001-T3-1"

    # The controller reserves ONLY the selected set, exactly once.
    assert controller.budget.reservations == {
        "T1": Decimal("3.00"),
        "T3": Decimal("3.00"),
    }
    assert sorted(controller.rate.reservations) == ["T1", "T3"]
    assert controller.budget.available == Decimal("4.00")
    assert controller.rate.used("api") == 2

    # Fresh leases were claimed (generation 1) and the time budgets unfrozen.
    assert controller.leases.current_lease("T1").generation == 1
    assert controller.leases.current_lease("T2") is None
    assert controller.leases.lease_is_live(
        "LEASE-RUN-001-T1-1", "RUN-001", now=T0
    )
    assert not controller.time_budget("T1").frozen

    # DISPATCH events carry the machine-readable decision.
    events = store.list_events("RUN-001")
    dispatch = [event for event in events if event.kind == "task.dispatch"]
    assert len(dispatch) == 2
    by_task = {event.payload["task_id"]: event for event in dispatch}
    payload = by_task["T1"].payload
    assert payload["wave_id"] == "wave-1"
    assert payload["lease_id"] == "LEASE-RUN-001-T1-1"
    assert payload["generation"] == 1
    assert payload["workspace_id"] == "WS-RUN-001-T1-1"
    assert payload["money_reserved"] == "3.00"
    assert payload["rate_reserved"] == [{"provider_key": "api", "units": 1}]
    assert payload["handoff_bytes"] > 0

    # A second tick while the wave is in flight dispatches nothing: the
    # reservations stay exactly once (no double reserve).
    second = controller.tick(T0 + timedelta(seconds=1))
    assert second.dispatched == ()
    assert second.snapshot.running == ("T1", "T3")
    assert controller.budget.reservations == {
        "T1": Decimal("3.00"),
        "T3": Decimal("3.00"),
    }
    assert controller.budget.reserved == Decimal("6.00")


def test_verified_report_advances_and_completes_the_wave_with_review(tmp_path):
    store = _make_store(tmp_path)
    clock = [T0]
    leases = LeaseLedger()
    controller = _make_controller(store, leases=leases, verifier=_verifier_for_clock(leases, clock))

    controller.tick(T0)
    lease_t1 = controller.leases.current_lease("T1")
    lease_t3 = controller.leases.current_lease("T3")

    # One policy-classified destructive/production operation runs in the wave.
    clock[0] = T0 + timedelta(seconds=5)
    result = controller.execute_operation(
        Operation("deploy", "prod/analysis", "public"),
        task_id="T1",
        production=True,
        now=T0 + timedelta(seconds=5),
    )
    assert result == "executed:" + controller.policy.audits[-1].token

    # A verified passed report advances T1; the wave stays open (T3 runs).
    report_t1 = _report_for(
        "T1",
        lease_t1,
        outputs=[_commit("abc1234"), OutputInfo(kind="file", ref="src/analysis.py")],
        deviations=["switched the test runner to pytest"],
        cost="2.50",
    )
    clock[0] = T0 + timedelta(seconds=6)
    acceptance1 = controller.accept_report(
        report_t1, now=T0 + timedelta(seconds=6)
    )
    assert acceptance1.accepted
    snapshot = controller.snapshot(T0 + timedelta(seconds=6))
    assert snapshot.passed == ("T1",)
    assert snapshot.running == ("T3",)
    # The passed attempt is closed: its lease is fenced and its provider rate
    # units are released, but money stays reserved until the wave settles.
    assert controller.leases.lease_status("LEASE-RUN-001-T1-1") is LeaseStatus.FENCED
    assert not controller.leases.lease_is_live(
        "LEASE-RUN-001-T1-1", "RUN-001", now=T0 + timedelta(seconds=6)
    )
    assert controller.rate.used("api") == 1
    assert controller.budget.reservations == {
        "T1": Decimal("3.00"),
        "T3": Decimal("3.00"),
    }

    # T3 passes -> the wave completes: money reconciles (settles the wave's
    # bookings as spend; the reported total only gates the hard-cap breach),
    # the deterministic wave-gate review samples the wave, and the wave closes.
    report_t3 = _report_for("T3", lease_t3, outputs=[_commit("def4567")], cost="1.50")
    clock[0] = T0 + timedelta(seconds=7)
    acceptance2 = controller.accept_report(
        report_t3, now=T0 + timedelta(seconds=7)
    )
    assert acceptance2.accepted
    assert controller.budget.actual == Decimal("6.00")  # settled bookings
    assert controller.budget.reservations == {}
    assert controller.snapshot(T0 + timedelta(seconds=7)).open_wave is None

    events = store.list_events("RUN-001")
    kinds = {event.kind for event in events}
    assert "task.passed" in kinds
    assert "wave.complete" in kinds
    assert "wave.review" in kinds
    review = [event for event in events if event.kind == "wave.review"][-1]
    assert review.payload["wave_id"] == "wave-1"
    # 100% of declared deviations + all destructive/production operations.
    assert review.payload["mandatory_ids"] == [
        "T1:deviation:0",
        "T1:operation:0",
    ]
    assert review.payload["pool_size"] == 3  # three plain outputs
    assert review.payload["sample_size"] == 1  # ceil(20% of 3)
    assert len(review.payload["reviewed_ids"]) == 3
    assert "T1:deviation:0" in review.payload["reviewed_ids"]

    # The next tick advances to the dependency-unlocked wave T2.
    advance = controller.tick(T0 + timedelta(seconds=10))
    assert [handoff.task_id for handoff in advance.dispatched] == ["T2"]
    assert advance.dispatched[0].lease.lease_id == "LEASE-RUN-001-T2-1"
    assert controller.budget.reservations == {"T2": Decimal("3.00")}
    assert controller.budget.available == Decimal("1.00")  # 10 - 6 settled - 3
    assert controller.snapshot(T0 + timedelta(seconds=10)).passed == (
        "T1",
        "T3",
    )


def test_failed_report_marks_the_task_failed_and_releases_the_attempt(tmp_path):
    store = _make_store(tmp_path)
    controller = _make_controller(store)
    controller.tick(T0)
    lease_t1 = controller.leases.current_lease("T1")

    report = _report_for("T1", lease_t1, status=ExecutionStatus.FAILED)
    acceptance = controller.accept_report(
        report, acceptance=_accepted(), now=T0 + timedelta(seconds=5)
    )
    assert acceptance.accepted
    snapshot = controller.snapshot(T0 + timedelta(seconds=5))
    assert snapshot.passed == ()
    assert snapshot.running == ("T3",)
    # The verified failure is terminal: the attempt is closed, rate released;
    # money stays reserved so the wave settle books the spend.
    assert not controller.leases.lease_is_live(
        "LEASE-RUN-001-T1-1", "RUN-001", now=T0 + timedelta(seconds=5)
    )
    assert controller.rate.used("api") == 1
    kinds = {event.kind for event in store.list_events("RUN-001")}
    assert "task.failed" in kinds


def test_unverified_report_is_rejected_fail_closed(tmp_path):
    store = _make_store(tmp_path)
    controller = _make_controller(store)  # no verifier injected
    controller.tick(T0)
    lease = controller.leases.current_lease("T1")
    report = _report_for("T1", lease)
    with pytest.raises(UnverifiedReport):
        controller.accept_report(report, now=T0 + timedelta(seconds=1))


def test_report_guards_fail_closed(tmp_path):
    store = _make_store(tmp_path)
    controller = _make_controller(store)
    controller.tick(T0)
    lease = controller.leases.current_lease("T1")

    # Unknown task ids never advance anything.
    with pytest.raises(UnknownTask):
        controller.accept_report(
            _report_for("T9", lease), acceptance=_accepted(), now=T0
        )

    # A report riding a non-current lease id is stale, not a retry.
    with pytest.raises(StaleLeaseReport):
        controller.accept_report(
            _report_for("T1", _stale_lease("T1")),
            acceptance=_accepted(),
            now=T0,
        )

    # A task that was never dispatched is not in flight.
    with pytest.raises(ReportMismatch):
        controller.accept_report(
            _report_for("T2", lease),
            acceptance=_accepted(),
            now=T0,
        )


# ---------------------------------------------------------------------------
# Prescribed scenario 2: expired lease releases reservations / time freeze
# ---------------------------------------------------------------------------


def test_expired_lease_releases_reservations_and_freezes_time_budget(tmp_path):
    store = _make_store(tmp_path)
    controller = _make_controller(
        store,
        tasks={"T1": _plans()["T1"]},
        lease_ttl=timedelta(seconds=60),
    )

    first = controller.tick(T0)
    assert [handoff.task_id for handoff in first.dispatched] == ["T1"]
    assert first.dispatched[0].lease.lease_id == "LEASE-RUN-001-T1-1"
    assert controller.budget.reservations == {"T1": Decimal("3.00")}
    assert controller.time_budget("T1").remaining(T0 + timedelta(seconds=30)) == 570

    # The lease lapsed: the tick sweeps it, releases money+rate, freezes the
    # time budget at the consumed elapsed time, emits the event, and then
    # re-dispatches the still-pending task with a fresh lease generation.
    later = T0 + timedelta(seconds=120)
    result = controller.tick(later)
    assert result.frozen == ("T1",)
    assert result.released == ("T1",)

    # Reservation released and then re-created EXACTLY once for the new claim.
    assert controller.budget.reservations == {"T1": Decimal("3.00")}
    assert sorted(controller.rate.reservations) == ["T1"]
    assert controller.budget.reserved == Decimal("3.00")

    lease2 = controller.leases.current_lease("T1")
    assert lease2.lease_id == "LEASE-RUN-001-T1-2"
    assert lease2.generation == 2
    assert controller.leases.lease_is_live(
        "LEASE-RUN-001-T1-2", "RUN-001", now=later
    )
    assert not controller.leases.lease_is_live(
        "LEASE-RUN-001-T1-1", "RUN-001", now=later
    )

    # The clock froze for 120 s and resumed: 600 - 120 - 1 = 479 remains.
    assert not controller.time_budget("T1").frozen
    assert controller.time_budget("T1").remaining(
        later + timedelta(seconds=1)
    ) == 479

    # The re-dispatched handoff is bound to the fresh KCC lease.
    assert len(result.dispatched) == 1
    assert result.dispatched[0].lease.lease_id == "LEASE-RUN-001-T1-2"

    events = store.list_events("RUN-001")
    frozen = [event for event in events if event.kind == "task.frozen"][-1]
    assert frozen.payload["reason"] == "lease.expired"
    assert frozen.payload["lease_id"] == "LEASE-RUN-001-T1-1"
    assert frozen.payload["released_money"] == "3.00"
    assert frozen.payload["released_rate"] == [{"provider_key": "api", "units": 1}]
    assert frozen.payload["elapsed_seconds"] == 120.0
    assert frozen.payload["time_remaining"] == 480.0
    assert frozen.payload["retained"] is False
    dispatch = [event for event in events if event.kind == "task.dispatch"][-1]
    assert dispatch.payload["lease_id"] == "LEASE-RUN-001-T1-2"
    assert dispatch.payload["generation"] == 2


def test_fenced_task_releases_reservations_and_freezes_time_budget(tmp_path):
    store = _make_store(tmp_path)
    controller = _make_controller(store, tasks={"T1": _plans()["T1"]})
    controller.tick(T0)

    later = T0 + timedelta(seconds=30)
    controller.fence_task("T1", now=later)
    assert controller.budget.reservations == {}
    assert controller.rate.reservations == {}
    assert controller.leases.lease_status("LEASE-RUN-001-T1-1") is LeaseStatus.FENCED
    assert controller.time_budget("T1").frozen
    assert controller.time_budget("T1").remaining(later) == 570
    events = store.list_events("RUN-001")
    frozen = [event for event in events if event.kind == "task.frozen"][-1]
    assert frozen.payload["reason"] == "fenced"
    assert frozen.payload["released_money"] == "3.00"


def test_time_budget_exhaustion_fails_the_task_without_redispatch(tmp_path):
    store = _make_store(tmp_path)
    plan = TaskPlan(
        id="T1",
        budget_ceiling=Decimal("3.00"),
        requirement_ids=("REQ-001",),
        acceptance_ids=("AC-001",),
        test_ids=("T-001",),
        attempt_budget=_attempt_budget(),
        time_budget_seconds=60,
        rate_demands=(RateDemand("api"),),
        trace=_trace(),
        policy_bundle_hash=POLICY_HASH,
    )
    controller = _make_controller(
        store, tasks={"T1": plan}, lease_ttl=timedelta(seconds=60)
    )
    controller.tick(T0)

    # The lease lapses exactly when the time budget is exhausted: the task
    # fails on the time budget instead of getting another attempt.
    result = controller.tick(T0 + timedelta(seconds=60))
    assert result.dispatched == ()
    assert result.frozen == ("T1",)
    assert controller.budget.reservations == {}
    assert controller.rate.reservations == {}
    event = [e for e in store.list_events("RUN-001") if e.kind == "task.failed"][-1]
    assert event.payload["task_id"] == "T1"
    assert event.payload["reason"] == "time budget exhausted"


# ---------------------------------------------------------------------------
# Prescribed scenario 3: PAUSED retains the reservation (separate path)
# ---------------------------------------------------------------------------


def test_pause_retains_reservation_and_resume_redispatches_without_double_reserve(tmp_path):
    store = _make_store(tmp_path)
    controller = _make_controller(store)
    controller.tick(T0)
    lease_t1 = controller.leases.current_lease("T1")
    assert lease_t1.generation == 1

    pause_at = T0 + timedelta(seconds=10)
    snapshot = controller.pause(pause_at)
    assert store.load_run("RUN-001").state is LifecycleState.PAUSED
    assert snapshot.run_state is LifecycleState.PAUSED
    assert snapshot.frozen == ("T1", "T3")
    # PAUSED: leases fenced + time budgets frozen, but reservations RETAINED.
    assert controller.budget.reservations == {
        "T1": Decimal("3.00"),
        "T3": Decimal("3.00"),
    }
    assert controller.rate.used("api") == 2
    assert controller.budget.reserved == Decimal("6.00")
    assert not controller.leases.lease_is_live(
        "LEASE-RUN-001-T1-1", "RUN-001", now=pause_at
    )
    events = store.list_events("RUN-001")
    frozen = [event for event in events if event.kind == "task.frozen"][-1]
    assert frozen.payload["reason"] == "run.paused"
    assert frozen.payload["retained"] is True
    assert frozen.payload["time_remaining"] == 590.0

    # A report against the paused run fails closed (lease fenced).
    with pytest.raises(StaleLeaseReport):
        controller.accept_report(
            _report_for("T1", lease_t1),
            acceptance=_accepted(),
            now=pause_at + timedelta(seconds=1),
        )

    # While the run is PAUSED a tick must not dispatch; after resume it
    # re-dispatches the retained set with fresh leases and NO new reservations.
    assert controller.tick(pause_at + timedelta(seconds=2)).dispatched == ()
    controller.resume(T0 + timedelta(seconds=20))
    assert store.load_run("RUN-001").state is LifecycleState.BUILDING
    result = controller.tick(T0 + timedelta(seconds=30))
    assert len(result.dispatched) == 2
    by_task = {handoff.task_id: handoff for handoff in result.dispatched}
    assert by_task["T1"].lease.lease_id == "LEASE-RUN-001-T1-2"
    assert by_task["T1"].lease.generation == 2
    assert controller.budget.reservations == {
        "T1": Decimal("3.00"),
        "T3": Decimal("3.00"),
    }
    assert controller.budget.reserved == Decimal("6.00")  # exactly once
    assert controller.rate.used("api") == 2
    # The unpause continues the clock: 600 - 10 elapsed - 1 s = 589 remains.
    assert controller.time_budget("T1").remaining(T0 + timedelta(seconds=31)) == 589
    dispatch = [
        event
        for event in store.list_events("RUN-001")
        if event.kind == "task.dispatch"
    ][-1]
    assert dispatch.payload["resumed"] is True


def test_pause_requires_building_and_resume_requires_paused(tmp_path):
    store = _make_store(tmp_path)
    controller = _make_controller(store)
    with pytest.raises(NotBuilding):
        controller.resume(T0)  # never paused
    controller.tick(T0)
    controller.pause(T0 + timedelta(seconds=5))
    with pytest.raises(NotBuilding):
        controller.pause(T0 + timedelta(seconds=6))  # already paused


# ---------------------------------------------------------------------------
# Prescribed scenario 3b: deterministic wave-gate deviation review
# ---------------------------------------------------------------------------


def test_wave_gate_review_samples_all_deviations_and_destructive_operations():
    items = [WaveEvidenceItem(id=f"out-{i:02d}", kind="output") for i in range(10)]
    items += [
        WaveEvidenceItem(id="dev-a", kind="deviation", deviation=True),
        WaveEvidenceItem(id="dev-b", kind="deviation", deviation=True),
        WaveEvidenceItem(id="op-x", kind="operation", destructive=True),
        WaveEvidenceItem(
            id="op-y", kind="operation", destructive=True, production=True
        ),
        WaveEvidenceItem(id="prod-1", kind="output", production=True),
    ]
    review = WaveGateReview.sample("wave-7", items)

    # 100% of declared deviations + all production/destructive operations.
    assert [item.id for item in review.mandatory] == [
        "dev-a",
        "dev-b",
        "op-x",
        "op-y",
        "prod-1",
    ]
    assert [item.id for item in review.pool] == [f"out-{i:02d}" for i in range(10)]
    # >= 20% of the remaining evidence is sampled (ceil(20% of 10) = 2).
    assert len(review.sampled) == 2
    assert (
        Decimal(review.sample_size) / Decimal(review.pool_size) >= Decimal("0.20")
    )
    # Minimum one reviewed item per nonempty wave is satisfied.
    assert len(review.reviewed) == 7
    assert {item.id for item in review.reviewed} == {
        "dev-a",
        "dev-b",
        "op-x",
        "op-y",
        "prod-1",
    } | {item.id for item in review.sampled}

    # Fully deterministic: input order and repeated calls are identical.
    assert WaveGateReview.sample("wave-7", list(reversed(items))) == review
    assert WaveGateReview.sample("wave-7", items) == review


def test_wave_gate_review_minimum_one_per_nonempty_wave():
    only = [
        WaveEvidenceItem(id="a", kind="output"),
        WaveEvidenceItem(id="b", kind="output"),
    ]
    review = WaveGateReview.sample("wave-1", only)
    assert len(review.sampled) == 1
    assert len(review.reviewed) == 1

    # An empty wave is reviewed as empty (no minimum applies).
    empty = WaveGateReview.sample("wave-2", [])
    assert empty.reviewed == ()
    assert empty.pool == ()

    # A single mandatory item with no pool still reviews that item.
    mandatory = WaveGateReview.sample(
        "wave-3", [WaveEvidenceItem(id="dev", kind="deviation", deviation=True)]
    )
    assert [item.id for item in mandatory.reviewed] == ["dev"]


def test_wave_gate_review_rejects_bad_ratio_and_item_ids():
    with pytest.raises(ValueError):
        WaveGateReview.sample("wave-1", [], ratio=Decimal("0.00"))
    with pytest.raises(ValueError):
        WaveGateReview.sample("wave-1", [], ratio=Decimal("1.50"))
    with pytest.raises(ValueError):
        WaveEvidenceItem(id="", kind="output")
    with pytest.raises(ValueError):
        WaveEvidenceItem(id="x", kind="")


def test_wave_gate_review_covers_production_operation_in_controller_wave(tmp_path):
    store = _make_store(tmp_path)
    controller = _make_controller(store, tasks={"T1": _plans()["T1"]})
    controller.tick(T0)
    lease_t1 = controller.leases.current_lease("T1")

    controller.execute_operation(
        Operation("deploy", "prod/analysis", "public"),
        task_id="T1",
        production=True,
        now=T0 + timedelta(seconds=5),
    )
    controller.accept_report(
        _report_for(
            "T1", lease_t1, deviations=["deviation X"], outputs=[_commit("abc1234")]
        ),
        acceptance=_accepted(),
        now=T0 + timedelta(seconds=6),
    )
    review_event = [
        event for event in store.list_events("RUN-001") if event.kind == "wave.review"
    ][-1]
    # Both the declared deviation and the production/destructive operation are
    # mandatory, and the pool outputs are sampled at >= 20% (min 1).
    assert review_event.payload["mandatory_ids"] == [
        "T1:deviation:0",
        "T1:operation:0",
    ]
    assert review_event.payload["pool_size"] == 1  # the report's commit output
    assert review_event.payload["sample_size"] == 1


# ---------------------------------------------------------------------------
# TaskPlan validation
# ---------------------------------------------------------------------------


def test_task_plan_rejects_broken_scopes(tmp_path):
    base = dict(
        requirement_ids=("REQ-001",),
        acceptance_ids=("AC-001",),
        test_ids=("T-001",),
        attempt_budget=_attempt_budget(),
        budget_ceiling=Decimal("3.00"),
    )
    with pytest.raises(ValueError):
        TaskPlan(id="T1", **base, policy_bundle_hash=POLICY_HASH)  # no trace
    with pytest.raises(ValueError):
        TaskPlan(
            id="T1",
            **base,
            trace=_trace(),
            policy_bundle_hash=None,  # no anchor
        )
    with pytest.raises(ValueError):
        TaskPlan(
            id="T1",
            **base,
            trace=_trace(),
            policy_bundle_hash=POLICY_HASH,
            time_budget_seconds=0,
        )
    with pytest.raises(ValueError):
        TaskPlan(
            id="T1",
            **dict(base, budget_ceiling=Decimal("0")),
            trace=_trace(),
            policy_bundle_hash=POLICY_HASH,
        )
    # A dependency outside the task universe is a broken run contract.
    broken = TaskPlan(
        id="T1",
        **base,
        trace=_trace(),
        policy_bundle_hash=POLICY_HASH,
        depends_on=("T9",),
    )
    with pytest.raises(ValueError):
        _make_controller(_make_store(tmp_path), tasks={"T1": broken})
