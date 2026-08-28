"""Behavioral contract for staging/production deployment + rollback.

Owned by ``test_deployment.py`` (see the KCC x Superpowers Hybrid
Framework Plan 05, Task 3: Staging/production deployment + rollback
contract, in
``.superpowers/bootstrap/plans/2026-08-27-05-resume-deploy-validation.task-contracts.md``).

A production deployment is an authorized, policy-classified, external
data-mutation operation (spec 14.3: production deployment and rollback
are recorded in the contract's explicit authority envelope; spec 14.5:
destructive operations classified before execution; spec 20.2:
production completion requires the contract-defined smoke/E2E
validation; spec 21: production deployment succeeds where authorized;
global contract: deploy and rollback MUST route through
``PolicyToolGate.call(Operation(...), args)`` -- DENIED never calls the
executor; AMBIGUOUS raises back to KCC machine interpretation, never a
direct user prompt; ruling R10: no extra approval gates). The
:class:`~kcc_autobuild.deployment.DeploymentAdapter` is the target-system
view that never holds policy authority (``data_class`` classification,
``health`` target truth, and the raw ``deploy`` / ``rollback`` mutations
invoked ONLY by the gate's executor);
:class:`~kcc_autobuild.deployment.DeploymentCoordinator` is the pure
decision + routing function for one deployment:

* the rollout class is taken from the LOCKED contract
  (``contract.tier1.rollout_class``); a caller-supplied
  ``requested_rollout`` that differs from the locked class raises
  (``RolloutMismatchError``) before anything happens -- an explicit
  request may never overrule what was locked (e.g. direct is rejected
  when canary is locked);
* the production target comes from
  ``contract.tier1.production_target`` and is the exact policy resource
  of BOTH operations (deploy and, on failure, rollback the SAME target);
* the production deploy operation goes through ``gate.call``; then the
  adapter's health check decides: healthy => DEPLOYED, unhealthy =>
  one rollback operation on the same target => ROLLED_BACK.

Prescribed scenario: canary health failure auto rollback -- the canary
deploy lands, the post-deploy health check fails, and the coordinator
immediately gates a rollback of the same production target.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

import pytest

from kcc_autobuild.contract import (
    AuthorityEnvelope,
    BuildContract,
    MoneyPolicy,
    RolloutClass as ContractRolloutClass,
    Tier1Invariants,
    lock_contract,
)
from kcc_autobuild.deployment import (
    DEPLOY_OPERATION,
    ROLLBACK_OPERATION,
    DeploymentAdapter,
    DeploymentConfigError,
    DeploymentContractError,
    DeploymentCoordinator,
    DeploymentError,
    DeploymentOutcome,
    RolloutClass,
    RolloutMismatchError,
)
from kcc_autobuild.models import ReadinessStatus
from kcc_autobuild.policy import (
    Operation,
    PolicyDecision,
    PolicyEvaluator,
    PolicyRule,
    sign_policy_bundle,
)
from kcc_autobuild.readiness import EvidenceRecord, ReadinessItem, ReadinessPack
from kcc_autobuild.tool_gate import AmbiguousPolicy, PolicyDenied, PolicyToolGate
from kcc_autobuild.trace import TraceEdge, TraceGraph, TraceNode

SECRET = "unit-test-deployment-secret"

PRODUCTION_TARGET = "prod/kcc-demo"
DATA_CLASS = "PERSONAL"


class _FakeDeploymentAdapter:
    """Target-system stand-in implementing the DeploymentAdapter protocol.

    ``data_class`` is the data sensitivity classification of the
    production target, ``healthy`` the post-deploy health truth;
    ``deploy`` / ``rollback`` are raw mutations recorded with the gate's
    unique policy decision token (they are invoked exclusively by the
    gate executor, never by the coordinator).
    """

    def __init__(
        self,
        *,
        data_class: str = DATA_CLASS,
        healthy: bool = True,
    ) -> None:
        self.data_class = data_class
        self.healthy = healthy
        self.deploys: list[tuple[str, RolloutClass, str]] = []
        self.rollbacks: list[tuple[str, str]] = []
        self.health_checks: list[str] = []

    def health(self, target: str) -> bool:
        self.health_checks.append(target)
        return self.healthy

    def deploy(self, target: str, rollout: RolloutClass, token: str) -> None:
        self.deploys.append((target, rollout, token))

    def rollback(self, target: str, token: str) -> None:
        self.rollbacks.append((target, token))


class _FakeTier1:
    """The tier-1 lock surface the coordinator reads (duck-typed)."""

    def __init__(
        self,
        *,
        rollout_class: object = RolloutClass.CANARY,
        production_target: object = PRODUCTION_TARGET,
    ) -> None:
        self.rollout_class = rollout_class
        self.production_target = production_target


class _FakeContract:
    """The locked-contract view the coordinator receives."""

    def __init__(self, tier1: _FakeTier1 | None = None) -> None:
        self.tier1 = tier1 or _FakeTier1()


def _contract(
    *,
    rollout_class: object = RolloutClass.CANARY,
    production_target: object = PRODUCTION_TARGET,
) -> _FakeContract:
    return _FakeContract(
        _FakeTier1(rollout_class=rollout_class, production_target=production_target)
    )


class _CountingGate:
    """Raw call recorder for the pure gate contract checks."""

    def __init__(self) -> None:
        self.calls: list[tuple[Operation, Mapping[str, object]]] = []

    def call(self, operation: Operation, args: Mapping[str, object]) -> Any:
        self.calls.append((operation, dict(args)))


class _PolicyCallGate:
    """Adapter-facing ``call(operation, args)`` over the one real gate.

    The coordinator MUST route every deploy/rollback mutation through
    ``gate.call``; this facade wraps the single
    :class:`~kcc_autobuild.tool_gate.PolicyToolGate` (raw mutation clients
    are never handed to adapters) and records the exact
    ``(operation, args)`` the coordinator issued so the tests can pin the
    routing contract.
    """

    def __init__(self, gate: PolicyToolGate, current: dict[str, Any]) -> None:
        if not isinstance(gate, PolicyToolGate):
            raise TypeError(
                "the call facade requires a PolicyToolGate, not a raw client"
            )
        self.gate = gate
        self.current = current
        self.calls: list[tuple[Operation, Mapping[str, object]]] = []

    def call(self, operation: Operation, args: Mapping[str, object]) -> Any:
        self.calls.append((operation, dict(args)))
        self.current.clear()
        self.current.update(args)
        return self.gate.execute(operation)


def _allowed_gate(
    adapter: _FakeDeploymentAdapter,
    *,
    target: str = PRODUCTION_TARGET,
    data_class: str = DATA_CLASS,
    deploy_rule: PolicyRule | None = None,
    rollback_rule: PolicyRule | None = None,
    tokens: list[str] | None = None,
    token_factory: Any = None,
) -> _PolicyCallGate:
    """Build the real gate bound to the adapter's raw mutations."""
    if deploy_rule is None:
        deploy_rule = PolicyRule(
            DEPLOY_OPERATION, target, data_class, PolicyDecision.ALLOWED
        )
    if rollback_rule is None:
        rollback_rule = PolicyRule(
            ROLLBACK_OPERATION, target, data_class, PolicyDecision.ALLOWED
        )
    evaluator = PolicyEvaluator(
        sign_policy_bundle([deploy_rule, rollback_rule], SECRET), SECRET
    )
    issued: list[str] = tokens if tokens is not None else []
    current: dict[str, Any] = {}

    def executor(operation: Operation, token: str) -> None:
        issued.append(token)
        if operation.operation == DEPLOY_OPERATION:
            adapter.deploy(
                current["target"], RolloutClass(current["rollout_class"]), token
            )
        elif operation.operation == ROLLBACK_OPERATION:
            adapter.rollback(current["target"], token)
        else:
            raise AssertionError(
                f"unexpected mutation verb {operation.operation!r}"
            )

    if token_factory is None:
        def token_factory() -> str:
            return f"dep-tok-{len(issued) + 1}"

    return _PolicyCallGate(
        PolicyToolGate(evaluator, executor, token_factory=token_factory), current
    )


