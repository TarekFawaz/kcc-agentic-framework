"""Outcome-based validation / the DONE gate.

Plan 05, Task 4 (Outcome-based validation / DONE gate): code generated,
compilation passed, unit tests passed or a deployment command succeeded
are NOT sufficient (spec 21) — the run is DONE only when every
contract-specific outcome condition holds (spec 20.2, 21):

* every locked Definition-of-Done outcome
  (``contract.tier1.definition_of_done_ids`` — a required Tier-1
  invariant covered by the canonical lock hash) is present in the
  executed production-validation evidence
  (``evidence.production_validation_ids``);
* every such outcome is also traced in the trace graph as a
  ``production_validation`` node (a production outcome that is neither
  traced nor executed is a missing production outcome and prevents
  DONE);
* monitoring is functioning (``monitoring_ok``);
* rollback/recovery evidence exists when the contract requires it
  (``contract.tier1.requires_rollback_evidence``);
* no critical unsolved finding remains (zero ``critical_findings``);
* budget and rate conformance hold (``budget_conformant``,
  ``rate_conformant``).

The behavioral contract is owned by
:file:`.KCC/runtime/tests/test_validation.py`:

- :class:`ValidationEvidence` is the executed-evidence pack; it is
  fail-closed (every boolean defaults to False, every list to empty) so
  DONE can only be reached by explicitly recorded evidence.
- :class:`DoneEvaluation` is the gate verdict: ``done`` with the
  deterministic ``missing`` list (empty exactly when ``done`` is True).
- :class:`DefinitionOfDoneEvaluator` is the pure decision function —
  no I/O, no wall clock, byte-identical output for identical input;
  the ``missing`` list is built in a fixed order (sorted outcome ids:
  trace coverage, then executed evidence; then monitoring, rollback
  evidence, critical findings, budget, rate).
- Malformed contract/trace/evidence input never gets guessed at: it
  raises :class:`ValidationContractError` /
  :class:`ValidationEvidenceError` (fail closed), mirroring the
  deployment coordinator of Plan 05 Task 3.
"""

from __future__ import annotations

from typing import Any

from pydantic import Field, field_validator, model_validator

from kcc_autobuild.models import StrictModel

PRODUCTION_VALIDATION_KIND = "production_validation"
"""Canonical trace node kind for a production validation outcome."""

_EVIDENCE_FIELDS = (
    "production_validation_ids",
    "monitoring_ok",
    "rollback_evidence",
    "critical_findings",
    "budget_conformant",
    "rate_conformant",
)
"""The executed-evidence surface the gate reads."""


def _select_evidence_fields(evidence: Any) -> dict[str, Any]:
    """Validate the executed-evidence view and select its fields.

    Fail closed: an evidence pack must carry the whole executed-evidence
    surface (booleans as real booleans, id/finding lists with non-empty
    string entries) — a half-shaped pack is never interpreted by guess.
    """
    if evidence is None:
        raise ValidationEvidenceError("evidence is required for the DONE gate")
    missing = [name for name in _EVIDENCE_FIELDS if not hasattr(evidence, name)]
    if missing:
        raise ValidationEvidenceError(
            "evidence is missing fields: " + ", ".join(missing)
        )
    executed_ids = _evidence_string_list(
        evidence.production_validation_ids, "production_validation_ids"
    )
    findings = _evidence_string_list(evidence.critical_findings, "critical_findings")
    selected = {
        "production_validation_ids": set(executed_ids),
        "critical_findings": findings,
    }
    for name in (
        "monitoring_ok",
        "rollback_evidence",
        "budget_conformant",
        "rate_conformant",
    ):
        value = getattr(evidence, name)
        if not isinstance(value, bool):
            raise ValidationEvidenceError(
                f"evidence.{name} must be a bool, got {type(value).__name__}"
            )
        selected[name] = value
    return selected


