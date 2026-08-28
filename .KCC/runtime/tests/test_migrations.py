"""Behavioral contract for migration journal / target-authoritative resume.

Owned by ``test_migrations.py`` (see the KCC x Superpowers Hybrid
Framework Plan 05, Task 2: Migration journal / target-authoritative
resume, in
``.superpowers/bootstrap/plans/2026-08-27-05-resume-deploy-validation.task-contracts.md``).

An interrupted database migration must resume from the *target system's*
truth (spec 14.6 / 22: durable target state is the source of truth;
conversation memory -- including KCC's own "step in progress" belief --
is never authoritative for whether a migration already landed). The
:class:`~kcc_autobuild.migrations.MigrationAdapter` is the target-system
view (``current_version`` / ``journal_contains`` / ``execute_mutation`` /
``validate``); :class:`~kcc_autobuild.migrations.MigrationCoordinator` is
the pure decision + routing function for one
:class:`~kcc_autobuild.migrations.MigrationStep`:

* if the **target version is already reached** (adapter
  ``current_version``) OR the **adapter journal already contains the
  step** => ``VALIDATE_ONLY`` with NO apply: no mutation, no policy gate
  call -- completed work is never repeated (spec 22);
* otherwise the mutation MUST route through
  ``PolicyToolGate.call(Operation(operation="db.migrate",
  resource=<step.resource>, data_class=<step.data_class>),
  args={step_id, target_version, idempotency_key})`` -- the ONLY
  external/data-mutation executor path (DENIED never calls the mutation;
  AMBIGUOUS raises back to KCC machine interpretation, never a direct
  user prompt) -- and only then is the target re-validated: validation
  failure raises instead of reporting APPLIED.

Prescribed scenario: commit-then-crash -- the target v2 is already set
while KCC still says the step is in progress => no apply (VALIDATE_ONLY,
zero gate calls, zero mutations).
"""

from __future__ import annotations

from typing import Any, Mapping

import pytest

from kcc_autobuild.migrations import (
    MIGRATION_OPERATION,
    MigrationAdapter,
    MigrationCoordinator,
    MigrationError,
    MigrationOutcome,
    MigrationResult,
    MigrationStep,
    MigrationValidationError,
)
from kcc_autobuild.policy import (
    Operation,
    PolicyDecision,
    PolicyEvaluator,
    PolicyRule,
    sign_policy_bundle,
)
from kcc_autobuild.tool_gate import AmbiguousPolicy, PolicyDenied, PolicyToolGate

SECRET = "unit-test-migration-secret"

RESOURCE = "prod/db"
DATA_CLASS = "PERSONAL"


def _step(
    step_id: str = "migrate-0002",
    target_version: str = "v2",
    idempotency_key: str = "migrate-0002-v2",
    resource: str = RESOURCE,
    data_class: str = DATA_CLASS,
) -> MigrationStep:
    return MigrationStep(
        id=step_id,
        target_version=target_version,
        idempotency_key=idempotency_key,
        resource=resource,
        data_class=data_class,
    )


class _FakeMigrationAdapter:
    """Target-system stand-in implementing the MigrationAdapter protocol.

    ``current_version`` is the durable schema version (``None`` = fresh
    target, no migration applied yet); ``journal`` is the durable applied-
    steps journal (step ids + idempotency keys). ``execute_mutation``
    commits the migration BEFORE recording the journal row, modelling the
    commit-then-crash window: the version may reach the target while the
    journal row is still absent.
    """

    def __init__(
        self,
        *,
        version: str | None = None,
        journal: list[str] | None = None,
        validate_ok: bool = True,
    ) -> None:
        self.version = version
        self.journal = list(journal or [])
        self.validate_ok = validate_ok
        self.mutations: list[tuple[MigrationStep, str]] = []
        self.validation_calls: list[MigrationStep] = []

    def current_version(self) -> str | None:
        return self.version

    def journal_contains(self, step: MigrationStep) -> bool:
        return step.id in self.journal or step.idempotency_key in self.journal

    def execute_mutation(self, step: MigrationStep, token: str) -> None:
        # Commit first, journal second -- the crash window.
        self.mutations.append((step, token))
        self.version = step.target_version
        self.journal.append(step.id)

    def validate(self, step: MigrationStep) -> bool:
        self.validation_calls.append(step)
        return self.validate_ok and self.version == step.target_version