# --- Types: RolloutClass / DeploymentOutcome / canonical verbs ---------------


def test_rollout_class_is_canonical():
    assert RolloutClass.CANARY.value == "CANARY"
    assert RolloutClass.DIRECT.value == "DIRECT"
    assert RolloutClass.CANARY == "CANARY"
    assert RolloutClass.DIRECT == "DIRECT"


def test_deployment_outcome_is_canonical():
    assert DeploymentOutcome.DEPLOYED.value == "DEPLOYED"
    assert DeploymentOutcome.ROLLED_BACK.value == "ROLLED_BACK"
    assert DeploymentOutcome.DEPLOYED == "DEPLOYED"
    assert DeploymentOutcome.ROLLED_BACK == "ROLLED_BACK"


def test_deployment_operation_verbs_are_pinned():
    # The policy-classified verbs for production deploy and rollback
    # (spec 14.5/24: destroyed-mutating calls are classified before
    # execution; deploy and rollback are distinct operations).
    assert DEPLOY_OPERATION == "deploy"
    assert ROLLBACK_OPERATION == "rollback"


# --- Adapter protocol --------------------------------------------------------


def test_adapter_protocol_is_runtime_checkable():
    assert isinstance(_FakeDeploymentAdapter(), DeploymentAdapter)
    assert not isinstance(object(), DeploymentAdapter)


