"""Harness capability contract (Plan 08, Task 1) -- behavioral tests.

Written first (strict TDD red phase) against the external behavior
contract of Task 1 of :file:`.superpowers/bootstrap/plans/
2026-08-27-08-harness-capability-deepseek-adapter.task-contracts.md`
(KCC x Superpowers Hybrid Framework)::

    Models enums ApprovalMode none/ask/never/unknown,
    MutationEnforcement none/prompt-only/kcc-policy-gate,
    ExecutionStrategy local/serial-worker/parallel-workers/full-autopilot;
    HarnessCapabilities unknown defaults false/0, supports, best_strategy;
    Full Autopilot requires read/write/exec + KCC_POLICY_GATE +
    approval none/never; unproven parallel degrades serial.
    Define HarnessProbe, HarnessTask, HarnessAdapter/HarnessError
    consuming TaskHandoff/ExecutionReport.

Binding semantics under test:

* The canonical enums carry exactly the prescribed values (lowercase)
  and parse back from their values.
* ``HarnessCapabilities`` is unknown by default (every capability false,
  confidence 0, approval UNKNOWN, enforcement NONE) and ``unknown()``
  yields exactly that; the capabilities never claim something that was
  not proven (harness-neutral core, adapter-specific capability levels).
* ``supports`` answers only for proven capabilities, accepts enum
  members or their value strings, requires every named capability, and
  rejects unknown capability names instead of silently guessing.
* ``best_strategy`` implements the capability ladder: local (nothing
  proven) < serial-worker (fresh worker proven only) <
  parallel-workers (fresh + parallel proven) < full-autopilot (fresh +
  parallel + read/write/exec + KCC_POLICY_GATE + approval none/never);
  unproven parallel degrades to serial, never further and never fakes
  a parallel or full-autopilot claim.
* ``HarnessProbe`` records only what the adapter probe could prove, with
  a timezone-aware timestamp and nonempty evidence entries.
* ``HarnessTask`` consumes the bounded ``TaskHandoff`` pack and the
  project-relative handoff/report paths confined under
  ``coordination/autobuild/<RUN>``, and ``validate_report`` binds the
  returned ``ExecutionReport`` back to the handoff identity (run_id,
  task_id, attempt == lease generation, lease_id, workspace_id) --
  a report file is the completion contract and a mismatched report is
  rejected with ``HarnessError`` (fail closed).
* ``HarnessAdapter`` is the abstract adapter contract (probe + execute)
  and cannot be constructed directly.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest
from pydantic import ValidationError

from kcc_autobuild.bridge import (
    AcceptanceEvidence,
    AttemptBudget,
    ExecutionReport,
    ExecutionStatus,
    FailureClass,
    FailureInfo,
    TaskHandoff,
    TaskLease,
    UsageInfo,
)
from kcc_autobuild.harnesses import (
    ApprovalMode,
    ExecutionStrategy,
    HarnessAdapter,
    HarnessCapabilities,
    HarnessCapability,
    HarnessError,
    HarnessProbe,
    HarnessTask,
    MutationEnforcement,
)
from kcc_autobuild.harnesses.models import HarnessCapabilities as ModelsCapabilities

POLICY_HASH = "a" * 64
RUN_ID = "RUN-001"
TASK_ID = "TASK-021"
LEASE_ID = "LEASE-RUN-001-TASK-021-1"


def _handoff(
    run_id: str = RUN_ID,
    task_id: str = TASK_ID,
    generation: int = 1,
    lease_id: str = LEASE_ID,
) -> TaskHandoff:
    return TaskHandoff(
        run_id=run_id,
        task_id=task_id,
        requirement_ids=["REQ-001"],
        acceptance_ids=["AC-001"],
        test_ids=["T-001"],
        lease=TaskLease(
            lease_id=lease_id, run_id=run_id, task_id=task_id, generation=generation
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


def _report(
    *,
    run_id: str = RUN_ID,
    task_id: str = TASK_ID,
    attempt: int = 1,
    lease_id: str = LEASE_ID,
    workspace_id: str = "workspace-1",
    status: ExecutionStatus = ExecutionStatus.PASSED,
) -> ExecutionReport:
    return ExecutionReport(
        run_id=run_id,
        task_id=task_id,
        attempt=attempt,
        status=status,
        lease_id=lease_id,
        workspace_id=workspace_id,
        usage=UsageInfo(),
        acceptance_evidence=(
            [
                AcceptanceEvidence(
                    acceptance_id="AC-001",
                    test_ids=["T-001"],
                    evidence_refs=["tests/test_models.py"],
                )
            ]
            if status is ExecutionStatus.PASSED
            else []
        ),
        failure=(
            None
            if status is ExecutionStatus.PASSED
            else FailureInfo(cls=FailureClass.BUG, message="boom")
        ),
    )


def _task(**overrides) -> HarnessTask:
    kwargs = {
        "handoff": _handoff(),
        "workspace_id": "workspace-1",
        "handoff_path": f"coordination/autobuild/{RUN_ID}/task-handoff.json",
        "report_path": f"coordination/autobuild/{RUN_ID}/execution-report.json",
    }
    kwargs.update(overrides)
    return HarnessTask(**kwargs)


def _full_autopilot_capabilities() -> HarnessCapabilities:
    return HarnessCapabilities(
        read=True,
        write=True,
        exec=True,
        fresh_workers=True,
        parallel_workers=True,
        approval_mode=ApprovalMode.NEVER,
        mutation_enforcement=MutationEnforcement.KCC_POLICY_GATE,
        confidence=1.0,
    )


# ---------------------------------------------------------------------------
# Canonical enums -- exact prescribed values, never renamed.
# ---------------------------------------------------------------------------


class TestApprovalMode:
    def test_canonical_members_and_values(self) -> None:
        assert [mode.value for mode in ApprovalMode] == [
            "none",
            "ask",
            "never",
            "unknown",
        ]
        assert ApprovalMode("none") is ApprovalMode.NONE
        assert ApprovalMode("ask") is ApprovalMode.ASK
        assert ApprovalMode("never") is ApprovalMode.NEVER
        assert ApprovalMode("unknown") is ApprovalMode.UNKNOWN

    def test_approval_modes_are_string_enums(self) -> None:
        assert ApprovalMode.NONE.value == "none"
        assert isinstance(ApprovalMode.NEVER, str)


class TestMutationEnforcement:
    def test_canonical_members_and_values(self) -> None:
        assert [mode.value for mode in MutationEnforcement] == [
            "none",
            "prompt-only",
            "kcc-policy-gate",
        ]
        assert MutationEnforcement("none") is MutationEnforcement.NONE
        assert MutationEnforcement("prompt-only") is MutationEnforcement.PROMPT_ONLY
        assert MutationEnforcement("kcc-policy-gate") is MutationEnforcement.KCC_POLICY_GATE

    def test_policy_gate_is_a_string_enum(self) -> None:
        assert MutationEnforcement.KCC_POLICY_GATE.value == "kcc-policy-gate"
        assert isinstance(MutationEnforcement.KCC_POLICY_GATE, str)


class TestExecutionStrategy:
    def test_canonical_members_and_values(self) -> None:
        assert [strategy.value for strategy in ExecutionStrategy] == [
            "local",
            "serial-worker",
            "parallel-workers",
            "full-autopilot",
        ]
        assert ExecutionStrategy("local") is ExecutionStrategy.LOCAL
        assert ExecutionStrategy("serial-worker") is ExecutionStrategy.SERIAL_WORKER
        assert ExecutionStrategy("parallel-workers") is ExecutionStrategy.PARALLEL_WORKERS
        assert ExecutionStrategy("full-autopilot") is ExecutionStrategy.FULL_AUTOPILOT


# ---------------------------------------------------------------------------
# HarnessCapabilities -- unknown defaults false/0, supports, best_strategy.
# ---------------------------------------------------------------------------


class TestUnknownDefaults:
    def test_defaults_are_unknown_false_and_zero(self) -> None:
        caps = HarnessCapabilities()
        assert caps.read is False
        assert caps.write is False
        assert caps.exec is False
        assert caps.fresh_workers is False
        assert caps.parallel_workers is False
        assert caps.subagents is False
        assert caps.approval_mode is ApprovalMode.UNKNOWN
        assert caps.mutation_enforcement is MutationEnforcement.NONE
        assert caps.confidence == 0.0

    def test_unknown_classmethod_yields_unknown_capabilities(self) -> None:
        caps = HarnessCapabilities.unknown()
        assert caps == HarnessCapabilities()
        assert caps.read is False
        assert caps.confidence == 0.0

    def test_unknown_capabilities_support_nothing(self) -> None:
        caps = HarnessCapabilities.unknown()
        for capability in HarnessCapability:
            assert caps.supports(capability) is False

    def test_unknown_capabilities_best_strategy_is_local(self) -> None:
        assert HarnessCapabilities.unknown().best_strategy() is ExecutionStrategy.LOCAL

    def test_default_capabilities_equal_unknown(self) -> None:
        assert HarnessCapabilities() == HarnessCapabilities.unknown()


class TestSupports:
    def test_supports_true_only_for_proven_capability(self) -> None:
        caps = HarnessCapabilities(read=True, approval_mode=ApprovalMode.NONE)
        assert caps.supports(HarnessCapability.READ) is True
        assert caps.supports(HarnessCapability.WRITE) is False
        assert caps.supports(HarnessCapability.APPROVAL_NONE) is True
        assert caps.supports(HarnessCapability.APPROVAL_NEVER) is False

    def test_supports_accepts_enum_members_and_value_strings(self) -> None:
        caps = HarnessCapabilities(write=True)
        assert caps.supports(HarnessCapability.WRITE) is True
        assert caps.supports("write") is True
        assert caps.supports("read") is False

    def test_supports_requires_every_named_capability(self) -> None:
        caps = HarnessCapabilities(read=True, write=False)
        assert caps.supports(HarnessCapability.READ, HarnessCapability.WRITE) is False
        assert caps.supports(HarnessCapability.READ) is True

    def test_policy_gate_capability_follows_mutation_enforcement(self) -> None:
        caps = HarnessCapabilities(mutation_enforcement=MutationEnforcement.KCC_POLICY_GATE)
        assert caps.supports(HarnessCapability.KCC_POLICY_GATE) is True
        caps = HarnessCapabilities(mutation_enforcement=MutationEnforcement.NONE)
        assert caps.supports(HarnessCapability.KCC_POLICY_GATE) is False
        caps = HarnessCapabilities(mutation_enforcement=MutationEnforcement.PROMPT_ONLY)
        assert caps.supports(HarnessCapability.KCC_POLICY_GATE) is False

    def test_approval_passive_means_none_or_never(self) -> None:
        assert HarnessCapabilities(approval_mode=ApprovalMode.NONE).supports(
            HarnessCapability.APPROVAL_PASSIVE
        )
        assert HarnessCapabilities(approval_mode=ApprovalMode.NEVER).supports(
            HarnessCapability.APPROVAL_PASSIVE
        )
        assert not HarnessCapabilities(approval_mode=ApprovalMode.ASK).supports(
            HarnessCapability.APPROVAL_PASSIVE
        )
        assert not HarnessCapabilities(approval_mode=ApprovalMode.UNKNOWN).supports(
            HarnessCapability.APPROVAL_PASSIVE
        )

    def test_supports_with_no_requirements_is_vacuously_true(self) -> None:
        assert HarnessCapabilities.unknown().supports() is True

    def test_unknown_capability_name_is_rejected_not_guessed(self) -> None:
        with pytest.raises(ValueError, match="unknown harness capability"):
            HarnessCapabilities.unknown().supports("telepathy")
        with pytest.raises(ValueError, match="unknown harness capability"):
            HarnessCapabilities.unknown().supports(HarnessCapability.READ, "telepathy")


class TestBestStrategy:
    def test_local_when_only_single_agent_execution_proven(self) -> None:
        caps = HarnessCapabilities(read=True, write=True, exec=True)
        assert caps.best_strategy() is ExecutionStrategy.LOCAL

    def test_fresh_worker_proven_yields_serial_worker(self) -> None:
        caps = HarnessCapabilities(fresh_workers=True)
        assert caps.best_strategy() is ExecutionStrategy.SERIAL_WORKER

    def test_fresh_and_parallel_proven_yield_parallel_workers(self) -> None:
        caps = HarnessCapabilities(fresh_workers=True, parallel_workers=True)
        assert caps.best_strategy() is ExecutionStrategy.PARALLEL_WORKERS

    def test_full_autopilot_requires_read_write_exec_policy_gate_and_passive_approval(
        self,
    ) -> None:
        assert _full_autopilot_capabilities().best_strategy() is ExecutionStrategy.FULL_AUTOPILOT

    @pytest.mark.parametrize(
        ("overrides", "expected"),
        [
            ({"read": False}, ExecutionStrategy.PARALLEL_WORKERS),
            ({"write": False}, ExecutionStrategy.PARALLEL_WORKERS),
            ({"exec": False}, ExecutionStrategy.PARALLEL_WORKERS),
            ({"fresh_workers": False}, ExecutionStrategy.LOCAL),
            ({"parallel_workers": False}, ExecutionStrategy.SERIAL_WORKER),
            (
                {"mutation_enforcement": MutationEnforcement.NONE},
                ExecutionStrategy.PARALLEL_WORKERS,
            ),
            (
                {"mutation_enforcement": MutationEnforcement.PROMPT_ONLY},
                ExecutionStrategy.PARALLEL_WORKERS,
            ),
            ({"approval_mode": ApprovalMode.ASK}, ExecutionStrategy.PARALLEL_WORKERS),
            ({"approval_mode": ApprovalMode.UNKNOWN}, ExecutionStrategy.PARALLEL_WORKERS),
        ],
    )
    def test_full_autopilot_denied_when_any_requirement_is_missing(
        self, overrides, expected
    ) -> None:
        caps = _full_autopilot_capabilities().model_copy(update=overrides)
        assert caps.best_strategy() is expected
        assert caps.full_autopilot_authorized is False

    def test_full_autopilot_accepts_approval_none_or_never(self) -> None:
        for mode in (ApprovalMode.NONE, ApprovalMode.NEVER):
            caps = _full_autopilot_capabilities().model_copy(update={"approval_mode": mode})
            assert caps.best_strategy() is ExecutionStrategy.FULL_AUTOPILOT

    def test_unproven_parallel_degrades_to_serial(self) -> None:
        """A harness with fresh workers and the full autopilot permission
        profile must never claim full-autopilot or parallel-workers while
        parallel execution is unproven: it degrades to serial-worker."""
        caps = HarnessCapabilities(
            read=True,
            write=True,
            exec=True,
            fresh_workers=True,
            parallel_workers=False,
            approval_mode=ApprovalMode.NEVER,
            mutation_enforcement=MutationEnforcement.KCC_POLICY_GATE,
        )
        assert caps.best_strategy() is ExecutionStrategy.SERIAL_WORKER
        assert caps.full_autopilot_authorized is False

    def test_parallel_without_fresh_workers_is_not_parallel(self) -> None:
        caps = HarnessCapabilities(parallel_workers=True, fresh_workers=False)
        assert caps.best_strategy() is ExecutionStrategy.LOCAL

    def test_full_autopilot_authorized_exposes_the_law(self) -> None:
        assert _full_autopilot_capabilities().full_autopilot_authorized is True
        assert HarnessCapabilities.unknown().full_autopilot_authorized is False


# ---------------------------------------------------------------------------
# HarnessProbe -- only proven capabilities, aware timestamp, nonempty evidence.
# ---------------------------------------------------------------------------


class TestHarnessProbe:
    def test_probe_records_identity_detection_capabilities_and_evidence(self) -> None:
        probe = HarnessProbe(
            harness_id="codex",
            detected=True,
            capabilities=HarnessCapabilities(read=True),
            probed_at=datetime(2026, 8, 29, 1, 2, 3, tzinfo=timezone.utc),
            evidence=["native AGENTS.md detected", "read tool allowlisted"],
        )
        assert probe.harness_id == "codex"
        assert probe.detected is True
        assert probe.capabilities.read is True
        assert probe.probed_at == datetime(2026, 8, 29, 1, 2, 3, tzinfo=timezone.utc)
        assert probe.evidence == ["native AGENTS.md detected", "read tool allowlisted"]
        assert probe.error is None

    def test_undetected_probe_keeps_unknown_capabilities(self) -> None:
        probe = HarnessProbe(
            harness_id="dsh",
            detected=False,
            probed_at=datetime(2026, 8, 29, 1, 2, 3, tzinfo=timezone.utc),
            error="dsh binary not found",
        )
        assert probe.capabilities == HarnessCapabilities.unknown()
        assert probe.detected is False
        assert probe.error == "dsh binary not found"
        assert probe.capabilities.best_strategy() is ExecutionStrategy.LOCAL

    def test_probe_requires_timezone_aware_timestamp(self) -> None:
        with pytest.raises(ValidationError, match="probed_at must be timezone-aware"):
            HarnessProbe(
                harness_id="codex",
                probed_at=datetime(2026, 8, 29, 1, 2, 3),
            )

    def test_probe_requires_nonempty_harness_id(self) -> None:
        with pytest.raises(ValidationError, match="harness_id"):
            HarnessProbe(
                harness_id="  ",
                probed_at=datetime(2026, 8, 29, 1, 2, 3, tzinfo=timezone.utc),
            )

    def test_probe_rejects_blank_evidence_entries(self) -> None:
        with pytest.raises(ValidationError, match="evidence"):
            HarnessProbe(
                harness_id="codex",
                probed_at=datetime(2026, 8, 29, 1, 2, 3, tzinfo=timezone.utc),
                evidence=["proven", " "],
            )

    def test_probe_rejects_blank_error(self) -> None:
        with pytest.raises(ValidationError, match="error"):
            HarnessProbe(
                harness_id="codex",
                probed_at=datetime(2026, 8, 29, 1, 2, 3, tzinfo=timezone.utc),
                error="   ",
            )


# ---------------------------------------------------------------------------
# HarnessTask -- consumes the bounded TaskHandoff + project-relative paths.
# ---------------------------------------------------------------------------


class TestHarnessTask:
    def test_task_carries_handoff_workspace_and_paths(self) -> None:
        task = _task()
        assert task.handoff.run_id == RUN_ID
        assert task.handoff.task_id == TASK_ID
        assert task.handoff.lease.lease_id == LEASE_ID
        assert task.workspace_id == "workspace-1"
        assert task.handoff_path == f"coordination/autobuild/{RUN_ID}/task-handoff.json"
        assert task.report_path == f"coordination/autobuild/{RUN_ID}/execution-report.json"

    def test_task_paths_must_live_under_the_run_coordination_dir(self) -> None:
        with pytest.raises(ValidationError, match="coordination/autobuild"):
            _task(handoff_path=f"coordination/autobuild/{RUN_ID.replace('001', '999')}/x.json")
        with pytest.raises(ValidationError, match="coordination/autobuild"):
            _task(report_path="coordination/other/RUN-001/report.json")

    def test_task_rejects_absolute_paths(self) -> None:
        with pytest.raises(ValidationError, match="project-relative"):
            _task(handoff_path="/etc/autobuild/handoff.json")

    def test_task_rejects_parent_traversal(self) -> None:
        with pytest.raises(ValidationError, match="project-relative"):
            _task(report_path="coordination/autobuild/RUN-001/../../report.json")

    def test_task_rejects_sibling_file_dotsegments(self) -> None:
        with pytest.raises(ValidationError, match="project-relative"):
            _task(report_path=f"coordination/autobuild/{RUN_ID}/./execution-report.json")

    def test_task_rejects_backslash_paths(self) -> None:
        with pytest.raises(ValidationError, match="project-relative"):
            _task(handoff_path=f"coordination\\autobuild\\{RUN_ID}\\task-handoff.json")

    def test_task_rejects_blank_workspace_id(self) -> None:
        with pytest.raises(ValidationError, match="workspace_id"):
            _task(workspace_id="  ")


class TestHarnessTaskReportBinding:
    """The report file is the completion contract: a report that does not
    bind to the handoff identity is rejected, never trusted (fail closed)."""

    def test_matching_report_is_accepted(self) -> None:
        task = _task()
        task.validate_report(_report())  # must not raise

    def test_run_id_mismatch_rejected(self) -> None:
        task = _task()
        with pytest.raises(HarnessError, match="run_id"):
            task.validate_report(_report(run_id="RUN-999"))

    def test_task_id_mismatch_rejected(self) -> None:
        task = _task()
        with pytest.raises(HarnessError, match="task_id"):
            task.validate_report(_report(task_id="TASK-999"))

    def test_attempt_must_equal_lease_generation(self) -> None:
        task = _task(handoff=_handoff(generation=2, lease_id="LEASE-RUN-001-TASK-021-2"))
        with pytest.raises(HarnessError, match="attempt"):
            task.validate_report(_report(attempt=1))
        task.validate_report(_report(attempt=2, lease_id="LEASE-RUN-001-TASK-021-2"))

    def test_lease_id_mismatch_rejected(self) -> None:
        task = _task()
        with pytest.raises(HarnessError, match="lease_id"):
            task.validate_report(_report(lease_id="LEASE-LOST"))

    def test_workspace_id_mismatch_rejected(self) -> None:
        task = _task()
        with pytest.raises(HarnessError, match="workspace_id"):
            task.validate_report(_report(workspace_id="workspace-666"))

    def test_failed_report_still_must_bind_identity(self) -> None:
        task = _task()
        report = _report(status=ExecutionStatus.FAILED)
        task.validate_report(report)
        with pytest.raises(HarnessError, match="run_id"):
            task.validate_report(_report(status=ExecutionStatus.FAILED, run_id="RUN-999"))


# ---------------------------------------------------------------------------
# HarnessError / HarnessAdapter -- contract boundary types.
# ---------------------------------------------------------------------------


class TestHarnessError:
    def test_harness_error_is_a_value_error(self) -> None:
        assert issubclass(HarnessError, ValueError)
        assert issubclass(HarnessError, Exception)


class TestHarnessAdapter:
    def test_adapter_cannot_be_constructed_directly(self) -> None:
        with pytest.raises(TypeError):
            HarnessAdapter()  # type: ignore[abstract]

    def test_concrete_adapter_implements_probe_and_execute(self) -> None:
        probe = HarnessProbe(
            harness_id="codex",
            detected=True,
            probed_at=datetime(2026, 8, 29, 1, 2, 3, tzinfo=timezone.utc),
        )

        class CodexAdapter(HarnessAdapter):
            harness_id = "codex"

            def probe(self) -> HarnessProbe:
                return probe

            def execute(self, task: HarnessTask) -> ExecutionReport:
                assert task.handoff.run_id == RUN_ID
                return _report()

        adapter = CodexAdapter()
        assert adapter.harness_id == "codex"
        assert adapter.probe() is probe

    def test_missing_execute_keeps_adapter_abstract(self) -> None:
        class PartialAdapter(HarnessAdapter):
            harness_id = "partial"

            def probe(self) -> HarnessProbe:
                return HarnessProbe(
                    harness_id="partial",
                    probed_at=datetime(2026, 8, 29, 1, 2, 3, tzinfo=timezone.utc),
                )

        with pytest.raises(TypeError):
            PartialAdapter()  # type: ignore[abstract]


# ---------------------------------------------------------------------------
# Public surface -- everything prescribed is importable from the package.
# ---------------------------------------------------------------------------


def test_public_api_exports_the_prescribed_names() -> None:
    models_exports = {
        "ApprovalMode",
        "MutationEnforcement",
        "ExecutionStrategy",
        "HarnessCapabilities",
        "HarnessProbe",
        "HarnessTask",
        "HarnessError",
        "HarnessCapability",
    }
    from kcc_autobuild.harnesses import __all__  # noqa: PLC0415

    assert models_exports <= set(__all__)
    assert "HarnessAdapter" in __all__


def test_capability_model_is_exposed_identically_from_package() -> None:
    assert HarnessCapabilities is ModelsCapabilities
