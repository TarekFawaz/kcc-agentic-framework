"""Behavioral contract for the policy tool gate (sole mutation executor path).

Owned by ``test_tool_gate.py`` (see the KCC x Superpowers Hybrid Framework Plan
04, Task 6: Deterministic destructive-operation policy evaluator, in
``.superpowers/bootstrap/plans/2026-08-27-04-scheduler-budget-rate-policy.task-contracts.md``).

:class:`~kcc_autobuild.tool_gate.PolicyToolGate` is the ONLY external /
data-mutation executor path: any provider, deploy or migration mutation
adapter receives the (already policy-bound) gate, never a raw client. For
every attempted execution the gate:

- evaluates the :class:`~kcc_autobuild.policy.Operation` against the signed
  ``PolicyBundle`` (policy.py), and
- logs a unique policy decision token / audit record BEFORE any executor
  invocation (audit first, then call), so every mutation is traceable to a
  single signed policy decision;
- ALLOWED -> invokes the wrapped executor exactly once, passing the decision
  token for correlation;
- DENIED -> raises :class:`PolicyDenied` and NEVER invokes the executor;
- AMBIGUOUS -> raises :class:`AmbiguousPolicy` back to KCC machine
  interpretation (spec 18/E4 path) -- a structured, machine-readable error,
  never a direct user prompt (spec 4.5 notifications-not-approvals; ruling
  R10: no extra approval gates), and never invokes the executor.
"""

from __future__ import annotations

import pytest

from kcc_autobuild.policy import (
    Operation,
    PolicyDecision,
    PolicyEvaluator,
    PolicyRule,
    sign_policy_bundle,
)
from kcc_autobuild.tool_gate import (
    AmbiguousPolicy,
    PolicyAudit,
    PolicyDenied,
    PolicyGateError,
    PolicyToolGate,
)

SECRET = "unit-test-gate-secret"

ALLOW_DEPLOY_PUBLIC = PolicyRule("deploy", "prod/app", "PUBLIC", PolicyDecision.ALLOWED)
DENY_DEPLOY_PERSONAL = PolicyRule("deploy", "prod/app", "PERSONAL", PolicyDecision.DENIED)


def build_gate(
    rules,
    executor,
    *,
    sink=None,
    token_factory=None,
    secret=SECRET,
):
    evaluator = PolicyEvaluator(sign_policy_bundle(rules, secret), secret)
    return PolicyToolGate(
        evaluator,
        executor=executor,
        audit_sink=sink,
        token_factory=token_factory,
    )


class RecordingSink:
    """Audit sink that records every :class:`PolicyAudit`, in call order."""

    def __init__(self, events=None):
        self.records = []
        self.events = events if events is not None else []

    def record(self, audit):
        self.records.append(audit)
        self.events.append(("audit", audit.token))


class RecordingExecutor:
    """Stand-in for a raw provider/deploy/migration client (never callable
    directly by an adapter; only the gate may invoke it)."""

    def __init__(self, events=None):
        self.calls = []
        self.events = events if events is not None else []

    def __call__(self, operation, token):
        self.calls.append((operation, token))
        self.events.append(("executor", token))
        return f"done:{operation.operation}:{operation.resource}"


# --- ALLOWED: audit first, then the single executor invocation ---------------


def test_allowed_logs_audit_before_calling_executor():
    events = []
    executor = RecordingExecutor(events)
    sink = RecordingSink(events)
    deploy = Operation("deploy", "prod/app", "PUBLIC")
    gate = build_gate(
        [ALLOW_DEPLOY_PUBLIC],
        executor,
        sink=sink,
        token_factory=lambda: "tok-1",
    )

    result = gate.execute(deploy)

    assert result == "done:deploy:prod/app"
    assert executor.calls == [(deploy, "tok-1")]
    # The audit record exists BEFORE the executor was invoked (no side effect
    # can occur without a prior policy decision record).
    assert events == [("audit", "tok-1"), ("executor", "tok-1")]
    assert len(sink.records) == 1
    audit = sink.records[0]
    assert audit.token == "tok-1"
    assert audit.decision is PolicyDecision.ALLOWED
    assert audit.operation == deploy
    assert gate.audits == [audit]


def test_allowed_without_sink_records_into_gate_audit_trail():
    executor = RecordingExecutor()
    gate = build_gate(
        [ALLOW_DEPLOY_PUBLIC], executor, token_factory=lambda: "tok-1"
    )
    gate.execute(Operation("deploy", "prod/app", "PUBLIC"))
    assert [audit.token for audit in gate.audits] == ["tok-1"]
    assert len(gate.audits) == 1


