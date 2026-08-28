"""Behavioral contract for outcome-based validation / the DONE gate.

Owned by ``test_validation.py`` (see the KCC x Superpowers Hybrid
Framework Plan 05, Task 4: Outcome-based validation / DONE gate, in
``.superpowers/bootstrap/plans/2026-08-27-05-resume-deploy-validation.task-contracts.md``).

Spec 21: the default Definition of Done is OUTCOME-based -- code
generated, compilation passed, unit tests passed or a deployment command
succeeded are NOT sufficient; DONE is sufficient only when all
contract-specific conditions are satisfied, including (spec 20.2 and
21): all contract-defined production smoke/E2E validations pass,
observability/monitoring is functioning, required rollback/recovery
evidence exists, no critical security/functional finding remains, and
budget and rate/conformance hold.

The gate is pure and fail-closed:

* :class:`DefinitionOfDoneEvaluator.evaluate` reads the LOCKED outcome
  set from ``contract.tier1.definition_of_done_ids`` (a required Tier-1
  invariant, part of the canonical hash -- the outcomes that gate DONE
  are locked before the build, never decided afterwards);
* every declared DoD id is required IN the executed evidence
  (``evidence.production_validation_ids``) AND traced as a
  ``production_validation`` node in ``trace`` -- a missing production
  outcome prevents DONE;
* ``monitoring_ok``, rollback evidence when the contract requires it
  (``contract.tier1.requires_rollback_evidence``), zero
  ``critical_findings``, ``budget_conformant`` and ``rate_conformant``
  are required as well;
* :class:`DoneEvaluation` carries the deterministic ``missing`` list
  (empty exactly when ``done`` is True), and any malformed
  contract/trace/evidence input raises a
  :class:`ValidationContractError` / :class:`ValidationEvidenceError`
  instead of being guessed at.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from pydantic import ValidationError

from kcc_autobuild.contract import (
    AuthorityEnvelope,
    BuildContract,
    MoneyPolicy,
    RolloutClass,
    Tier1Invariants,
    lock_contract,
    tier1_canonical_hash,
)
from kcc_autobuild.models import ReadinessStatus
from kcc_autobuild.readiness import EvidenceRecord, ReadinessItem, ReadinessPack
from kcc_autobuild.trace import TraceEdge, TraceGraph, TraceNode
from kcc_autobuild.validation import (
    DefinitionOfDoneEvaluator,
    DoneEvaluation,
    ValidationContractError,
    ValidationEvidence,
    ValidationEvidenceError,
)

# --- Dual-outcome DoD surface ------------------------------------------------
# Two declared production outcomes so "one validated, one missing" is
# expressible; PROD-SMOKE-99 is an extra executed/traced outcome that
# must never gate DONE (DoD ids are the ONLY outcomes that gate).

DOD_IDS = ["PROD-SMOKE-06", "PROD-SMOKE-08"]
EXTRA_OUTCOME = "PROD-SMOKE-99"


class _Node:
    """Minimal trace node view (id + kind)."""

    def __init__(self, node_id: str, kind: str) -> None:
        self.id = node_id
        self.kind = kind


class _Graph:
    """Minimal trace graph view carrying typed nodes."""

    def __init__(self, nodes: list[_Node]) -> None:
        self.nodes = nodes


class _FakeTier1:
    """The tier-1 lock surface the evaluator reads (duck-typed)."""

    def __init__(
        self,
        *,
        definition_of_done_ids: object = None,
        requires_rollback_evidence: bool = False,
        has_rollback_flag: bool = True,
    ) -> None:
        self.definition_of_done_ids = (
            list(DOD_IDS) if definition_of_done_ids is None else definition_of_done_ids
        )
        if has_rollback_flag:
            self.requires_rollback_evidence = requires_rollback_evidence


class _BareTier1:
    """A tier-1 surface that never declares its Definition of Done sets."""


class _FakeContract:
    """The locked-contract view the evaluator receives."""

    def __init__(self, tier1: object = None, **tier1_kwargs: object) -> None:
        self.tier1 = tier1 if tier1 is not None else _FakeTier1(**tier1_kwargs)


def _trace(*production_validation_ids: str) -> _Graph:
    """A trace with ``production_validation`` nodes for the given ids."""
    nodes = [_Node(pid, "production_validation") for pid in production_validation_ids]
    nodes.append(_Node("REQ-001", "requirement"))
    return _Graph(nodes)


def _evidence(**overrides: object) -> ValidationEvidence:
    """A fully-passing evidence pack, one condition overridable at a time."""
    defaults: dict[str, object] = {
        "production_validation_ids": list(DOD_IDS),
        "monitoring_ok": True,
        "rollback_evidence": True,
        "critical_findings": [],
        "budget_conformant": True,
        "rate_conformant": True,
    }
    defaults.update(overrides)
    return ValidationEvidence(**defaults)  # type: ignore[arg-type]


def _evaluate(contract: object, trace: object, evidence: object) -> DoneEvaluation:
    return DefinitionOfDoneEvaluator().evaluate(contract, trace, evidence)


# --- DoneEvaluation model ----------------------------------------------------


def test_done_evaluation_is_consistent() -> None:
    """done=True requires an empty missing list; a non-DONE gate must
    report what is missing (fail-closed, like ReportAcceptance)."""
    assert DoneEvaluation(done=True, missing=[]).done is True
    assert DoneEvaluation(done=False, missing=["something"]).missing == [
        "something"
    ]
    with pytest.raises(ValidationError):
        DoneEvaluation(done=True, missing=["something"])
    with pytest.raises(ValidationError):
        DoneEvaluation(done=False, missing=[])


# --- ValidationEvidence model ------------------------------------------------


def test_validation_evidence_defaults_are_fail_closed() -> None:
    """An empty evidence pack asserts nothing positive: every boolean
    defaults to False and every list to empty."""
    evidence = ValidationEvidence()
    assert evidence.production_validation_ids == []
    assert evidence.monitoring_ok is False
    assert evidence.rollback_evidence is False
    assert evidence.critical_findings == []
    assert evidence.budget_conformant is False
    assert evidence.rate_conformant is False


def test_validation_evidence_rejects_blank_production_validation_id() -> None:
    with pytest.raises(ValidationError):
        ValidationEvidence(production_validation_ids=["PROD-01", "  "])


def test_validation_evidence_rejects_duplicate_production_validation_ids() -> None:
    with pytest.raises(ValidationError):
        ValidationEvidence(production_validation_ids=["PROD-01", "PROD-01"])


def test_validation_evidence_rejects_blank_critical_finding() -> None:
    with pytest.raises(ValidationError):
        ValidationEvidence(critical_findings=["  "])


# --- The DONE gate: happy path ----------------------------------------------


def test_all_conditions_met_is_done() -> None:
    """Full outcome set traced and executed, monitoring/rollback/budget/
    rate OK, zero critical findings => DONE with nothing missing."""
    contract = _FakeContract()
    evaluation = _evaluate(
        contract,
        _trace(*DOD_IDS, EXTRA_OUTCOME),
        _evidence(production_validation_ids=[*DOD_IDS, EXTRA_OUTCOME]),
    )
    assert evaluation.done is True
    assert evaluation.missing == []


def test_extra_executed_and_traced_outcomes_do_not_gate() -> None:
    """Outcomes beyond the declared DoD ids never block DONE -- only the
    contract-locked set gates."""
    contract = _FakeContract(definition_of_done_ids=["PROD-SMOKE-06"])
    evaluation = _evaluate(
        contract,
        _trace(*DOD_IDS, EXTRA_OUTCOME),
        _evidence(production_validation_ids=[*DOD_IDS, EXTRA_OUTCOME]),
    )
    assert evaluation.done is True


# --- Each required condition -------------------------------------------------


def test_missing_definition_of_done_outcome_prevents_done() -> None:
    """A declared DoD outcome with no executed production validation is
    a missing production outcome => NOT DONE (spec 20.2 / 21)."""
    contract = _FakeContract()
    evaluation = _evaluate(
        contract,
        _trace(*DOD_IDS, EXTRA_OUTCOME),
        _evidence(production_validation_ids=["PROD-SMOKE-06", EXTRA_OUTCOME]),
    )
    assert evaluation.done is False
    assert "missing production outcome 'PROD-SMOKE-08'" in evaluation.missing


def test_missing_traced_production_outcome_prevents_done() -> None:
    """A DoD outcome that is not traced as a ``production_validation``
    node in the trace graph is a missing production outcome => NOT DONE."""
    contract = _FakeContract()
    evaluation = _evaluate(
        contract,
        _trace("PROD-SMOKE-08"),
        _evidence(production_validation_ids=[*DOD_IDS, EXTRA_OUTCOME]),
    )
    assert evaluation.done is False
    assert (
        "production outcome 'PROD-SMOKE-06' is not traced as a "
        "production_validation node"
    ) in evaluation.missing


def test_done_requires_monitoring_ok() -> None:
    """Spec 21: observability must be functioning; spec 20.2: monitoring
    must be active."""
    evaluation = _evaluate(
        _FakeContract(), _trace(*DOD_IDS), _evidence(monitoring_ok=False)
    )
    assert evaluation.done is False
    assert "monitoring is not confirmed" in evaluation.missing


def test_done_requires_rollback_evidence_when_contract_requires_it() -> None:
    """A contract that locks ``requires_rollback_evidence`` needs the
    rollback/recovery evidence record (spec 21)."""
    contract = _FakeContract(requires_rollback_evidence=True)
    evaluation = _evaluate(
        contract, _trace(*DOD_IDS), _evidence(rollback_evidence=False)
    )
    assert evaluation.done is False
    assert "rollback evidence is required but missing" in evaluation.missing

    evaluation = _evaluate(
        contract, _trace(*DOD_IDS), _evidence(rollback_evidence=True)
    )
    assert evaluation.done is True


def test_rollback_evidence_not_required_when_contract_does_not_require_it() -> None:
    """Without the locked flag the absence of a rollback record is not a
    DoD failure (only the contract may raise the bar)."""
    contract = _FakeContract(requires_rollback_evidence=False)
    evaluation = _evaluate(
        contract, _trace(*DOD_IDS), _evidence(rollback_evidence=False)
    )
    assert evaluation.done is True


def test_done_requires_zero_critical_findings() -> None:
    """Spec 20.2/21: no critical security/functional finding may remain."""
    evaluation = _evaluate(
        _FakeContract(),
        _trace(*DOD_IDS),
        _evidence(critical_findings=["auth bypass on reset"]),
    )
    assert evaluation.done is False
    assert "critical findings remain: auth bypass on reset" in evaluation.missing


def test_done_requires_budget_conformant() -> None:
    """Spec 21: budget conformance holds."""
    evaluation = _evaluate(
        _FakeContract(), _trace(*DOD_IDS), _evidence(budget_conformant=False)
    )
    assert evaluation.done is False
    assert "budget is not conformant" in evaluation.missing


def test_done_requires_rate_conformant() -> None:
    """Spec 21: rate conformance holds."""
    evaluation = _evaluate(
        _FakeContract(), _trace(*DOD_IDS), _evidence(rate_conformant=False)
    )
    assert evaluation.done is False
    assert "rate is not conformant" in evaluation.missing


# --- Determinism and fail-closed input discipline ----------------------------


def test_missing_conditions_are_reported_in_deterministic_order() -> None:
    """The missing list is byte-identical for identical input: sorted
    outcome ids (trace, then executed evidence), then monitoring,
    rollback, critical findings, budget, rate."""
    contract = _FakeContract(requires_rollback_evidence=True)
    evaluation = _evaluate(
        contract,
        _trace(),
        _evidence(
            production_validation_ids=[],
            monitoring_ok=False,
            rollback_evidence=False,
            critical_findings=["finding-b", "finding-a"],
            budget_conformant=False,
            rate_conformant=False,
        ),
    )
    assert evaluation.done is False
    assert evaluation.missing == [
        "production outcome 'PROD-SMOKE-06' is not traced as a "
        "production_validation node",
        "missing production outcome 'PROD-SMOKE-06'",
        "production outcome 'PROD-SMOKE-08' is not traced as a "
        "production_validation node",
        "missing production outcome 'PROD-SMOKE-08'",
        "monitoring is not confirmed",
        "rollback evidence is required but missing",
        "critical findings remain: finding-a, finding-b",
        "budget is not conformant",
        "rate is not conformant",
    ]


def test_evaluator_rejects_contract_without_tier1() -> None:
    with pytest.raises(ValidationContractError):
        _evaluate(object(), _trace(*DOD_IDS), _evidence())


def test_evaluator_rejects_contract_without_definition_of_done_ids() -> None:
    """A locked surface that never declares its outcomes cannot be gated:
    the DoD set is mandatory, never guessed."""
    with pytest.raises(ValidationContractError):
        _evaluate(_FakeContract(_BareTier1()), _trace(*DOD_IDS), _evidence())


def test_evaluator_rejects_non_string_definition_of_done_id() -> None:
    contract = _FakeContract(definition_of_done_ids=["PROD-01", 7])
    with pytest.raises(ValidationContractError):
        _evaluate(contract, _trace(*DOD_IDS), _evidence())


def test_evaluator_rejects_trace_without_nodes() -> None:
    with pytest.raises(ValidationContractError):
        _evaluate(_FakeContract(), object(), _evidence())


def test_evaluator_rejects_incomplete_evidence() -> None:
    """An evidence pack that is not the executed-validation evidence
    shape fails closed instead of guessing what is missing."""
    with pytest.raises(ValidationEvidenceError):
        _evaluate(_FakeContract(), _trace(*DOD_IDS), object())


def test_evaluator_rejects_evidence_without_production_validation_ids() -> None:
    class _PartialEvidence:
        monitoring_ok = True
        rollback_evidence = True
        critical_findings = []
        budget_conformant = True
        rate_conformant = True

    with pytest.raises(ValidationEvidenceError):
        _evaluate(_FakeContract(), _trace(*DOD_IDS), _PartialEvidence())


def test_evaluator_rejects_evidence_with_blank_executed_outcome_id() -> None:
    class _BlankIdEvidence:
        production_validation_ids = ["", "PROD-SMOKE-06"]
        monitoring_ok = True
        rollback_evidence = True
        critical_findings = []
        budget_conformant = True
        rate_conformant = True

    with pytest.raises(ValidationEvidenceError):
        _evaluate(_FakeContract(), _trace(*DOD_IDS), _BlankIdEvidence())


def test_evaluator_defaults_absent_rollback_flag_to_false() -> None:
    """A tier-1 view without the rollback-evidence flag matches the
    contract model default: rollback evidence is not required."""
    contract = _FakeContract(has_rollback_flag=False)
    evaluation = _evaluate(
        contract, _trace(*DOD_IDS), _evidence(rollback_evidence=False)
    )
    assert evaluation.done is True


# --- Real locked BuildContract integration -----------------------------------
# The gate must be operable against the ACTUAL contract model: the DoD
# outcome set is a Tier-1 locked invariant on
# :class:`~kcc_autobuild.contract.Tier1Invariants` (StrictModel forbids
# extra fields), so the duck-typed fakes above cannot hide a gap between
# the evaluator and a genuinely locked BuildContract.  These tests lock a
# real contract via :func:`~kcc_autobuild.contract.lock_contract` and run
# the full DONE gate against it.


REAL_NOW = datetime(2026, 1, 2, 12, 0, 0, tzinfo=timezone.utc)
EVIDENCE_TTL = timedelta(hours=4)
REAL_DOD_IDS = ["PROD-01", "PROD-02"]


def _real_trace() -> TraceGraph:
    """A trace where REQ-001 reaches both AC and PROD coverage, with two
    production_validation outcomes (PROD-01, PROD-02)."""
    return TraceGraph(
        nodes=[
            TraceNode(id="REQ-001", kind="requirement"),
            TraceNode(id="IMPL-01", kind="implementation"),
            TraceNode(id="AC-001", kind="acceptance"),
            TraceNode(id="PROD-01", kind="production_validation"),
            TraceNode(id="PROD-02", kind="production_validation"),
        ],
        edges=[
            TraceEdge(source="REQ-001", target="IMPL-01"),
            TraceEdge(source="IMPL-01", target="AC-001"),
            TraceEdge(source="IMPL-01", target="PROD-01"),
            TraceEdge(source="IMPL-01", target="PROD-02"),
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
    definition_of_done_ids: object = None,
    requires_rollback_evidence: bool = False,
) -> BuildContract:
    """A genuinely locked BuildContract carrying the Tier-1 DoD lock."""
    contract = BuildContract(
        tier1=Tier1Invariants(
            product_scope="internal CLI analysis tool",
            non_goals=["no public API"],
            primary_user_journeys=["run one analysis end to end"],
            authority=AuthorityEnvelope(
                production_deployment=True,
                rollback=True,
            ),
            money=MoneyPolicy(),
            production_target="prod/kcc-demo",
            rollout_class=RolloutClass.CANARY,
            definition_of_done=(
                "analysis output is produced end to end and validated in staging"
            ),
            definition_of_done_ids=(
                list(REAL_DOD_IDS) if definition_of_done_ids is None
                else definition_of_done_ids
            ),
            requires_rollback_evidence=requires_rollback_evidence,
        ),
        trace=_real_trace(),
        readiness=_real_readiness(),
    )
    return lock_contract(contract, now=REAL_NOW)


def test_definition_of_done_ids_are_locked_tier1_invariants() -> None:
    """The DoD outcome set is a Tier-1 locked invariant: it lives on the
    real contract model and is part of the canonical lock hash, so it
    cannot be altered after lock without a contract revision."""
    locked = _locked_real_contract()
    assert locked.tier1.definition_of_done_ids == REAL_DOD_IDS
    assert locked.contract_hash == tier1_canonical_hash(locked)

    twin = _locked_real_contract(definition_of_done_ids=["PROD-01"])
    assert twin.contract_hash != locked.contract_hash


def test_real_locked_contract_full_evidence_is_done() -> None:
    contract = _locked_real_contract()
    evaluation = _evaluate(
        contract,
        contract.trace,
        ValidationEvidence(
            production_validation_ids=list(REAL_DOD_IDS),
            monitoring_ok=True,
            rollback_evidence=True,
            budget_conformant=True,
            rate_conformant=True,
        ),
    )
    assert evaluation.done is True
    assert evaluation.missing == []


def test_real_locked_contract_missing_outcome_blocks_done() -> None:
    """Against a genuinely locked contract, a missing production outcome
    prevents DONE (the prescribed "missing production outcome" case)."""
    contract = _locked_real_contract()
    evaluation = _evaluate(
        contract,
        contract.trace,
        ValidationEvidence(
            production_validation_ids=["PROD-01"],
            monitoring_ok=True,
            rollback_evidence=True,
            budget_conformant=True,
            rate_conformant=True,
        ),
    )
    assert evaluation.done is False
    assert "missing production outcome 'PROD-02'" in evaluation.missing


def test_real_locked_contract_rollback_evidence_gate() -> None:
    """The locked ``requires_rollback_evidence`` decision is honored by
    the gate against the real contract model."""
    contract = _locked_real_contract(requires_rollback_evidence=True)
    evidence = ValidationEvidence(
        production_validation_ids=list(REAL_DOD_IDS),
        monitoring_ok=True,
        rollback_evidence=False,
        budget_conformant=True,
        rate_conformant=True,
    )
    evaluation = _evaluate(contract, contract.trace, evidence)
    assert evaluation.done is False
    assert "rollback evidence is required but missing" in evaluation.missing

    evidence.rollback_evidence = True
    evaluation = _evaluate(contract, contract.trace, evidence)
    assert evaluation.done is True
