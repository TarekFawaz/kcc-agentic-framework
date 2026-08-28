"""Harness capability contract models (Plan 08, Task 1).

Behavioral contract owned by
:file:`.KCC/runtime/tests/harnesses/test_models.py` (see the KCC x
Superpowers Hybrid Framework Plan 08, Task 1: "Harness Capability
Contract", in ``.superpowers/bootstrap/plans/2026-08-27-08-``
``harness-capability-deepseek-adapter.task-contracts.md``).

The core is harness-neutral and the adapter reports ONLY proven
capabilities (plan Global Constraint: "the core never claims 'works on
every CLI'; each harness adapter reports ONLY proven capabilities").

* :class:`ApprovalMode`, :class:`MutationEnforcement` and
  :class:`ExecutionStrategy` are canonical, lowercase string enums.
* :class:`HarnessCapabilities` is *unknown* by default -- every
  capability false, confidence 0, approval ``unknown``, mutation
  enforcement ``none`` -- and :meth:`HarnessCapabilities.unknown`
  returns exactly that.  ``supports`` answers only what was proven and
  rejects unknown capability names (fail closed, never guess).
* :meth:`HarnessCapabilities.best_strategy` implements the capability
  ladder ``local -> serial-worker -> parallel-workers -> full-autopilot``:
  Full Autopilot requires read/write/exec + ``KCC_POLICY_GATE`` +
  approval ``none``/``never`` (and proven fresh + parallel workers);
  **unproven parallel degrades to serial** -- a parallel or
  full-autopilot claim is never faked.
* :class:`HarnessProbe` records a single probe outcome (detected,
  proven capabilities, evidence, error) with a timezone-aware
  timestamp.
* :class:`HarnessTask` consumes the bounded :class:`~kcc_autobuild.bridge.TaskHandoff`
  pack together with the project-relative handoff/report paths confined
  under ``coordination/autobuild/<RUN>``; :meth:`HarnessTask.validate_report`
  binds the returned :class:`~kcc_autobuild.bridge.ExecutionReport` back
  to the handoff identity -- the report file is the completion contract
  and a mismatched report raises :class:`HarnessError` (fail closed).
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from enum import Enum

from pydantic import Field, ValidationInfo, field_validator, model_validator

from kcc_autobuild.bridge import ExecutionReport, TaskHandoff
from kcc_autobuild.models import StrictModel

COORDINATION_ROOT = "coordination/autobuild"
"""Canonical project-relative root of per-run dispatch artifacts.