class _PolicyCallGate:
    """Adapter-facing ``call(operation, args)`` over the one real gate.

    The coordinator MUST route every mutation through ``gate.call``; this
    facade wraps the single
    :class:`~kcc_autobuild.tool_gate.PolicyToolGate` (raw mutation clients
    are never handed to adapters) and records the exact
    ``(operation, args)`` the coordinator issued so the tests can pin the
    routing contract.
    """

    def __init__(self, gate: PolicyToolGate) -> None:
        if not isinstance(gate, PolicyToolGate):
            raise TypeError(
                "the call facade requires a PolicyToolGate, not a raw client"
            )
        self.gate = gate
        self.calls: list[tuple[Operation, Mapping[str, object]]] = []

    def call(self, operation: Operation, args: Mapping[str, object]) -> Any:
        self.calls.append((operation, dict(args)))
        return self.gate.execute(operation)


def _allowed_gate(
    adapter: _FakeMigrationAdapter,
    step: MigrationStep,
    *,
    rule: PolicyRule | None = None,
    tokens: list[str] | None = None,
    token_factory: Any = None,
) -> _PolicyCallGate:
    """Build the real gate bound to the adapter's raw mutation."""
    if rule is None:
        rule = PolicyRule(MIGRATION_OPERATION, step.resource, step.data_class, PolicyDecision.ALLOWED)
    evaluator = PolicyEvaluator(sign_policy_bundle([rule], SECRET), SECRET)
    issued: list[str] = tokens if tokens is not None else []

    def executor(operation: Operation, token: str) -> None:
        issued.append(token)
        adapter.execute_mutation(step, token)

    if token_factory is None:
        def token_factory() -> str:
            return f"mig-tok-{len(issued) + 1}"

    return _PolicyCallGate(
        PolicyToolGate(evaluator, executor, token_factory=token_factory)
    )


# --- Types: MigrationStep / MigrationOutcome / MigrationResult --------------


def test_migration_step_holds_the_contact_fields():
    step = _step()
    assert step.id == "migrate-0002"
    assert step.target_version == "v2"
    assert step.idempotency_key == "migrate-0002-v2"
    assert step.resource == RESOURCE
    assert step.data_class == DATA_CLASS


def test_migration_step_rejects_blank_fields():
    for field in ("id", "target_version", "idempotency_key", "resource", "data_class"):
        kwargs = dict(
            id="migrate-0002",
            target_version="v2",
            idempotency_key="migrate-0002-v2",
            resource=RESOURCE,
            data_class=DATA_CLASS,
        )
        kwargs[field] = ""
        with pytest.raises(ValueError):
            MigrationStep(**kwargs)


def test_migration_step_rejects_non_string_fields():
    bad = dict(
        id=1,
        target_version=2,
        idempotency_key=3,
        resource=4,
        data_class=5,
    )
    for field in bad:
        kwargs = dict(
            id="migrate-0002",
            target_version="v2",
            idempotency_key="migrate-0002-v2",
            resource=RESOURCE,
            data_class=DATA_CLASS,
        )
        kwargs[field] = bad[field]
        with pytest.raises(TypeError):
            MigrationStep(**kwargs)  # type: ignore[arg-type]


def test_migration_step_is_frozen_and_comparable():
    step = _step()
    with pytest.raises(AttributeError):
        step.target_version = "v3"  # type: ignore[misc]
    assert _step() == step


def test_migration_outcome_is_canonical():
    assert MigrationOutcome.VALIDATE_ONLY.value == "VALIDATE_ONLY"
    assert MigrationOutcome.APPLIED.value == "APPLIED"
    assert MigrationOutcome.APPLIED == "APPLIED"


def test_migration_result_carries_step_and_outcome():
    step = _step()
    result = MigrationResult(step=step, outcome=MigrationOutcome.VALIDATE_ONLY)
    assert result.step is step
    assert result.outcome is MigrationOutcome.VALIDATE_ONLY
    assert result == MigrationResult(step, MigrationOutcome.VALIDATE_ONLY)


def test_migration_operation_verb_is_pinned():
    # The policy-classified verb for database migration (spec 14.3:
    # "database migration within the approved destructive-action policy").
    assert MIGRATION_OPERATION == "db.migrate"


# --- Adapter protocol --------------------------------------------------------