# --- DENIED: never calls the executor ---------------------------------------


def test_denied_never_calls_executor_and_raises():
    events = []
    executor = RecordingExecutor(events)
    sink = RecordingSink(events)
    gate = build_gate(
        [DENY_DEPLOY_PERSONAL],
        executor,
        sink=sink,
        token_factory=lambda: "tok-2",
    )

    with pytest.raises(PolicyDenied) as exc:
        gate.execute(Operation("deploy", "prod/app", "PERSONAL"))

    assert executor.calls == []
    assert events == [("audit", "tok-2")]  # decision logged, executor never touched
    denied = exc.value
    assert denied.token == "tok-2"
    assert denied.decision is PolicyDecision.DENIED
    assert denied.operation == Operation("deploy", "prod/app", "PERSONAL")
    assert isinstance(denied, PolicyGateError)
    assert sink.records[0].decision is PolicyDecision.DENIED


def test_denied_unlisted_operation_never_calls_executor():
    executor = RecordingExecutor()
    gate = build_gate(
        [ALLOW_DEPLOY_PUBLIC], executor, token_factory=lambda: "tok-3"
    )
    with pytest.raises(PolicyDenied):
        gate.execute(Operation("destroy", "prod/app", "PUBLIC"))
    assert executor.calls == []


# --- AMBIGUOUS: machine-interpretable escalation, never a user prompt --------


def test_ambiguous_raises_machine_readable_error_and_skips_executor():
    events = []
    executor = RecordingExecutor(events)
    sink = RecordingSink(events)
    gate = build_gate(
        [ALLOW_DEPLOY_PUBLIC],
        executor,
        sink=sink,
        token_factory=lambda: "tok-4",
    )

    with pytest.raises(AmbiguousPolicy) as exc:
        gate.execute(Operation("deploy", "prod/app", "PERSONAL"))

    assert executor.calls == []
    assert events == [("audit", "tok-4")]
    ambiguous = exc.value
    # Structured machine-readable payload for KCC's exception path (spec 18:
    # E4 -- irreversible/ambiguous action outside approved policy). It is an
    # exception on the machine path -- there is no interactive prompt.
    assert ambiguous.token == "tok-4"
    assert ambiguous.decision is PolicyDecision.AMBIGUOUS
    assert ambiguous.operation == Operation("deploy", "prod/app", "PERSONAL")
    assert isinstance(ambiguous, PolicyGateError)
    assert isinstance(ambiguous, RuntimeError)
    assert sink.records[0].decision is PolicyDecision.AMBIGUOUS
    assert gate.audits[0].decision is PolicyDecision.AMBIGUOUS


def test_ambiguous_escalation_matches_failure_classification_contract():
    # The policy layer feeds the failure classifier's CONTRACT class: the
    # structured fields let the controller map AMBIGUOUS to a policy/contract
    # failure without asking the user (R10: no extra approval gates).
    from kcc_autobuild.failure_classifier import FailureEvidence, classify
    from kcc_autobuild.models import FailureClass

    gate = build_gate([ALLOW_DEPLOY_PUBLIC], RecordingExecutor())
    with pytest.raises(AmbiguousPolicy) as exc:
        gate.execute(Operation("deploy", "prod/app", "PERSONAL"))
    evidence = FailureEvidence(
        message=f"policy ambiguous: {exc.value.token} {exc.value.operation}"
    )
    assert classify(evidence) is FailureClass.CONTRACT


# --- Unique decision tokens --------------------------------------------------


def test_decision_tokens_are_unique_per_execution():
    executor = RecordingExecutor()
    gate = build_gate([ALLOW_DEPLOY_PUBLIC], executor)
    deploy = Operation("deploy", "prod/app", "PUBLIC")
    gate.execute(deploy)
    gate.execute(deploy)
    tokens = [audit.token for audit in gate.audits]
    assert len(tokens) == 2
    assert len(set(tokens)) == 2  # unique: every attempt gets its own audit
    assert [token for _, token in executor.calls] == tokens


# --- Audit-before-call holds even when the executor itself fails -------------


def test_audit_recorded_before_executor_exception_propagates():
    def exploding_executor(operation, token):
        raise RuntimeError(f"boom {token}")

    sink = RecordingSink()
    gate = build_gate(
        [ALLOW_DEPLOY_PUBLIC],
        exploding_executor,
        sink=sink,
        token_factory=lambda: "tok-5",
    )
    with pytest.raises(RuntimeError, match="boom tok-5"):
        gate.execute(Operation("deploy", "prod/app", "PUBLIC"))
    # The policy decision was still logged before the (failed) call.
    assert [audit.token for audit in sink.records] == ["tok-5"]
    assert sink.records[0].decision is PolicyDecision.ALLOWED


