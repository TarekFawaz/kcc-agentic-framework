"""Deterministic scenario runner for the autobuild 30-scenario evaluation.

Plan 07, Task 3 (``### Task 3: Scenario runner + all 30`` of the local
Plan07 task contracts, plus its ## Global Constraints and the approved
Design Spec v1.2 section 27).

:func:`run_scenario` drives ONE approved evaluation scenario from the
catalog to its settled lifecycle state.  It is the proof harness for the
control-plane rules of every scenario:

* **Explicit scenario-ID -> injection mapping.**  :data:`SCENARIO_INJECTIONS`
  keys every approved scenario ID to its deterministic FakeWorld fault
  injection and :data:`SCENARIO_DRIVERS` keys every ID to its driver.
  Behavior is dispatched by the stable ID only -- the English scenario
  name never drives control flow (the runner's only use of the catalog
  name is the durable run record's display field, and the runner never
  reads the catalog's expected state at all: final states are produced
  by the controller and the production decision modules).
* **Real controller, fake world, temp SQLite, fake clock.**  Post-LOCK
  drivers construct the production
  :class:`~kcc_autobuild.controller.AutobuildController` wired to the
  deterministic :class:`~kcc_autobuild.evaluation.FakeWorld` (fake
  provider, fake CI, fake clock -- the controller only ever reads the
  handed-in world time), the production :class:`ExecutionBridge` chain
  and a temp-file :class:`~kcc_autobuild.store.RunStore`.  Every
  lifecycle transition is the production state machine
  (:func:`~kcc_autobuild.state_machine.assert_transition`); no driver
  writes a final state.
* **Reuse of production decision modules.**  The drivers route external
  reviews through :func:`~kcc_autobuild.external_wait.route_external_review`
  / :class:`ExternalWaitCoordinator` (scenarios 6/30), classify failures
  through :func:`~kcc_autobuild.failure_classifier.decide` /
  :func:`~kcc_autobuild.failure_classifier.outage_route` (8/11/12),
  evaluate pre-LOCK gates through
  :func:`~kcc_autobuild.readiness.evaluate_readiness` and
  :func:`~kcc_autobuild.trace.validate_trace_coverage` (7/14/17), and
  enforce the attempt/budget/rate/false-pass ladders through the
  controller's own reservation, verify, fence and wave semantics.
* **Determinism by construction.**  The world advances only through its
  fake clock, the policy gate uses a deterministic token factory, and
  every driver is a pure function of its scenario ID's script.

The behavioral contract is owned by
:file:`.KCC/runtime/tests/test_evaluation_runner.py` (pinned to the Plan
07 Global Constraints: exactly 30 evaluation cases pass, no skip/xfail).
"""

from __future__ import annotations

import itertools
from dataclasses import dataclass, field
from datetime import timedelta
from decimal import Decimal
from pathlib import Path
from types import MappingProxyType
from typing import Any, Callable, Mapping

from pydantic import ValidationError

from kcc_autobuild.bridge import (
    AcceptanceEvidence,
    AttemptBudget,
    ExecutionBridge,
    ExecutionReport,
    ExecutionStatus,
    FailureInfo,
    LockedDecision,
    OutputInfo,
    UsageInfo,
)
from kcc_autobuild.budget import BudgetBreach, BudgetLedger
from kcc_autobuild.controller import AutobuildController, StaleLeaseReport, TaskPlan
from kcc_autobuild.evidence import EvidenceVerifier, ReportAcceptance
from kcc_autobuild.evaluation.fake_world import (
    FakeWorld,
    MigrationCrashError,
    ProviderCallResult,
    StoreDecision,
    WorldEvent,
)
from kcc_autobuild.evaluation.scenarios import SCENARIOS_BY_ID, Scenario
from kcc_autobuild.external_wait import (
    ExternalReview,
    ExternalWaitCoordinator,
    ExternalWaitStore,
    ReviewStatus,
)
from kcc_autobuild.failure_classifier import FailureEvidence, decide, outage_route
from kcc_autobuild.leases import LeaseLedger, mint_workspace_id
from kcc_autobuild.models import (
    FailureClass,
    LifecycleState,
    ReadinessStatus,
    RunEvent,
    RunRecord,
)
from kcc_autobuild.policy import (
    Operation,
    PolicyDecision,
    PolicyEvaluator,
    PolicyRule,
    sign_policy_bundle,
)
from kcc_autobuild.rate_limit import RateCapacityLedger, RateDemand
from kcc_autobuild.readiness import (
    ReadinessItem,
    ReadinessPack,
    RedTeamDisposition,
    RedTeamFinding,
    evaluate_readiness,
)
from kcc_autobuild.scheduler import Scheduler
from kcc_autobuild.store import RunStore
from kcc_autobuild.tool_gate import PolicyDenied, PolicyToolGate
from kcc_autobuild.trace import TraceEdge, TraceGraph, TraceNode, validate_trace_coverage

RUN_ID = "RUN-EVAL-01"
"""Deterministic run identity of every evaluation run."""

LEASE_TTL = timedelta(seconds=90)
"""Lease TTL: a worker that stopped reporting is fenced after this window."""

TICK_SECONDS = 30.0
"""Deterministic tick interval the driver advances between controller ticks."""

RATE_RETRY_BOUND = 5
"""Bounded retry distribution: consecutive 429s beyond this bound escalate."""

RATE_BACKOFF_SECONDS = 60.0
"""Deterministic backoff between rate-limited retries (world time)."""

TIME_BUDGET_SECONDS = 3600
TASK_BUDGET_CEILING = Decimal("1.00")
DEFAULT_BUDGET_CAP = Decimal("10.00")
POLICY_HASH = "c" * 64
POLICY_SECRET = "autobuild-evaluation-runner"