def _evidence_string_list(value: Any, name: str) -> list[str]:
    if not isinstance(value, (list, tuple)):
        raise ValidationEvidenceError(
            f"evidence.{name} must be a list of non-empty strings, "
            f"got {type(value).__name__}"
        )
    for entry in value:
        if not isinstance(entry, str) or not entry.strip():
            raise ValidationEvidenceError(
                f"evidence.{name} entries must be non-empty strings"
            )
    return list(value)


class ValidationEvidence(StrictModel):
    """Executed production-validation evidence (spec 20.2, 21).

    Fail-closed defaults: nothing is asserted unless explicitly
    recorded — compiling/passing/deploying alone never satisfies this
    pack.  ``production_validation_ids`` are the executed production
    smoke/E2E validation outcomes (spec 20.2), ``monitoring_ok`` that
    observability is functioning, ``rollback_evidence`` that the
    required rollback/recovery evidence exists, ``critical_findings``
    the remaining critical security/functional findings (zero of them
    may remain), and ``budget_conformant`` / ``rate_conformant`` the
    budget and rate conformance of the run (spec 21).
    """

    production_validation_ids: list[str] = Field(default_factory=list)
    monitoring_ok: bool = False
    rollback_evidence: bool = False
    critical_findings: list[str] = Field(default_factory=list)
    budget_conformant: bool = False
    rate_conformant: bool = False

    @field_validator("production_validation_ids")
    @classmethod
    def _executed_ids_unique(cls, value: list[str]) -> list[str]:
        if not value:
            return value
        if any(not entry.strip() for entry in value):
            raise ValueError(
                "production_validation_ids entries must not be empty"
            )
        if len(value) != len(set(value)):
            raise ValueError(
                "production_validation_ids must not contain duplicates"
            )
        return value

    @field_validator("critical_findings")
    @classmethod
    def _findings_not_blank(cls, value: list[str]) -> list[str]:
        if any(not entry.strip() for entry in value):
            raise ValueError("critical_findings entries must not be empty")
        return value


class DoneEvaluation(StrictModel):
    """Verdict of the DONE gate for one run.

    ``done`` is True exactly when nothing is ``missing``: a DONE verdict
    never carries a missing condition, and a non-DONE verdict always
    reports every missing condition (fail-closed, deterministic).
    """

    done: bool
    missing: list[str] = Field(default_factory=list)

    @field_validator("missing")
    @classmethod
    def _missing_entries_not_blank(cls, value: list[str]) -> list[str]:
        if any(not entry.strip() for entry in value):
            raise ValueError("missing entries must not be empty")
        return value

    @model_validator(mode="after")
    def _consistent(self) -> DoneEvaluation:
        if self.done and self.missing:
            raise ValueError("a DONE evaluation must not report missing conditions")
        if not self.done and not self.missing:
            raise ValueError("a non-DONE evaluation must report what is missing")
        return self


class DefinitionOfDoneError(RuntimeError):
    """Base class for DONE-gate refusals (fail closed)."""


class ValidationContractError(DefinitionOfDoneError):
    """The locked contract/trace does not carry the DoD surface.

    Raised when ``contract.tier1``, ``contract.tier1.definition_of_done_ids``
    or ``trace.nodes`` is missing or malformed: the gate refuses to
    classify a run whose locked outcome set it cannot read, and no
    verdict is guessed.
    """


class ValidationEvidenceError(DefinitionOfDoneError):
    """The executed-validation evidence is missing or malformed.

    Raised when the evidence pack does not carry the complete
    executed-evidence surface (or carries non-bool flags / blank or
    non-string ids and findings): fail closed instead of interpreting a
    partial or conflicting claim.
    """