def test_coordinator_rejects_non_adapter():
    with pytest.raises(TypeError):
        DeploymentCoordinator(adapter=object(), gate=_CountingGate())  # type: ignore[arg-type]


def test_coordinator_rejects_gate_without_call():
    class _RawClientGate:
        pass

    with pytest.raises(TypeError):
        DeploymentCoordinator(  # type: ignore[arg-type]
            adapter=_FakeDeploymentAdapter(), gate=_RawClientGate()
        )


# --- Locked-contract discipline ----------------------------------------------


def test_contract_without_tier1_is_rejected():
    class _NoTier1:
        pass

    coordinator = DeploymentCoordinator(
        adapter=_FakeDeploymentAdapter(), gate=_CountingGate()
    )
    with pytest.raises(DeploymentContractError):
        coordinator.deploy(_NoTier1())  # type: ignore[arg-type]


def test_contract_without_locked_rollout_class_is_rejected():
    class _BareTier1:
        production_target = PRODUCTION_TARGET

    class _Contract:
        tier1 = _BareTier1()

    coordinator = DeploymentCoordinator(
        adapter=_FakeDeploymentAdapter(), gate=_CountingGate()
    )
    with pytest.raises(DeploymentContractError):
        coordinator.deploy(_Contract())  # type: ignore[arg-type]


def test_contract_with_unknown_locked_rollout_class_is_rejected():
    coordinator = DeploymentCoordinator(
        adapter=_FakeDeploymentAdapter(), gate=_CountingGate()
    )
    with pytest.raises(DeploymentContractError):
        coordinator.deploy(_contract(rollout_class="bluegreen"))  # type: ignore[arg-type]


def test_contract_without_production_target_is_rejected():
    coordinator = DeploymentCoordinator(
        adapter=_FakeDeploymentAdapter(), gate=_CountingGate()
    )
    with pytest.raises(DeploymentContractError):
        coordinator.deploy(_contract(production_target=None))  # type: ignore[arg-type]


def test_contract_with_blank_production_target_is_rejected():
    coordinator = DeploymentCoordinator(
        adapter=_FakeDeploymentAdapter(), gate=_CountingGate()
    )
    with pytest.raises(DeploymentContractError):
        coordinator.deploy(_contract(production_target="  "))  # type: ignore[arg-type]