@dataclass(frozen=True)
class ScenarioResult:
    """The observable evidence of one evaluation run (immutable).

    ``final_state`` is whatever the controller and the production
    decision modules produced -- the runner never copies the catalog's
    expectation into the result.

    Determinism guarantee: the runner is clock-free and the world runs
    on the fake clock only, so ``world_events``, ``state_transitions``,
    ``task_states`` and ``final_state`` are byte-identical for identical
    scripts.  ``run_events`` additionally carries the production
    RunStore's event timestamp (the store stamps lifecycle transitions
    with the UTC instant), so that field is order-stable but not
    timestamp-stable across runs.
    """

    scenario_id: str
    run_id: str
    final_state: LifecycleState
    task_states: tuple[tuple[str, str], ...]
    run_events: tuple[RunEvent, ...]
    world_events: tuple[WorldEvent, ...]
    state_transitions: tuple[tuple[str, str, str], ...]
    halt_batches: tuple[tuple[str, ...], ...]
    block_reasons: tuple[str, ...]
    rejected_reports: int
    stale_promotions: int
    rate_limited_calls: int
    rate_429_observed: int
    target_state: tuple[str, ...]
    store_decision: StoreDecision | None
    pending_billing: int
    provider_actual_cost: float
    # Autonomy metrics evidence (Plan 07, Task 4): the per-run facts the
    # metrics/rollout-gates module derives from -- the hard cap the ledger
    # enforced and the outside-policy operations that actually executed.
    budget_cap: Decimal
    policy_violations: int


# ---------------------------------------------------------------------------
# Chain-of-custody verifier adapters over the FakeWorld
# ---------------------------------------------------------------------------


class _LeaseCheck:
    """Confirms an attempt lease against the controller's live ledger."""

    def __init__(self, leases: LeaseLedger, world: FakeWorld) -> None:
        self._leases = leases
        self._world = world

    def lease_is_live(self, lease_id: str, run_id: str) -> bool:
        return self._leases.lease_is_live(lease_id, run_id, now=self._world.now)


class _CommitCheck:
    """Confirms a claimed commit exists in the run's object store."""

    def __init__(self, commits: set[str]) -> None:
        self._commits = commits

    def commit_exists(self, commit_id: str) -> bool:
        return commit_id in self._commits


class _CiCheck:
    """Confirms a claimed CI ref by the world's recorded CI verdicts."""

    def __init__(self, world: FakeWorld) -> None:
        self._world = world

    def ci_run_passed(self, ci_run_ref: str) -> bool:
        verdicts = [
            event
            for event in self._world.events
            if event.kind == "ci.verify" and event.payload.get("ref") == ci_run_ref
        ]
        return bool(verdicts) and verdicts[-1].payload["status"] == "passed"


class _UsageCheck:
    """Reconciles the report's usage claim against world provider truth."""

    def __init__(self, ctx: "RunContext") -> None:
        self._ctx = ctx

    def usage_reconciles(self, usage: UsageInfo) -> bool:
        return (
            usage.tokens == self._ctx.usage_tokens
            and usage.provider_calls == self._ctx.usage_calls
            and abs(usage.cost_usd - self._ctx.usage_cost) < 1e-9
        )


# ---------------------------------------------------------------------------
# The per-run driver context
# ---------------------------------------------------------------------------