class _CountingGate:
    def __init__(self) -> None:
        self.calls: list[tuple[Operation, Mapping[str, object]]] = []

    def call(self, operation: Operation, args: Mapping[str, object]) -> Any:
        self.calls.append((operation, args))


def test_adapter_protocol_is_runtime_checkable():
    assert isinstance(_FakeMigrationAdapter(), MigrationAdapter)
    assert not isinstance(object(), MigrationAdapter)


def test_coordinator_rejects_non_adapter():
    with pytest.raises(TypeError):
        MigrationCoordinator(adapter=object(), gate=_CountingGate())  # type: ignore[arg-type]


def test_coordinator_rejects_gate_without_call():
    class _RawClientGate:
        pass

    with pytest.raises(TypeError):
        MigrationCoordinator(adapter=_FakeMigrationAdapter(), gate=_RawClientGate())  # type: ignore[arg-type]


def test_coordinator_rejects_non_step():
    coordinator = MigrationCoordinator(
        adapter=_FakeMigrationAdapter(), gate=_CountingGate()
    )
    with pytest.raises(TypeError):
        coordinator.apply("migrate-0002")  # type: ignore[arg-type]


# --- Skipped when target version already reached -----------------------------


def test_target_version_reached_is_validate_only_with_no_apply():
    adapter = _FakeMigrationAdapter(version="v2")
    gate = _CountingGate()
    result = MigrationCoordinator(adapter=adapter, gate=gate).apply(_step())
    assert result.outcome is MigrationOutcome.VALIDATE_ONLY
    assert result.step == _step()
    assert adapter.mutations == []
    assert adapter.validation_calls == []
    assert gate.calls == []


def test_commit_then_crash_target_v2_set_while_kcc_says_in_progress_no_apply():
    # Prescribed scenario: the migration committed on the target (v2) but
    # KCC's durable run still says the step is in progress. Target-system
    # truth wins: no apply, no gate call, no mutation -- the step is
    # reported VALIDATE_ONLY exactly once.
    adapter = _FakeMigrationAdapter(version="v2", journal=[])
    step = _step(target_version="v2")
    gate = _allowed_gate(adapter, step)
    result = MigrationCoordinator(adapter=adapter, gate=gate).apply(step)
    assert result.outcome is MigrationOutcome.VALIDATE_ONLY
    assert adapter.mutations == []
    assert adapter.validation_calls == []
    assert gate.calls == []
    assert gate.gate.audits == []


# --- Skipped when the adapter journal already contains the step --------------


def test_journal_already_contains_step_is_validate_only_with_no_apply():
    step = _step()
    # Journal rows may carry the step id or its idempotency key.
    for entry in (step.id, step.idempotency_key):
        adapter = _FakeMigrationAdapter(version="v1", journal=[entry])
        gate = _allowed_gate(adapter, step)
        result = MigrationCoordinator(adapter=adapter, gate=gate).apply(step)
        assert result.outcome is MigrationOutcome.VALIDATE_ONLY
        assert adapter.mutations == []
        assert adapter.validation_calls == []
        assert gate.calls == []
        assert gate.gate.audits == []


def test_both_skip_conditions_agree_on_validate_only():
    step = _step()
    adapter = _FakeMigrationAdapter(version="v2", journal=[step.id])
    gate = _allowed_gate(adapter, step)
    result = MigrationCoordinator(adapter=adapter, gate=gate).apply(step)
    assert result.outcome is MigrationOutcome.VALIDATE_ONLY
    assert adapter.mutations == []


# --- Apply path: gate routing, then validate or raise ------------------------


def test_apply_routes_mutation_through_gate_call_with_exact_operation_and_args():
    adapter = _FakeMigrationAdapter(version="v1")
    step = _step()
    gate = _allowed_gate(adapter, step)
    result = MigrationCoordinator(adapter=adapter, gate=gate).apply(step)
    assert result.outcome is MigrationOutcome.APPLIED
    assert gate.calls == [
        (
            Operation(operation="db.migrate", resource=RESOURCE, data_class=DATA_CLASS),
            {
                "step_id": step.id,
                "target_version": step.target_version,
                "idempotency_key": step.idempotency_key,
            },
        )
    ]
    assert adapter.validation_calls == [step]