def test_coordinator_rejects_blank_adapter_data_class():
    # A misconfigured target view (no data sensitivity classification)
    # is a DeploymentError subclass, never a raw ValueError/TypeError:
    # without a real data_class the policy gate cannot authorize the
    # production operation, so nothing may be routed.
    adapter = _FakeDeploymentAdapter(data_class="")
    gate = _CountingGate()
    coordinator = DeploymentCoordinator(adapter=adapter, gate=gate)
    with pytest.raises(DeploymentConfigError) as excinfo:
        coordinator.deploy(_contract())
    assert isinstance(excinfo.value, DeploymentError)
    assert "data_class" in str(excinfo.value)
    assert gate.calls == []
    assert adapter.deploys == []
    assert adapter.rollbacks == []


def test_coordinator_rejects_none_adapter_data_class():
    adapter = _FakeDeploymentAdapter(data_class=None)  # type: ignore[arg-type]
    coordinator = DeploymentCoordinator(adapter=adapter, gate=_CountingGate())
    with pytest.raises(DeploymentConfigError):
        coordinator.deploy(_contract())


def test_coordinator_rejects_non_string_adapter_data_class():
    adapter = _FakeDeploymentAdapter(data_class=42)  # type: ignore[arg-type]
    coordinator = DeploymentCoordinator(adapter=adapter, gate=_CountingGate())
    with pytest.raises(DeploymentConfigError):
        coordinator.deploy(_contract())


# --- Requested rollout vs locked rollout -------------------------------------


def test_direct_rejected_when_canary_locked():
    # Prescribed scenario: canary is the locked rollout class and an
    # explicit DIRECT request may never overrule the lock. Fails closed
    # BEFORE any gate call or mutation.
    adapter = _FakeDeploymentAdapter()
    gate = _allowed_gate(adapter)
    coordinator = DeploymentCoordinator(adapter=adapter, gate=gate)
    with pytest.raises(RolloutMismatchError) as excinfo:
        coordinator.deploy(_contract(rollout_class=RolloutClass.CANARY), RolloutClass.DIRECT)
    assert excinfo.value.locked is RolloutClass.CANARY
    assert excinfo.value.requested is RolloutClass.DIRECT
    assert gate.calls == []
    assert gate.gate.audits == []
    assert adapter.deploys == []
    assert adapter.rollbacks == []
    assert adapter.health_checks == []


def test_requested_matching_locked_rollout_is_allowed():
    # Explicitly requesting the locked class is not a mismatch: the lock
    # wins and the deploy proceeds as normal.
    adapter = _FakeDeploymentAdapter(healthy=True)
    gate = _allowed_gate(adapter)
    outcome = DeploymentCoordinator(adapter=adapter, gate=gate).deploy(
        _contract(rollout_class=RolloutClass.CANARY), RolloutClass.CANARY
    )
    assert outcome is DeploymentOutcome.DEPLOYED
    assert len(gate.calls) == 1
    assert adapter.deploys == [
        (PRODUCTION_TARGET, RolloutClass.CANARY, "dep-tok-1")
    ]


def test_requested_rollout_of_unknown_class_is_rejected():
    adapter = _FakeDeploymentAdapter()
    gate = _allowed_gate(adapter)
    coordinator = DeploymentCoordinator(adapter=adapter, gate=gate)
    with pytest.raises(ValueError):
        coordinator.deploy(_contract(), "bluegreen")  # type: ignore[arg-type]
    assert gate.calls == []
    assert adapter.deploys == []


# --- Deploy path: locked class + production target through the gate ----------


def test_default_rollout_uses_the_locked_class():
    # No requested rollout: the coordinator must use the locked
    # contract.tier1.rollout_class, never an implicit default.
    adapter = _FakeDeploymentAdapter()
    gate = _allowed_gate(adapter)
    outcome = DeploymentCoordinator(adapter=adapter, gate=gate).deploy(
        _contract(rollout_class=RolloutClass.CANARY)
    )
    assert outcome is DeploymentOutcome.DEPLOYED
    assert gate.calls == [
        (
            Operation(
                operation=DEPLOY_OPERATION,
                resource=PRODUCTION_TARGET,
                data_class=DATA_CLASS,
            ),
            {"target": PRODUCTION_TARGET, "rollout_class": "CANARY"},
        )
    ]