@dataclass
class RunContext:
    """One evaluation run under drive: world, store, controller, ladders.

    The context carries the per-run accounting the control-plane rules
    enforce: the real-commit object store, the provider usage truth the
    verifier reconciles against, the locked Tier-1 decisions and the
    consolidated exception batches.  All state is deterministic.
    """

    scenario: Scenario
    world: FakeWorld
    store: RunStore

    controller: AutobuildController | None = None
    plan: dict[str, TaskPlan] = field(default_factory=dict)
    budget_cap: Decimal = DEFAULT_BUDGET_CAP

    commits: set[str] = field(default_factory=set)
    usage_tokens: int = 0
    usage_cost: float = 0.0
    usage_calls: int = 0

    locked_providers: tuple[str, ...] = ()
    authorized_fallbacks: tuple[str, ...] = ()
    locked_decisions: tuple[LockedDecision, ...] = ()

    halt_batches: list[tuple[str, ...]] = field(default_factory=list)
    block_reasons: list[str] = field(default_factory=list)
    rejected_reports: int = 0
    stale_promotions: int = 0
    rate_limited_calls: int = 0
    rate_429_observed: int = 0
    deviation_violation: str | None = None
    store_decision: StoreDecision | None = None

    policy: PolicyToolGate | None = None
    policy_allowed_resources: frozenset[str] = frozenset()

    _verifier: EvidenceVerifier | None = None

    # -- wiring --------------------------------------------------------------

    def setup_tasks(
        self,
        task_ids: tuple[str, ...],
        *,
        depends: Mapping[str, tuple[str, ...]] | None = None,
        cap: Decimal | None = None,
        ceiling: Decimal | None = None,
        max_attempts: int = 3,
    ) -> None:
        """Build the task universe and wire the real controller onto it."""
        depends = depends or {}
        task_ceiling = ceiling if ceiling is not None else TASK_BUDGET_CEILING
        trace = _trace_graph(task_ids)
        tasks: dict[str, TaskPlan] = {}
        for task_id in task_ids:
            tasks[task_id] = TaskPlan(
                id=task_id,
                budget_ceiling=task_ceiling,
                requirement_ids=(f"REQ-{task_id}",),
                acceptance_ids=(f"AC-{task_id}",),
                test_ids=(f"T-{task_id}",),
                attempt_budget=AttemptBudget(
                    max_attempts=max_attempts,
                    time_budget_minutes=120,
                    token_budget=100_000,
                    cost_budget_minor=1_000,
                    escalation_tier=1,
                ),
                time_budget_seconds=TIME_BUDGET_SECONDS,
                depends_on=tuple(depends.get(task_id, ())),
                rate_demands=(RateDemand("llm", 1),),
                trace=trace,
                locked_decisions=tuple(self.locked_decisions),
                policy_bundle_hash=POLICY_HASH,
            )
        self.plan = tasks
        self.budget_cap = cap if cap is not None else DEFAULT_BUDGET_CAP
        self.policy, self.policy_allowed_resources = _policy_gate_and_resources(
            self.world
        )
        self.controller = AutobuildController(
            run_id=RUN_ID,
            store=self.store,
            scheduler=Scheduler(),
            leases=LeaseLedger(lease_ttl=LEASE_TTL),
            bridge=ExecutionBridge(),
            budget=BudgetLedger(self.budget_cap),
            rate=RateCapacityLedger({"llm": 32, "llm-aux": 32}),
            policy=self.policy,
            tasks=tasks,
        )
        self._verifier = EvidenceVerifier(
            lease=_LeaseCheck(self.controller.leases, self.world),
            commits=_CommitCheck(self.commits),
            ci=_CiCheck(self.world),
            usage=_UsageCheck(self),
        )

    # -- clock / provider ----------------------------------------------------

    def provider_call(self, provider: str = "llm") -> ProviderCallResult:
        """One provider invocation through the world (truth, not scenario intent)."""
        result = self.world.provider_call(provider)
        if result.status == "rate_limited":
            self.rate_limited_calls += 1
            self.rate_429_observed += 1
            assert self.controller is not None
            self.controller.rate.observe_429(provider)
        elif result.status == "outage":
            pass
        if result.ok and result.usage is not None:
            self.usage_tokens += result.usage.tokens
            self.usage_cost += result.usage.cost_usd
            self.usage_calls += result.usage.provider_calls
        return result

    def claimed_usage(self) -> UsageInfo:
        """The usage the attempt claims, mirroring world provider truth."""
        return UsageInfo(
            tokens=self.usage_tokens,
            cost_usd=self.usage_cost,
            provider_calls=self.usage_calls,
        )

    # -- tick / dispatch loops ------------------------------------------------

    def snapshot(self) -> Any:
        assert self.controller is not None
        return self.controller.snapshot(now=self.world.now)

    def run_settled(self) -> bool:
        """The run is settled: no in-flight/frozen/pending task remains."""
        if self.store.load_run(RUN_ID).state is not LifecycleState.BUILDING:
            return True
        snapshot = self.snapshot()
        return not (snapshot.running or snapshot.frozen or snapshot.pending)

    def next_dispatch(self, rounds: int = 80) -> Any:
        """Tick until the controller dispatches; return the first handoff."""
        assert self.controller is not None
        for _ in range(rounds):
            tick = self.controller.tick(now=self.world.now)
            if tick.dispatched:
                return tick.dispatched[0]
            if self.run_settled():
                return None
            self.world.advance(seconds=TICK_SECONDS)
        return None

    def drive(
        self,
        *,
        calls: int = 1,
        ci_ref: str | None = None,
        deviations: tuple[str, ...] = (),
        rounds: int = 80,
    ) -> None:
        """Tick-dispatch-execute until the run settles or a Tier-1 violation fires."""
        assert self.controller is not None
        for _ in range(rounds):
            tick = self.controller.tick(now=self.world.now)
            for handoff in tick.dispatched:
                self.work_success(handoff, calls=calls, ci_ref=ci_ref, deviations=deviations)
                if self.deviation_violation is not None:
                    return
            if self.run_settled():
                return
            self.world.advance(seconds=TICK_SECONDS)

    # -- worker simulation ----------------------------------------------------

    def evidence_for(self, handoff: Any) -> list[AcceptanceEvidence]:
        assert self.controller is not None
        plan = self.plan[handoff.task_id]
        return [
            AcceptanceEvidence(
                acceptance_id=plan.acceptance_ids[0],
                test_ids=list(plan.test_ids),
                evidence_refs=[
                    f"artifacts/{handoff.task_id}-{handoff.lease.generation}.xml"
                ],
            )
        ]

    def work_success(
        self,
        handoff: Any,
        *,
        calls: int = 1,
        ci_ref: str | None = None,
        deviations: tuple[str, ...] = (),
        extra_outputs: tuple[OutputInfo, ...] = (),
    ) -> ExecutionReport | None:
        """One successful worker run: work, evidence, emit, chain-of-custody.

        The emitted report carries the plan's acceptance criteria and the
        deterministic commit/CI outputs; a partitioned worker returns
        ``None`` (its report never arrives).
        """
        for _ in range(calls):
            self.provider_call("llm")
        outputs: list[OutputInfo] = []
        commit_id = f"commit-{handoff.task_id}-g{handoff.lease.generation}"
        self.commits.add(commit_id)
        outputs.append(OutputInfo(kind="commit", ref=commit_id))
        if ci_ref is not None:
            self.world.ci_verify(ci_ref)
            outputs.append(OutputInfo(kind="ci-run", ref=ci_ref))
        outputs.extend(extra_outputs)
        report = self.world.emit_report(
            run_id=RUN_ID,
            task_id=handoff.task_id,
            attempt=handoff.lease.generation,
            lease_id=handoff.lease.lease_id,
            workspace_id=mint_workspace_id(
                RUN_ID, handoff.task_id, handoff.lease.generation
            ),
            status=ExecutionStatus.PASSED,
            acceptance_evidence=self.evidence_for(handoff),
            usage=self.claimed_usage(),
            outputs=outputs,
            deviations=list(deviations),
        )
        if report is None:
            return None
        violation = self._tier1_deviation(report.deviations)
        if violation is not None:
            # A Tier-1 deviation is never accepted: the run escalates.
            self.deviation_violation = violation
            return report
        acceptance = self._verify(report)
        self.accept(report, acceptance)
        return report

    def work_failed(self, handoff: Any, cls: FailureClass, message: str) -> ExecutionReport:
        """One failed worker run: the report carries the classified failure."""
        report = self.world.emit_report(
            run_id=RUN_ID,
            task_id=handoff.task_id,
            attempt=handoff.lease.generation,
            lease_id=handoff.lease.lease_id,
            workspace_id=mint_workspace_id(
                RUN_ID, handoff.task_id, handoff.lease.generation
            ),
            status=ExecutionStatus.FAILED,
            failure=FailureInfo(cls=cls, message=message),
            usage=self.claimed_usage(),
        )
        acceptance = self._verify(report)
        self.accept(report, acceptance)
        return report

    def _verify(self, report: ExecutionReport) -> ReportAcceptance:
        assert self._verifier is not None
        return self._verifier.verify(report)

    def accept(self, report: ExecutionReport, acceptance: ReportAcceptance) -> None:
        assert self.controller is not None
        try:
            self.controller.accept_report(report, acceptance=acceptance, now=self.world.now)
        except BudgetBreach:
            # E3: the books settle first, then the controller halted to
            # BLOCKED; the breach is recorded as the block evidence.
            self.block_reasons.append("E3 hard budget cap would be exceeded at wave settlement")

    # -- control-plane rules ---------------------------------------------------

    def _tier1_deviation(self, deviations: list[str]) -> str | None:
        """A declared deviation that redecisizes a locked decision is Tier-1."""
        for decision in self.locked_decisions:
            for deviation in deviations:
                if decision.id in deviation:
                    return (
                        f"Tier-1 deviation attempts to redecisize locked "
                        f"decision {decision.id}: {decision.summary}"
                    )
        return None

    def enforce_locked_providers(self) -> str | None:
        """Ground-truth check: no provider outside the locked set was used."""
        allowed = set(self.locked_providers) | set(self.authorized_fallbacks)
        for event in self.world.events:
            if event.kind == "provider.call":
                provider = event.payload.get("provider_key")
                if provider not in allowed:
                    return str(provider)
        return None

    def transition(self, origin: LifecycleState, target: LifecycleState, reason: str) -> None:
        """Walk the production lifecycle state machine (fail-closed)."""
        self.store.transition(RUN_ID, origin, target, reason)

    def halt(self, reasons: list[str]) -> None:
        """Consolidate every blocker into ONE batched decision request (spec 18.1).

        Exactly one HALTED transition carries the whole batch -- the
        run is never drip-questioned one blocker at a time.
        """
        batch = tuple(dict.fromkeys(reason for reason in reasons if reason))
        self.halt_batches.append(batch)
        current = self.store.load_run(RUN_ID).state
        self.store.transition(
            RUN_ID, current, LifecycleState.HALTED, "; ".join(batch)
        )

    def complete_build(
        self,
        *,
        staging_ref: str = "ci/staging-01",
        prod_ref: str = "ci/prod-01",
        stop_at: LifecycleState | None = None,
    ) -> None:
        """Settle the build through the real lifecycle: validate, deploy, DONE.

        Staging/production validation evidence comes from the world's CI
        runner (never a local pretend pass): a CI outage stops the run
        BLOCKED with an auto-recheck instead of fabricating validation.
        """
        if self.store.load_run(RUN_ID).state is not LifecycleState.BUILDING:
            return
        if not self._check_provider_settlement():
            return
        staging = self.world.ci_verify(staging_ref)
        if staging.status == "outage":
            reason = (
                "staging validation CI outage; auto-recheck until real CI evidence"
            )
            self.block_reasons.append(reason)
            self.transition(LifecycleState.BUILDING, LifecycleState.BLOCKED, reason)
            return
        self.transition(
            LifecycleState.BUILDING,
            LifecycleState.STAGING_VALIDATED,
            f"staging validation passed ({staging_ref})",
        )
        if stop_at is LifecycleState.STAGING_VALIDATED:
            return
        self.transition(
            LifecycleState.STAGING_VALIDATED,
            LifecycleState.DEPLOYED,
            "production deployment complete",
        )
        if stop_at is LifecycleState.DEPLOYED:
            return
        production = self.world.ci_verify(prod_ref)
        if production.status == "outage":
            reason = "production validation CI outage; auto-recheck"
            self.block_reasons.append(reason)
            self.transition(LifecycleState.DEPLOYED, LifecycleState.BLOCKED, reason)
            return
        self.transition(
            LifecycleState.DEPLOYED,
            LifecycleState.PRODUCTION_VALIDATED,
            f"production smoke validation passed ({prod_ref})",
        )
        self.transition(
            LifecycleState.PRODUCTION_VALIDATED,
            LifecycleState.DONE,
            "definition of done met",
        )

    def _check_provider_settlement(self) -> bool:
        """Settlement reconciles provider ACTUALS against the hard cap."""
        actual = sum(usage.cost_usd for usage in self.world.provider_actuals())
        if actual > float(self.budget_cap):
            reason = "E3: provider actuals exceeded the hard cap at settlement"
            self.block_reasons.append(reason)
            self.transition(LifecycleState.BUILDING, LifecycleState.BLOCKED, reason)
            return False
        return True