# --- Mutation adapters receive the gate, never a raw client -----------------


class _GatedMutationAdapter:
    """Test stand-in for the provider/deploy/migration mutation adapters.

    They are constructed with the already-policy-bound
    :class:`PolicyToolGate` -- a raw client is rejected outright, so the gate
    stays the ONLY external/data-mutation executor path.
    """

    def __init__(self, gate):
        if not isinstance(gate, PolicyToolGate):
            raise TypeError(
                "mutation adapters receive a PolicyToolGate, not a raw client"
            )
        self._gate = gate

    def apply(self, operation):
        return self._gate.execute(operation)


class ProviderMutationAdapter(_GatedMutationAdapter):
    """Provider mutation adapter (receives the gate)."""


class DeployMutationAdapter(_GatedMutationAdapter):
    """Deployment mutation adapter (receives the gate)."""


class MigrationMutationAdapter(_GatedMutationAdapter):
    """Database migration adapter (receives the gate)."""


def test_provider_deploy_migration_adapters_route_through_the_gate():
    raw_client = RecordingExecutor()  # in production this never leaves the gate
    sink = RecordingSink()
    gate = build_gate(
        [ALLOW_DEPLOY_PUBLIC], raw_client, sink=sink, token_factory=lambda: f"tok-{len(sink.records) + 1}"
    )
    provider = ProviderMutationAdapter(gate)
    deploy = DeployMutationAdapter(gate)
    migration = MigrationMutationAdapter(gate)

    provider_result = provider.apply(Operation("deploy", "prod/app", "PUBLIC"))
    deploy_result = deploy.apply(Operation("deploy", "prod/app", "PUBLIC"))
    migration_result = migration.apply(Operation("deploy", "prod/app", "PUBLIC"))

    assert provider_result == deploy_result == migration_result == "done:deploy:prod/app"
    # The raw client was reached exactly three times, always via the gate,
    # each with its own decision token.
    assert len(raw_client.calls) == 3
    assert len(sink.records) == 3
    assert len(set(audit.token for audit in sink.records)) == 3


def test_adapter_rejects_a_raw_client():
    raw_client = RecordingExecutor()
    with pytest.raises(TypeError, match="not a raw client"):
        DeployMutationAdapter(raw_client)  # type: ignore[arg-type]
    with pytest.raises(TypeError, match="not a raw client"):
        ProviderMutationAdapter(raw_client)  # type: ignore[arg-type]
    with pytest.raises(TypeError, match="not a raw client"):
        MigrationMutationAdapter(raw_client)  # type: ignore[arg-type]


def test_adapter_denied_and_ambiguous_never_reach_the_raw_client():
    raw_client = RecordingExecutor()
    gate = build_gate([ALLOW_DEPLOY_PUBLIC, DENY_DEPLOY_PERSONAL], raw_client)
    deploy = DeployMutationAdapter(gate)
    with pytest.raises(PolicyDenied):
        deploy.apply(Operation("deploy", "prod/app", "PERSONAL"))
    with pytest.raises(AmbiguousPolicy):
        deploy.apply(Operation("deploy", "staging/app", "PUBLIC"))
    assert raw_client.calls == []


# --- Gate construction and argument validation -------------------------------


def test_gate_rejects_non_callable_executor():
    evaluator = PolicyEvaluator(sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], SECRET), SECRET)
    with pytest.raises(TypeError):
        PolicyToolGate(evaluator, executor="not-callable")  # type: ignore[arg-type]


def test_gate_rejects_non_evaluator():
    with pytest.raises(TypeError):
        PolicyToolGate(evaluator="not-an-evaluator", executor=lambda op, token: None)  # type: ignore[arg-type]


def test_gate_rejects_non_operation_without_auditing():
    executor = RecordingExecutor()
    gate = build_gate([ALLOW_DEPLOY_PUBLIC], executor)
    with pytest.raises(TypeError):
        gate.execute("deploy")  # type: ignore[arg-type]
    assert executor.calls == []
    assert gate.audits == []


def test_gate_audit_is_a_frozen_value_object():
    audit = PolicyAudit(token="tok-9", operation=Operation("deploy", "prod/app", "PUBLIC"), decision=PolicyDecision.ALLOWED)
    assert audit == PolicyAudit(token="tok-9", operation=Operation("deploy", "prod/app", "PUBLIC"), decision=PolicyDecision.ALLOWED)
    with pytest.raises(Exception):
        audit.token = "tok-10"  # type: ignore[misc]
