"""Generic compatibility harness adapter (Plan 08, Task 2).

The generic harness is the fallback compatibility mode: *any*
file+command environment the local shell and filesystem can serve.  Its
probe is deliberately conservative (plan Global Constraint: "generic
compatibility degrades to local sequential; never fake fresh/parallel
workers or policy enforcement"):

* :meth:`GenericHarnessAdapter.probe` checks the LOCAL shell (``sh -c``
  style) and the LOCAL filesystem (read + write of the workspace); only
  what the checks actually prove is reported.  Fresh workers, parallel
  workers and subagents are NEVER proven by the generic adapter, its
  ``mutation_enforcement`` stays ``none`` and its approval mode stays
  ``unknown`` -- the generic harness is not a policy-guarded worker,
  and its best strategy degrades to ``LOCAL`` (local sequential).
* A failed check degrades the report truthfully: that capability simply
  remains unproven, the confidence reflects the proven fraction of the
  read/write/exec compatibility trio, the failure is recorded and the
  harness is NOT detected (so the registry never selects a broken
  generic environment).
* :meth:`GenericHarnessAdapter.execute` never fakes a worker dispatch:
  no fresh-worker CLI was proven, so it raises :class:`HarnessError`
  (fail closed) until a real local runner is wired.

The checks are injectable for tests (``shell`` name, ``workspace``
path, timeout) but always run for real -- a generic capability claim is
a live observation, never a constant.
"""

from __future__ import annotations

import os
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path

from kcc_autobuild.bridge import ExecutionReport
from kcc_autobuild.harnesses.base import HarnessAdapter
from kcc_autobuild.harnesses.models import (
    HarnessCapabilities,
    HarnessError,
    HarnessProbe,
    HarnessTask,
)

GENERIC_HARNESS_ID = "generic"
"""Canonical harness id of the generic compatibility adapter."""

_PROBE_FILE_PREFIX = ".kcc-generic-probe-"


class GenericHarnessAdapter(HarnessAdapter):
    """Conservative generic (local shell/filesystem) compatibility adapter.

    ``shell`` names the POSIX shell the exec check runs (default
    ``sh``); ``workspace`` is the project path the filesystem checks
    exercise (default: the current working directory at probe time);
    ``timeout_seconds`` bounds the shell check.
    """

    harness_id: str = GENERIC_HARNESS_ID

    def __init__(
        self,
        *,
        shell: str = "sh",
        workspace: str | Path | None = None,
        timeout_seconds: float = 10.0,
    ) -> None:
        if not shell.strip():
            raise ValueError("shell must be a non-blank command name")
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        self.shell = shell
        self.workspace = Path(workspace) if workspace is not None else None
        self.timeout_seconds = timeout_seconds

    @property
    def _workspace(self) -> Path:
        return self.workspace if self.workspace is not None else Path.cwd()

    def probe(self) -> HarnessProbe:
        """Prove ONLY what the local shell/filesystem checks observe."""
        probed_at = datetime.now(timezone.utc)
        capabilities = HarnessCapabilities.unknown()
        evidence: list[str] = []
        failures: list[str] = []
        workspace = self._workspace
        self._probe_shell(capabilities, evidence, failures)
        self._probe_read(workspace, capabilities, evidence, failures)
        self._probe_write(workspace, capabilities, evidence, failures)
        # Confidence: the proven fraction of the local compatibility trio.
        capabilities.confidence = round(
            (int(capabilities.read) + int(capabilities.write) + int(capabilities.exec))
            / 3,
            2,
        )
        detected = capabilities.read and capabilities.write and capabilities.exec
        return HarnessProbe(
            harness_id=self.harness_id,
            detected=detected,
            capabilities=capabilities,
            probed_at=probed_at,
            evidence=evidence,
            error="; ".join(failures) if failures else None,
        )

    def execute(self, task: HarnessTask) -> ExecutionReport:
        """No external worker dispatch is proven for the generic harness.

        The generic compatibility harness has no fresh-worker CLI, so a
        dispatched execution cannot be faked: ``execute`` raises
        :class:`HarnessError` (fail closed) until a real local runner is
        wired.
        """
        raise HarnessError(
            "generic compatibility mode dispatches no external worker "
            "(no fresh-worker CLI proven); the local shell/filesystem "
            "session consumes tasks sequentially in-process and "
            "execute() is unavailable"
        )

    def _probe_shell(
        self,
        capabilities: HarnessCapabilities,
        evidence: list[str],
        failures: list[str],
    ) -> None:
        """Exec check: the local shell really runs a trivial command."""
        command = f"{self.shell} -c 'exit 0'"
        try:
            process = subprocess.run(
                [self.shell, "-c", "exit 0"],
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            failures.append(f"local shell exec check failed: {exc}")
            return
        if process.returncode == 0:
            capabilities.exec = True
            evidence.append(f"local shell exec proven: {command}")
        else:
            failures.append(
                f"local shell exec check exited {process.returncode}"
            )

    def _probe_read(
        self,
        workspace: Path,
        capabilities: HarnessCapabilities,
        evidence: list[str],
        failures: list[str],
    ) -> None:
        """Read check: the workspace is a readable directory."""
        try:
            entries = os.listdir(workspace)
        except OSError as exc:
            failures.append(f"workspace read check failed: {exc}")
            return
        capabilities.read = True
        evidence.append(
            f"workspace read proven: {workspace} ({len(entries)} entries)"
        )

    def _probe_write(
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
                handle.write("kcc generic probe\n")
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
