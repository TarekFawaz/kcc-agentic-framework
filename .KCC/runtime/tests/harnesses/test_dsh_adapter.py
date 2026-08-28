"""DeepSeek Harness (dsh) execution adapter (Plan 08, Task 4) -- tests.

Written first (strict TDD red phase) against the external behavior
contract of Task 4 of :file:`.superpowers/bootstrap/plans/
2026-08-27-08-harness-capability-deepseek-adapter.task-contracts.md`
(KCC x Superpowers Hybrid Framework)::

    DSH runtime probe/adapter.  Feature-probe, never exact-version gate.
    Probe native AGENTS.md + generated skills; fresh worker/parallel only
    proven by installed headless profile; approval_mode=NEVER +
    mutation_enforcement=KCC_POLICY_GATE only after `doctor dsh --live`
    proves effective hardened profile/guard.  Dispatch fresh
    `dsh --profile headless` worker referencing project-relative
    TaskHandoff/report paths under coordination/autobuild/<RUN>; report
    file is completion contract, process exit 0 without valid
    ExecutionReport fails.  Normalize harness metadata only; KCC still
    verifies lease/commits/CI/tests/policy.  CLI `harness probe dsh`,
    `harness doctor dsh`; live doctor disposable kcc-autobuild profile
    invokes `kcc_harness_status` exactly once and accepts exactly one
    `KCC_DSH_STATUS:` JSON line proving sandbox workspace-write,
    approval never, expected guard; any extra/missing/prompt/error fails.

Binding semantics under test:

* The probe is feature-based: it observes the workspace's native
  ``AGENTS.md``, the generated ``.dsh/skills/*/SKILL.md`` packages, the
  dsh CLI boot and an installed headless profile -- never an exact
  version gate (a dsh binary that refuses ``--version`` must not fail
  the probe).
* Fresh/parallel worker capability is proven ONLY by an installed,
  bootable headless profile; without it both stay false and the
  strategy degrades (never faked).
* ``approval_mode=NEVER`` + ``mutation_enforcement=KCC_POLICY_GATE`` is
  granted only by a PASSED LIVE doctor outcome (``live=True,
  passed=True``); an offline doctor outcome or the mere presence of
  generated skills never grants it.
* ``execute`` writes the bounded TaskHandoff pack, dispatches
  ``dsh --profile headless`` with a prompt referencing the
  project-relative handoff/report paths under
  ``coordination/autobuild/<RUN>``, and treats the report file as the
  completion contract: exit 0 without a fresh valid report is a
  :class:`HarnessError`, as are non-zero exits, invalid reports and
  identity mismatches.
* The raw report document is normalized by removing harness metadata
  ONLY every other field is preserved and validated, so a non-metadata
  extra field still fails closed.
* ``harness probe dsh`` and ``harness doctor dsh`` exist on the CLI and
  print deterministic JSON; the doctor validates exactly one
  ``KCC_DSH_STATUS:`` line (extra, missing, prompt or error fails).
"""

from __future__ import annotations

import json
import stat
from pathlib import Path

import pytest
from pydantic import ValidationError
from typer.testing import CliRunner

from kcc_autobuild.bridge import (
    AttemptBudget,
    ExecutionReport,
    TaskHandoff,
    TaskLease,
)
from kcc_autobuild.cli import app
from kcc_autobuild.harnesses import (
    ApprovalMode,
    ExecutionStrategy,
    HarnessAdapter,
    HarnessCapability,
    HarnessError,
    HarnessTask,
    MutationEnforcement,
)
from kcc_autobuild.harnesses.dsh import (
    DshDoctorOutcome,
    DshHarnessAdapter,
    dsh_doctor,
)

POLICY_HASH = "a" * 64
RUN_ID = "RUN-001"
TASK_ID = "TASK-021"
LEASE_ID = "LEASE-RUN-001-TASK-021-1"

STATUS_JSON = (
    '{"sandbox":"workspace-write","approval":"never","guard":"kcc-policy-gate"}'
)
STATUS_LINE = f"KCC_DSH_STATUS: {STATUS_JSON}"

REPORT_YAML = (
    "run_id: RUN-001\n"
    "task_id: TASK-021\n"
    "attempt: 1\n"
    "status: passed\n"
    "lease_id: LEASE-RUN-001-TASK-021-1\n"
    "workspace_id: workspace-1\n"
    "acceptance_evidence:\n"
    "  - acceptance_id: AC-001\n"
    "    test_ids: [T-001]\n"
    "    evidence_refs: [tests/test_dsh_adapter.py]\n"
    "failure: null\n"
    "usage: {}\n"
    "outputs: []\n"
    "deviations: []\n"
    "trace_updates: []\n"
)