Plan 08, Task 4 dispatches workers against project-relative
TaskHandoff/ExecutionReport paths under ``coordination/autobuild/<RUN>``;
a :class:`HarnessTask` refuses to reference anything outside it.
"""


class ApprovalMode(str, Enum):
    """How a harness asks the human for approval (canonical, lowercase).

    ``NONE`` means no approval requested; ``ASK`` means each governed
    action asks; ``NEVER`` means never ask; ``UNKNOWN`` is the default
    until an adapter probed the harness.  Full Autopilot requires
    ``NONE`` or ``NEVER`` (plan Global Constraint: "approval none/never").
    """

    NONE = "none"
    ASK = "ask"
    NEVER = "never"
    UNKNOWN = "unknown"


class MutationEnforcement(str, Enum):
    """How a harness enforces mutation safety (canonical, lowercase).

    ``NONE`` -- no enforcement, ``PROMPT_ONLY`` -- every mutation asks
    the human, ``KCC_POLICY_GATE`` -- governed actions are executed
    through the exact KCC policy wrappers.  Full Autopilot requires
    ``KCC_POLICY_GATE``; skill generation alone is never sufficient.
    """

    NONE = "none"
    PROMPT_ONLY = "prompt-only"
    KCC_POLICY_GATE = "kcc-policy-gate"


class ExecutionStrategy(str, Enum):
    """Proven execution strategy of a harness (canonical, lowercase).

    ``LOCAL`` -- the harness can only run in-process, ``SERIAL_WORKER``
    -- fresh workers run one at a time, ``PARALLEL_WORKERS`` -- fresh
    workers run in parallel, ``FULL_AUTOPILOT`` -- fresh autonomous
    workers are fully enforced by the KCC policy gate with no human ask.
    Unproven parallel degrades to serial (never claimed).
    """

    LOCAL = "local"
    SERIAL_WORKER = "serial-worker"
    PARALLEL_WORKERS = "parallel-workers"
    FULL_AUTOPILOT = "full-autopilot"


class HarnessCapability(str, Enum):
    """One capability name a harness adapter may prove.

    ``supports`` accepts either the enum member or its value string;
    names outside this set are rejected, never guessed.
    """

    READ = "read"
    WRITE = "write"
    EXEC = "exec"
    FRESH_WORKERS = "fresh-workers"
    PARALLEL_WORKERS = "parallel-workers"
    SUBAGENTS = "subagents"
    KCC_POLICY_GATE = "kcc-policy-gate"
    APPROVAL_NONE = "approval-none"
    APPROVAL_NEVER = "approval-never"
    APPROVAL_PASSIVE = "approval-passive"  # none or never: no human ask


class HarnessError(ValueError):
    """Raised when a harness operation cannot satisfy the contract.

    Used for fail-closed outcomes -- e.g. an :class:`ExecutionReport`
    that does not bind to the :class:`HarnessTask` identity is rejected
    with ``HarnessError`` instead of being trusted.
    """


class HarnessCapabilities(StrictModel):
    """Proven capabilities of one harness (unknown by default).

    Every field defaults to the *unknown* state -- false/0 -- so a
    probe failure yields a capability set that claims nothing.  The
    adapter must prove a capability before setting it: no fake fresh
    workers, no fake parallel workers, no fake policy enforcement
    (plan Global Constraint "harness-neutral core, adapter-specific
    capability levels").
    """

    read: bool = False
    write: bool = False
    exec: bool = False
    fresh_workers: bool = False
    parallel_workers: bool = False
    subagents: bool = False
    approval_mode: ApprovalMode = ApprovalMode.UNKNOWN
    mutation_enforcement: MutationEnforcement = MutationEnforcement.NONE
    confidence: float = Field(default=0.0, ge=0.0, le=1.0)

    @classmethod
    def unknown(cls) -> HarnessCapabilities:
        """The unknown capability set: every capability false, score 0."""
        return cls()

    def supports(self, *capabilities: HarnessCapability | str) -> bool:
        """True iff every named capability is proven.

        Names may be :class:`HarnessCapability` members or their value
        strings.  Every name is validated first and an unknown name
        raises :class:`ValueError` (fail closed): a capability that does
        not exist must never be silently reported as unsupported/passed,
        regardless of the other names.
        """
        names: list[str] = []
        for capability in capabilities:
            if isinstance(capability, HarnessCapability):
                names.append(capability.value)
            elif isinstance(capability, str):
                try:
                    names.append(HarnessCapability(capability).value)
                except ValueError:
                    raise ValueError(
                        f"unknown harness capability {capability!r}"
                    ) from None
            else:
                raise TypeError(
                    "capabilities must be HarnessCapability members or "
                    f"their value strings, got {type(capability).__name__}"
                )
        return all(self._supports_one(name) for name in names)

    def _supports_one(self, name: str) -> bool:
        if name == HarnessCapability.READ.value:
            return self.read
        if name == HarnessCapability.WRITE.value:
            return self.write
        if name == HarnessCapability.EXEC.value:
            return self.exec
        if name == HarnessCapability.FRESH_WORKERS.value:
            return self.fresh_workers
        if name == HarnessCapability.PARALLEL_WORKERS.value:
            return self.parallel_workers
        if name == HarnessCapability.SUBAGENTS.value:
            return self.subagents
        if name == HarnessCapability.KCC_POLICY_GATE.value:
            return self.mutation_enforcement is MutationEnforcement.KCC_POLICY_GATE
        if name == HarnessCapability.APPROVAL_NONE.value:
            return self.approval_mode is ApprovalMode.NONE
        if name == HarnessCapability.APPROVAL_NEVER.value:
            return self.approval_mode is ApprovalMode.NEVER
        if name == HarnessCapability.APPROVAL_PASSIVE.value:
            return self.approval_mode in (ApprovalMode.NONE, ApprovalMode.NEVER)
        raise ValueError(f"unknown harness capability {name!r}")

    @property
    def full_autopilot_authorized(self) -> bool:
        """Full Autopilot law: read/write/exec + KCC_POLICY_GATE +
        approval none/never, with fresh and parallel workers proven."""
        return (
            self.read
            and self.write
            and self.exec
            and self.fresh_workers
            and self.parallel_workers
            and self.mutation_enforcement is MutationEnforcement.KCC_POLICY_GATE
            and self.approval_mode in (ApprovalMode.NONE, ApprovalMode.NEVER)
        )

    def best_strategy(self) -> ExecutionStrategy:
        """The strongest strategy these proven capabilities support.

        Ladder: local -> serial-worker (fresh worker proven) ->
        parallel-workers (fresh + parallel proven) -> full-autopilot
        (fresh + parallel + read/write/exec + KCC_POLICY_GATE +
        approval none/never).  Unproven parallel degrades to serial and
        is never faked.
        """
        if self.full_autopilot_authorized:
            return ExecutionStrategy.FULL_AUTOPILOT
        if self.parallel_workers and self.fresh_workers:
            return ExecutionStrategy.PARALLEL_WORKERS
        if self.fresh_workers:
            return ExecutionStrategy.SERIAL_WORKER
        return ExecutionStrategy.LOCAL


class HarnessProbe(StrictModel):
    """Outcome of one feature probe of one harness adapter.

    ``detected`` is the probe verdict; ``capabilities`` are only the
    capabilities the probe could prove (unknown/false/0 by default);
    ``evidence`` holds the probe observations (feature checks -- never
    an exact-version gate) and ``error`` the failure reason when the
    probe failed.
    """

    harness_id: str
    detected: bool = False
    capabilities: HarnessCapabilities = Field(default_factory=HarnessCapabilities.unknown)
    probed_at: datetime
    evidence: list[str] = Field(default_factory=list)
    error: str | None = None

    @field_validator("harness_id")
    @classmethod
    def _harness_id_nonblank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("harness_id must not be empty")
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


def _project_relative(value: str, name: str) -> None:
    """Reject absolute / sibling / traversal path forms (fail closed)."""
    if not value or value != value.strip():
        raise ValueError(f"{name} must be a non-blank project-relative path")
    if "\\" in value or value.startswith("/") or re.match(r"^[A-Za-z]:[\\/]", value):
        raise ValueError(f"{name} must be a project-relative path")
    segments = value.split("/")
    if any(segment in ("", ".", "..") for segment in segments):
        raise ValueError(f"{name} must be a project-relative path")


class HarnessTask(StrictModel):
    """One unit of harness work: the bounded handoff + its artifacts.

    Consumes the :class:`~kcc_autobuild.bridge.TaskHandoff` pack (the
    KCC -> execution-plane contract) and names the project-relative
    TaskHandoff/ExecutionReport paths the fresh worker writes under
    ``coordination/autobuild/<RUN>`` (Plan 08, Task 4).  The
    report file is the completion contract:
    :meth:`validate_report` binds the returned
    :class:`~kcc_autobuild.bridge.ExecutionReport` back to this task's
    identity (run_id, task_id, attempt == lease generation, lease_id,
    workspace_id) and raises :class:`HarnessError` on any mismatch.
    """

    handoff: TaskHandoff
    workspace_id: str
    handoff_path: str
    report_path: str

    @field_validator("workspace_id")
    @classmethod
    def _workspace_id_nonblank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("workspace_id must not be empty")
        return value

    @field_validator("handoff_path", "report_path")
    @classmethod
    def _paths_project_relative(cls, value: str, info: ValidationInfo) -> str:
        _project_relative(value, info.field_name)
        return value

    @model_validator(mode="after")
    def _paths_confined_to_run_dir(self) -> HarnessTask:
        prefix = f"{COORDINATION_ROOT}/{self.handoff.run_id}/"
        for name in ("handoff_path", "report_path"):
            value = getattr(self, name)
            if not value.startswith(prefix):
                raise ValueError(
                    f"{name} must live under {COORDINATION_ROOT}/<run_id> "
                    f"for run {self.handoff.run_id!r}"
                )
        return self

    def validate_report(self, report: ExecutionReport) -> None:
        """Bind a returned ExecutionReport to this task (completion contract).

        Every identity component must match the handoff: ``run_id``,
        ``task_id``, ``attempt`` (must equal the lease generation),
        ``lease_id`` and ``workspace_id``.  Any mismatch raises
        :class:`HarnessError` -- a report that is not bound to the
        dispatch is never trusted.
        """
        handoff = self.handoff
        if report.run_id != handoff.run_id:
            raise HarnessError(
                f"report run_id {report.run_id!r} does not match handoff "
                f"run_id {handoff.run_id!r}"
            )
        if report.task_id != handoff.task_id:
            raise HarnessError(
                f"report task_id {report.task_id!r} does not match handoff "
                f"task_id {handoff.task_id!r}"
            )
        if report.attempt != handoff.lease.generation:
            raise HarnessError(
                f"report attempt {report.attempt} does not match lease "
                f"generation {handoff.lease.generation}"
            )
        if report.lease_id != handoff.lease.lease_id:
            raise HarnessError(
                f"report lease_id {report.lease_id!r} does not match handoff "
                f"lease_id {handoff.lease.lease_id!r}"
            )
        if report.workspace_id != self.workspace_id:
            raise HarnessError(
                f"report workspace_id {report.workspace_id!r} does not match "
                f"task workspace_id {self.workspace_id!r}"
            )