def test_canary_deploy_healthy_is_deployed():
    adapter = _FakeDeploymentAdapter(healthy=True)
    gate = _allowed_gate(adapter)
    outcome = DeploymentCoordinator(adapter=adapter, gate=gate).deploy(
        _contract(rollout_class=RolloutClass.CANARY)
    )
    assert outcome is DeploymentOutcome.DEPLOYED
    # Exactly one deploy mutation, correlated with the one audit token;
    # no rollback, health checked once on the production target.
    assert adapter.deploys == [
        (PRODUCTION_TARGET, RolloutClass.CANARY, "dep-tok-1")
    ]
    assert adapter.rollbacks == []
    assert adapter.health_checks == [PRODUCTION_TARGET]
    assert len(gate.gate.audits) == 1
    assert gate.gate.audits[0].token == "dep-tok-1"


def test_direct_rollout_deploys_when_locked_direct():
    adapter = _FakeDeploymentAdapter(healthy=True)
    gate = _allowed_gate(adapter)
    outcome = DeploymentCoordinator(adapter=adapter, gate=gate).deploy(
        _contract(rollout_class=RolloutClass.DIRECT)
    )
    assert outcome is DeploymentOutcome.DEPLOYED
    assert gate.calls[0][1]["rollout_class"] == "DIRECT"
    assert adapter.deploys == [
        (PRODUCTION_TARGET, RolloutClass.DIRECT, "dep-tok-1")
    ]
    assert adapter.rollbacks == []
    assert adapter.health_checks == [PRODUCTION_TARGET]


def test_locked_canary_class_from_canonical_string_is_accepted():
    adapter = _FakeDeploymentAdapter()
    gate = _allowed_gate(adapter)
    outcome = DeploymentCoordinator(adapter=adapter, gate=gate).deploy(
        _contract(rollout_class="CANARY")
    )
    assert outcome is DeploymentOutcome.DEPLOYED
    assert adapter.deploys == [
        (PRODUCTION_TARGET, RolloutClass.CANARY, "dep-tok-1")
    ]


# --- Health failure => rollback the same target ------------------------------


def test_canary_health_failure_auto_rollback():
    # Prescribed scenario: the canary deploy lands, the post-deploy
    # health check fails, and the coordinator immediately routes ONE
    # rollback of the SAME production target through the gate and
    # reports ROLLED_BACK.
    adapter = _FakeDeploymentAdapter(healthy=False)
    gate = _allowed_gate(adapter)
    outcome = DeploymentCoordinator(adapter=adapter, gate=gate).deploy(
        _contract(rollout_class=RolloutClass.CANARY)
    )
    assert outcome is DeploymentOutcome.ROLLED_BACK
    # Deploy first, then rollback -- separate policy-classified
    # operations, both on the exact production target.
    assert gate.calls == [
        (
            Operation(
                operation=DEPLOY_OPERATION,
                resource=PRODUCTION_TARGET,
                data_class=DATA_CLASS,
            ),
            {"target": PRODUCTION_TARGET, "rollout_class": "CANARY"},
        ),
        (
            Operation(
                operation=ROLLBACK_OPERATION,
                resource=PRODUCTION_TARGET,
                data_class=DATA_CLASS,
            ),
            {"target": PRODUCTION_TARGET},
        ),
    ]
    assert adapter.deploys == [
        (PRODUCTION_TARGET, RolloutClass.CANARY, "dep-tok-1")
    ]
    assert adapter.rollbacks == [(PRODUCTION_TARGET, "dep-tok-2")]
    # Health is checked once, after the deploy, before the rollback.
    assert adapter.health_checks == [PRODUCTION_TARGET]
    # Two separate policy decisions, each with its own unique token.
    assert len(gate.gate.audits) == 2
    assert [audit.token for audit in gate.gate.audits] == ["dep-tok-1", "dep-tok-2"]
    assert all(
        audit.decision is PolicyDecision.ALLOWED for audit in gate.gate.audits
    )


