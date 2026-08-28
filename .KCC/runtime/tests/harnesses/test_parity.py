"""Cross-harness ExecutionReport parity (Plan 08, Task 6).

Behavioral contract owned by the Plan 08 Task 6 section of
``.superpowers/bootstrap/plans/2026-08-27-08-``
``harness-capability-deepseek-adapter.task-contracts.md``:

* **Parity normalizes ExecutionReport removing only harness metadata.**
  ``normalize_harness_metadata`` is the only normalization allowed: the
  canonical report fields (lease identity, acceptance criteria, Test
  IDs, usage, deviations, policy trace, evidence) are never treated as
  harness metadata, and a non-metadata extra field still fails the
  strict ``ExecutionReport`` schema (fail closed) instead of being
  dropped.
* **Codex/DSH fixtures are identical.** A Codex-flavored raw worker
  report (Codex metadata idioms) and a DSH-flavored raw worker report
  (DSH metadata idioms) must normalize to the identical canonical
  document and validate to identical ``ExecutionReport`` models --
  lease, AC, Test, usage, deviations, policy trace and evidence are
  byte-for-byte the same after normalization, so KCC's evidence
  chain-of-custody verification consumes one report shape no matter
  which harness produced it.

The harness-neutral core therefore never claims "works on every CLI":
each harness adapter reports only proven capabilities, and parity holds
at the report shape, not at the capability level.

The report file is still the completion contract: both normalized
fixtures must bind to the same :class:`~kcc_autobuild.harnesses.models.HarnessTask`
identity (run, task, attempt/lease generation, lease, workspace).
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from kcc_autobuild.bridge import (
    AttemptBudget,
    ExecutionReport,
    HARNESS_METADATA_FIELDS,
    TaskHandoff,
    TaskLease,
    normalize_harness_metadata,
)
from kcc_autobuild.harnesses.models import HarnessTask

POLICY_HASH = "a" * 64
RUN_ID = "RUN-001"
TASK_ID = "TASK-021"
LEASE_ID = "LEASE-RUN-001-TASK-021-1"
WORKSPACE_ID = "workspace-1"

# ---------------------------------------------------------------------------
# The canonical report document (the shape KCC verifies).
#
# One canonical document shared by both fixtures; every field below is
# task evidence and must survive normalization untouched.
# ---------------------------------------------------------------------------


CANONICAL_REPORT: dict[str, object] = {
    "run_id": RUN_ID,
    "task_id": TASK_ID,
    "attempt": 1,
    "status": "passed",
    "lease_id": LEASE_ID,
    "workspace_id": WORKSPACE_ID,
    "acceptance_evidence": [
        {
            "acceptance_id": "AC-001",
            "test_ids": ["T-001", "T-002"],
            "evidence_refs": [
                ".KCC/runtime/tests/harnesses/test_parity.py",
                ".KCC/runtime/tests/harnesses/test_dsh_adapter.py",
            ],
        }
    ],
    "failure": None,
    "usage": {"tokens": 12345, "provider_calls": 3, "cost_usd": 0.12},
    "outputs": [
        {"kind": "file", "ref": "docs/autobuild/harnesses.md"},
        # Policy trace: the run's durable gate audit, produced by KCC's
        # policy gate (coordination/autobuild/<RUN>/gate-audit.jsonl).
        {"kind": "policy-audit", "ref": f"coordination/autobuild/{RUN_ID}/gate-audit.jsonl"},
    ],
    "deviations": ["editorial copy documented as out-of-scope"],
    "trace_updates": [
        "gate-audit: decision token KCC-000001 recorded",
        "trace: AC-001 -> T-001/T-002 -> PASS",
    ],
}

# ---------------------------------------------------------------------------
# Harness-idiomatic metadata fields (invocation facts, model names,
# durations, captured output -- never task evidence).  Each harness carries
# its OWN idiom; the sets are disjoint and every key is in
# HARNESS_METADATA_FIELDS.
# ---------------------------------------------------------------------------

CODEX_METADATA: dict[str, object] = {
    "harness": "codex",
    "worker": "codex-worker-1",
    "session_id": "sess-codex-9",
    "model": "gpt-5-codex",
    "provider": "openai",
    "invocation": "codex --profile kcc",
    "invoked_at": "2026-08-28T12:00:00+00:00",
    "duration_ms": 4200,
    "exit_code": 0,
    "tool_calls": ["read", "write"],
    "final_message": "task complete",
    "raw_output": "captured transcript",
}

DSH_METADATA: dict[str, object] = {
    "harness_id": "dsh",
    "dsh": "deepseek-harness/1.0",
    "profile": "headless",
    "worker_id": "worker-7",
    "started_at": "2026-08-28T12:00:01+00:00",
    "finished_at": "2026-08-28T12:00:05+00:00",
    "stdout": "captured stdout",
    "stderr": "",
    "banner": "dsh boot banner",
    "kcc_dsh_status": {
        "sandbox": "workspace-write",
        "approval": "never",
        "guard": "kcc-policy-gate",
    },
    "logs": ["probe", "dispatch"],
}


def _flavor(metadata: dict[str, object]) -> dict[str, object]:
    """One raw harness-flavored worker report document."""
    document = dict(CANONICAL_REPORT)
    document.update(metadata)
    return document


CODEX_DOCUMENT = _flavor(CODEX_METADATA)
DSH_DOCUMENT = _flavor(DSH_METADATA)


def _handoff() -> TaskHandoff:
    return TaskHandoff(
        run_id=RUN_ID,
        task_id=TASK_ID,
        requirement_ids=["REQ-001"],
        acceptance_ids=["AC-001"],
        test_ids=["T-001", "T-002"],
        lease=TaskLease(
            lease_id=LEASE_ID, run_id=RUN_ID, task_id=TASK_ID, generation=1
        ),
        attempt_budget=AttemptBudget(
            max_attempts=3,
            time_budget_minutes=60,
            token_budget=100000,
            cost_budget_minor=500,
            escalation_tier=1,
        ),
        policy_bundle_hash=POLICY_HASH,
    )


def _task() -> HarnessTask:
    return HarnessTask(
        handoff=_handoff(),
        workspace_id=WORKSPACE_ID,
        handoff_path=f"coordination/autobuild/{RUN_ID}/task-handoff.json",
        report_path=f"coordination/autobuild/{RUN_ID}/execution-report.yaml",
    )


# ---------------------------------------------------------------------------
# Parity: normalization removes ONLY harness metadata.
# ---------------------------------------------------------------------------


def test_codex_and_dsh_fixtures_normalize_to_identical_documents() -> None:
    codex_norm = normalize_harness_metadata(CODEX_DOCUMENT)
    dsh_norm = normalize_harness_metadata(DSH_DOCUMENT)

    assert codex_norm == CANONICAL_REPORT
    assert dsh_norm == CANONICAL_REPORT
    assert codex_norm == dsh_norm
    assert sorted(codex_norm) == sorted(CANONICAL_REPORT)
    assert sorted(dsh_norm) == sorted(CANONICAL_REPORT)


def test_metadata_fields_are_stripped_but_canonical_fields_survive() -> None:
    normalized = normalize_harness_metadata(DSH_DOCUMENT)

    # Every harness-metadata field was removed; no canonical field was.
    for name in DSH_METADATA:
        assert name not in normalized
    for name in CODEX_METADATA:
        assert name not in normalize_harness_metadata(CODEX_DOCUMENT)
    for name in CANONICAL_REPORT:
        assert name in normalized


def test_harness_metadata_idioms_are_disjoint_and_canonical() -> None:
    # Each harness uses its own metadata idiom; parity is normalized
    # equality, not raw-document equality.
    assert set(CODEX_METADATA).isdisjoint(set(DSH_METADATA))
    # Every idiom key is a known harness-metadata field (never task
    # evidence), so it is exactly the set normalization may remove.
    assert set(CODEX_METADATA) <= HARNESS_METADATA_FIELDS
    assert set(DSH_METADATA) <= HARNESS_METADATA_FIELDS


# ---------------------------------------------------------------------------
# Parity: identical lease / AC / Test / usage / deviations / policy trace /
# evidence after normalization.
# ---------------------------------------------------------------------------


def test_both_fixtures_validate_to_identical_execution_reports() -> None:
    codex_report = ExecutionReport.model_validate(
        normalize_harness_metadata(CODEX_DOCUMENT)
    )
    dsh_report = ExecutionReport.model_validate(
        normalize_harness_metadata(DSH_DOCUMENT)
    )

    assert codex_report.model_dump() == dsh_report.model_dump()
    assert codex_report.model_dump() == ExecutionReport.model_validate(
        dict(CANONICAL_REPORT)
    ).model_dump()


def test_parity_fixture_pins_lease_ac_test_usage_deviations_policy_and_evidence() -> None:
    report = ExecutionReport.model_validate(dict(CANONICAL_REPORT))

    # Lease identity.
    assert report.run_id == RUN_ID
    assert report.task_id == TASK_ID
    assert report.attempt == 1
    assert report.lease_id == LEASE_ID
    assert report.workspace_id == WORKSPACE_ID

    # AC -> Test mapping and evidence refs.
    assert [e.acceptance_id for e in report.acceptance_evidence] == ["AC-001"]
    assert report.acceptance_evidence[0].test_ids == ["T-001", "T-002"]
    assert report.acceptance_evidence[0].evidence_refs == [
        ".KCC/runtime/tests/harnesses/test_parity.py",
        ".KCC/runtime/tests/harnesses/test_dsh_adapter.py",
    ]

    # Usage.
    assert report.usage.tokens == 12345
    assert report.usage.provider_calls == 3
    assert report.usage.cost_usd == 0.12

    # Deviations.
    assert report.deviations == ["editorial copy documented as out-of-scope"]

    # Policy trace (gate audit output + trace updates).
    assert [o.kind for o in report.outputs] == ["file", "policy-audit"]
    assert report.outputs[1].ref == (
        f"coordination/autobuild/{RUN_ID}/gate-audit.jsonl"
    )
    assert report.trace_updates == [
        "gate-audit: decision token KCC-000001 recorded",
        "trace: AC-001 -> T-001/T-002 -> PASS",
    ]


def test_parity_does_not_strip_evidence_that_mentions_harness() -> None:
    # A substring like "harness" inside an evidence ref is task evidence,
    # not a harness-metadata field; it must survive normalization.
    normalized = normalize_harness_metadata(CODEX_DOCUMENT)
    assert normalized["outputs"][0]["ref"] == "docs/autobuild/harnesses.md"
    assert normalized["acceptance_evidence"][0]["evidence_refs"] == [
        ".KCC/runtime/tests/harnesses/test_parity.py",
        ".KCC/runtime/tests/harnesses/test_dsh_adapter.py",
    ]


# ---------------------------------------------------------------------------
# Parity fail-closed: a non-metadata extra field is never dropped.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "document",
    [CODEX_DOCUMENT, DSH_DOCUMENT],
    ids=["codex", "dsh"],
)
def test_parity_fails_closed_on_non_metadata_extra_fields(document) -> None:
    bogus = dict(document)
    bogus["acceptance_notes"] = "not a harness-metadata field"
    normalized = normalize_harness_metadata(bogus)

    # Normalization must NOT have silently dropped the field...
    assert "acceptance_notes" in normalized
    # ...so the strict ExecutionReport schema rejects it (fail closed).
    with pytest.raises(ValidationError):
        ExecutionReport.model_validate(normalized)


# ---------------------------------------------------------------------------
# Parity completion contract: the same leased task accepts both shapes.
# ---------------------------------------------------------------------------


def test_parity_reports_bind_to_the_same_harness_task_identity() -> None:
    task = _task()
    codex_report = ExecutionReport.model_validate(
        normalize_harness_metadata(CODEX_DOCUMENT)
    )
    dsh_report = ExecutionReport.model_validate(
        normalize_harness_metadata(DSH_DOCUMENT)
    )

    # The report file is the completion contract: neither raise.
    task.validate_report(codex_report)
    task.validate_report(dsh_report)
