"""Generic compatibility harness adapter (Plan 08, Task 2) -- tests.

Written first (strict TDD red phase) against the external behavior
contract of Task 2 of :file:`.superpowers/bootstrap/plans/
2026-08-27-08-harness-capability-deepseek-adapter.task-contracts.md`
(KCC x Superpowers Hybrid Framework)::

    Generic conservative probe uses local shell/filesystem but never
    fakes fresh/parallel workers or policy enforcement; compatibility
    can degrade to local sequential.
    Tests: beta parallel preferred; generic capability truth/degradation.

Binding semantics under test:

* The generic adapter probes the LOCAL shell (``sh -c``) and the local
  filesystem (read/write of the workspace): only what those checks
  actually prove is reported -- read/write/exec when the checks pass,
  never fresh workers, never parallel workers, never subagents and
  never KCC policy enforcement (``mutation_enforcement`` stays ``none``,
  approval stays ``unknown``: the generic compatibility harness is not
  a policy-guarded worker).
* Full local file+command compatibility is ``detected`` and its
  strategy degrades to ``LOCAL`` -- a generic harness is never claimed
  to be serial/parallel/full-autopilot.
* A failed check degrades the capability set truthfully (that capability
  simply stays unproven, confidence reflects the proven fraction, the
  probe records the failure and is NOT detected) -- a broken shell or
  missing workspace never produces a fake capability claim.
* ``execute`` never fakes a worker dispatch: the generic harness has no
  external worker CLI, so it raises ``HarnessError`` (fail closed).
"""

from __future__ import annotations

import pytest

from kcc_autobuild.bridge import (
    AttemptBudget,
    TaskHandoff,
    TaskLease,
)
from kcc_autobuild.harnesses import (
    ApprovalMode,
    ExecutionStrategy,
    HarnessCapability,
    HarnessError,
    HarnessTask,
    MutationEnforcement,
)
from kcc_autobuild.harnesses.generic import GENERIC_HARNESS_ID, GenericHarnessAdapter

POLICY_HASH = "a" * 64


