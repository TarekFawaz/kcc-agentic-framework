"""DeepSeek Harness (dsh) runtime probe and execution adapter (Plan 08, Task 4).

The dsh adapter is the harness-specific execution adapter of the
harness-neutral core: it feature-probes the installed DeepSeek Harness
CLI and its KCC workspace bootstrapping and reports ONLY what the probes
could prove (``never fake fresh/parallel workers or policy
enforcement`` -- plan Global Constraint):

* **Feature-based, never an exact-version gate:** the probe observes the
  dsh CLI boot, the profile boot and the workspace facts (native
  ``AGENTS.md``, generated ``.dsh/skills/*/SKILL.md`` packages); no
  version string is ever parsed or required.
* **Fresh/parallel workers are proven ONLY by an installed, bootable
  headless profile** (``$DSH_HOME/profiles/headless`` with its bundle
  banner and a passing boot probe).  Without it both capabilities stay
  false and the strategy degrades to ``LOCAL`` -- never faked.
* **``approval_mode=NEVER`` + ``mutation_enforcement=KCC_POLICY_GATE``
  are granted ONLY after a passed live doctor proof**
  (:class:`DshDoctorOutcome` with ``live=True`` and ``passed=True``).
  An offline doctor outcome, a failed doctor or raw skill files never
  grant hardened capabilities: skill generation alone is insufficient
  for Full Autopilot.
* :meth:`DshHarnessAdapter.execute` dispatches a fresh
  ``dsh --profile headless`` worker for one :class:`~kcc_autobuild.harnesses.models.HarnessTask`:
  it writes the bounded TaskHandoff pack to the project-relative
  handoff path, references the project-relative TaskHandoff/report
  paths under ``coordination/autobuild/<RUN>`` in the worker prompt and
  treats the report file as the completion contract -- a process exit 0
  without a *fresh, valid* :class:`~kcc_autobuild.bridge.ExecutionReport`
  at the report path fails.  The raw report document is normalized by
  removing harness metadata ONLY (:func:`kcc_autobuild.bridge.normalize_harness_metadata`);
  identity is bound via :meth:`~kcc_autobuild.harnesses.models.HarnessTask.validate_report`.
  The adapter never verifies lease liveness, commits, CI, tests or
  policy -- KCC alone verifies chain-of-custody evidence.
* :func:`dsh_doctor` implements the live doctor: a *disposable*
  ``kcc-autobuild`` profile under a temporary ``DSH_HOME`` (template:
  the installed headless profile; node_modules symlinked, never
  modified) invokes ``kcc_harness_status`` exactly once through one
  worker probe and accepts exactly one ``KCC_DSH_STATUS:`` JSON line
  proving sandbox ``workspace-write``, approval ``never`` and the
  expected guard ``kcc-policy-gate``; any extra, missing, prompt-like
  or erroring output fails.

Behavioral contract owned by
:file:`.KCC/runtime/tests/harnesses/test_dsh_adapter.py`.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path

import yaml
from pydantic import Field, ValidationError, field_validator, model_validator

from kcc_autobuild.bridge import ExecutionReport, normalize_harness_metadata
from kcc_autobuild.harnesses.base import HarnessAdapter
from kcc_autobuild.harnesses.models import (
    ApprovalMode,
    HarnessCapabilities,
    HarnessError,
    HarnessProbe,
    HarnessTask,
    MutationEnforcement,
)
from kcc_autobuild.models import StrictModel

DSH_HARNESS_ID = "dsh"
"""Canonical harness id of the DeepSeek Harness adapter."""

DEFAULT_DSH_PROFILE = "headless"
"""The fresh-worker profile the adapter dispatches (``dsh --profile headless``)."""

DOCTOR_DISPOSABLE_PROFILE = "kcc-autobuild"
"""Name of the disposable profile the live doctor boots."""

DOCTOR_TEMPLATE_PROFILE = "headless"
"""Installed profile the doctor templates the disposable one from."""

SANDBOX_WORKSPACE_WRITE = "workspace-write"
"""Expected sandbox value proven by a live doctor status line."""

APPROVAL_NEVER = "never"
"""Expected approval-mode value proven by a live doctor status line."""

GUARD_KCC_POLICY_GATE = "kcc-policy-gate"
"""Expected mutation guard value proven by a live doctor status line."""

KCC_DSH_STATUS_PREFIX = "KCC_DSH_STATUS:"
"""Prefix of the single status line the live doctor accepts."""

DOCTOR_PROBE_PROMPT = (
    "KCC harness doctor probe. Call the kcc_harness_status tool exactly "
    "once. Then print your final answer as exactly one line, nothing else: "
    f"{KCC_DSH_STATUS_PREFIX} <the JSON object the tool returned>."
)
"""The one-shot probe prompt of the live doctor.

