"""Behavioral tests for the Execution Report bridge and evidence gate.

Written first (strict TDD red phase) against the external behavior
contract of :mod:`kcc_autobuild.bridge` (the :class:`ExecutionReport`
models) and :mod:`kcc_autobuild.evidence` (:class:`EvidenceVerifier`,
:class:`ReportAcceptance`) -- KCC x Superpowers Hybrid Framework
Plan 03, Task 2; Design Spec v1.2 sections 16.2, 21, 22; plan Global
Constraints.

Binding semantics under test:

* every execution attempt reports exactly one Execution Report -- a
  lease is required (``lease_id``/``run_id`` nonempty, canonical run
  identity, positive attempt number);
* report status is lowercase (``passed`` / ``failed`` / ``blocked``);
* a passed report requires acceptance evidence: AC IDs, Test IDs and
  evidence refs; a failed/blocked report carries a failure
  classification from the canonical taxonomy AUTH|RATE|OUTAGE|BUG|
  DATA|ENV|CONTRACT|UNKNOWN (``FailureClass``, never renamed);
* Execution Report claims are not trusted until KCC verifies
  chain-of-custody evidence: a stale lease, a nonexistent claimed
  commit, invalid passed evidence (referenced CI runs that did not
  pass) or a usage reconciliation failure all return
  ``accepted=False`` with ``counts_as_failed_attempt=True``.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from kcc_autobuild.bridge import (
    AcceptanceEvidence,
    ExecutionReport,
    ExecutionStatus,
    FailureInfo,
    OutputInfo,
    UsageInfo,
)
from kcc_autobuild.evidence import (
    CiVerifier,
    CommitVerifier,
    EvidenceVerifier,
    LeaseVerifier,
    ProviderUsageVerifier,
    ReportAcceptance,
)
from kcc_autobuild.models import FailureClass

COMMIT_A = "a" * 40
COMMIT_B = "b" * 40


# ---------------------------------------------------------------------------
# Fakes for the chain-of-custody verifier protocols
# ---------------------------------------------------------------------------


class FakeLeaseVerifier:
    """Records calls; the ``live`` flag controls the lease verdict."""

    def __init__(self, live: bool = True) -> None:
        self.live = live
        self.calls: list[tuple[str, str]] = []

    def lease_is_live(self, lease_id: str, run_id: str) -> bool:
        self.calls.append((lease_id, run_id))
        return self.live and bool(lease_id.strip())


class FakeCommitVerifier:
    """Says a commit exists iff its id is in the known set."""

    def __init__(self, existing: list[str] | None = None) -> None:
        self.existing = set(existing or [])
        self.calls: list[str] = []

    def commit_exists(self, commit_id: str) -> bool:
        self.calls.append(commit_id)
        return commit_id in self.existing


class FakeCiVerifier:
    """Says a CI run passed iff its ref is in the passing set."""

    def __init__(self, passed_runs: list[str] | None = None) -> None:
        self.passed_runs = set(passed_runs or [])
        self.calls: list[str] = []

    def ci_run_passed(self, ci_run_ref: str) -> bool:
        self.calls.append(ci_run_ref)
        return ci_run_ref in self.passed_runs


class FakeUsageVerifier:
    """Records calls; the ``reconciles`` flag controls reconciliation."""

    def __init__(self, reconciles: bool = True) -> None:
        self.reconciles = reconciles
        self.calls: list[UsageInfo] = []

    def usage_reconciles(self, usage: UsageInfo) -> bool:
        self.calls.append(usage)
        return self.reconciles


# ---------------------------------------------------------------------------
# Builders (a minimally valid report by default)
# ---------------------------------------------------------------------------


def _evidence(
    acceptance_id: str = "AC-014-1",
    test_ids: list[str] | None = None,
    evidence_refs: list[str] | None = None,
) -> AcceptanceEvidence:
    return AcceptanceEvidence(
        acceptance_id=acceptance_id,
        test_ids=test_ids if test_ids is not None else ["T-041", "T-042"],
        evidence_refs=(
            evidence_refs
            if evidence_refs is not None
            else ["artifacts/run-001/t-041.log", "artifacts/run-001/t-042.log"]
        ),
    )


def _usage(tokens: int = 120_000, cost_usd: float = 1.25, provider_calls: int = 42) -> UsageInfo:
    return UsageInfo(tokens=tokens, cost_usd=cost_usd, provider_calls=provider_calls)


def _failure(cls: FailureClass = FailureClass.BUG, message: str = "boom") -> FailureInfo:
    return FailureInfo(cls=cls, message=message)


def _report(*, status: str = "passed", **overrides: object) -> ExecutionReport:
    fields: dict[str, object] = {
        "run_id": "RUN-001",
        "task_id": "TASK-021",
        "attempt": 1,
        "status": status,
        "lease_id": "LEASE-2026-0001",
        "workspace_id": "WS-RUN-001",
        "acceptance_evidence": [_evidence()],
        "failure": None,
        "usage": _usage(),
        "outputs": [],
        "deviations": [],
        "trace_updates": [],
    }
    fields.update(overrides)
    return ExecutionReport(**fields)


def _verifier(
    lease: FakeLeaseVerifier | None = None,
    commits: FakeCommitVerifier | None = None,
    ci: FakeCiVerifier | None = None,
    usage: FakeUsageVerifier | None = None,
) -> EvidenceVerifier:
    return EvidenceVerifier(
        lease=lease or FakeLeaseVerifier(live=True),
        commits=commits or FakeCommitVerifier(existing=[COMMIT_A]),
        ci=ci or FakeCiVerifier(passed_runs=["ci-041"]),
        usage=usage or FakeUsageVerifier(reconciles=True),
    )


# ---------------------------------------------------------------------------
# ExecutionReport model -- lease/identity/attempt
# ---------------------------------------------------------------------------


class TestExecutionReportIdentity:
    """A report exists per attempt and is bound to a live lease."""

    def test_lease_id_required_and_nonempty(self) -> None:
        with pytest.raises(ValidationError, match="lease_id"):
            _report(lease_id="")
        with pytest.raises(ValidationError, match="lease_id"):
            _report(lease_id="   ")
        with pytest.raises(ValidationError, match="lease_id"):
            _report(lease_id=None)  # type: ignore[arg-type]

    def test_run_id_uses_canonical_pattern(self) -> None:
        with pytest.raises(ValidationError, match="run_id"):
            _report(run_id="run-001")
        with pytest.raises(ValidationError, match="run_id"):
            _report(run_id="")
        assert _report().run_id == "RUN-001"

    def test_task_id_and_workspace_id_nonempty(self) -> None:
        with pytest.raises(ValidationError, match="task_id"):
            _report(task_id="")
        with pytest.raises(ValidationError, match="workspace_id"):
            _report(workspace_id="  ")

    def test_attempt_must_be_positive(self) -> None:
        with pytest.raises(ValidationError, match="attempt"):
            _report(attempt=0)
        with pytest.raises(ValidationError, match="attempt"):
            _report(attempt=-1)
        assert _report(attempt=2).attempt == 2


class TestExecutionStatus:
    """Status is lowercase: passed / failed / blocked."""

    def test_status_values_lowercase(self) -> None:
        assert [member.value for member in ExecutionStatus] == [
            "passed",
            "failed",
            "blocked",
        ]

    def test_uppercase_status_rejected(self) -> None:
        with pytest.raises(ValidationError):
            _report(status="PASSED")
        with pytest.raises(ValidationError):
            _report(status="Passed")

    def test_valid_statuses_accepted(self) -> None:
        assert _report(status="failed", acceptance_evidence=[], failure=_failure()).status is (
            ExecutionStatus.FAILED
        )
        assert _report(
            status="blocked",
            acceptance_evidence=[],
            failure=_failure(cls=FailureClass.OUTAGE, message="provider outage"),
        ).status is ExecutionStatus.BLOCKED


# ---------------------------------------------------------------------------
# ExecutionReport model -- passed-evidence requirement
# ---------------------------------------------------------------------------


class TestPassedEvidenceRequirements:
    """Passed reports require AC IDs, Test IDs and evidence refs."""

    def test_passed_report_requires_acceptance_evidence(self) -> None:
        with pytest.raises(ValidationError, match="acceptance evidence"):
            _report(acceptance_evidence=[])

    def test_acceptance_evidence_requires_ac_id(self) -> None:
        with pytest.raises(ValidationError, match="acceptance_id"):
            _evidence(acceptance_id="")
        with pytest.raises(ValidationError, match="acceptance_id"):
            _evidence(acceptance_id="  ")

    def test_acceptance_evidence_requires_test_ids(self) -> None:
        with pytest.raises(ValidationError, match="test_ids"):
            _evidence(test_ids=[])
        with pytest.raises(ValidationError, match="test_ids"):
            _evidence(test_ids=["  "])
        with pytest.raises(ValidationError, match="test_ids"):
            _evidence(test_ids=["T-041", "T-041"])

    def test_acceptance_evidence_requires_evidence_refs(self) -> None:
        with pytest.raises(ValidationError, match="evidence_refs"):
            _evidence(evidence_refs=[])
        with pytest.raises(ValidationError, match="evidence_refs"):
            _evidence(evidence_refs=["", "artifacts/x.log"])
        with pytest.raises(ValidationError, match="evidence_refs"):
            _evidence(evidence_refs=["artifacts/x.log", "artifacts/x.log"])

    def test_acceptance_ids_must_be_unique(self) -> None:
        with pytest.raises(ValidationError, match="acceptance"):
            _report(acceptance_evidence=[_evidence(), _evidence(acceptance_id="AC-014-1")])

    def test_passed_report_rejects_failure_classification(self) -> None:
        with pytest.raises(ValidationError, match="failure"):
            _report(failure=_failure())

    def test_passed_report_carries_full_evidence(self) -> None:
        report = _report()
        assert report.acceptance_evidence[0].acceptance_id == "AC-014-1"
        assert report.acceptance_evidence[0].test_ids == ["T-041", "T-042"]
        assert report.acceptance_evidence[0].evidence_refs == [
            "artifacts/run-001/t-041.log",
            "artifacts/run-001/t-042.log",
        ]
        assert report.failure is None


# ---------------------------------------------------------------------------
# FailureInfo taxonomy and non-passed reports
# ---------------------------------------------------------------------------


class TestFailureInfo:
    """Failure classification is the canonical taxonomy, never renamed."""

    def test_class_alias_taxonomy_pinned(self) -> None:
        assert [member.value for member in FailureClass] == [
            "AUTH",
            "RATE",
            "OUTAGE",
            "BUG",
            "DATA",
            "ENV",
            "CONTRACT",
            "UNKNOWN",
        ]

    def test_cls_member(self) -> None:
        for value in ("AUTH", "RATE", "OUTAGE", "BUG", "DATA", "ENV", "CONTRACT", "UNKNOWN"):
            assert FailureClass(value).value == value

    def test_failure_info_requires_message(self) -> None:
        with pytest.raises(ValidationError, match="message"):
            FailureInfo(cls=FailureClass.AUTH, message="")
        with pytest.raises(ValidationError, match="message"):
            FailureInfo(cls=FailureClass.AUTH, message="   ")

    def test_failure_info_classifies(self) -> None:
        info = _failure(cls=FailureClass.RATE, message="rate limit exceeded")
        assert info.cls is FailureClass.RATE
        assert info.message == "rate limit exceeded"

    def test_failed_report_requires_failure_classification(self) -> None:
        with pytest.raises(ValidationError, match="failure"):
            _report(status="failed", acceptance_evidence=[])
        report = _report(status="failed", acceptance_evidence=[], failure=_failure())
        assert report.status is ExecutionStatus.FAILED
        assert report.failure is not None
        assert report.failure.cls is FailureClass.BUG

    def test_blocked_report_requires_failure_classification(self) -> None:
        with pytest.raises(ValidationError, match="failure"):
            _report(status="blocked", acceptance_evidence=[])
        report = _report(
            status="blocked",
            acceptance_evidence=[],
            failure=_failure(cls=FailureClass.OUTAGE, message="provider outage"),
        )
        assert report.status is ExecutionStatus.BLOCKED

    def test_invalid_class_value_rejected(self) -> None:
        with pytest.raises(ValidationError):
            _failure(cls="NOT-A-CLASS")  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# Usage / outputs / deviations / trace updates
# ---------------------------------------------------------------------------


class TestExecutionReportDetail:
    def test_usage_values_not_negative(self) -> None:
        with pytest.raises(ValidationError, match="tokens"):
            _usage(tokens=-1)
        with pytest.raises(ValidationError, match="cost_usd"):
            _usage(cost_usd=-0.01)
        with pytest.raises(ValidationError, match="provider_calls"):
            _usage(provider_calls=-1)

    def test_usage_required(self) -> None:
        with pytest.raises(ValidationError, match="usage"):
            _report(usage=None)  # type: ignore[arg-type]

    def test_output_requires_nonempty_kind_and_ref(self) -> None:
        with pytest.raises(ValidationError, match="kind"):
            OutputInfo(kind="", ref="src/app.py")
        with pytest.raises(ValidationError, match="ref"):
            OutputInfo(kind="file", ref="  ")

    def test_output_commit_nonempty_when_present(self) -> None:
        with pytest.raises(ValidationError, match="commit"):
            OutputInfo(kind="file", ref="src/app.py", commit=" ")
        output = OutputInfo(kind="commit", ref=COMMIT_A)
        assert output.commit is None

    def test_deviations_and_trace_updates_have_nonempty_entries(self) -> None:
        with pytest.raises(ValidationError, match="deviations"):
            _report(deviations=[""])
        with pytest.raises(ValidationError, match="trace_updates"):
            _report(trace_updates=["  "])
        report = _report(deviations=["scope drift"], trace_updates=["trace: AC-014-1 -> PROD-SMOKE-06"])
        assert report.deviations == ["scope drift"]
        assert report.trace_updates == ["trace: AC-014-1 -> PROD-SMOKE-06"]


# ---------------------------------------------------------------------------
# EvidenceVerifier -- chain-of-custody gate
# ---------------------------------------------------------------------------


class TestEvidenceVerifier:
    """Claims are not trusted until KCC verifies chain-of-custody evidence."""

    def test_accepts_report_with_verified_evidence(self) -> None:
        acceptance = _verifier().verify(_report())
        assert acceptance.accepted is True
        assert acceptance.counts_as_failed_attempt is False
        assert acceptance.reasons == []

    def test_accepts_failed_report_with_verified_evidence(self) -> None:
        report = _report(status="failed", acceptance_evidence=[], failure=_failure())
        acceptance = _verifier().verify(report)
        assert acceptance.accepted is True
        assert acceptance.counts_as_failed_attempt is False

    def test_stale_lease_rejected_and_counts_failed_attempt(self) -> None:
        lease = FakeLeaseVerifier(live=False)
        acceptance = _verifier(lease=lease).verify(_report())
        assert acceptance.accepted is False
        assert acceptance.counts_as_failed_attempt is True
        assert any("lease" in reason for reason in acceptance.reasons)
        assert lease.calls == [("LEASE-2026-0001", "RUN-001")]

    def test_nonexistent_commit_rejected_and_counts_failed_attempt(self) -> None:
        report = _report(outputs=[OutputInfo(kind="commit", ref=COMMIT_B)])
        acceptance = _verifier(commits=FakeCommitVerifier(existing=[COMMIT_A])).verify(report)
        assert acceptance.accepted is False
        assert acceptance.counts_as_failed_attempt is True
        assert any(COMMIT_B in reason for reason in acceptance.reasons)

    def test_existing_claim_commit_accepted(self) -> None:
        report = _report(outputs=[OutputInfo(kind="commit", ref=COMMIT_A)])
        acceptance = _verifier(commits=FakeCommitVerifier(existing=[COMMIT_A])).verify(report)
        assert acceptance.accepted is True
        assert acceptance.counts_as_failed_attempt is False

    def test_output_commit_field_is_verified(self) -> None:
        report = _report(
            outputs=[OutputInfo(kind="file", ref="src/app.py", commit=COMMIT_B)]
        )
        acceptance = _verifier(commits=FakeCommitVerifier(existing=[COMMIT_A])).verify(report)
        assert acceptance.accepted is False
        assert any(COMMIT_B in reason for reason in acceptance.reasons)

    def test_every_claimed_commit_is_verified(self) -> None:
        report = _report(
            outputs=[
                OutputInfo(kind="commit", ref=COMMIT_A),
                OutputInfo(kind="commit", ref=COMMIT_B),
            ]
        )
        commits = FakeCommitVerifier(existing=[COMMIT_A])
        acceptance = _verifier(commits=commits).verify(report)
        assert acceptance.accepted is False
        assert set(commits.calls) == {COMMIT_A, COMMIT_B}
        assert any(COMMIT_B in reason for reason in acceptance.reasons)

    def test_failed_ci_run_invalidates_passed_evidence(self) -> None:
        report = _report(outputs=[OutputInfo(kind="ci-run", ref="ci-041")])
        acceptance = _verifier(ci=FakeCiVerifier(passed_runs=[])).verify(report)
        assert acceptance.accepted is False
        assert acceptance.counts_as_failed_attempt is True
        assert any("CI run 'ci-041'" in reason for reason in acceptance.reasons)

    def test_passing_ci_run_keeps_passed_report_accepted(self) -> None:
        report = _report(outputs=[OutputInfo(kind="ci-run", ref="ci-041")])
        acceptance = _verifier(ci=FakeCiVerifier(passed_runs=["ci-041"])).verify(report)
        assert acceptance.accepted is True

    def test_ci_runs_not_required_for_failed_reports(self) -> None:
        report = _report(
            status="failed",
            acceptance_evidence=[],
            failure=_failure(),
            outputs=[OutputInfo(kind="ci-run", ref="ci-041")],
        )
        acceptance = _verifier(ci=FakeCiVerifier(passed_runs=[])).verify(report)
        assert acceptance.accepted is True

    def test_usage_reconciliation_failure_rejected(self) -> None:
        report = _report()
        acceptance = _verifier(usage=FakeUsageVerifier(reconciles=False)).verify(report)
        assert acceptance.accepted is False
        assert acceptance.counts_as_failed_attempt is True
        assert any("usage" in reason.lower() for reason in acceptance.reasons)

    def test_rejections_always_count_as_failed_attempts(self) -> None:
        cases = [
            FakeLeaseVerifier(live=False),
            FakeCommitVerifier(existing=[]),
            FakeCiVerifier(passed_runs=[]),
            FakeUsageVerifier(reconciles=False),
        ]
        for fake in cases:
            report = _report()
            if isinstance(fake, FakeCommitVerifier):
                report = _report(outputs=[OutputInfo(kind="commit", ref=COMMIT_A)])
            if isinstance(fake, FakeCiVerifier):
                report = _report(outputs=[OutputInfo(kind="ci-run", ref="ci-041")])
            acceptance = _verifier(
                lease=fake if isinstance(fake, FakeLeaseVerifier) else None,
                commits=fake if isinstance(fake, FakeCommitVerifier) else None,
                ci=fake if isinstance(fake, FakeCiVerifier) else None,
                usage=fake if isinstance(fake, FakeUsageVerifier) else None,
            ).verify(report)
            assert acceptance.accepted is False
            assert acceptance.counts_as_failed_attempt is True
            assert acceptance.reasons


# ---------------------------------------------------------------------------
# ReportAcceptance invariants
# ---------------------------------------------------------------------------


class TestReportAcceptance:
    """A rejected report always counts as a failed attempt (fail-closed)."""

    def test_rejected_report_must_count_as_failed_attempt(self) -> None:
        with pytest.raises(ValidationError, match="failed attempt"):
            ReportAcceptance(accepted=False, counts_as_failed_attempt=False, reasons=["bad"])

    def test_accepted_report_must_not_count_as_failed_attempt(self) -> None:
        with pytest.raises(ValidationError, match="failed attempt"):
            ReportAcceptance(accepted=True, counts_as_failed_attempt=True, reasons=[])

    def test_rejected_report_requires_reasons(self) -> None:
        with pytest.raises(ValidationError, match="reasons"):
            ReportAcceptance(accepted=False, counts_as_failed_attempt=True, reasons=[])

    def test_accepted_report_must_not_carry_reasons(self) -> None:
        with pytest.raises(ValidationError, match="reasons"):
            ReportAcceptance(accepted=True, counts_as_failed_attempt=False, reasons=["warn"])

    def test_consistent_acceptance(self) -> None:
        verdict = ReportAcceptance(accepted=True, counts_as_failed_attempt=False, reasons=[])
        assert verdict.accepted is True
        verdict_rejected = ReportAcceptance(
            accepted=False, counts_as_failed_attempt=True, reasons=["stale lease"]
        )
        assert verdict_rejected.counts_as_failed_attempt is True
