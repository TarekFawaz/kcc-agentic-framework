"""Chain-of-custody evidence verification for Execution Reports.

Plan 03, Task 2: an :class:`ExecutionReport` is an evidence claim and
claims are not trusted until KCC verifies them (Global Constraint).
:class:`EvidenceVerifier` re-checks the claim against the verifier
protocols -- :class:`LeaseVerifier` (the attempt lease is still live),
:class:`CommitVerifier` (every claimed commit exists), :class:`CiVerifier`
(passed-evidence CI runs passed) and :class:`ProviderUsageVerifier`
(claimed usage reconciles with provider records).

Fail-closed semantics: any failed check yields a :class:`ReportAcceptance`
with ``accepted=False`` and ``counts_as_failed_attempt=True``, so a
rejected report always consumes one attempt budget (Global Constraint:
"one KCC lease, one budget envelope, one isolated workspace, and one
Execution Report" -- no unaccounted attempts).
"""

from __future__ import annotations

from typing import Protocol

from pydantic import Field, model_validator

from kcc_autobuild.bridge import (
    ExecutionReport,
    ExecutionStatus,
    UsageInfo,
)
from kcc_autobuild.models import StrictModel

COMMIT_OUTPUT_KIND = "commit"
"""``OutputInfo.kind`` value that names a commit (ref = commit id)."""

CI_RUN_OUTPUT_KIND = "ci-run"
"""``OutputInfo.kind`` value that names a CI run (ref = CI run ref)."""


class LeaseVerifier(Protocol):
    """Confirms the attempt lease is still live for the run.

    A stale (expired, revoked or unknown) lease must not be accepted:
    the execution attempt it bound is no longer accounted for.
    """

    def lease_is_live(self, lease_id: str, run_id: str) -> bool: ...


class CommitVerifier(Protocol):
    """Confirms a claimed commit exists in the repository object store.

    A report may name commits in ``OutputInfo``; every claim must
    resolve to a real commit or the report is rejected.
    """

    def commit_exists(self, commit_id: str) -> bool: ...


class CiVerifier(Protocol):
    """Confirms a claimed CI run completed with a passing result.

    Passed-evidence integrity: a ``passed`` report may reference CI
    runs in ``OutputInfo``; a referenced run that did not pass voids
    the passed evidence.
    """

    def ci_run_passed(self, ci_run_ref: str) -> bool: ...


class ProviderUsageVerifier(Protocol):
    """Reconciles claimed provider usage against provider records.

    The worker's ``UsageInfo`` is a claim; KCC reconciles it with
    provider billing/quota records before the report is accepted.
    """

    def usage_reconciles(self, usage: UsageInfo) -> bool: ...


def _claimed_commit_ids(report: ExecutionReport) -> list[str]:
    """Commit ids the report claims, deduped and sorted.

    Covers both ``OutputInfo(kind="commit", ref=<id>)`` declarations
    and the optional ``commit`` field on any output.
    """
    ids: set[str] = set()
    for output in report.outputs:
        if output.kind == COMMIT_OUTPUT_KIND and output.ref.strip():
            ids.add(output.ref)
        if output.commit:
            ids.add(output.commit)
    return sorted(ids)


def _claimed_ci_runs(report: ExecutionReport) -> list[str]:
    """CI run refs the report claims, deduped and sorted."""
    return sorted(
        {
            output.ref
            for output in report.outputs
            if output.kind == CI_RUN_OUTPUT_KIND and output.ref.strip()
        }
    )


class ReportAcceptance(StrictModel):
    """Verdict of the KCC evidence gate for one Execution Report.

    ``accepted=False`` must carry nonempty ``reasons`` and always
    counts as a failed attempt; ``accepted=True`` never does.  The
    model enforces this consistency (fail-closed, deterministic).
    """

    accepted: bool
    counts_as_failed_attempt: bool
    reasons: list[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def _consistent(self) -> ReportAcceptance:
        if self.accepted and self.counts_as_failed_attempt:
            raise ValueError("an accepted report must not count as a failed attempt")
        if not self.accepted and not self.counts_as_failed_attempt:
            raise ValueError("a rejected report must count as a failed attempt")
        if not self.accepted and not self.reasons:
            raise ValueError("a rejected report must carry rejection reasons")
        if self.accepted and self.reasons:
            raise ValueError("an accepted report must not carry rejection reasons")
        return self


class EvidenceVerifier:
    """KCC-side evidence gate; the only acceptor of Execution Reports.

    Verification is deterministic (fixed check order: lease, claimed
    commits, passed evidence, usage reconciliation) so the ``reasons``
    list is stable for automation.
    """

    def __init__(
        self,
        lease: LeaseVerifier,
        commits: CommitVerifier,
        ci: CiVerifier,
        usage: ProviderUsageVerifier,
    ) -> None:
        self._lease = lease
        self._commits = commits
        self._ci = ci
        self._usage = usage

    def verify(self, report: ExecutionReport) -> ReportAcceptance:
        """Verify the report's chain-of-custody evidence.

        A rejected report always counts as a failed attempt; only a
        report whose lease is live, whose claimed commits exist, whose
        passed evidence is intact (and CI-verified) and whose usage
        reconciles is accepted.
        """
        reasons: list[str] = []

        if not self._lease.lease_is_live(report.lease_id, report.run_id):
            reasons.append(f"lease '{report.lease_id}' is stale or not live")

        for commit_id in _claimed_commit_ids(report):
            if not self._commits.commit_exists(commit_id):
                reasons.append(f"claimed commit '{commit_id}' does not exist")

        if report.status is ExecutionStatus.PASSED:
            reasons.extend(self._passed_evidence_problems(report))

        if not self._usage.usage_reconciles(report.usage):
            reasons.append("provider usage did not reconcile with claimed usage")

        accepted = not reasons
        return ReportAcceptance(
            accepted=accepted,
            counts_as_failed_attempt=not accepted,
            reasons=reasons,
        )

    def _passed_evidence_problems(self, report: ExecutionReport) -> list[str]:
        """Problems in the passed-evidence set of a ``passed`` report."""
        problems: list[str] = []
        if not report.acceptance_evidence:
            problems.append("passed report declares no acceptance evidence")
        else:
            for evidence in report.acceptance_evidence:
                if (
                    not evidence.acceptance_id.strip()
                    or not evidence.test_ids
                    or not evidence.evidence_refs
                ):
                    problems.append(
                        f"acceptance evidence for '{evidence.acceptance_id}' "
                        "is missing AC/Test ID or evidence ref"
                    )
        if report.failure is not None:
            problems.append("passed report carries a failure classification")
        for ci_run_ref in _claimed_ci_runs(report):
            if not self._ci.ci_run_passed(ci_run_ref):
                problems.append(f"CI run '{ci_run_ref}' did not pass")
        return problems