The disposable worker must invoke ``kcc_harness_status`` exactly once and
answer with exactly one status line; any prompt, error or extra output
fails the doctor.
"""

_PROBE_FILE_PREFIX = ".kcc-dsh-probe-"


class DshDoctorOutcome(StrictModel):
    """Outcome of one dsh doctor run (live proof or offline preflight).

    A *live* doctor (``live=True``) boots a disposable
    ``kcc-autobuild`` profile and validates the single
    ``KCC_DSH_STATUS:`` JSON line: ``passed`` requires the exact proof
    values (sandbox ``workspace-write``, approval ``never``, guard
    ``kcc-policy-gate``) and no error.  An *offline* doctor
    (``live=False``) reports read-only prerequisites only and can pass
    without any status values -- but an offline outcome is never a proof
    and never grants hardened capabilities.
    """

    harness_id: str = DSH_HARNESS_ID
    live: bool
    profile: str = DOCTOR_DISPOSABLE_PROFILE
    passed: bool
    sandbox: str | None = None
    approval: str | None = None
    guard: str | None = None
    probed_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    evidence: list[str] = Field(default_factory=list)
    error: str | None = None

    @field_validator("profile")
    @classmethod
    def _profile_nonblank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("profile must not be empty")
        return value

    @field_validator("probed_at")
    @classmethod
    def _probed_at_must_be_aware_utc(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("probed_at must be timezone-aware")
        return value.astimezone(timezone.utc)

    @field_validator("evidence")
    @classmethod
    def _evidence_entries_nonblank(cls, value: list[str]) -> list[str]:
        for entry in value:
            if not entry.strip():
                raise ValueError("evidence entries must not be blank")
        return value

    @field_validator("error")
    @classmethod
    def _error_nonblank_when_present(cls, value: str | None) -> str | None:
        if value is not None and not value.strip():
            raise ValueError("error must not be blank when set")
        return value

    @model_validator(mode="after")
    def _passed_requires_the_live_proof(self) -> DshDoctorOutcome:
        if self.passed:
            if self.error is not None:
                raise ValueError("a passed doctor must not carry an error")
            if self.live and (
                self.sandbox != SANDBOX_WORKSPACE_WRITE
                or self.approval != APPROVAL_NEVER
                or self.guard != GUARD_KCC_POLICY_GATE
            ):
                raise ValueError(
                    "a passed live doctor must prove sandbox workspace-write, "
                    "approval never and the kcc-policy-gate guard"
                )
        return self


def build_worker_prompt(task: HarnessTask) -> str:
    """The prompt of the fresh headless worker for one bounded task.

    The prompt references the project-relative TaskHandoff/report paths
    confined under ``coordination/autobuild/<RUN>`` (as required by the
    plan) and makes the completion contract explicit: the report file is
    the only completion signal, so exiting 0 without a valid
    :class:`ExecutionReport` fails the attempt.
    """
    handoff = task.handoff
    return (
        f"You are the KCC autobuild execution worker for run "
        f"{handoff.run_id}, task {handoff.task_id}, attempt "
        f"{handoff.lease.generation}, workspace {task.workspace_id}. "
        f"Read the bounded task handoff pack at the project-relative path "
        f"'{task.handoff_path}' (relative to the repository root) and "
        f"execute exactly its scoped task. When the task is complete, "
        f"write your terminal ExecutionReport (machine schema "
        f"kcc_autobuild.bridge.ExecutionReport) to the project-relative "
        f"path '{task.report_path}' and stop. The report file is the "
        f"completion contract: exiting 0 without a valid report fails the "
        f"attempt."
    )


class DshHarnessAdapter(HarnessAdapter):
    """Feature-probing execution adapter for the DeepSeek Harness CLI.

    ``dsh_bin`` names the CLI executable (resolved through ``PATH`` when
    relative), ``workspace`` is the project root the adapter observes and
    dispatches in, ``dsh_home`` is the DSH home whose installed headless
    profile proves fresh workers (default: ``$DSH_HOME`` or ``~/.dsh``),
    and ``doctor`` is the optional :class:`DshDoctorOutcome` that gates
    the hardened capabilities.  All probes are feature probes -- no
    exact-version gate anywhere.
    """

    harness_id: str = DSH_HARNESS_ID

    def __init__(
        self,
        *,
        dsh_bin: str = "dsh",
        workspace: str | Path | None = None,
        dsh_home: str | Path | None = None,
        profile: str = DEFAULT_DSH_PROFILE,
        timeout_seconds: float = 30.0,
        doctor: DshDoctorOutcome | None = None,
    ) -> None:
        if not dsh_bin.strip():
            raise ValueError("dsh_bin must be a non-blank command name")
        if not profile.strip():
            raise ValueError("profile must be a non-blank profile name")
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        self.dsh_bin = dsh_bin
        self.workspace = Path(workspace) if workspace is not None else None
        self.dsh_home = Path(dsh_home) if dsh_home is not None else None
        self.profile = profile
        self.timeout_seconds = timeout_seconds
        self.doctor = doctor

    @property
    def _workspace(self) -> Path:
        return self.workspace if self.workspace is not None else Path.cwd()

    @property
    def _dsh_home(self) -> Path:
        if self.dsh_home is not None:
            return self.dsh_home
        configured = os.environ.get("DSH_HOME")
        if configured:
            return Path(configured)
        return Path.home() / ".dsh"

    def probe(self) -> HarnessProbe:
        """Feature-probe the dsh harness; report only what was proven."""
        probed_at = datetime.now(timezone.utc)
        capabilities = HarnessCapabilities.unknown()
        evidence: list[str] = []
        failures: list[str] = []
        workspace = self._workspace
        self._probe_native_agents_md(workspace, capabilities, evidence, failures)
        skills = self._probe_generated_skills(workspace, evidence, failures)
        self._probe_dsh_cli(capabilities, evidence, failures)
        self._probe_headless_profile(capabilities, evidence, failures)
        self._probe_workspace_write(workspace, capabilities, evidence, failures)
        self._apply_doctor_proof(capabilities, evidence)
        capabilities.confidence = round(
            (int(capabilities.read) + int(capabilities.write) + int(capabilities.exec))
            / 3,
            2,
        )
        detected = (
            capabilities.read
            and capabilities.write
            and capabilities.exec
            and skills
        )
        return HarnessProbe(
            harness_id=self.harness_id,
            detected=detected,
            capabilities=capabilities,
            probed_at=probed_at,
            evidence=evidence,
            error="; ".join(failures) if failures else None,
        )

    def execute(self, task: HarnessTask) -> ExecutionReport:
        """Dispatch one fresh headless worker and return its report.

        Writes the pack, dispatches ``dsh --profile headless`` with the
        project-relative handoff/report paths, then treats the report
        file as the completion contract: exit 0 without a fresh, valid,
        identity-bound :class:`ExecutionReport` is a
        :class:`HarnessError`.  The raw report document is normalized by
        dropping harness metadata only; the adapter verifies no lease
        liveness, commits, CI, tests or policy (KCC owns chain of
        custody).
        """
        workspace = self._workspace
        handoff_file = workspace / task.handoff_path
        report_file = workspace / task.report_path
        try:
            handoff_file.parent.mkdir(parents=True, exist_ok=True)
            report_file.parent.mkdir(parents=True, exist_ok=True)
            handoff_file.write_bytes(task.handoff.pack())
        except OSError as exc:
            raise HarnessError(
                f"cannot write task handoff pack to {task.handoff_path}: {exc}"
            ) from exc
        # The completion contract is a report produced by THIS attempt:
        # a stale pre-existing report must never satisfy it.
        try:
            report_file.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            raise HarnessError(
                f"cannot reset report path {task.report_path}: {exc}"
            ) from exc
        prompt = build_worker_prompt(task)
        try:
            process = subprocess.run(
                [self.dsh_bin, "--profile", self.profile, prompt],
                cwd=workspace,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
                check=False,
                env={**os.environ, "DSH_HOME": str(self._dsh_home)},
            )
        except subprocess.TimeoutExpired as exc:
            raise HarnessError(
                f"dsh worker timed out after {self.timeout_seconds}s"
            ) from exc
        except OSError as exc:
            raise HarnessError(
                f"cannot launch dsh worker {self.dsh_bin!r}: {exc}"
            ) from exc
        if process.returncode != 0:
            detail = process.stderr.strip() or process.stdout.strip()
            raise HarnessError(
                f"dsh worker exited {process.returncode}"
                + (f": {detail[:400]}" if detail else "")
            )
        if not report_file.is_file():
            raise HarnessError(
                f"dsh worker exited 0 but produced no ExecutionReport at "
                f"{task.report_path} (the report file is the completion contract)"
            )
        try:
            raw = yaml.safe_load(report_file.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError) as exc:
            raise HarnessError(
                f"ExecutionReport at {task.report_path} is unreadable: {exc}"
            ) from exc
        if not isinstance(raw, dict):
            raise HarnessError(
                f"ExecutionReport at {task.report_path} must be a mapping"
            )
        try:
            normalized = normalize_harness_metadata(raw)
            report = ExecutionReport.model_validate(normalized)
        except (TypeError, ValueError, ValidationError) as exc:
            raise HarnessError(
                f"ExecutionReport at {task.report_path} is invalid"
            ) from exc
        task.validate_report(report)
        return report

    def _probe_native_agents_md(
        self,
        workspace: Path,
        capabilities: HarnessCapabilities,
        evidence: list[str],
        failures: list[str],
    ) -> None:
        """Read check: the native AGENTS.md project entrypoint exists."""
        agents_md = workspace / "AGENTS.md"
        try:
            with agents_md.open("r", encoding="utf-8") as handle:
                header = handle.read(256)
        except OSError as exc:
            failures.append(f"native AGENTS.md probe failed: {exc}")
            return
        capabilities.read = True
        evidence.append(
            f"native AGENTS.md proven: {agents_md} "
            f"({len(header)} bytes inspected)"
        )

    def _probe_generated_skills(
        self,
        workspace: Path,
        evidence: list[str],
        failures: list[str],
    ) -> bool:
        """Generated-skill check: .dsh/skills/<name>/SKILL.md packages exist."""
        skills_root = workspace / ".dsh" / "skills"
        packages: list[Path] = []
        try:
            entries = list(skills_root.iterdir())
        except OSError as exc:
            failures.append(f"generated skills probe failed: {exc}")
            return False
        for entry in entries:
            skill_file = entry / "SKILL.md"
            if entry.is_dir() and skill_file.is_file():
                packages.append(skill_file)
        if not packages:
            failures.append(
                "no generated dsh skills found under .dsh/skills/<name>/SKILL.md"
            )
            return False
        evidence.append(
            f"generated skills proven: {len(packages)} SKILL.md packages "
            f"under {skills_root}"
        )
        return True

    def _probe_dsh_cli(
        self,
        capabilities: HarnessCapabilities,
        evidence: list[str],
        failures: list[str],
    ) -> None:
        """Exec check: the dsh CLI boots (feature probe, never version)."""
        try:
            process = subprocess.run(
                [self.dsh_bin, "--help"],
                cwd=self._workspace,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
                check=False,
                env={**os.environ, "DSH_HOME": str(self._dsh_home)},
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            failures.append(f"dsh CLI feature probe failed: {exc}")
            return
        if process.returncode == 0:
            capabilities.exec = True
            evidence.append(
                f"dsh CLI proven: {self.dsh_bin} --help exited 0 "
                "(feature probe, no version gate)"
            )
        else:
            failures.append(f"dsh CLI feature probe exited {process.returncode}")

    def _probe_headless_profile(
        self,
        capabilities: HarnessCapabilities,
        evidence: list[str],
        failures: list[str],
    ) -> None:
        """Fresh/parallel workers are proven ONLY by an installed headless
        profile whose bundle boot probe passes (never faked)."""
        profile_dir = self._dsh_home / "profiles" / self.profile
        package_json = profile_dir / "package.json"
        if not profile_dir.is_dir() or not package_json.is_file():
            failures.append(
                f"fresh worker capability not proven: no installed "
                f"'{self.profile}' profile under {self._dsh_home / 'profiles'}"
            )
            return
        evidence.append(
            f"installed headless profile present: {profile_dir}"
        )
        try:
            process = subprocess.run(
                [self.dsh_bin, "--profile", self.profile, "--help"],
                cwd=self._workspace,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
                check=False,
                env={**os.environ, "DSH_HOME": str(self._dsh_home)},
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            failures.append(
                f"headless profile boot probe failed: {exc}"
            )
            return
        if process.returncode != 0:
            failures.append(
                f"headless profile boot probe exited {process.returncode} "
                "(installed profile does not boot; fresh workers unproven)"
            )
            return
        capabilities.fresh_workers = True
        capabilities.parallel_workers = True
        evidence.append(
            f"fresh/parallel worker capability proven: installed "
            f"'{self.profile}' profile boot probe exited 0"
        )

    def _probe_workspace_write(
        self,
        workspace: Path,
        capabilities: HarnessCapabilities,
        evidence: list[str],
        failures: list[str],
    ) -> None:
        """Write check: a temporary probe file can be created and removed."""
        probe_path = workspace / (
            f"{_PROBE_FILE_PREFIX}{os.getpid()}-{uuid.uuid4().hex[:8]}"
        )
        try:
            with probe_path.open("w", encoding="utf-8") as handle:
                handle.write("kcc dsh probe\n")
            probe_path.unlink()
        except OSError as exc:
            failures.append(f"workspace write check failed: {exc}")
            try:
                probe_path.unlink(missing_ok=True)
            except OSError:
                pass
            return
        capabilities.write = True
        evidence.append(
            "workspace write proven (temporary probe file created and removed)"
        )

    def _apply_doctor_proof(
        self,
        capabilities: HarnessCapabilities,
        evidence: list[str],
    ) -> None:
        """Grant hardened capabilities only for a passed LIVE doctor proof."""
        doctor = self.doctor
        if (
            doctor is not None
            and doctor.harness_id == self.harness_id
            and doctor.live
            and doctor.passed
        ):
            capabilities.approval_mode = ApprovalMode.NEVER
            capabilities.mutation_enforcement = MutationEnforcement.KCC_POLICY_GATE
            evidence.append(
                "live doctor proof: sandbox workspace-write, approval never, "
                "kcc-policy-gate guard"
            )
        elif doctor is not None:
            evidence.append(
                "hardened capabilities not granted: no passed live doctor proof"
            )


def dsh_doctor(
    *,
    live: bool,
    dsh_bin: str = "dsh",
    workspace: str | Path | None = None,
    dsh_home: str | Path | None = None,
    profile: str = DOCTOR_DISPOSABLE_PROFILE,
    template: str = DOCTOR_TEMPLATE_PROFILE,
    timeout_seconds: float = 600.0,
    boot_timeout_seconds: float = 120.0,
    temp_root: str | Path | None = None,
) -> DshDoctorOutcome:
    """Run the dsh doctor (live proof or offline preflight).

    The live doctor builds a *disposable* ``kcc-autobuild`` profile (a
    temporary ``DSH_HOME`` templated from the installed ``headless``
    profile -- config files copied, ``node_modules`` symlinked, the real
    profiles never modified), dispatches one worker probe that invokes
    ``kcc_harness_status`` exactly once, and accepts exactly one
    ``KCC_DSH_STATUS:`` JSON line proving sandbox ``workspace-write``,
    approval ``never`` and the ``kcc-policy-gate`` guard.  Any extra,
    missing, prompt-like or erroring output fails the doctor -- including
    any non-empty stderr, so a human prompt on the side channel can never
    slip through as a passed proof.  The
    offline doctor (``live=False``) checks the same prerequisites and
    boot probe only: it never invokes the tool and its outcome is not a
    proof.
    """
    probed_at = datetime.now(timezone.utc)
    evidence: list[str] = []
    if not dsh_bin.strip():
        raise ValueError("dsh_bin must be a non-blank command name")
    if timeout_seconds <= 0 or boot_timeout_seconds <= 0:
        raise ValueError("timeouts must be positive")
    cwd = Path(workspace) if workspace is not None else Path.cwd()
    home = (
        Path(dsh_home)
        if dsh_home is not None
        else Path(os.environ.get("DSH_HOME") or (Path.home() / ".dsh"))
    )
    template_dir = home / "profiles" / template
    package_json = template_dir / "package.json"
    if not template_dir.is_dir() or not package_json.is_file():
        return DshDoctorOutcome(
            live=live,
            profile=profile,
            passed=False,
            probed_at=probed_at,
            evidence=evidence,
            error=(
                f"no installed '{template}' profile to template the "
                f"disposable '{profile}' profile from (looked in "
                f"{home / 'profiles'})"
            ),
        )
    evidence.append(f"installed '{template}' profile template: {template_dir}")
    template_node_modules = template_dir / "node_modules"
    if not template_node_modules.is_dir():
        return DshDoctorOutcome(
            live=live,
            profile=profile,
            passed=False,
            probed_at=probed_at,
            evidence=evidence,
            error=f"profile template is incomplete: {template_node_modules} missing",
        )
    cli_probe = _run(
        [dsh_bin, "--help"],
        cwd=cwd,
        env={**os.environ, "DSH_HOME": str(home)},
        timeout=boot_timeout_seconds,
    )
    if cli_probe.error is not None:
        return DshDoctorOutcome(
            live=live,
            profile=profile,
            passed=False,
            probed_at=probed_at,
            evidence=evidence,
            error=f"dsh CLI feature probe failed: {cli_probe.error}",
        )
    if cli_probe.returncode != 0:
        return DshDoctorOutcome(
            live=live,
            profile=profile,
            passed=False,
            probed_at=probed_at,
            evidence=evidence,
            error=f"dsh CLI feature probe exited {cli_probe.returncode}",
        )
    evidence.append(f"dsh CLI feature probe proven: {dsh_bin} --help exited 0")

    temp_root_path = Path(temp_root) if temp_root is not None else None
    if temp_root_path is not None:
        temp_root_path.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="dsh-doctor-", dir=temp_root_path
    ) as temp_dir:
        disposable_home = Path(temp_dir) / "dsh-home"
        disposable_dir = disposable_home / "profiles" / profile
        try:
            _template_disposable_profile(template_dir, disposable_dir)
        except OSError as exc:
            return DshDoctorOutcome(
                live=live,
                profile=profile,
                passed=False,
                probed_at=probed_at,
                evidence=evidence,
                error=f"cannot build disposable profile: {exc}",
            )
        evidence.append(
            f"disposable '{profile}' profile built: {disposable_dir}"
            " (temporary DSH_HOME, template files copied, node_modules symlinked)"
        )
        disposable_env = {**os.environ, "DSH_HOME": str(disposable_home)}
        if not live:
            boot = _run(
                [dsh_bin, "--profile", profile, "--help"],
                cwd=cwd,
                env=disposable_env,
                timeout=boot_timeout_seconds,
            )
            if boot.error is not None:
                return DshDoctorOutcome(
                    live=False,
                    profile=profile,
                    passed=False,
                    probed_at=probed_at,
                    evidence=evidence,
                    error=f"disposable profile boot failed: {boot.error}",
                )
            if boot.returncode != 0:
                return DshDoctorOutcome(
                    live=False,
                    profile=profile,
                    passed=False,
                    probed_at=probed_at,
                    evidence=evidence,
                    error=f"disposable profile boot exited {boot.returncode}",
                )
            evidence.append(
                f"disposable '{profile}' profile boots (preflight complete); "
                "no live proof run"
            )
            return DshDoctorOutcome(
                live=False,
                profile=profile,
                passed=True,
                probed_at=probed_at,
                evidence=evidence,
            )
        worker = _run(
            [dsh_bin, "--profile", profile, DOCTOR_PROBE_PROMPT],
            cwd=cwd,
            env=disposable_env,
            timeout=timeout_seconds,
        )
        if worker.error is not None:
            return DshDoctorOutcome(
                live=True,
                profile=profile,
                passed=False,
                probed_at=probed_at,
                evidence=evidence,
                error=f"doctor worker probe failed: {worker.error}",
            )
        if worker.returncode != 0:
            detail = worker.stderr.strip() or worker.stdout.strip()
            return DshDoctorOutcome(
                live=True,
                profile=profile,
                passed=False,
                probed_at=probed_at,
                evidence=evidence,
                error=f"doctor worker exited {worker.returncode}"
                + (f": {detail[:400]}" if detail else ""),
            )
        if worker.stderr.strip():
            # The live doctor accepts exactly one KCC_DSH_STATUS line:
            # any extra output -- including a human prompt or noise on
            # the stderr side channel -- fails the doctor (fail closed).
            evidence.append(f"doctor worker stderr: {worker.stderr.strip()[:400]}")
            return DshDoctorOutcome(
                live=True,
                profile=profile,
                passed=False,
                probed_at=probed_at,
                evidence=evidence,
                error=(
                    "doctor worker wrote to stderr (any extra output fails "
                    f"the live doctor): {worker.stderr.strip()[:400]}"
                ),
            )
        sandbox, approval, guard, validation_error = _validate_status_line(
            worker.stdout
        )
        evidence.append(
            f"doctor worker probe exited 0; stdout: "
            f"{worker.stdout.strip()[:400] if worker.stdout.strip() else '(empty)'}"
        )
        if validation_error is not None:
            return DshDoctorOutcome(
                live=True,
                profile=profile,
                passed=False,
                probed_at=probed_at,
                evidence=evidence,
                error=validation_error,
            )
        return DshDoctorOutcome(
            live=True,
            profile=profile,
            passed=True,
            sandbox=sandbox,
            approval=approval,
            guard=guard,
            probed_at=probed_at,
            evidence=evidence,
        )


def _template_disposable_profile(template_dir: Path, profile_dir: Path) -> None:
    """Copy a profile's config files and symlink its node_modules.

    The disposable profile never mutates the installed template: config
    files are copied and the dependency tree is symlinked read-through.
    """
    profile_dir.mkdir(parents=True)
    for name in (
        "package.json",
        "cordis.yml",
        "cordis.patch.yml",
        "pnpm-workspace.yaml",
        "pnpm-lock.yaml",
    ):
        source = template_dir / name
        if source.is_file():
            shutil.copy2(source, profile_dir / name)
    (profile_dir / "node_modules").symlink_to(
        template_dir / "node_modules", target_is_directory=True
    )


def _validate_status_line(
    stdout: str,
) -> tuple[str | None, str | None, str | None, str | None]:
    """Validate the single ``KCC_DSH_STATUS:`` line of the live doctor.

    Returns ``(sandbox, approval, guard, error)`` with the proof values
    on success and an error description on any extra, missing,
    prompt-like or malformed output.
    """
    lines = [line for line in stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        return (
            None,
            None,
            None,
            f"expected exactly one non-empty stdout line, got {len(lines)} "
            "(any extra output fails the live doctor)",
        )
    line = lines[0].strip()
    if not line.startswith(KCC_DSH_STATUS_PREFIX):
        return (
            None,
            None,
            None,
            f"worker output does not contain a {KCC_DSH_STATUS_PREFIX} line",
        )
    payload = line[len(KCC_DSH_STATUS_PREFIX):].strip()
    try:
        data = json.loads(payload)
    except json.JSONDecodeError as exc:
        return (
            None,
            None,
            None,
            f"{KCC_DSH_STATUS_PREFIX} payload is not valid JSON: {exc}",
        )
    if not isinstance(data, dict):
        return (
            None,
            None,
            None,
            f"{KCC_DSH_STATUS_PREFIX} payload must be a JSON object",
        )
    expected_keys = {"sandbox", "approval", "guard"}
    if set(data.keys()) != expected_keys:
        return (
            None,
            None,
            None,
            f"{KCC_DSH_STATUS_PREFIX} payload must carry exactly "
            f"{sorted(expected_keys)}, got {sorted(data.keys())}",
        )
    values = (data.get("sandbox"), data.get("approval"), data.get("guard"))
    expected = (SANDBOX_WORKSPACE_WRITE, APPROVAL_NEVER, GUARD_KCC_POLICY_GATE)
    if values != expected:
        return (
            None,
            None,
            None,
            f"{KCC_DSH_STATUS_PREFIX} payload does not prove the expected "
            f"hardened status: {json.dumps(data, sort_keys=True)}",
        )
    return values + (None,)


class _RunResult:
    """Outcome of one doctor subprocess invocation (fail closed on launch)."""

    def __init__(
        self,
        *,
        returncode: int,
        stdout: str,
        stderr: str,
        error: str | None = None,
    ) -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.error = error


def _run(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: float,
) -> _RunResult:
    """Run a doctor subprocess, converting launch/timeout failures to errors."""
    try:
        process = subprocess.run(
            command,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env=env,
        )
    except subprocess.TimeoutExpired as exc:
        return _RunResult(
            returncode=-1,
            stdout="",
            stderr="",
            error=f"command timed out after {timeout}s",
        )
    except OSError as exc:
        return _RunResult(
            returncode=-1,
            stdout="",
            stderr="",
            error=f"cannot launch command: {type(exc).__name__}: {exc}",
        )
    return _RunResult(
        returncode=process.returncode,
        stdout=process.stdout,
        stderr=process.stderr,
    )