class DefinitionOfDoneEvaluator:
    """Pure decision function for the DONE gate.

    Stateless and deterministic: every input — the locked Tier-1 DoD
    outcome set and rollback-evidence requirement, the trace graph
    (traced outcomes), the executed-evidence pack — is validated before
    evaluation, and the verdict's ``missing`` list is ordered
    deterministically (outcome ids first, then the remaining gates in
    the fixed order above).
    """

    def evaluate(self, contract: Any, trace: Any, evidence: Any) -> DoneEvaluation:
        """Evaluate every Definition-of-Done condition of the contract.

        Returns :class:`DoneEvaluation`: ``done`` True only when all
        locked outcome ids are traced AND executed, monitoring is
        confirmed, rollback evidence exists when required, no critical
        finding remains, and budget/rate conformance holds.
        """
        tier1 = self._tier1(contract)
        outcome_ids = self._outcome_ids(tier1)
        requires_rollback = self._rollback_required(tier1)
        traced_ids = self._traced_outcome_ids(trace)
        evidence_fields = _select_evidence_fields(evidence)

        missing: list[str] = []
        for outcome_id in sorted(set(outcome_ids)):
            if outcome_id not in traced_ids:
                missing.append(
                    f"production outcome '{outcome_id}' is not traced as a "
                    "production_validation node"
                )
            if outcome_id not in evidence_fields["production_validation_ids"]:
                missing.append(f"missing production outcome '{outcome_id}'")
        if not evidence_fields["monitoring_ok"]:
            missing.append("monitoring is not confirmed")
        if requires_rollback and not evidence_fields["rollback_evidence"]:
            missing.append("rollback evidence is required but missing")
        if evidence_fields["critical_findings"]:
            missing.append(
                "critical findings remain: "
                + ", ".join(sorted(evidence_fields["critical_findings"]))
            )
        if not evidence_fields["budget_conformant"]:
            missing.append("budget is not conformant")
        if not evidence_fields["rate_conformant"]:
            missing.append("rate is not conformant")

        return DoneEvaluation(done=not missing, missing=missing)

    @staticmethod
    def _tier1(contract: Any) -> Any:
        tier1 = getattr(contract, "tier1", None)
        if tier1 is None:
            raise ValidationContractError(
                "the DONE gate requires a locked contract carrying "
                "tier-1 invariants (contract.tier1)"
            )
        return tier1

    @staticmethod
    def _outcome_ids(tier1: Any) -> list[str]:
        value = getattr(tier1, "definition_of_done_ids", None)
        if value is None:
            raise ValidationContractError(
                "the DONE gate requires the locked Definition-of-Done "
                "outcome set (contract.tier1.definition_of_done_ids)"
            )
        if not isinstance(value, (list, tuple)):
            raise ValidationContractError(
                "contract.tier1.definition_of_done_ids must be a list of "
                f"non-empty strings, got {type(value).__name__}"
            )
        for outcome_id in value:
            if not isinstance(outcome_id, str) or not outcome_id.strip():
                raise ValidationContractError(
                    "contract.tier1.definition_of_done_ids entries must "
                    "be non-empty strings"
                )
        return list(value)

    @staticmethod
    def _rollback_required(tier1: Any) -> bool:
        """The Tier-1 rollback-evidence requirement.

        A tier-1 view without the flag matches the contract model
        default: rollback evidence is not required.
        """
        value = getattr(tier1, "requires_rollback_evidence", False)
        if not isinstance(value, bool):
            raise ValidationContractError(
                "contract.tier1.requires_rollback_evidence must be a bool"
            )
        return value

    @staticmethod
    def _traced_outcome_ids(trace: Any) -> set[str]:
        nodes = getattr(trace, "nodes", None)
        if nodes is None:
            raise ValidationContractError(
                "the DONE gate requires a trace graph (trace.nodes)"
            )
        traced: set[str] = set()
        for node in nodes:
            if getattr(node, "kind", None) != PRODUCTION_VALIDATION_KIND:
                continue
            node_id = getattr(node, "id", None)
            if not isinstance(node_id, str) or not node_id.strip():
                raise ValidationContractError(
                    "production_validation trace nodes must carry a "
                    "non-empty id"
                )
            traced.add(node_id)
        return traced