def _handoff() -> TaskHandoff:
    return TaskHandoff(
        run_id="RUN-001",
        task_id="TASK-021",
        requirement_ids=["REQ-001"],
        acceptance_ids=["AC-001"],
        test_ids=["T-001"],
        lease=TaskLease(
            lease_id="LEASE-RUN-001-TASK-021-1",
            run_id="RUN-001",
            task_id="TASK-021",
            generation=1,
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
        workspace_id="workspace-1",
        handoff_path="coordination/autobuild/RUN-001/handoff.json",
        report_path="coordination/autobuild/RUN-001/report.json",
    )


# --- Capability truth ---------------------------------------------------------


def test_generic_probe_reports_only_proven_local_capabilities(tmp_path) -> None:
    probe = GenericHarnessAdapter(workspace=tmp_path, shell="sh").probe()
    capabilities = probe.capabilities
    assert probe.harness_id == GENERIC_HARNESS_ID
    assert probe.detected is True
    assert probe.error is None
    assert capabilities.read is True
    assert capabilities.write is True
    assert capabilities.exec is True
    # Truth: nothing beyond the local shell/filesystem session is proven.
    assert capabilities.fresh_workers is False
    assert capabilities.parallel_workers is False
    assert capabilities.subagents is False
    assert capabilities.mutation_enforcement is MutationEnforcement.NONE
    assert capabilities.approval_mode is ApprovalMode.UNKNOWN
    assert capabilities.confidence == pytest.approx(1.0)
    assert probe.evidence  # probe observations are recorded
    assert probe.probed_at.tzinfo is not None


def test_generic_probe_never_fakes_workers_or_policy_enforcement(tmp_path) -> None:
    capabilities = GenericHarnessAdapter(workspace=tmp_path, shell="sh").probe().capabilities
    # Never fakes fresh/parallel workers...
    assert not capabilities.supports(HarnessCapability.FRESH_WORKERS)
    assert not capabilities.supports(HarnessCapability.PARALLEL_WORKERS)
    assert not capabilities.supports(HarnessCapability.SUBAGENTS)
    # ...and never fakes policy enforcement / passive approval.
    assert not capabilities.supports(HarnessCapability.KCC_POLICY_GATE)
    assert not capabilities.supports(HarnessCapability.APPROVAL_PASSIVE)
    assert not capabilities.full_autopilot_authorized


def test_generic_compatibility_degrades_to_local_sequential(tmp_path) -> None:
    probe = GenericHarnessAdapter(workspace=tmp_path, shell="sh").probe()
    # A generic file+command harness is usable, but its strategy is LOCAL:
    # no fresh workers were proven, so it never claims serial or parallel.
    assert probe.capabilities.best_strategy() is ExecutionStrategy.LOCAL
    assert probe.detected is True


# --- Capability degradation ---------------------------------------------------


def test_generic_probe_degrades_truthfully_when_shell_missing(tmp_path) -> None:
    probe = GenericHarnessAdapter(
        workspace=tmp_path, shell="__no_such_shell_123__"
    ).probe()
    capabilities = probe.capabilities
    assert capabilities.exec is False  # never faked
    assert capabilities.read is True  # filesystem check still passed
    assert capabilities.write is True
    assert probe.detected is False  # not a usable file+command session
    assert probe.error is not None
    assert "shell" in (probe.error or "")
    assert capabilities.confidence == pytest.approx(0.67)
    # Degradation is bounded and truthful: still LOCAL, still no policy claim.
    assert capabilities.best_strategy() is ExecutionStrategy.LOCAL
    assert capabilities.mutation_enforcement is MutationEnforcement.NONE


def test_generic_probe_degrades_truthfully_when_workspace_unreadable(
    tmp_path,
) -> None:
    probe = GenericHarnessAdapter(
        workspace=tmp_path / "does-not-exist", shell="sh"
    ).probe()
    capabilities = probe.capabilities
    assert capabilities.read is False
    assert capabilities.write is False
    assert capabilities.exec is True  # shell check is independent
    assert probe.detected is False
    assert capabilities.confidence == pytest.approx(0.33)


def test_generic_probe_leaves_no_probe_files_behind(tmp_path) -> None:
    GenericHarnessAdapter(workspace=tmp_path, shell="sh").probe()
    leftovers = list(tmp_path.glob(".kcc-generic-probe-*"))
    assert leftovers == []


def test_generic_probe_uses_the_given_workspace_and_shell(tmp_path) -> None:
    probe = GenericHarnessAdapter(workspace=tmp_path, shell="sh").probe()
    joined = "\n".join(probe.evidence)
    assert "sh -c 'exit 0'" in joined
    assert str(tmp_path) in joined


def test_generic_probe_verdict_is_stable_across_repeated_calls(tmp_path) -> None:
    adapter = GenericHarnessAdapter(workspace=tmp_path, shell="sh")
    first = adapter.probe()
    second = adapter.probe()
    assert first.detected == second.detected
    assert first.error == second.error
    assert first.evidence == second.evidence
    assert first.capabilities == second.capabilities


def test_generic_adapter_constructor_validation() -> None:
    with pytest.raises(ValueError, match="shell"):
        GenericHarnessAdapter(shell="   ")
    with pytest.raises(ValueError, match="timeout"):
        GenericHarnessAdapter(timeout_seconds=0.0)
    with pytest.raises(ValueError, match="timeout"):
        GenericHarnessAdapter(timeout_seconds=-1.0)


# --- Usage through the registry (capability truth/degradation) ----------------


def test_generic_is_selectable_for_local_sequential_compatibility(tmp_path) -> None:
    from kcc_autobuild.harnesses.registry import HarnessRegistry

    registry = HarnessRegistry()
    registry.register(GenericHarnessAdapter(workspace=tmp_path, shell="sh"))
    selection = registry.select()
    assert selection.harness_id == GENERIC_HARNESS_ID
    assert selection.strategy is ExecutionStrategy.LOCAL
    assert selection.capabilities.read is True
    assert selection.capabilities.write is True
    assert selection.capabilities.exec is True
    assert selection.capabilities.fresh_workers is False
    assert selection.capabilities.supports(HarnessCapability.KCC_POLICY_GATE) is False


def test_degraded_generic_is_never_selected(tmp_path) -> None:
    from kcc_autobuild.harnesses.registry import HarnessRegistry

    registry = HarnessRegistry()
    registry.register(
        GenericHarnessAdapter(
            workspace=tmp_path, shell="__no_such_shell_123__"
        )
    )
    probe = registry.probe_all()[GENERIC_HARNESS_ID]
    assert probe.detected is False
    assert probe.capabilities.exec is False  # truth, no fake exec
    with pytest.raises(HarnessError, match="no detected harness"):
        registry.select()


# --- Execute: no fake dispatch ------------------------------------------------


def test_generic_execute_fails_closed_instead_of_faking_worker_dispatch() -> None:
    adapter = GenericHarnessAdapter()
    with pytest.raises(HarnessError, match="no external worker"):
        adapter.execute(_task())


def test_generic_adapter_is_a_harness_adapter(tmp_path) -> None:
    from kcc_autobuild.harnesses import HarnessAdapter

    adapter = GenericHarnessAdapter(workspace=tmp_path, shell="sh")
    assert isinstance(adapter, HarnessAdapter)
    assert adapter.harness_id == GENERIC_HARNESS_ID