def test_apply_commits_mutation_and_journal_for_a_fresh_target():
    adapter = _FakeMigrationAdapter(version=None)
    step = _step(target_version="v2")
    gate = _allowed_gate(adapter, step)
    result = MigrationCoordinator(adapter=adapter, gate=gate).apply(step)
    assert result.outcome is MigrationOutcome.APPLIED
    assert adapter.version == "v2"
    assert adapter.journal == [step.id]
    assert [mutation_step for mutation_step, _ in adapter.mutations] == [step]


def test_apply_after_commit_then_crash_resume_is_validate_only():
    # Retrying the same step (e.g. after a KCC restart) must not re-apply:
    # the first attempt landed on the target and its journal row exists.
    adapter = _FakeMigrationAdapter()  # fresh target for the first apply
    step = _step()
    gate = _allowed_gate(adapter, step)
    coordinator = MigrationCoordinator(adapter=adapter, gate=gate)
    assert coordinator.apply(step).outcome is MigrationOutcome.APPLIED

    after = _FakeMigrationAdapter(version=adapter.version, journal=adapter.journal)
    second_gate = _allowed_gate(after, step)
    resume = MigrationCoordinator(adapter=after, gate=second_gate)
    assert resume.apply(step).outcome is MigrationOutcome.VALIDATE_ONLY

    assert adapter.mutations == [(step, "mig-tok-1")]
    assert len(gate.calls) == 1
    assert second_gate.calls == []
    assert after.mutations == []


def test_validate_failure_raises_instead_of_reporting_applied():
    adapter = _FakeMigrationAdapter(version="v1", validate_ok=False)
    step = _step()
    gate = _allowed_gate(adapter, step)
    coordinator = MigrationCoordinator(adapter=adapter, gate=gate)
    with pytest.raises(MigrationValidationError) as excinfo:
        coordinator.apply(step)
    assert step.id in str(excinfo.value)
    assert step.target_version in str(excinfo.value)
    # The mutation was attempted once and the target was re-checked; it
    # just did not reach the target truth, so the coordinator fails closed.
    assert len(adapter.mutations) == 1
    assert adapter.validation_calls == [step]


def test_validation_error_is_a_migration_error():
    assert issubclass(MigrationValidationError, MigrationError)


# --- Gate discipline: DENIED / AMBIGUOUS never call the mutation -------------


def test_denied_never_invokes_the_mutation():
    adapter = _FakeMigrationAdapter(version="v1")
    step = _step()
    rule = PolicyRule(MIGRATION_OPERATION, RESOURCE, DATA_CLASS, PolicyDecision.DENIED)
    gate = _allowed_gate(adapter, step, rule=rule)
    coordinator = MigrationCoordinator(adapter=adapter, gate=gate)
    with pytest.raises(PolicyDenied):
        coordinator.apply(step)
    assert adapter.mutations == []  # the raw mutation never ran
    assert adapter.validation_calls == []
    assert gate.gate.audits[-1].decision is PolicyDecision.DENIED


def test_ambiguous_raises_back_to_machine_interpretation_and_never_mutates():
    adapter = _FakeMigrationAdapter(version="v1")
    step = _step()
    # Same operation, mismatched resource --> AMBIGUOUS, never a user prompt.
    rule = PolicyRule(MIGRATION_OPERATION, "staging/db", DATA_CLASS, PolicyDecision.ALLOWED)
    gate = _allowed_gate(adapter, step, rule=rule)
    coordinator = MigrationCoordinator(adapter=adapter, gate=gate)
    with pytest.raises(AmbiguousPolicy) as excinfo:
        coordinator.apply(step)
    assert adapter.mutations == []
    assert adapter.validation_calls == []
    assert excinfo.value.operation.operation == "db.migrate"
    assert excinfo.value.decision is PolicyDecision.AMBIGUOUS
    assert gate.gate.audits[-1].decision is PolicyDecision.AMBIGUOUS


def test_executor_receives_the_policy_audit_token():
    adapter = _FakeMigrationAdapter(version="v1")
    step = _step()
    gate = _allowed_gate(adapter, step)
    MigrationCoordinator(adapter=adapter, gate=gate).apply(step)
    assert len(gate.gate.audits) == 1
    assert len(adapter.mutations) == 1
    mutation_step, token = adapter.mutations[0]
    assert mutation_step is step
    # The mutation call is correlated with the same unique decision token
    # the gate logged BEFORE invoking the executor.
    assert token == gate.gate.audits[0].token
    assert token == "mig-tok-1"
