"""Execution Report bridge models for the KCC <-> Superpowers handoff.

Plan 03, Task 2 (Superpowers Execution Bridge): the worker's terminal
:class:`ExecutionReport` is an *evidence claim*, never proof.  KCC alone
accepts or advances a run, and :mod:`kcc_autobuild.evidence` re-checks
the chain-of-custody evidence (lease, commits, CI, usage) before the
claim is believed (plan Global Constraint: "Execution Report claims are
not trusted until KCC verifies chain-of-custody evidence").

Design Spec v1.2 context: task handoff pack (section 16.2), Definition
of Done (section 21: all acceptance criteria have passing required
Test IDs first, plus evidence traceability) and resumability (section
22: commits/artifacts, test results, review findings, spend/token
actuals, deviations).

Every execution attempt owns exactly one Execution Report bound to the
attempt lease (Global Constraint: "one KCC lease, one budget envelope,
one isolated workspace, and one Execution Report"), so the lease/run
identity and positive attempt number are required.  Status is
lowercase (``passed`` / ``failed`` / ``blocked``); a passed report must
declare acceptance evidence -- AC IDs, Test IDs and evidence refs --
and must not carry a failure classification, while failed/blocked
reports must carry one.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_execution_report.py`.
"""

from __future__ import annotations

from enum import Enum

from pydantic import Field, ValidationInfo, field_validator, model_validator

from kcc_autobuild.models import FailureClass, RUN_ID_PATTERN, StrictModel


def _require_nonempty(value: str, name: str) -> str:
    if not value.strip():
        raise ValueError(f"{name} must not be empty")
    return value


def _require_nonempty_unique(values: list[str], name: str) -> list[str]:
    if not values:
        raise ValueError(f"{name} must not be empty")
    for value in values:
        _require_nonempty(value, name)
    if len(values) != len(set(values)):
        raise ValueError(f"{name} must not contain duplicates")
    return values


class ExecutionStatus(str, Enum):
    """Terminal status of one execution attempt (lowercase keys).

    A ``passed`` report is the only status whose evidence must prove
    the acceptance criteria; ``failed`` and ``blocked`` reports carry a
    :class:`FailureInfo` classification instead.
    """

    PASSED = "passed"
    FAILED = "failed"
    BLOCKED = "blocked"


class AcceptanceEvidence(StrictModel):
    """Evidence statement for one acceptance criterion.

    Each statement names the acceptance criterion (``acceptance_id``,
    e.g. ``AC-014-1``), the Test IDs that validate it (Design Spec
    section 10.2/12.4: every acceptance criterion maps to one or more
    Test IDs) and the evidence refs (paths/URLs of the test artifacts).
    """

    acceptance_id: str
    test_ids: list[str]
    evidence_refs: list[str]

    @field_validator("acceptance_id")
    @classmethod
    def _acceptance_id_nonempty(cls, value: str) -> str:
        return _require_nonempty(value, "acceptance_id")

    @field_validator("test_ids")
    @classmethod
    def _test_ids_nonempty(cls, value: list[str]) -> list[str]:
        return _require_nonempty_unique(value, "test_ids")

    @field_validator("evidence_refs")
    @classmethod
    def _evidence_refs_nonempty(cls, value: list[str]) -> list[str]:
        return _require_nonempty_unique(value, "evidence_refs")


class FailureInfo(StrictModel):
    """A classified failure of one execution attempt.

    ``cls`` is the failure-class alias and must be one of the canonical
    taxonomy AUTH|RATE|OUTAGE|BUG|DATA|ENV|CONTRACT|UNKNOWN
    (:class:`kcc_autobuild.models.FailureClass` -- the canonical enum,
    never renamed).
    """

    cls: FailureClass
    message: str

    @field_validator("message")
    @classmethod
    def _message_nonempty(cls, value: str) -> str:
        return _require_nonempty(value, "message")