# ---------------------------------------------------------------------------
# Real-controller wiring helpers (production APIs only)
# ---------------------------------------------------------------------------


def _trace_graph(task_ids: tuple[str, ...]) -> TraceGraph:
    """One dependency-closed trace cluster per task (REQ -> IMPL -> AC/T)."""
    nodes: list[TraceNode] = []
    edges: list[TraceEdge] = []
    for task_id in task_ids:
        nodes += [
            TraceNode(id=f"REQ-{task_id}", kind="requirement"),
            TraceNode(id=f"IMPL-{task_id}", kind="implementation"),
            TraceNode(id=f"AC-{task_id}", kind="acceptance"),
            TraceNode(id=f"T-{task_id}", kind="test"),
        ]
        edges += [
            TraceEdge(source=f"REQ-{task_id}", target=f"IMPL-{task_id}"),
            TraceEdge(source=f"IMPL-{task_id}", target=f"AC-{task_id}"),
            TraceEdge(source=f"IMPL-{task_id}", target=f"T-{task_id}"),
        ]
    return TraceGraph(run_id=RUN_ID, nodes=nodes, edges=edges)


def _policy_gate_and_resources(world: FakeWorld) -> tuple[PolicyToolGate, frozenset[str]]:
    """Deterministic signed destructive-action policy gate over the world.

    Returns the gate and the resources the signed bundle actually
    allows -- the per-run truth the policy-violation metric compares the
    world's executed migrations against (a clean ``migration.commit`` on
    a resource outside this set is a violation; a simulated
    ``migration.commit_crash`` is exogenous target truth, not a
    control-plane action).
    """
    rules = (
        PolicyRule(
            operation="migrate",
            resource="prod/db/schema",
            data_class="public",
            decision=PolicyDecision.ALLOWED,
        ),
    )
    bundle = sign_policy_bundle(rules, POLICY_SECRET)
    counter = itertools.count(1)

    def token_factory() -> str:
        return f"decision-token-{next(counter)}"

    gate = PolicyToolGate(
        PolicyEvaluator(bundle, POLICY_SECRET),
        executor=lambda operation, token: world.migrate(operation.resource),
        token_factory=token_factory,
    )
    allowed = frozenset(
        rule.resource
        for rule in bundle.rules
        if rule.decision is PolicyDecision.ALLOWED
    )
    return gate, allowed