runner = CliRunner()


# ---------------------------------------------------------------------------
# Fixtures: a KCC-initialized dsh workspace + an installed headless profile.
# ---------------------------------------------------------------------------


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


def _task(**overrides) -> HarnessTask:
    kwargs = {
        "handoff": _handoff(),
        "workspace_id": "workspace-1",
        "handoff_path": f"coordination/autobuild/{RUN_ID}/task-handoff.json",
        "report_path": f"coordination/autobuild/{RUN_ID}/execution-report.yaml",
    }
    kwargs.update(overrides)
    return HarnessTask(**kwargs)


def _report_yaml(report: str = REPORT_YAML) -> str:
    return report


def _workspace(root: Path) -> Path:
    """A KCC-initialized dsh workspace: native AGENTS.md + generated skills."""
    workspace = root / "workspace"
    (workspace / ".dsh" / "skills" / "example").mkdir(parents=True)
    (workspace / "AGENTS.md").write_text(
        "# AGENTS.md\n\nGenerated project entrypoint (preserved).\n",
        encoding="utf-8",
    )
    (workspace / ".dsh" / "skills" / "example" / "SKILL.md").write_text(
        "---\nname: example\n---\n\nExample generated skill.\n",
        encoding="utf-8",
    )
    return workspace


def _dsh_home(root: Path, *, headless: bool = True) -> Path:
    """An installed headless profile under a DSH_HOME."""
    home = root / "dsh-home"
    if headless:
        profile = home / "profiles" / "headless"
        (profile / "node_modules").mkdir(parents=True)
        (profile / "package.json").write_text(
            json.dumps(
                {
                    "name": "dsh-profile-headless",
                    "private": True,
                    "dependencies": {},
                    "dsh": {
                        "profile": {
                            "bundles": [
                                "@deepseek-ai/dsh-base",
                                "@deepseek-ai/dsh-headless",
                            ]
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        (profile / "cordis.patch.yml").write_text("[]\n", encoding="utf-8")
        (profile / "cordis.yml").write_text("[]\n", encoding="utf-8")
        (profile / "pnpm-workspace.yaml").write_text(
            "packages:\n  - .\n", encoding="utf-8"
        )
    return home


def _fake_dsh(
    root: Path,
    *,
    name: str = "dsh",
    exit_code: int = 0,
    boot_exit_code: int = 0,
    boot_stdout: str = "dsh launcher help\n",
    stdout: str = "",
    stderr: str = "",
    capture_args: bool = False,
    report: str | None = None,
    report_path: str = "coordination/autobuild/RUN-001/execution-report.yaml",
    help_refuses_version: bool = False,
) -> Path:
    """An executable fake dsh binary with controllable behavior.

    Feature-probe invocations are ``dsh --help`` /
    ``dsh --profile <name> --help`` (argument list contains ``--help``);
    a worker dispatch is any invocation without ``--help``.
    """
    bin_path = root / "bin" / name
    bin_path.parent.mkdir(parents=True)
    script = ["#!/bin/sh"]
    if capture_args:
        script.append('printf "%s\\n" "$@" > "$(dirname "$0")/argv.txt"')
    script.append('case " $* " in')
    script.append("  *\" --help \"*)")
    if help_refuses_version:
        script.append("    if [ \"$1\" = \"--version\" ] || [ \"$2\" = \"--version\" ]; then")
        script.append("      exit 1")
        script.append("    fi")
    script.append(f'    printf "%s\\n" "{boot_stdout}"')
    script.append(f"    exit {boot_exit_code}")
    script.append("    ;;")
    script.append("esac")
    if report is not None:
        script.append(f"mkdir -p \"$(dirname \"{report_path}\")\"")
        script.append(f"cat > \"{report_path}\" <<'KCC_REPORT_EOF'")
        script.append(report.rstrip("\n"))
        script.append("KCC_REPORT_EOF")
    if stdout:
        script.append(f"cat <<'KCC_STDOUT_EOF'\n{stdout}\nKCC_STDOUT_EOF")
    if stderr:
        script.append(f"cat >&2 <<'KCC_STDERR_EOF'\n{stderr}\nKCC_STDERR_EOF")
    script.append(f"exit {exit_code}")
    bin_path.write_text("\n".join(script) + "\n", encoding="utf-8")
    bin_path.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
    return bin_path


def _adapter_factory(tmp_path):
    def make(**overrides) -> DshHarnessAdapter:
        kwargs = {
            "dsh_bin": str(_fake_dsh(tmp_path)),
            "workspace": _workspace(tmp_path),
            "dsh_home": _dsh_home(tmp_path),
            "timeout_seconds": 30.0,
        }
        kwargs.update(overrides)
        return DshHarnessAdapter(**kwargs)

    return make


def _doctor(**overrides):
    kwargs = {
        "live": True,
        "passed": True,
        "sandbox": "workspace-write",
        "approval": "never",
        "guard": "kcc-policy-gate",
    }
    kwargs.update(overrides)
    return DshDoctorOutcome(**kwargs)


# ---------------------------------------------------------------------------
# Probe: capability truth and feature-based checks.
# ---------------------------------------------------------------------------


class TestDshProbe:
    def test_probe_reports_only_proven_native_capabilities(self, tmp_path) -> None:
        probe = _adapter_factory(tmp_path)().probe()
        capabilities = probe.capabilities
        assert probe.harness_id == "dsh"
        assert probe.detected is True
        assert probe.error is None
        # Workspace facts proven by the checks: native AGENTS.md + generated
        # skills + workspace write + dsh CLI + installed headless profile.
        assert capabilities.read is True
        assert capabilities.write is True
        assert capabilities.exec is True
        assert capabilities.fresh_workers is True
        assert capabilities.parallel_workers is True
        assert capabilities.subagents is False
        # No policy claim without a passed live doctor.
        assert capabilities.mutation_enforcement is MutationEnforcement.NONE
        assert capabilities.approval_mode is ApprovalMode.UNKNOWN
        assert capabilities.confidence == pytest.approx(1.0)
        evidence = "\n".join(probe.evidence)
        assert "AGENTS.md" in evidence
        assert "SKILL.md" in evidence
        assert "headless" in evidence
        assert probe.probed_at.tzinfo is not None

    def test_probe_is_feature_based_never_exact_version_gate(self, tmp_path) -> None:
        # The fake refuses --version outright and prints no version at all:
        # a feature probe never calls it and still detects the harness.
        fake = _fake_dsh(tmp_path, boot_stdout="dsh 0.0.0 arbitrary\n", help_refuses_version=True)
        probe = DshHarnessAdapter(
            dsh_bin=str(fake),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path),
        ).probe()
        assert probe.detected is True
        assert probe.capabilities.exec is True
        assert probe.capabilities.fresh_workers is True

    def test_probe_never_claims_policy_or_passive_approval_without_doctor(
        self, tmp_path
    ) -> None:
        capabilities = _adapter_factory(tmp_path)().probe().capabilities
        assert not capabilities.supports(HarnessCapability.KCC_POLICY_GATE)
        assert not capabilities.supports(HarnessCapability.APPROVAL_PASSIVE)
        assert not capabilities.supports(HarnessCapability.APPROVAL_NEVER)
        assert not capabilities.full_autopilot_authorized
        # Fresh + parallel are proven, but without the policy gate the
        # strategy is parallel workers at most -- never full autopilot.
        assert capabilities.best_strategy() is ExecutionStrategy.PARALLEL_WORKERS

    def test_probe_grants_never_and_policy_gate_only_after_live_doctor(
        self, tmp_path
    ) -> None:
        adapter = _adapter_factory(tmp_path)(doctor=_doctor())
        capabilities = adapter.probe().capabilities
        assert capabilities.approval_mode is ApprovalMode.NEVER
        assert capabilities.mutation_enforcement is MutationEnforcement.KCC_POLICY_GATE
        assert capabilities.supports(HarnessCapability.KCC_POLICY_GATE)
        assert capabilities.supports(HarnessCapability.APPROVAL_PASSIVE)
        assert capabilities.best_strategy() is ExecutionStrategy.FULL_AUTOPILOT
        assert capabilities.full_autopilot_authorized is True

    def test_probe_ignores_non_live_doctor_outcome(self, tmp_path) -> None:
        # An offline doctor reports prerequisites only: its (live=False)
        # outcome must never grant hardened capabilities.
        offline = _doctor(live=False)
        capabilities = _adapter_factory(tmp_path)(doctor=offline).probe().capabilities
        assert capabilities.approval_mode is ApprovalMode.UNKNOWN
        assert capabilities.mutation_enforcement is MutationEnforcement.NONE
        assert capabilities.best_strategy() is ExecutionStrategy.PARALLEL_WORKERS

    def test_probe_ignores_failed_doctor_outcome(self, tmp_path) -> None:
        failed = _doctor(passed=False, sandbox=None, approval=None, guard=None, error="boom")
        capabilities = _adapter_factory(tmp_path)(doctor=failed).probe().capabilities
        assert capabilities.approval_mode is ApprovalMode.UNKNOWN
        assert capabilities.mutation_enforcement is MutationEnforcement.NONE

    def test_probe_degrades_without_installed_headless_profile(self, tmp_path) -> None:
        empty_home = _dsh_home(tmp_path / "empty-dsh-root", headless=False)
        adapter = _adapter_factory(tmp_path)(dsh_home=empty_home)
        probe = adapter.probe()
        capabilities = probe.capabilities
        # Fresh/parallel are only ever proven by an installed headless
        # profile: without one they are never claimed.
        assert capabilities.fresh_workers is False
        assert capabilities.parallel_workers is False
        assert capabilities.best_strategy() is ExecutionStrategy.LOCAL
        assert probe.error is not None
        assert "headless" in (probe.error or "")

    def test_probe_degrades_when_headless_profile_boot_fails(self, tmp_path) -> None:
        fake = _fake_dsh(tmp_path, boot_exit_code=2)
        probe = DshHarnessAdapter(
            dsh_bin=str(fake),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path),
        ).probe()
        # An installed-but-unbootable profile proves nothing.
        assert probe.capabilities.fresh_workers is False
        assert probe.capabilities.parallel_workers is False
        assert probe.error is not None

    def test_probe_degrades_without_generated_skills(self, tmp_path) -> None:
        workspace = _workspace(tmp_path)
        import shutil

        shutil.rmtree(workspace / ".dsh")
        probe = DshHarnessAdapter(
            dsh_bin=str(_fake_dsh(tmp_path)),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
        ).probe()
        assert probe.detected is False
        assert probe.error is not None
        assert "skill" in (probe.error or "").lower()

    def test_probe_degrades_without_native_agents_md(self, tmp_path) -> None:
        workspace = _workspace(tmp_path)
        (workspace / "AGENTS.md").unlink()
        probe = DshHarnessAdapter(
            dsh_bin=str(_fake_dsh(tmp_path)),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
        ).probe()
        assert probe.capabilities.read is False
        assert probe.detected is False
        assert probe.capabilities.confidence == pytest.approx(0.67)

    def test_probe_degrades_when_dsh_cli_missing(self, tmp_path) -> None:
        adapter = DshHarnessAdapter(
            dsh_bin="__no_such_dsh_binary_123__",
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path),
        )
        probe = adapter.probe()
        assert probe.capabilities.exec is False
        assert probe.detected is False
        assert probe.error is not None

    def test_probe_leaves_no_probe_files_behind(self, tmp_path) -> None:
        adapter = _adapter_factory(tmp_path)()
        adapter.probe()
        leftovers = list((tmp_path / "workspace").glob(".*kcc*probe*"))
        assert leftovers == []

    def test_probe_verdict_is_stable_across_repeated_calls(self, tmp_path) -> None:
        adapter = _adapter_factory(tmp_path)()
        first = adapter.probe()
        second = adapter.probe()
        assert first.detected == second.detected
        assert first.error == second.error
        assert first.evidence == second.evidence
        assert first.capabilities == second.capabilities

    def test_adapter_constructor_validation(self, tmp_path) -> None:

        with pytest.raises(ValueError, match="dsh_bin"):
            DshHarnessAdapter(dsh_bin="   ")
        with pytest.raises(ValueError, match="profile"):
            DshHarnessAdapter(profile="   ")
        with pytest.raises(ValueError, match="timeout"):
            DshHarnessAdapter(timeout_seconds=0.0)
        with pytest.raises(ValueError, match="timeout"):
            DshHarnessAdapter(timeout_seconds=-1.0)

    def test_dsh_adapter_is_a_harness_adapter(self, tmp_path) -> None:
        adapter = _adapter_factory(tmp_path)()
        assert isinstance(adapter, HarnessAdapter)
        assert adapter.harness_id == "dsh"

    def test_dsh_adapter_can_be_registered_and_selected(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.registry import HarnessRegistry

        registry = HarnessRegistry()
        registry.register(_adapter_factory(tmp_path)())
        selection = registry.select()
        assert selection.harness_id == "dsh"
        assert selection.strategy is ExecutionStrategy.PARALLEL_WORKERS
        assert selection.capabilities.read is True
        assert selection.capabilities.supports(HarnessCapability.KCC_POLICY_GATE) is False


# ---------------------------------------------------------------------------
# Doctor outcome model.
# ---------------------------------------------------------------------------


class TestDshDoctorOutcome:
    def test_passed_live_outcome_must_prove_expected_values(self) -> None:

        with pytest.raises(ValidationError):
            DshDoctorOutcome(
                live=True,
                passed=True,
                sandbox="workspace-write",
                approval="ask",
                guard="kcc-policy-gate",
            )
        with pytest.raises(ValidationError):
            DshDoctorOutcome(
                live=True,
                passed=True,
                sandbox="workspace-write",
                approval="never",
                guard="none",
            )
        with pytest.raises(ValidationError):
            DshDoctorOutcome(
                live=True,
                passed=True,
                sandbox=None,
                approval=None,
                guard=None,
            )

    def test_passed_outcome_cannot_carry_an_error(self) -> None:

        with pytest.raises(ValidationError):
            DshDoctorOutcome(
                live=True,
                passed=True,
                sandbox="workspace-write",
                approval="never",
                guard="kcc-policy-gate",
                error="boom",
            )

    def test_offline_outcome_may_pass_prereqs_without_values(self) -> None:

        outcome = DshDoctorOutcome(live=False, passed=True, evidence=["prereqs ok"])
        assert outcome.sandbox is None
        assert outcome.approval is None
        assert outcome.guard is None


# ---------------------------------------------------------------------------
# Execute: dispatch + report-file completion contract.
# ---------------------------------------------------------------------------


class TestDshExecute:
    def test_execute_dispatches_headless_worker_and_returns_normalized_report(
        self, tmp_path
    ) -> None:
        workspace = _workspace(tmp_path)
        fake = _fake_dsh(
            tmp_path,
            capture_args=True,
            report=_report_yaml(),
            report_path="coordination/autobuild/RUN-001/execution-report.yaml",
        )
        adapter = DshHarnessAdapter(
            dsh_bin=str(fake),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
        )
        task = _task()
        report = adapter.execute(task)

        # The bounded handoff pack was written to the project-relative path.
        handoff_file = workspace / "coordination/autobuild/RUN-001/task-handoff.json"
        assert handoff_file.exists()
        assert json.loads(handoff_file.read_text(encoding="utf-8"))["run_id"] == RUN_ID

        # The dispatch referenced the project-relative paths under
        # coordination/autobuild/<RUN> and the headless profile.
        argv = (tmp_path / "bin" / "argv.txt").read_text(encoding="utf-8")
        assert "--profile" in argv
        assert "headless" in argv
        prompt = argv.splitlines()[-1]
        assert "coordination/autobuild/RUN-001/task-handoff.json" in prompt
        assert "coordination/autobuild/RUN-001/execution-report.yaml" in prompt

        # The returned report is the validated, bound ExecutionReport.
        assert isinstance(report, ExecutionReport)
        assert report.run_id == RUN_ID
        assert report.task_id == TASK_ID
        assert report.attempt == 1
        assert report.lease_id == LEASE_ID
        assert report.workspace_id == "workspace-1"
        assert report.status.value == "passed"
        assert report.acceptance_evidence[0].acceptance_id == "AC-001"

    def test_execute_normalizes_harness_metadata_only(self, tmp_path) -> None:
        workspace = _workspace(tmp_path)
        with_metadata = (
            REPORT_YAML
            + "harness_id: dsh\n"
            + "model: deepseek/deepseek-v4-flash-vision-exp\n"
            + "duration_ms: 1234\n"
            + "worker_id: worker-7\n"
        )
        fake = _fake_dsh(
            tmp_path,
            report=with_metadata,
            report_path="coordination/autobuild/RUN-001/execution-report.yaml",
        )
        adapter = DshHarnessAdapter(
            dsh_bin=str(fake),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
        )
        report = adapter.execute(_task())
        assert report.run_id == RUN_ID
        # Harness metadata was stripped; everything else was preserved.
        assert report.acceptance_evidence[0].test_ids == ["T-001"]

    def test_execute_rejects_non_metadata_extra_fields(self, tmp_path) -> None:
        workspace = _workspace(tmp_path)
        bogus = REPORT_YAML + "bogus_field: 1\n"
        fake = _fake_dsh(
            tmp_path,
            report=bogus,
            report_path="coordination/autobuild/RUN-001/execution-report.yaml",
        )
        adapter = DshHarnessAdapter(
            dsh_bin=str(fake),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
        )
        with pytest.raises(HarnessError, match="ExecutionReport"):
            adapter.execute(_task())

    def test_execute_exit_zero_without_report_fails(self, tmp_path) -> None:
        # The completion contract: exit 0 without a valid ExecutionReport
        # file is a failure, even though the process succeeded.
        workspace = _workspace(tmp_path)
        fake = _fake_dsh(tmp_path, exit_code=0, stdout="finished")
        adapter = DshHarnessAdapter(
            dsh_bin=str(fake),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
        )
        with pytest.raises(HarnessError, match="no ExecutionReport"):
            adapter.execute(_task())

    def test_execute_requires_a_freshly_produced_report(self, tmp_path) -> None:
        # A stale pre-existing report at the report path must not satisfy
        # the completion contract: it is removed before dispatch.
        workspace = _workspace(tmp_path)
        report_file = (
            workspace / "coordination/autobuild/RUN-001/execution-report.yaml"
        )
        report_file.parent.mkdir(parents=True)
        report_file.write_text(REPORT_YAML, encoding="utf-8")
        fake = _fake_dsh(tmp_path, exit_code=0)
        adapter = DshHarnessAdapter(
            dsh_bin=str(fake),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
        )
        with pytest.raises(HarnessError, match="no ExecutionReport"):
            adapter.execute(_task())
        assert not report_file.exists()

    def test_execute_nonzero_exit_fails(self, tmp_path) -> None:
        workspace = _workspace(tmp_path)
        fake = _fake_dsh(tmp_path, exit_code=3)
        adapter = DshHarnessAdapter(
            dsh_bin=str(fake),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
        )
        with pytest.raises(HarnessError, match="exited"):
            adapter.execute(_task())

    def test_execute_invalid_report_fails(self, tmp_path) -> None:
        workspace = _workspace(tmp_path)
        fake = _fake_dsh(
            tmp_path,
            report="not: [valid\n  yaml: payload",
            report_path="coordination/autobuild/RUN-001/execution-report.yaml",
        )
        adapter = DshHarnessAdapter(
            dsh_bin=str(fake),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
        )
        with pytest.raises(HarnessError):
            adapter.execute(_task())

    def test_execute_mismatched_identity_fails(self, tmp_path) -> None:
        workspace = _workspace(tmp_path)
        mismatch = REPORT_YAML.replace("run_id: RUN-001", "run_id: RUN-999")
        fake = _fake_dsh(
            tmp_path,
            report=mismatch,
            report_path="coordination/autobuild/RUN-001/execution-report.yaml",
        )
        adapter = DshHarnessAdapter(
            dsh_bin=str(fake),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
        )
        with pytest.raises(HarnessError, match="run_id"):
            adapter.execute(_task())

    def test_execute_unwritable_handoff_path_fails(self, tmp_path) -> None:
        workspace = _workspace(tmp_path)
        (workspace / "coordination").write_text("a file blocks the directory\n", encoding="utf-8")
        adapter = DshHarnessAdapter(
            dsh_bin=str(_fake_dsh(tmp_path)),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
        )
        with pytest.raises(HarnessError, match="handoff"):
            adapter.execute(_task())

    def test_execute_timeout_fails(self, tmp_path) -> None:
        workspace = _workspace(tmp_path)
        fake = _fake_dsh(tmp_path, name="slow-dsh")
        script = fake.read_text(encoding="utf-8")
        fake.write_text(script.replace("exit 0", "sleep 30\n exit 0"), encoding="utf-8")
        adapter = DshHarnessAdapter(
            dsh_bin=str(fake),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
            timeout_seconds=0.05,
        )
        with pytest.raises(HarnessError, match="timed out"):
            adapter.execute(_task())


# ---------------------------------------------------------------------------
# Doctor: live proof protocol + offline preflight.
# ---------------------------------------------------------------------------


class TestDshDoctor:
    def test_doctor_live_passes_with_exactly_one_status_line(self, tmp_path) -> None:
        workspace = _workspace(tmp_path)
        fake = _fake_dsh(tmp_path, stdout=STATUS_LINE)
        outcome = dsh_doctor(
            dsh_bin=str(fake),
            workspace=workspace,
            dsh_home=_dsh_home(tmp_path),
            live=True,
            timeout_seconds=30.0,
            temp_root=tmp_path / "doctor-tmp",
        )
        assert outcome.live is True
        assert outcome.passed is True
        assert outcome.error is None
        assert outcome.sandbox == "workspace-write"
        assert outcome.approval == "never"
        assert outcome.guard == "kcc-policy-gate"
        assert any("KCC_DSH_STATUS" in entry for entry in outcome.evidence)

    def test_doctor_live_fails_on_extra_status_lines(self, tmp_path) -> None:
        
        outcome = dsh_doctor(
            dsh_bin=str(_fake_dsh(tmp_path, stdout=f"{STATUS_LINE}\n{STATUS_LINE}")),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path),
            live=True,
            temp_root=tmp_path / "doctor-tmp",
        )
        assert outcome.passed is False
        assert "exactly one" in (outcome.error or "")

    def test_doctor_live_fails_on_missing_status_line(self, tmp_path) -> None:
        
        outcome = dsh_doctor(
            dsh_bin=str(_fake_dsh(tmp_path, stdout="I could not find the tool.")),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path),
            live=True,
            temp_root=tmp_path / "doctor-tmp",
        )
        assert outcome.passed is False
        assert "KCC_DSH_STATUS" in (outcome.error or "")

    def test_doctor_live_fails_when_worker_nonzero_exit(self, tmp_path) -> None:
        
        outcome = dsh_doctor(
            dsh_bin=str(_fake_dsh(tmp_path, stdout=STATUS_LINE, exit_code=9)),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path),
            live=True,
            temp_root=tmp_path / "doctor-tmp",
        )
        assert outcome.passed is False
        assert "exited" in (outcome.error or "")

    @pytest.mark.parametrize(
        "json_text",
        [
            '{"sandbox":"workspace-write","approval":"ask","guard":"kcc-policy-gate"}',
            '{"sandbox":"workspace-write","approval":"never","guard":"none"}',
            '{"sandbox":"readonly","approval":"never","guard":"kcc-policy-gate"}',
            '{"sandbox":"workspace-write","approval":"never"}',
            '{"sandbox":"workspace-write","approval":"never","guard":"kcc-policy-gate","extra":true}',
            "not json",
        ],
    )
    def test_doctor_live_fails_on_any_deviation(self, tmp_path, json_text) -> None:
        outcome = dsh_doctor(
            dsh_bin=str(_fake_dsh(tmp_path, stdout=f"KCC_DSH_STATUS: {json_text}")),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path),
            live=True,
            temp_root=tmp_path / "doctor-tmp",
        )
        assert outcome.passed is False
        assert outcome.error is not None

    def test_doctor_live_fails_on_prompt_on_stderr(self, tmp_path) -> None:
        # A human approval prompt surfacing on stderr must fail the live
        # doctor even when the status line is present: any extra output,
        # prompt or error fails, and a prompt on the side channel is the
        # exact signal the hardened gate must catch.
        from kcc_autobuild.harnesses.dsh import dsh_doctor

        outcome = dsh_doctor(
            dsh_bin=str(
                _fake_dsh(
                    tmp_path,
                    stdout=STATUS_LINE,
                    stderr="Do you approve this action? (yes/no)",
                )
            ),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path),
            live=True,
            temp_root=tmp_path / "doctor-tmp",
        )
        assert outcome.passed is False
        assert "stderr" in (outcome.error or "").lower()

    def test_doctor_live_fails_on_any_stderr_output(self, tmp_path) -> None:
        # The live doctor accepts exactly one KCC_DSH_STATUS line of
        # output: any non-empty stderr (even informational noise) fails.
        from kcc_autobuild.harnesses.dsh import dsh_doctor

        outcome = dsh_doctor(
            dsh_bin=str(
                _fake_dsh(tmp_path, stdout=STATUS_LINE, stderr="plugin boot notice")
            ),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path),
            live=True,
            temp_root=tmp_path / "doctor-tmp",
        )
        assert outcome.passed is False
        assert "stderr" in (outcome.error or "").lower()

    def test_doctor_live_fails_on_prompt_output(self, tmp_path) -> None:
        extra = STATUS_LINE + "\nDo you approve this action? (yes/no)"
        outcome = dsh_doctor(
            dsh_bin=str(_fake_dsh(tmp_path, stdout=extra)),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path),
            live=True,
            temp_root=tmp_path / "doctor-tmp",
        )
        assert outcome.passed is False
        assert "exactly one" in (outcome.error or "")

    def test_doctor_live_fails_without_installed_headless_template(
        self, tmp_path
    ) -> None:
        outcome = dsh_doctor(
            dsh_bin=str(_fake_dsh(tmp_path, stdout=STATUS_LINE)),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path, headless=False),
            live=True,
            temp_root=tmp_path / "doctor-tmp",
        )
        assert outcome.passed is False
        assert "headless" in (outcome.error or "").lower()

    def test_doctor_cleans_up_the_disposable_profile(self, tmp_path) -> None:
        temp_root = tmp_path / "doctor-tmp"
        outcome = dsh_doctor(
            dsh_bin=str(_fake_dsh(tmp_path, stdout=STATUS_LINE)),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path),
            live=True,
            temp_root=temp_root,
        )
        assert outcome.passed is True
        assert not temp_root.exists() or not any(temp_root.iterdir())

    def test_doctor_offline_report_prereqs_without_live_proof(self, tmp_path) -> None:
        
        outcome = dsh_doctor(
            dsh_bin=str(_fake_dsh(tmp_path)),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path),
            live=False,
            temp_root=tmp_path / "doctor-tmp",
        )
        assert outcome.live is False
        assert outcome.passed is True
        assert outcome.error is None
        assert outcome.sandbox is None  # prereqs only; no hardened proof
        assert outcome.approval is None
        assert outcome.guard is None

    def test_doctor_offline_fails_when_template_missing(self, tmp_path) -> None:
        
        outcome = dsh_doctor(
            dsh_bin=str(_fake_dsh(tmp_path)),
            workspace=_workspace(tmp_path),
            dsh_home=_dsh_home(tmp_path, headless=False),
            live=False,
            temp_root=tmp_path / "doctor-tmp",
        )
        assert outcome.passed is False