class UsageInfo(StrictModel):
    """Claimed provider usage for the attempt (spend/token actuals).

    Values are nonnegative; KCC reconciles the claim against provider
    records before the report can be accepted (:class:`ProviderUsageVerifier`).
    """

    tokens: int = 0
    cost_usd: float = 0.0
    provider_calls: int = 0

    @field_validator("tokens", "provider_calls")
    @classmethod
    def _nonnegative_int(cls, value: int, info: ValidationInfo) -> int:
        if value < 0:
            raise ValueError(f"{info.field_name} must not be negative")
        return value

    @field_validator("cost_usd")
    @classmethod
    def _nonnegative_float(cls, value: float) -> float:
        if value < 0:
            raise ValueError("cost_usd must not be negative")
        return value


class OutputInfo(StrictModel):
    """One declared task output (artifact, commit or CI run).

    ``kind`` names the output type (``file``, ``commit``, ``ci-run``,
    ``test-report``, ...).  ``ref`` is the artifact path/URL or, for
    ``commit``/``ci-run`` kinds, the commit id / CI run ref.  ``commit``
    optionally names the commit that produced the output and is verified
    by :class:`kcc_autobuild.evidence.CommitVerifier`.
    """

    kind: str
    ref: str
    commit: str | None = None

    @field_validator("kind", "ref")
    @classmethod
    def _required_text(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)

    @field_validator("commit")
    @classmethod
    def _commit_nonempty_when_present(cls, value: str | None) -> str | None:
        if value is not None:
            _require_nonempty(value, "commit")
        return value


class ExecutionReport(StrictModel):
    """Terminal Execution Report of one execution attempt (a claim).

    Chain of custody: the report is bound to the attempt lease
    (``lease_id`` + ``run_id`` + positive ``attempt``) and to its
    isolated workspace.  A ``passed`` report must declare acceptance
    evidence -- AC IDs, Test IDs and evidence refs -- and must not
    carry a failure classification; ``failed``/``blocked`` reports must
    carry one.

    Note: this is the claim only.  :class:`kcc_autobuild.evidence.EvidenceVerifier`
    is the only authority that turns a claim into an accepted outcome.
    """

    run_id: str = Field(pattern=RUN_ID_PATTERN)
    task_id: str
    attempt: int = Field(ge=1)
    status: ExecutionStatus
    lease_id: str
    workspace_id: str
    acceptance_evidence: list[AcceptanceEvidence] = Field(default_factory=list)
    failure: FailureInfo | None = None
    usage: UsageInfo
    outputs: list[OutputInfo] = Field(default_factory=list)
    deviations: list[str] = Field(default_factory=list)
    trace_updates: list[str] = Field(default_factory=list)

    @field_validator("task_id", "lease_id", "workspace_id")
    @classmethod
    def _identity_nonempty(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)

    @field_validator("deviations", "trace_updates")
    @classmethod
    def _entries_nonempty(cls, value: list[str], info: ValidationInfo) -> list[str]:
        for entry in value:
            _require_nonempty(entry, info.field_name)
        return value

    @model_validator(mode="after")
    def _acceptance_ids_unique(self) -> ExecutionReport:
        ac_ids = [evidence.acceptance_id for evidence in self.acceptance_evidence]
        if len(ac_ids) != len(set(ac_ids)):
            raise ValueError("acceptance of the report must reference unique AC ids")
        return self

    @model_validator(mode="after")
    def _status_evidence_consistency(self) -> ExecutionReport:
        if self.status is ExecutionStatus.PASSED:
            if not self.acceptance_evidence:
                raise ValueError(
                    "passed reports must declare acceptance evidence "
                    "(AC IDs, Test IDs and evidence refs)"
                )
            if self.failure is not None:
                raise ValueError(
                    "passed reports must not carry a failure classification"
                )
        elif self.failure is None:
            raise ValueError(
                f"{self.status.value} reports must carry a failure classification"
            )
        return self