def test_health_failure_rolls_back_when_locked_direct_too():
    adapter = _FakeDeploymentAdapter(healthy=False)
    gate = _allowed_gate(adapter)
    outcome = DeploymentCoordinator(adapter=adapter, gate=gate).deploy(
        _contract(rollout_class=RolloutClass.DIRECT)
    )
    assert outcome is DeploymentOutcome.ROLLED_BACK
    assert gate.calls[1][0] == Operation(
        operation=ROLLBACK_OPERATION,
        resource=PRODUCTION_TARGET,
        data_class=DATA_CLASS,
    )
    assert adapter.rollbacks == [(PRODUCTION_TARGET, "dep-tok-2")]
    assert len(gate.gate.audits) == 2


# --- Gate discipline: DENIED / AMBIGUOUS never call the mutation -------------


def test_denied_deploy_never_invokes_the_mutation():
    adapter = _FakeDeploymentAdapter()
    gate = _allowed_gate(
        adapter,
        deploy_rule=PolicyRule(
            DEPLOY_OPERATION, PRODUCTION_TARGET, DATA_CLASS, PolicyDecision.DENIED
        ),
    )
    coordinator = DeploymentCoordinator(adapter=adapter, gate=gate)
    with pytest.raises(PolicyDenied):
        coordinator.deploy(_contract())
    assert adapter.deploys == []  # the raw mutation never ran
    assert adapter.rollbacks == []
    assert adapter.health_checks == []  # health is target truth AFTER a deploy
    assert gate.gate.audits[-1].decision is PolicyDecision.DENIED


def test_ambiguous_deploy_raises_back_to_machine_interpretation():
    adapter = _FakeDeploymentAdapter()
    # Same operation under a different resource => AMBIGUOUS, never a
    # user prompt (spec 4.5/18; ruling R10: no extra approval gates).
    gate = _allowed_gate(
        adapter,
        deploy_rule=PolicyRule(
            DEPLOY_OPERATION, "staging/kcc-demo", DATA_CLASS, PolicyDecision.ALLOWED
        ),
    )
    coordinator = DeploymentCoordinator(adapter=adapter, gate=gate)
    with pytest.raises(AmbiguousPolicy) as excinfo:
        coordinator.deploy(_contract())
    assert adapter.deploys == []
    assert adapter.rollbacks == []
    assert adapter.health_checks == []
    assert excinfo.value.operation.operation == DEPLOY_OPERATION
    assert excinfo.value.decision is PolicyDecision.AMBIGUOUS
    assert gate.gate.audits[-1].decision is PolicyDecision.AMBIGUOUS


def test_denied_rollback_never_invokes_the_rollback_mutation():
    adapter = _FakeDeploymentAdapter(healthy=False)
    gate = _allowed_gate(
        adapter,
        rollback_rule=PolicyRule(
            ROLLBACK_OPERATION, PRODUCTION_TARGET, DATA_CLASS, PolicyDecision.DENIED
        ),
    )
    coordinator = DeploymentCoordinator(adapter=adapter, gate=gate)
    with pytest.raises(PolicyDenied):
        coordinator.deploy(_contract())
    # The deploy happened once; the rollback was DENIED and never ran --
    # the failure propagates fail-closed instead of reporting ROLLED_BACK.
    assert adapter.deploys == [(PRODUCTION_TARGET, RolloutClass.CANARY, "dep-tok-1")]
    assert adapter.rollbacks == []
    assert len(gate.gate.audits) == 2
    assert gate.gate.audits[-1].decision is PolicyDecision.DENIED