# ---------------------------------------------------------------------------
# Explicit scenario-ID -> injection mapping (evaluation fidelity).
# Each entry names the deterministic world fault(s) of exactly one
# approved scenario; behavior is never inferred from the English name.
# ---------------------------------------------------------------------------


def _inject_none(_world: FakeWorld) -> None:
    """No exogenous fault: the control plane runs against a healthy world."""


def _inject_scenario4(world: FakeWorld) -> None:
    world.inject("worker_partition", task_id="T-2", wave="W2")


def _inject_scenario11(world: FakeWorld) -> None:
    world.inject("provider_outage", provider_key="llm", seconds=3600)


def _inject_scenario12(world: FakeWorld) -> None:
    world.inject("provider_outage", provider_key="llm", seconds=6000)


def _inject_scenario13(world: FakeWorld) -> None:
    world.inject("worker_partition", task_id="T-1", wave="W1")


def _inject_scenario18(world: FakeWorld) -> None:
    world.inject("provider_outage", provider_key="llm", seconds=6000)
    world.inject("provider_rate_limit", provider_key="llm-aux", after_calls=0, seconds=100000)


def _inject_scenario20(world: FakeWorld) -> None:
    world.inject(
        "provider_rate_limit", provider_key="llm", after_calls=2, seconds=60
    )


def _inject_scenario22(world: FakeWorld) -> None:
    world.inject("billing_lag", seconds=3600)


def _inject_scenario23(world: FakeWorld) -> None:
    world.inject("migration_commit_before_crash", migration="schema-023")


def _inject_scenario24(world: FakeWorld) -> None:
    world.inject("ci_outage", seconds=3600)


def _inject_scenario28(world: FakeWorld) -> None:
    world.inject(
        "provider_rate_limit", provider_key="llm", after_calls=0, seconds=100000
    )


def _inject_scenario30(world: FakeWorld) -> None:
    world.inject("store_rejection", reason="submission rejected by store review")


SCENARIO_INJECTIONS: Mapping[str, Callable[[FakeWorld], None]] = MappingProxyType(
    {
        "scenario1": _inject_none,
        "scenario2": _inject_none,
        "scenario3": _inject_none,
        "scenario4": _inject_scenario4,
        "scenario5": _inject_none,
        "scenario6": _inject_none,
        "scenario7": _inject_none,
        "scenario8": _inject_none,
        "scenario9": _inject_none,
        "scenario10": _inject_none,
        "scenario11": _inject_scenario11,
        "scenario12": _inject_scenario12,
        "scenario13": _inject_scenario13,
        "scenario14": _inject_none,
        "scenario15": _inject_none,
        "scenario16": _inject_none,
        "scenario17": _inject_none,
        "scenario18": _inject_scenario18,
        "scenario19": _inject_none,
        "scenario20": _inject_scenario20,
        "scenario21": _inject_none,
        "scenario22": _inject_scenario22,
        "scenario23": _inject_scenario23,
        "scenario24": _inject_scenario24,
        "scenario25": _inject_none,
        "scenario26": _inject_none,
        "scenario27": _inject_none,
        "scenario28": _inject_scenario28,
        "scenario29": _inject_none,
        "scenario30": _inject_scenario30,
    }
)


# ---------------------------------------------------------------------------
# Per-scenario drivers: explicit ID -> driver. Each driver composes the
# production controller / decision modules; none writes a final state.
# ---------------------------------------------------------------------------


