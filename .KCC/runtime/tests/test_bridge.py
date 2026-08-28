"""Behavioral tests for bounded autobuild task handoff packs.

Written first (strict TDD red phase) against the external behavior
contract of :mod:`kcc_autobuild.bridge` (the :class:`ExecutionBridge`
and the :class:`TaskHandoff` / :class:`LockedDecision` models) -- KCC x
Superpowers Hybrid Framework Plan 03, Task 3; Design Spec v1.2 section
16.2 (bounded task handoff pack) and the plan Global Constraints.

Binding semantics under test:

* every fresh implementation agent receives a **bounded** handoff pack:
  ``ExecutionBridge(..., max_handoff_bytes=65536)`` produces a pack of
  at most 65536 serialized bytes, and a pack that would exceed the
  bridge's byte limit is rejected (fail-closed, no oversized dispatch);
* only **scoped** context travels: the pack carries the task's
  requirements, their forward-reachable trace context, acceptance IDs
  and Test IDs -- fixture rows for an unrelated requirement (REQ-999)
  and an unrelated provider never leak into the pack;
* locked decisions carry the explicit ``LOCKED_DO_NOT_REDECIDE``
  marker (spec 16.2: explicit "LOCKED -- DO NOT REDECIDE" markers); a
  decision without the marker cannot be constructed;
* no plaintext secret travels: provider credential data is secret
  *reference* only (``vault://`` / ``env://`` / ``keychain://``),
  raw secrets are rejected, and the serialized pack never contains one
  (spec section 24; plan Global Constraint chain of custody);
* the handoff lease is bound to the run/task and its generation is
  strictly positive (one KCC lease per execution attempt);
* the pack is refused when acceptance IDs or Test IDs are missing, and
  when acceptance/Test IDs sit outside the task's reachable trace
  context (only scoped context, fail-closed);
* the pack carries the policy evaluator's canonical bundle hash -- the
  signed/locked policy fingerprint of the contract -- and refuses to
  be built without one;
* the anchor hash is **cross-verified, fail-closed**: when the source
  Build Contract is supplied it must be **locked** (canonical hash
  present) and an explicit ``policy_bundle_hash`` must equal the
  contract's canonical ``contract_hash`` -- a mismatch or an unlocked
  contract is rejected, so a self-inconsistent pack anchored to the
  wrong policy bundle can never be produced;
* scoping is never silently disabled: without the trace graph the
  bridge cannot prove acceptance/Test-ID reachability, so it refuses
  to build instead of packing unscoped IDs;
* the attempt budget is mandatory (KCC owns it) and a failed build
  never consumes a lease generation -- one generation per *issued*
  pack, one KCC lease per attempt.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from pydantic import ValidationError

from kcc_autobuild.bridge import (
    LOCKED_DO_NOT_REDECIDE,
    AttemptBudget,
    ExecutionBridge,
    HandoffError,
    HandoffOverflowError,
    LockedDecision,
    ProviderConstraint,
    TaskHandoff,
    TaskLease,
)
from kcc_autobuild.contract import (
    AuthorityEnvelope,
    BuildContract,
    MoneyPolicy,
    ProviderEntry,
    Tier1Invariants,
    Tier2Details,
    lock_contract,
)
from kcc_autobuild.models import DependencyStatus
from kcc_autobuild.readiness import (
    EvidenceRecord,
    ReadinessItem,
    ReadinessPack,
    ReadinessStatus,
)
from kcc_autobuild.trace import TraceEdge, TraceGraph, TraceNode

POLICY_HASH = "a" * 64
RAW_SECRET = "sk-live-deadbeefcafe1234567890abcdef"
NOW = datetime(2026, 1, 2, 12, 0, 0, tzinfo=timezone.utc)
TTL = timedelta(hours=4)


# ---------------------------------------------------------------------------
# Fixtures: a trace with a scoped task cluster plus an unrelated REQ-999
# cluster, and a contract whose whitelist carries an unrelated provider.
# ---------------------------------------------------------------------------


def _trace() -> TraceGraph:
    """REQ-001 (the task's scope) and REQ-999 (unrelated) clusters."""
    return TraceGraph(
        run_id="RUN-001",
        nodes=[
            TraceNode(id="REQ-001", kind="requirement"),
            TraceNode(id="IMPL-001", kind="implementation"),
            TraceNode(id="AC-001", kind="acceptance"),
            TraceNode(id="T-001", kind="test"),
            TraceNode(id="PROD-001", kind="production_validation"),
            TraceNode(id="REQ-999", kind="requirement"),
            TraceNode(id="IMPL-999", kind="implementation"),
            TraceNode(id="AC-999", kind="acceptance"),
            TraceNode(id="T-999", kind="test"),
            TraceNode(id="PROD-999", kind="production_validation"),
        ],
        edges=[
            TraceEdge(source="REQ-001", target="IMPL-001"),
            TraceEdge(source="IMPL-001", target="AC-001"),
            TraceEdge(source="IMPL-001", target="T-001"),
            TraceEdge(source="T-001", target="PROD-001"),
            TraceEdge(source="REQ-999", target="IMPL-999"),
            TraceEdge(source="IMPL-999", target="AC-999"),
            TraceEdge(source="IMPL-999", target="T-999"),
            TraceEdge(source="IMPL-999", target="PROD-999"),
        ],
    )


def _contract(**tier1_overrides: object) -> BuildContract:
    defaults: dict[str, object] = {
        "provider_whitelist": [
            ProviderEntry(provider="openai", paid=True),
            # unrelated provider: on the contract whitelist but NOT in
            # the task's provider scope -- must never reach the pack.
            ProviderEntry(provider="unrelated-provider", paid=True),
        ],
        "authority": AuthorityEnvelope(
            auto_provision_status=DependencyStatus.AUTO_PROVISION_AUTHORIZED,
            auto_provision_providers=["openai"],
            approved_accounts=["acct-openai-1"],
            credential_refs=["vault://prod/openai-key"],
        ),
        "money": MoneyPolicy(
            per_provider_caps={"openai": 10_000, "unrelated-provider": 5_000}
        ),
        "production_target": "https://internal.example.com",
        "definition_of_done": (
            "analysis output is produced end to end and validated in staging"
        ),
    }
    defaults.update(tier1_overrides)
    return BuildContract(
        tier1=Tier1Invariants(
            product_scope="internal analysis tool",
            non_goals=["no public API"],
            primary_user_journeys=["run one analysis end to end"],
            **defaults,  # type: ignore[arg-type]
        ),
        tier2=Tier2Details(),
        trace=_trace(),
    )


def _locked_contract() -> BuildContract:
    """A lockable contract: full trace coverage plus evidence-backed
    readiness, so the fixture carries the canonical Tier-1 lock hash."""
    contract = _contract()
    contract.readiness = ReadinessPack(
        items=[
            ReadinessItem(
                id="IT-001",
                provider="openai",
                status=ReadinessStatus.READY,
                required_kinds=["identity"],
                evidence=[
                    EvidenceRecord(
                        kind="identity",
                        result="pass",
                        checked_at=NOW,
                        resource_ids=["resource-1"],
                        scopes=["scopes:read"],
                    )
                ],
                evidence_ttl=TTL,
            )
        ]
    )
    return lock_contract(contract, now=NOW)


def _decision(
    decision_id: str,
    summary: str,
    requirement_ids: list[str] | None = None,
) -> LockedDecision:
    return LockedDecision(
        id=decision_id,
        summary=summary,
        requirement_ids=[] if requirement_ids is None else requirement_ids,
    )


def _decisions() -> list[LockedDecision]:
    """One decision for the task's requirement, one for the unrelated one."""
    return [
        _decision("ADR-001", "analysis scope is the internal tool only", ["REQ-001"]),
        _decision("ADR-999", "REQ-999 unrelated decision", ["REQ-999"]),
    ]


def _budget() -> AttemptBudget:
    return AttemptBudget(
        max_attempts=3,
        time_budget_minutes=120,
        token_budget=250_000,
        cost_budget_minor=2_000,
        escalation_tier=1,
    )


def _model_kwargs(**overrides: object) -> dict[str, object]:
    """Minimal required fields for a direct ``TaskHandoff`` construction."""
    kwargs: dict[str, object] = {
        "run_id": "RUN-001",
        "task_id": "TASK-021",
        "requirement_ids": ["REQ-001"],
        "acceptance_ids": ["AC-001"],
        "test_ids": ["T-001"],
        "lease": TaskLease(
            lease_id="LEASE-RUN-001-TASK-021-1",
            run_id="RUN-001",
            task_id="TASK-021",
            generation=1,
        ),
        "attempt_budget": _budget(),
        "policy_bundle_hash": POLICY_HASH,
    }
    kwargs.update(overrides)
    return kwargs


def _build(
    bridge: ExecutionBridge | None = None,
    **overrides: object,
) -> TaskHandoff:
    """Build a minimal valid handoff; overrides replace any input.

    The default source contract is **locked** (canonical hash present)
    so the pack's anchor hash can always be cross-verified; the default
    ``policy_bundle_hash`` is ``None`` so the bridge derives it from the
    locked contract's canonical hash.
    """
    inputs: dict[str, object] = {
        "run_id": "RUN-001",
        "task_id": "TASK-021",
        "requirement_ids": ["REQ-001"],
        "acceptance_ids": ["AC-001"],
        "test_ids": ["T-001"],
        "providers": ["openai"],
        "trace": _trace(),
        "contract": _locked_contract(),
        "locked_decisions": _decisions(),
        "attempt_budget": _budget(),
        "policy_bundle_hash": None,
    }
    inputs.update(overrides)
    return (bridge or ExecutionBridge()).build_handoff(**inputs)  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# LockedDecision -- explicit LOCKED_DO_NOT_REDECIDE marker
# ---------------------------------------------------------------------------


class TestLockedDecision:
    """A locked contract/decision excerpt always carries the marker."""

    def test_marker_constant_is_exact(self) -> None:
        assert LOCKED_DO_NOT_REDECIDE == "LOCKED_DO_NOT_REDECIDE"

    def test_decision_carries_exact_marker(self) -> None:
        decision = _decision("ADR-001", "analysis scope is locked")
        assert decision.marker == "LOCKED_DO_NOT_REDECIDE"
        assert decision.id == "ADR-001"
        assert decision.summary == "analysis scope is locked"

    def test_decision_rejects_any_other_marker(self) -> None:
        with pytest.raises(ValidationError, match="LOCKED_DO_NOT_REDECIDE"):
            LockedDecision(
                id="ADR-001",
                summary="scope",
                requirement_ids=["REQ-001"],
                marker="REDECIDE-AS-YOU-LIKE",  # type: ignore[arg-type]
            )

    def test_decision_requires_id_and_summary(self) -> None:
        with pytest.raises(ValidationError, match="id"):
            LockedDecision(id="", summary="scope", requirement_ids=["REQ-001"])
        with pytest.raises(ValidationError, match="summary"):
            LockedDecision(id="ADR-001", summary="   ", requirement_ids=["REQ-001"])

    def test_decision_requirement_ids_nonempty_entries(self) -> None:
        with pytest.raises(ValidationError, match="requirement_ids"):
            LockedDecision(id="ADR-001", summary="scope", requirement_ids=["  "])

    def test_decision_requirement_ids_may_be_global(self) -> None:
        decision = _decision("ADR-GLOBAL", "applies to the whole run")
        assert decision.requirement_ids == []


# ---------------------------------------------------------------------------
# TaskHandoff -- prescribed fields and identity invariants
# ---------------------------------------------------------------------------


class TestTaskHandoffFields:
    """TaskHandoff carries exactly the scoped context of spec 16.2."""

    def test_all_prescribed_fields_are_present(self) -> None:
        handoff = _build()
        assert handoff.run_id == "RUN-001"
        assert handoff.task_id == "TASK-021"
        assert handoff.requirement_ids == ["REQ-001"]
        assert [node.id for node in handoff.trace_nodes] == [
            "AC-001",
            "IMPL-001",
            "PROD-001",
            "REQ-001",
            "T-001",
        ]
        assert handoff.acceptance_ids == ["AC-001"]
        assert handoff.test_ids == ["T-001"]
        assert [decision.id for decision in handoff.locked_decisions] == ["ADR-001"]
        assert handoff.lease.run_id == "RUN-001"
        assert handoff.lease.task_id == "TASK-021"
        assert handoff.attempt_budget.max_attempts == 3
        assert [c.provider for c in handoff.provider_constraints] == ["openai"]
        assert handoff.policy_bundle_hash == _locked_contract().contract_hash

    def test_missing_acceptance_ids_rejected(self) -> None:
        with pytest.raises(HandoffError, match="acceptance"):
            _build(acceptance_ids=[])

    def test_missing_test_ids_rejected(self) -> None:
        with pytest.raises(HandoffError, match="test id"):
            _build(test_ids=[])

    def test_missing_requirement_ids_rejected(self) -> None:
        with pytest.raises(HandoffError, match="requirement"):
            _build(requirement_ids=[])

    def test_model_rejects_missing_acceptance_ids(self) -> None:
        with pytest.raises(ValidationError, match="acceptance_ids"):
            TaskHandoff(**{**_model_kwargs(), "acceptance_ids": []})  # type: ignore[arg-type]

    def test_model_rejects_missing_test_ids(self) -> None:
        with pytest.raises(ValidationError, match="test_ids"):
            TaskHandoff(**{**_model_kwargs(), "test_ids": []})  # type: ignore[arg-type]

    def test_model_rejects_missing_requirement_ids(self) -> None:
        with pytest.raises(ValidationError, match="requirement_ids"):
            TaskHandoff(**{**_model_kwargs(), "requirement_ids": []})  # type: ignore[arg-type]

    def test_duplicate_ids_rejected(self) -> None:
        with pytest.raises(ValidationError, match="requirement_ids"):
            _build(requirement_ids=["REQ-001", "REQ-001"])
        with pytest.raises(ValidationError, match="acceptance_ids"):
            _build(acceptance_ids=["AC-001", "AC-001"])
        with pytest.raises(ValidationError, match="test_ids"):
            _build(test_ids=["T-001", "T-001"])

    def test_policy_bundle_hash_uses_canonical_sha256_shape(self) -> None:
        handoff = _build()
        assert len(handoff.policy_bundle_hash) == 64
        assert handoff.policy_bundle_hash == _locked_contract().contract_hash
        with pytest.raises(ValidationError, match="policy_bundle_hash"):
            TaskHandoff(**{**_model_kwargs(), "policy_bundle_hash": "not-a-hash"})  # type: ignore[arg-type]

    def test_policy_bundle_hash_is_required_by_the_bridge(self) -> None:
        with pytest.raises(HandoffError, match="policy bundle hash"):
            _build(contract=None, providers=[], policy_bundle_hash=None)

    def test_policy_bundle_hash_carries_the_locked_contract_hash(self) -> None:
        contract = _locked_contract()
        handoff = _build(contract=contract, policy_bundle_hash=None)
        assert handoff.policy_bundle_hash == contract.contract_hash
        assert len(handoff.policy_bundle_hash) == 64

    def test_explicit_policy_bundle_hash_must_match_the_locked_contract(self) -> None:
        """Anchor invariant (regression): an explicit hash that does not
        match the locked contract's canonical hash is a self-inconsistent
        pack and must be rejected (fail-closed), not silently packed."""
        contract = _locked_contract()
        with pytest.raises(HandoffError, match="does not match"):
            _build(contract=contract, policy_bundle_hash="b" * 64)

    def test_explicit_policy_bundle_hash_may_equal_the_locked_contract_hash(
        self,
    ) -> None:
        contract = _locked_contract()
        handoff = _build(
            contract=contract, policy_bundle_hash=contract.contract_hash
        )
        assert handoff.policy_bundle_hash == contract.contract_hash

    def test_unlocked_contract_cannot_anchor_a_pack(self) -> None:
        """A contract without a canonical lock hash cannot anchor a pack,
        so an explicit hash can never be cross-verified against it."""
        with pytest.raises(HandoffError, match="locked"):
            _build(contract=_contract(), policy_bundle_hash=POLICY_HASH)

    def test_unknown_requirement_rejected(self) -> None:
        with pytest.raises(HandoffError, match="REQ-777"):
            _build(requirement_ids=["REQ-777"])

    def test_unknown_provider_rejected(self) -> None:
        with pytest.raises(HandoffError, match="provider"):
            _build(providers=["ghost-provider"])

    def test_lease_must_be_bound_to_the_handoff_run(self) -> None:
        with pytest.raises(ValidationError, match="lease"):
            TaskHandoff(
                run_id="RUN-001",
                task_id="TASK-021",
                requirement_ids=["REQ-001"],
                acceptance_ids=["AC-001"],
                test_ids=["T-001"],
                lease=TaskLease(
                    lease_id="LEASE-1", run_id="RUN-999", task_id="TASK-021", generation=1
                ),
                attempt_budget=_budget(),
                policy_bundle_hash=POLICY_HASH,
            )

    def test_lease_must_be_bound_to_the_handoff_task(self) -> None:
        with pytest.raises(ValidationError, match="lease"):
            TaskHandoff(
                run_id="RUN-001",
                task_id="TASK-021",
                requirement_ids=["REQ-001"],
                acceptance_ids=["AC-001"],
                test_ids=["T-001"],
                lease=TaskLease(
                    lease_id="LEASE-1", run_id="RUN-001", task_id="TASK-999", generation=1
                ),
                attempt_budget=_budget(),
                policy_bundle_hash=POLICY_HASH,
            )


class TestLease:
    """One KCC lease per attempt, with a strictly positive generation."""

    def test_lease_generation_is_positive(self) -> None:
        handoff = _build()
        assert handoff.lease.generation >= 1

    def test_lease_generation_increments_per_handoff(self) -> None:
        bridge = ExecutionBridge()
        first = _build(bridge)
        second = _build(bridge)
        assert first.lease.generation == 1
        assert second.lease.generation == 2
        assert first.lease.lease_id != second.lease.lease_id

    def test_lease_bound_to_run_task_and_generation(self) -> None:
        handoff = _build()
        assert handoff.lease.lease_id == "LEASE-RUN-001-TASK-021-1"
        assert handoff.lease.run_id == handoff.run_id
        assert handoff.lease.task_id == handoff.task_id

    def test_lease_model_rejects_non_positive_generation(self) -> None:
        with pytest.raises(ValidationError, match="generation"):
            TaskLease(lease_id="LEASE-1", run_id="RUN-001", task_id="TASK-021", generation=0)


# ---------------------------------------------------------------------------
# ExecutionBridge -- bounded packs
# ---------------------------------------------------------------------------


class TestExecutionBridgeBound:
    """The handoff pack is bounded: <= max_handoff_bytes, else rejected."""

    def test_default_bridge_returns_at_most_65536_bytes(self) -> None:
        handoff = _build()
        assert len(handoff.pack()) <= 65536

    def test_explicit_max_handoff_bytes_obeyed(self) -> None:
        handoff = _build(ExecutionBridge(max_handoff_bytes=65536))
        assert len(handoff.pack()) <= 65536

    def test_pack_length_is_exact_and_deterministic(self) -> None:
        handoff = _build()
        assert handoff.pack() == handoff.pack()
        assert len(handoff.pack()) == len(handoff.pack())

    def test_byte_overflow_rejected(self) -> None:
        bridge = ExecutionBridge(max_handoff_bytes=64)
        with pytest.raises(HandoffOverflowError, match="64"):
            _build(bridge)

    def test_overflow_failure_does_not_produce_a_pack(self) -> None:
        bridge = ExecutionBridge(max_handoff_bytes=32)
        with pytest.raises(HandoffOverflowError):
            _build(bridge)

    def test_max_handoff_bytes_must_be_positive(self) -> None:
        with pytest.raises(ValueError, match="max_handoff_bytes"):
            ExecutionBridge(max_handoff_bytes=0)


# ---------------------------------------------------------------------------
# ExecutionBridge -- scoped context only
# ---------------------------------------------------------------------------


class TestExecutionBridgeScoping:
    """Only reachable requirement/trace context travels; REQ-999 stays home."""

    def test_unrelated_requirement_excluded(self) -> None:
        handoff = _build()
        node_ids = [node.id for node in handoff.trace_nodes]
        assert "REQ-001" in node_ids
        assert "REQ-999" not in node_ids
        assert "AC-999" not in node_ids
        assert "T-999" not in node_ids
        assert "IMPL-999" not in node_ids

    def test_unrelated_provider_excluded(self) -> None:
        handoff = _build()
        providers = [constraint.provider for constraint in handoff.provider_constraints]
        assert providers == ["openai"]
        assert "unrelated-provider" not in providers

    def test_unrelated_locked_decision_excluded(self) -> None:
        handoff = _build()
        decision_ids = [decision.id for decision in handoff.locked_decisions]
        assert decision_ids == ["ADR-001"]
        assert "ADR-999" not in decision_ids

    def test_global_locked_decision_included(self) -> None:
        handoff = _build(
            locked_decisions=[
                _decision("ADR-001", "scoped decision", ["REQ-001"]),
                _decision("ADR-GLOBAL", "applies to the whole run"),
            ]
        )
        assert [decision.id for decision in handoff.locked_decisions] == [
            "ADR-001",
            "ADR-GLOBAL",
        ]

    def test_acceptance_ids_must_be_reachable_from_task_requirements(self) -> None:
        with pytest.raises(HandoffError, match="AC-999"):
            _build(acceptance_ids=["AC-999"])

    def test_test_ids_must_be_reachable_from_task_requirements(self) -> None:
        with pytest.raises(HandoffError, match="T-999"):
            _build(test_ids=["T-999"])

    def test_acceptance_ids_must_be_acceptance_nodes(self) -> None:
        with pytest.raises(HandoffError, match="IMPL-001"):
            _build(acceptance_ids=["IMPL-001"])

    def test_provider_constraints_carry_derived_spend_caps(self) -> None:
        handoff = _build()
        constraint = handoff.provider_constraints[0]
        assert constraint.provider == "openai"
        assert constraint.paid is True
        assert constraint.spend_cap == 10_000
        assert constraint.approved_accounts == ["acct-openai-1"]
        assert constraint.auto_provision is DependencyStatus.AUTO_PROVISION_AUTHORIZED

    def test_provider_constraints_do_not_auto_provision_unrelated_provider(self) -> None:
        handoff = _build(providers=None)
        constraints = {
            constraint.provider: constraint
            for constraint in handoff.provider_constraints
        }
        unrelated = constraints["unrelated-provider"]
        assert unrelated.auto_provision is DependencyStatus.USER_MUST_PROVIDE
        assert unrelated.approved_accounts == []

    def test_unrelated_provider_does_not_carry_authority_credentials(self) -> None:
        """Regression: authority-global accounts/credential refs are
        scoped to the auto-provision-authorized providers they belong
        to; an out-of-scope provider constraint must never carry them."""
        handoff = _build(providers=None)
        constraints = {
            constraint.provider: constraint
            for constraint in handoff.provider_constraints
        }
        unrelated = constraints["unrelated-provider"]
        assert unrelated.credential_refs == []
        assert unrelated.approved_accounts == []
        openai = constraints["openai"]
        assert openai.credential_refs == ["vault://prod/openai-key"]
        assert openai.approved_accounts == ["acct-openai-1"]


class TestExecutionBridgeFailClosed:
    """Fail-closed rules of the bridge (fix round): scoping is never
    silently disabled, inputs are validated as HandoffErrors, and a
    failed build never consumes a lease generation."""

    def test_trace_scoping_cannot_be_silently_disabled(self) -> None:
        """trace=None must fall back to the contract trace graph, so
        acceptance/Test-ID reachability is still enforced."""
        with pytest.raises(HandoffError, match="AC-999"):
            _build(trace=None, acceptance_ids=["AC-999"])
        handoff = _build(trace=None)
        assert [node.id for node in handoff.trace_nodes] == [
            "AC-001",
            "IMPL-001",
            "PROD-001",
            "REQ-001",
            "T-001",
        ]

    def test_missing_trace_graph_is_rejected(self) -> None:
        """With no trace argument and no contract trace graph, the
        bridge cannot prove reachability and refuses to build."""
        with pytest.raises(HandoffError, match="trace"):
            _build(
                trace=None,
                contract=None,
                providers=[],
                policy_bundle_hash=POLICY_HASH,
            )

    def test_attempt_budget_is_required(self) -> None:
        """attempt_budget=None raises a bridge HandoffError, never a
        raw pydantic ValidationError (fail-closed, KCC owns budgets)."""
        with pytest.raises(HandoffError, match="attempt budget"):
            _build(attempt_budget=None)

    def test_failed_build_does_not_consume_lease_generation(self) -> None:
        bridge = ExecutionBridge()
        with pytest.raises(HandoffError):
            _build(bridge, attempt_budget=None)
        handoff = _build(bridge)
        assert handoff.lease.generation == 1
        assert handoff.lease.lease_id == "LEASE-RUN-001-TASK-021-1"

    def test_overflow_failure_does_not_consume_lease_generation(self) -> None:
        bridge = ExecutionBridge(max_handoff_bytes=512)
        with pytest.raises(HandoffOverflowError):
            _build(bridge)
        bridge.max_handoff_bytes = 65536
        handoff = _build(bridge)
        assert handoff.lease.generation == 1


# ---------------------------------------------------------------------------
# Secrets -- references only, never plaintext (spec section 24)
# ---------------------------------------------------------------------------


class TestNoPlaintextSecrets:
    """Provider credentials travel as references only; raw secrets rejected."""

    def test_credential_references_only_in_provider_constraints(self) -> None:
        handoff = _build()
        constraint = handoff.provider_constraints[0]
        assert constraint.credential_refs == ["vault://prod/openai-key"]

    def test_serialized_pack_has_no_plaintext_secret(self) -> None:
        handoff = _build()
        payload = handoff.pack()
        assert b"sk-live-" not in payload
        assert b"vault://prod/openai-key" in payload

    def test_raw_secret_in_locked_decision_rejected(self) -> None:
        with pytest.raises(ValidationError, match="secret"):
            _build(
                locked_decisions=[
                    _decision(
                        "ADR-LEAK",
                        f"call the provider with {RAW_SECRET}",
                        ["REQ-001"],
                    )
                ]
            )

    def test_raw_secret_credential_ref_rejected(self) -> None:
        with pytest.raises(ValidationError, match="credential_ref"):
            ProviderConstraint(
                provider="openai",
                credential_refs=[RAW_SECRET],
            )

    def test_credential_ref_must_be_a_secret_reference(self) -> None:
        with pytest.raises(ValidationError, match="credential_ref"):
            ProviderConstraint(
                provider="openai",
                credential_refs=["https://example.com/key"],
            )
        constraint = ProviderConstraint(
            provider="openai",
            credential_refs=["env://OPENAI_KEY", "keychain://kcc/openai"],
        )
        assert constraint.credential_refs == ["env://OPENAI_KEY", "keychain://kcc/openai"]