def test_executor_receives_the_policy_audit_tokens():
    adapter = _FakeDeploymentAdapter(healthy=False)
    gate = _allowed_gate(adapter)
    DeploymentCoordinator(adapter=adapter, gate=gate).deploy(_contract())
    assert len(gate.gate.audits) == 2
    # Each mutation call is correlated with the same unique decision
    # token its gate decision logged BEFORE invoking the executor.
    assert adapter.deploys[0][2] == gate.gate.audits[0].token
    assert adapter.rollbacks[0][1] == gate.gate.audits[1].token


# --- Real locked BuildContract integration -----------------------------------
# The coordinator must be operable against the ACTUAL contract model: the
# rollout class and production target are Tier-1 locked invariants on
# :class:`~kcc_autobuild.contract.Tier1Invariants` (StrictModel forbids
# extra fields), so the duck-typed fakes above cannot hide a gap between
# the coordinator and a genuinely locked BuildContract.  These tests lock
# a real contract via :func:`~kcc_autobuild.contract.lock_contract` and
# run the full deploy + rollback path against it.


REAL_NOW = datetime(2026, 1, 2, 12, 0, 0, tzinfo=timezone.utc)
EVIDENCE_TTL = timedelta(hours=4)


def _real_trace() -> TraceGraph:
    """A trace where REQ-001 reaches both AC and PROD coverage."""
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


def _real_readiness() -> ReadinessPack:
    """Evidence-backed ready pack so the fixture is lockable."""
    return ReadinessPack(
        items=[
            ReadinessItem(
                id="IT-001",
                provider="provider-a",
                status=ReadinessStatus.READY,
                required_kinds=["identity"],
                evidence=[
                    EvidenceRecord(
                        kind="identity",
                        result="pass",
                        checked_at=REAL_NOW,
                        resource_ids=["resource-1"],
                        scopes=["scopes:read"],
                    )
                ],
                evidence_ttl=EVIDENCE_TTL,
            )
        ]
    )


def _locked_real_contract(
    *,
    rollout_class: object = RolloutClass.CANARY,
    production_target: object = PRODUCTION_TARGET,
    production_deployment: bool = True,
) -> BuildContract:
    """A genuinely locked BuildContract carrying the Tier-1 rollout lock.

    ``rollout_class`` is a real Tier-1 field -- the lock only succeeds
    (and the hash covers it) because the contract model owns it.
    """
    contract = BuildContract(
        tier1=Tier1Invariants(
            product_scope="internal CLI analysis tool",
            non_goals=["no public API"],
            primary_user_journeys=["run one analysis end to end"],
            authority=AuthorityEnvelope(
                production_deployment=production_deployment,
                rollback=production_deployment,
            ),
            money=MoneyPolicy(),
            production_target=production_target,
            rollout_class=rollout_class,
            definition_of_done=(
                "analysis output is produced end to end and validated in staging"
            ),
        ),
        trace=_real_trace(),
        readiness=_real_readiness(),
    )
    return lock_contract(contract, now=REAL_NOW)


def test_deployment_uses_the_contract_model_rollout_vocabulary():
    # ONE canonical rollout vocabulary: the enum the coordinator consumes
    # IS the enum locked into Tier1Invariants, never a parallel copy that
    # could diverge from what the contract model validates.
    assert RolloutClass is ContractRolloutClass


def test_real_locked_canary_contract_deploys_through_the_gate():
    # The full happy path against a genuinely locked BuildContract: the
    # locked tier1.rollout_class drives the deploy operation, the locked
    # production_target is the exact policy resource, and the post-deploy
    # health check passes => DEPLOYED.
    adapter = _FakeDeploymentAdapter(healthy=True)
    gate = _allowed_gate(adapter)
    contract = _locked_real_contract()
    outcome = DeploymentCoordinator(adapter=adapter, gate=gate).deploy(contract)
    assert outcome is DeploymentOutcome.DEPLOYED
    assert contract.tier1.rollout_class is RolloutClass.CANARY
    assert gate.calls == [
        (
            Operation(
                operation=DEPLOY_OPERATION,
                resource=PRODUCTION_TARGET,
                data_class=DATA_CLASS,
            ),
            {"target": PRODUCTION_TARGET, "rollout_class": "CANARY"},
        )
    ]
    assert adapter.deploys == [
        (PRODUCTION_TARGET, RolloutClass.CANARY, "dep-tok-1")
    ]
    assert adapter.rollbacks == []
    assert adapter.health_checks == [PRODUCTION_TARGET]


