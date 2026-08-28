"""Harness adapter contract (Plan 08, Task 1).

Defines the abstract execution-adapter boundary of the harness-neutral
core: every adapter reports what its probe could prove
(:func:`probe`) and executes one bounded :class:`HarnessTask`
(:func:`execute`), returning the :class:`ExecutionReport` the worker
produced.  The concrete adapters (Codex, DeepSeek/DSH, generic, ...)
live in later Plan 08 tasks; this base fixes the contract they must
honor -- adapter-specific capability levels, never a "works on every
CLI" claim.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import ClassVar

from kcc_autobuild.bridge import ExecutionReport
from kcc_autobuild.harnesses.models import HarnessProbe, HarnessTask


class HarnessAdapter(ABC):
    """Abstract contract of one harness execution adapter.

    ``harness_id`` names the harness (e.g. ``codex``, ``dsh``).  A
    concrete adapter must implement:

    * :func:`probe` -- return the :class:`HarnessProbe` outcome of the
      feature probe; only proven capabilities may be reported
      (never fake fresh/parallel workers or policy enforcement).
    * :func:`execute` -- run the :class:`HarnessTask` against the
      harness and return the worker's :class:`ExecutionReport`.
    """

    harness_id: ClassVar[str] = ""

    @abstractmethod
    def probe(self) -> HarnessProbe:
        """Probe the harness and report only what is proven."""

    @abstractmethod
    def execute(self, task: HarnessTask) -> ExecutionReport:
        """Execute one bounded task and return its ExecutionReport."""