# ---------------------------------------------------------------------------
# CLI: harness probe dsh / harness doctor dsh.
# ---------------------------------------------------------------------------


class TestHarnessCli:
    def test_harness_probe_dsh_prints_deterministic_json(self, tmp_path) -> None:
        fake = _fake_dsh(tmp_path)
        result = runner.invoke(
            app,
            [
                "harness",
                "probe",
                "dsh",
                "--repo-root",
                str(_workspace(tmp_path)),
                "--dsh-bin",
                str(fake),
                "--dsh-home",
                str(_dsh_home(tmp_path)),
            ],
        )
        assert result.exit_code == 0, result.stderr
        payload = json.loads(result.stdout)
        assert payload["harness_id"] == "dsh"
        assert payload["detected"] is True
        assert payload["capabilities"]["fresh_workers"] is True
        assert payload["capabilities"]["approval_mode"] == "unknown"
        assert payload["capabilities"]["mutation_enforcement"] == "none"
        # Deterministic output: sorted keys.
        assert list(payload.keys()) == sorted(payload.keys())

    def test_harness_probe_rejects_unknown_harness(self, tmp_path) -> None:
        result = runner.invoke(
            app,
            ["harness", "probe", "codex", "--repo-root", str(tmp_path)],
        )
        assert result.exit_code != 0
        assert "codex" in result.stderr

    def test_harness_doctor_dsh_live(self, tmp_path) -> None:
        fake = _fake_dsh(tmp_path, stdout=STATUS_LINE)
        result = runner.invoke(
            app,
            [
                "harness",
                "doctor",
                "dsh",
                "--live",
                "--repo-root",
                str(_workspace(tmp_path)),
                "--dsh-bin",
                str(fake),
                "--dsh-home",
                str(_dsh_home(tmp_path)),
            ],
        )
        assert result.exit_code == 0, result.stderr
        payload = json.loads(result.stdout)
        assert payload["live"] is True
        assert payload["passed"] is True
        assert payload["guard"] == "kcc-policy-gate"

    def test_harness_doctor_dsh_live_failure_exits_nonzero(self, tmp_path) -> None:
        fake = _fake_dsh(tmp_path, stdout="no status line here")
        result = runner.invoke(
            app,
            [
                "harness",
                "doctor",
                "dsh",
                "--live",
                "--repo-root",
                str(_workspace(tmp_path)),
                "--dsh-bin",
                str(fake),
                "--dsh-home",
                str(_dsh_home(tmp_path)),
            ],
        )
        assert result.exit_code != 0
        payload = json.loads(result.stdout)
        assert payload["passed"] is False

    def test_harness_doctor_dsh_offline(self, tmp_path) -> None:
        fake = _fake_dsh(tmp_path)
        result = runner.invoke(
            app,
            [
                "harness",
                "doctor",
                "dsh",
                "--repo-root",
                str(_workspace(tmp_path)),
                "--dsh-bin",
                str(fake),
                "--dsh-home",
                str(_dsh_home(tmp_path)),
            ],
        )
        assert result.exit_code == 0, result.stderr
        payload = json.loads(result.stdout)
        assert payload["live"] is False
        assert payload["passed"] is True