def test_real_locked_canary_health_failure_auto_rolls_back():
    # Prescribed scenario against a real locked contract: the canary
    # deploy lands, health fails, and the coordinator gates a rollback of
    # the same locked production target => ROLLED_BACK.
    adapter = _FakeDeploymentAdapter(healthy=False)
    gate = _allowed_gate(adapter)
    outcome = DeploymentCoordinator(adapter=adapter, gate=gate).deploy(
        _locked_real_contract()
    )
    assert outcome is DeploymentOutcome.ROLLED_BACK
    assert gate.calls[0][0] == Operation(
        operation=DEPLOY_OPERATION,
        resource=PRODUCTION_TARGET,
        data_class=DATA_CLASS,
    )
    assert gate.calls[1][0] == Operation(
        operation=ROLLBACK_OPERATION,
        resource=PRODUCTION_TARGET,
        data_class=DATA_CLASS,
    )
    assert gate.calls[1][1] == {"target": PRODUCTION_TARGET}
    assert adapter.deploys == [
        (PRODUCTION_TARGET, RolloutClass.CANARY, "dep-tok-1")
    ]
    assert adapter.rollbacks == [(PRODUCTION_TARGET, "dep-tok-2")]
    assert adapter.health_checks == [PRODUCTION_TARGET]


def test_real_locked_canary_rejects_direct_request():
    # "direct rejected when canary locked" against a real locked
    # BuildContract: the Tier-1 lock wins and nothing is routed.
    adapter = _FakeDeploymentAdapter()
    gate = _allowed_gate(adapter)
    coordinator = DeploymentCoordinator(adapter=adapter, gate=gate)
    with pytest.raises(RolloutMismatchError) as excinfo:
        coordinator.deploy(_locked_real_contract(), RolloutClass.DIRECT)
    assert excinfo.value.locked is RolloutClass.CANARY
    assert excinfo.value.requested is RolloutClass.DIRECT
    assert gate.calls == []
    assert adapter.deploys == []
    assert adapter.rollbacks == []
    assert adapter.health_checks == []


def test_real_contract_uses_its_locked_production_target():
    # The exact production_target locked into Tier 1 is the policy
    # resource of the operation -- not a default and not the adapter's.
    target = "prod/app-internal"
    adapter = _FakeDeploymentAdapter()
    gate = _allowed_gate(adapter, target=target)
    outcome = DeploymentCoordinator(adapter=adapter, gate=gate).deploy(
        _locked_real_contract(production_target=target)
    )
    assert outcome is DeploymentOutcome.DEPLOYED
    assert gate.calls[0][0].resource == target
    assert gate.calls[0][1] == {"target": target, "rollout_class": "CANARY"}
    assert adapter.deploys == [(target, RolloutClass.CANARY, "dep-tok-1")]
    assert adapter.health_checks == [target]


def test_real_locked_contract_without_rollout_lock_refuses_deployment():
    # A genuinely locked contract that never authorized production
    # deployment carries no locked rollout class; deploying against it
    # must fail closed before any gate call, even though the contract
    # itself is legitimately locked.
    contract = _locked_real_contract(
        production_deployment=False, rollout_class=None
    )
    assert contract.locked_at is not None
    assert contract.contract_hash is not None
    gate = _CountingGate()
    coordinator = DeploymentCoordinator(
        adapter=_FakeDeploymentAdapter(), gate=gate
    )
    with pytest.raises(DeploymentContractError):
        coordinator.deploy(contract)
    assert gate.calls == []