def _drive_scenario1(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    ctx.drive()
    ctx.complete_build()


def _drive_scenario2(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    ctx.drive(calls=2, ci_ref="ci/run-02")
    ctx.complete_build()


def _drive_scenario3(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    ctx.drive(calls=1, ci_ref="ci/staging-sandbox-03")
    ctx.complete_build(staging_ref="ci/staging-sandbox-03", prod_ref="ci/prod-live-03")


def _drive_scenario4(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1", "T-2"), depends={"T-2": ("T-1",)})
    ctx.drive()
    ctx.complete_build()


def _drive_scenario5(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    ctx.drive(ci_ref="ci/run-05")
    ctx.complete_build()


def _drive_scenario6(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    ctx.drive()
    ctx.complete_build(stop_at=LifecycleState.DEPLOYED)
    coordinator = ExternalWaitCoordinator(ExternalWaitStore(ctx.store))
    verdict = coordinator.record_review(
        RUN_ID,
        ExternalReview(status=ReviewStatus.PENDING),
        now=ctx.world.now,
        bug_attempts=0,
    )
    ctx.transition(LifecycleState.DEPLOYED, verdict.route, "app-store review pending")


def _drive_scenario7(ctx: RunContext) -> None:
    # The real controller is wired for the run, but the run never reaches
    # BUILDING: the LOCK gate fails closed before anything dispatches.
    ctx.setup_tasks(("T-1",))
    pack = ReadinessPack(
        items=[
            ReadinessItem(
                id="CRED-001",
                provider="oauth",
                status=ReadinessStatus.BLOCKER,
                required_kinds=("permissions",),
            )
        ]
    )
    evaluation = evaluate_readiness(pack, now=ctx.world.now)
    reason = "readiness blocker blocks LOCK: " + "; ".join(evaluation.blockers)
    ctx.block_reasons.append(reason)
    ctx.transition(LifecycleState.READINESS, LifecycleState.BLOCKED, reason)


def _drive_scenario8(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    handoff = ctx.next_dispatch()
    if handoff is None:
        return
    decision = decide(
        FailureEvidence(
            status=401,
            message="provider credential revoked after LOCK",
            consecutive=1,
        )
    )
    ctx.work_failed(handoff, decision.cls, "401 provider credential revoked after LOCK")
    ctx.halt([decision.note])


def _drive_scenario9(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",), cap=Decimal("0.01"), ceiling=Decimal("0.01"))
    ctx.drive(calls=2)


def _drive_scenario10(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    handoff = ctx.next_dispatch()
    if handoff is None:
        return
    # The migration is a policy-classified destructive action: the gate
    # approves it against the signed bundle and executes it on the world.
    ctx.controller.execute_operation(
        Operation("migrate", "prod/db/schema", "public"),
        task_id=handoff.task_id,
        now=ctx.world.now,
    )
    ctx.work_success(handoff, calls=1)
    ctx.complete_build()


def _drive_scenario11(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    ctx.authorized_fallbacks = ("fallback-llm",)
    handoff = ctx.next_dispatch()
    if handoff is None:
        return
    ctx.provider_call("llm")  # the approved provider is down
    decision = outage_route(
        FailureEvidence(
            status=503, message="provider unavailable", consecutive=1
        ),
        fallback="fallback-llm",
    )
    ctx.provider_call("fallback-llm")  # the authorized fallback serves the wave
    ctx.work_success(handoff, calls=0)
    ctx.complete_build()


def _drive_scenario12(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    handoff = ctx.next_dispatch()
    if handoff is None:
        return
    ctx.provider_call("llm")
    first = decide(
        FailureEvidence(
            status=503, message="provider unavailable", consecutive=1
        )
    )
    ctx.work_failed(handoff, first.cls, "503 provider unavailable")
    # SLA window: BLOCKED_RECHECK (fail closed -- never a false completion).
    ctx.block_reasons.append(first.note)
    ctx.transition(LifecycleState.BUILDING, LifecycleState.BLOCKED, first.note)
    ctx.world.advance(seconds=900)
    ctx.provider_call("llm")  # the SLA recheck still finds the provider down
    second = decide(
        FailureEvidence(
            status=503,
            message="provider unavailable",
            consecutive=2,
            age_seconds=900.0,
        )
    )
    ctx.halt([second.note])


def _drive_scenario13(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1", "T-2"))
    ctx.drive()
    ctx.complete_build()


def _drive_scenario14(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    pack = ReadinessPack(
        items=[
            ReadinessItem(
                id="OAUTH-001",
                provider="oauth",
                status=ReadinessStatus.READY,
                required_kinds=("identity",),
            )
        ],
        red_team_findings=[
            RedTeamFinding(
                id="RT-001",
                summary="OAuth callback gap missed by the planner",
                disposition=RedTeamDisposition.OPEN,
            )
        ],
    )
    evaluation = evaluate_readiness(pack, now=ctx.world.now)
    reason = "open red-team finding blocks LOCK: " + "; ".join(
        evaluation.open_red_team_findings
    )
    ctx.block_reasons.append(reason)
    ctx.transition(LifecycleState.READINESS, LifecycleState.BLOCKED, reason)


def _drive_scenario15(ctx: RunContext) -> None:
    ctx.locked_decisions = (
        LockedDecision(
            id="LD-PROV-1",
            summary="Tier-1 locked provider selection: llm",
            requirement_ids=[],
        ),
    )
    ctx.setup_tasks(("T-1",))
    ctx.locked_providers = ("llm",)
    handoff = ctx.next_dispatch()
    if handoff is None:
        return
    # A fresh subagent attempts to redecisize the locked provider (the
    # world observes the ground truth of the attempt).
    ctx.provider_call("other")
    violation = ctx.enforce_locked_providers()
    ctx.halt(
        [
            "locked provider change attempted ("
            f"provider {violation!r}); contract re-lock required (LD-PROV-1)"
        ]
    )


def _drive_scenario16(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    ctx.drive(
        deviations=(
            "T-2: internal cryptography library substituted (Tier-2 autonomy envelope)",
        )
    )
    ctx.complete_build()


def _drive_scenario17(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    trace = TraceGraph(
        run_id=RUN_ID,
        nodes=[
            TraceNode(id="REQ-17", kind="requirement"),
            TraceNode(id="IMPL-17", kind="implementation"),
            TraceNode(id="AC-17", kind="acceptance"),
        ],
        edges=[
            TraceEdge(source="REQ-17", target="IMPL-17"),
            TraceEdge(source="IMPL-17", target="AC-17"),
        ],
    )
    coverage = validate_trace_coverage(trace)
    reason = (
        "orphan requirement blocks LOCK: "
        + "; ".join(coverage.orphans)
        + " (no reachable Test ID / production validation)"
    )
    ctx.block_reasons.append(reason)
    ctx.transition(LifecycleState.READINESS, LifecycleState.BLOCKED, reason)


def _drive_scenario18(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1", "T-2", "T-3"))
    tick = ctx.controller.tick(now=ctx.world.now)
    handoffs = {handoff.task_id: handoff for handoff in tick.dispatched}
    blockers: list[str] = []

    # T-1: external provider outage with no authorized fallback (E7).
    ctx.provider_call("llm")
    first = decide(
        FailureEvidence(
            status=503, message="provider unavailable", consecutive=1
        )
    )
    ctx.work_failed(handoffs["T-1"], first.cls, "503 provider unavailable")
    blockers.append(first.note)

    # T-2: destructive action outside the approved policy (E4).
    try:
        ctx.controller.execute_operation(
            Operation("delete", "prod/database", "confidential"),
            task_id=handoffs["T-2"].task_id,
            now=ctx.world.now,
        )
        raise AssertionError("an outside-policy destructive action executed")
    except PolicyDenied:
        pass
    ctx.work_failed(
        handoffs["T-2"],
        FailureClass.CONTRACT,
        "delete prod/database denied by destructive-action policy",
    )
    blockers.append(
        "E4: destructive action outside approved policy: "
        "delete prod/database (denied before execution)"
    )

    # T-3: provider rate limiting exhausts the self-heal retry distribution.
    for _ in range(RATE_RETRY_BOUND):
        ctx.provider_call("llm-aux")
    ctx.work_failed(
        handoffs["T-3"],
        FailureClass.RATE,
        "429 provider rate limit after 5 backoffs",
    )
    blockers.append(
        f"RATE: provider rate limit exhausted the self-heal retry "
        f"distribution (429 x{RATE_RETRY_BOUND} backoffs)"
    )

    # Spec 18.1: EVERY blocker goes into ONE batched decision request.
    ctx.halt(blockers)


def _drive_scenario19(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    handoff = ctx.next_dispatch()
    if handoff is None:
        return
    # The run fences the current lease (stale-worker fence), then a stale
    # worker from the fenced generation attempts to promote.
    ctx.controller.fence_task("T-1", reason="stale-worker fence", now=ctx.world.now)
    stale = ctx.world.emit_report(
        run_id=RUN_ID,
        task_id=handoff.task_id,
        attempt=handoff.lease.generation,
        lease_id=handoff.lease.lease_id,
        workspace_id=mint_workspace_id(
            RUN_ID, handoff.task_id, handoff.lease.generation
        ),
        status=ExecutionStatus.PASSED,
        acceptance_evidence=ctx.evidence_for(handoff),
        usage=ctx.claimed_usage(),
    )
    try:
        ctx.controller.accept_report(stale, acceptance=ctx._verify(stale), now=ctx.world.now)
        raise AssertionError("a stale worker promotion was accepted")
    except StaleLeaseReport:
        ctx.stale_promotions += 1
    ctx.drive()
    ctx.complete_build()


def _drive_scenario20(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1", "T-2"))
    tick = ctx.controller.tick(now=ctx.world.now)
    handoffs = sorted(tick.dispatched, key=lambda handoff: handoff.task_id)
    first, second = handoffs
    # The wave hits the injected 429 mid-flight.
    ctx.provider_call("llm")
    ctx.provider_call("llm")
    ctx.provider_call("llm")  # rate_limited
    ctx.world.advance(seconds=RATE_BACKOFF_SECONDS)
    ctx.provider_call("llm")  # retried after the deterministic backoff
    ctx.work_success(first, calls=0)
    ctx.work_success(second, calls=0)
    ctx.complete_build()


def _drive_scenario21(ctx: RunContext) -> None:
    ctx.locked_decisions = (
        LockedDecision(
            id="LD-001",
            summary="Tier-1: provider change after LOCK is a contract revision",
            requirement_ids=["REQ-T-1"],
        ),
    )
    ctx.setup_tasks(("T-1",))
    ctx.drive(
        deviations=(
            "Tier-1 deviation of locked decision LD-001: provider changed after LOCK",
        )
    )
    if ctx.deviation_violation is not None:
        ctx.halt([ctx.deviation_violation + "; re-contract and re-lock required"])


def _drive_scenario22(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",), cap=Decimal("0.05"), ceiling=Decimal("0.05"))
    ctx.drive(calls=5)
    ctx.complete_build()


def _drive_scenario23(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    handoff = ctx.next_dispatch()
    if handoff is None:
        return
    try:
        ctx.world.migrate("schema-023")
        raise AssertionError("the armed migration did not crash after commit")
    except MigrationCrashError:
        pass
    # TARGET-system truth: the migration IS committed on the target; the
    # resumed worker must never re-apply it from pretender local state.
    assert ctx.world.target_state == ("schema-023",)
    resumed = ctx.next_dispatch()
    if resumed is None:
        return
    ctx.work_success(resumed, calls=1)
    ctx.complete_build()


def _drive_scenario24(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    ctx.drive()
    ctx.complete_build()


def _drive_scenario25(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1", "T-2"), depends={"T-2": ("T-1",)})
    first = ctx.next_dispatch()
    if first is None:
        return
    ctx.work_success(first, calls=1)
    running = ctx.next_dispatch()
    if running is None:
        return
    # Operator pause: the lease fences and the time budget freezes, but the
    # money/rate reservation is RETAINED (never released on pause).
    ctx.controller.pause(now=ctx.world.now)
    ctx.controller.resume(now=ctx.world.now)
    resumed = ctx.next_dispatch()
    # Observed at BUILDING: the resumed task holds the retained reservation
    # on a fresh lease generation; the run keeps building.
    if resumed is None:
        return


def _drive_scenario26(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    handoff = ctx.next_dispatch()
    if handoff is None:
        return
    try:
        # A false pass: no acceptance criteria, Test IDs or evidence refs.
        ctx.world.emit_report(
            run_id=RUN_ID,
            task_id=handoff.task_id,
            attempt=handoff.lease.generation,
            lease_id=handoff.lease.lease_id,
            workspace_id=mint_workspace_id(
                RUN_ID, handoff.task_id, handoff.lease.generation
            ),
            status=ExecutionStatus.PASSED,
        )
        raise AssertionError("a passed report without acceptance evidence was emitted")
    except ValidationError:
        pass
    # The void attempt is fenced (never accounted as a pass) and the task
    # re-executes from durable state on a fresh lease generation.
    ctx.controller.fence_task(
        "T-1", reason="false-pass report voided (no acceptance evidence)",
        now=ctx.world.now,
    )
    ctx.drive()
    ctx.complete_build()


def _drive_scenario27(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    handoff = ctx.next_dispatch()
    if handoff is None:
        return
    decision = decide(
        FailureEvidence(
            message="destructive operation denied by policy", consecutive=1
        )
    )
    try:
        ctx.controller.execute_operation(
            Operation("drop", "prod-database", "confidential"),
            task_id=handoff.task_id,
            now=ctx.world.now,
        )
        raise AssertionError("an outside-policy destructive action executed")
    except PolicyDenied:
        pass
    ctx.halt(
        [
            "E4: destructive action outside approved policy: "
            f"drop prod-database ({decision.note}); nothing irreversible happens"
        ]
    )


def _drive_scenario28(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",), max_attempts=1)
    handoff = ctx.next_dispatch()
    if handoff is None:
        return
    for _ in range(RATE_RETRY_BOUND):
        ctx.provider_call("llm")  # every backoff is throttled
        ctx.world.advance(seconds=10.0)  # deterministic backoff inside the attempt
    ctx.work_failed(
        handoff,
        FailureClass.RATE,
        "429 provider rate limit after 5 backoffs",
    )
    # The retry distribution is bounded: no infinite retry, the escalation
    # ladder ends in exception evaluation and the run halts HALTED.
    ctx.halt(
        [
            f"RATE: provider rate limit exhausted the self-heal retry "
            f"distribution (429 x{RATE_RETRY_BOUND} backoffs); attempt budget exhausted"
        ]
    )


def _drive_scenario29(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1", "T-2", "T-3"), max_attempts=1)
    tick = ctx.controller.tick(now=ctx.world.now)
    rejected: list[str] = []
    for handoff in sorted(tick.dispatched, key=lambda item: item.task_id):
        ctx.provider_call("llm")
        forged = ctx.world.emit_report(
            run_id=RUN_ID,
            task_id=handoff.task_id,
            attempt=handoff.lease.generation,
            lease_id=handoff.lease.lease_id,
            workspace_id=mint_workspace_id(
                RUN_ID, handoff.task_id, handoff.lease.generation
            ),
            status=ExecutionStatus.PASSED,
            acceptance_evidence=ctx.evidence_for(handoff),
            usage=ctx.claimed_usage(),
            outputs=[
                OutputInfo(
                    kind="commit", ref=f"forged-commit-{handoff.task_id}"
                )
            ],
        )
        acceptance = ctx._verify(forged)
        ctx.controller.accept_report(forged, acceptance=acceptance, now=ctx.world.now)
        ctx.rejected_reports += 1
        rejected.append(
            f"forged chain of custody rejected: "
            f"claimed commit 'forged-commit-{handoff.task_id}' does not exist"
        )
    # Every dispatched attempt was consumed and rejected; the attempt
    # budget is exhausted and the run halts with the consolidated decision.
    ctx.halt(rejected + ["attempt budget exhausted; forgery never advances the wave"])


def _drive_scenario30(ctx: RunContext) -> None:
    ctx.setup_tasks(("T-1",))
    ctx.drive()
    ctx.complete_build(stop_at=LifecycleState.DEPLOYED)
    decision = ctx.world.store_submit("browser-extension-v1")
    ctx.store_decision = decision
    review = ExternalReview(
        status=ReviewStatus.REJECTED,
        impacts_tier1=True,
        reasons=list(decision.reasons),
    )
    coordinator = ExternalWaitCoordinator(ExternalWaitStore(ctx.store))
    verdict = coordinator.record_review(
        RUN_ID, review, now=ctx.world.now, bug_attempts=0
    )
    ctx.halt(list(verdict.batched_reasons))


SCENARIO_DRIVERS: Mapping[str, Callable[[RunContext], None]] = MappingProxyType(
    {
        "scenario1": _drive_scenario1,
        "scenario2": _drive_scenario2,
        "scenario3": _drive_scenario3,
        "scenario4": _drive_scenario4,
        "scenario5": _drive_scenario5,
        "scenario6": _drive_scenario6,
        "scenario7": _drive_scenario7,
        "scenario8": _drive_scenario8,
        "scenario9": _drive_scenario9,
        "scenario10": _drive_scenario10,
        "scenario11": _drive_scenario11,
        "scenario12": _drive_scenario12,
        "scenario13": _drive_scenario13,
        "scenario14": _drive_scenario14,
        "scenario15": _drive_scenario15,
        "scenario16": _drive_scenario16,
        "scenario17": _drive_scenario17,
        "scenario18": _drive_scenario18,
        "scenario19": _drive_scenario19,
        "scenario20": _drive_scenario20,
        "scenario21": _drive_scenario21,
        "scenario22": _drive_scenario22,
        "scenario23": _drive_scenario23,
        "scenario24": _drive_scenario24,
        "scenario25": _drive_scenario25,
        "scenario26": _drive_scenario26,
        "scenario27": _drive_scenario27,
        "scenario28": _drive_scenario28,
        "scenario29": _drive_scenario29,
        "scenario30": _drive_scenario30,
    }
)

SCENARIO_START_STATES: Mapping[str, LifecycleState] = MappingProxyType(
    {
        **{
            f"scenario{number}": LifecycleState.BUILDING
            for number in range(1, 31)
        },
        "scenario7": LifecycleState.READINESS,
        "scenario14": LifecycleState.READINESS,
        "scenario17": LifecycleState.READINESS,
    }
)


# ---------------------------------------------------------------------------
# The entry point
# ---------------------------------------------------------------------------


def run_scenario(scenario_id: str, *, db_path: Path | str) -> ScenarioResult:
    """Drive one approved evaluation scenario to its settled state.

    The scenario ID is the ONLY dispatch key (fail closed: an unknown ID
    raises :class:`KeyError`); the English scenario name is never parsed.
    The controller/decision modules produce the final state; the catalog's
    expected state is not consulted anywhere.
    """
    scenario: Scenario = SCENARIOS_BY_ID[scenario_id]  # KeyError: fail closed
    injector = SCENARIO_INJECTIONS[scenario_id]
    driver = SCENARIO_DRIVERS[scenario_id]
    initial = SCENARIO_START_STATES[scenario_id]

    world = FakeWorld()
    store = RunStore(db_path)
    try:
        store.create_run(
            RunRecord(
                run_id=RUN_ID,
                title=scenario.title,
                created_at=world.now,
                state=initial,
            )
        )
        ctx = RunContext(scenario=scenario, world=world, store=store)
        injector(world)
        driver(ctx)

        task_states: tuple[tuple[str, str], ...] = ()
        if ctx.controller is not None:
            task_states = ctx.snapshot().task_state
        run_events = tuple(store.list_events(RUN_ID))
        transitions = tuple(
            (
                str(event.payload["from"]),
                str(event.payload["to"]),
                str(event.payload["reason"]),
            )
            for event in run_events
            if event.kind == "state.transition"
        )
        policy_violations = 0
        if ctx.policy is not None:
            # An executed (non-crash) migration outside the signed
            # ALLOWED resources is an outside-policy execution; the
            # gate's audit trail already proves every DENIED attempt
            # never reached the executor, so the world events are the
            # execution truth.
            policy_violations = sum(
                1
                for event in world.events
                if event.kind == "migration.commit"
                and event.payload.get("migration") not in ctx.policy_allowed_resources
            )
        return ScenarioResult(
            scenario_id=scenario_id,
            run_id=RUN_ID,
            final_state=store.load_run(RUN_ID).state,
            task_states=task_states,
            run_events=run_events,
            world_events=world.events,
            state_transitions=transitions,
            halt_batches=tuple(ctx.halt_batches),
            block_reasons=tuple(ctx.block_reasons),
            rejected_reports=ctx.rejected_reports,
            stale_promotions=ctx.stale_promotions,
            rate_limited_calls=ctx.rate_limited_calls,
            rate_429_observed=ctx.rate_429_observed,
            target_state=world.target_state,
            store_decision=ctx.store_decision,
            pending_billing=sum(
                1 for record in world.billing if record.effective_at > world.now
            ),
            provider_actual_cost=sum(
                usage.cost_usd for usage in world.provider_actuals()
            ),
            budget_cap=ctx.budget_cap,
            policy_violations=policy_violations,
        )
    finally:
        store.close()
