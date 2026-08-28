"""Harness capability contract package (Plan 08, Task 1).

Public surface of the harness-neutral capability model:

* canonical enums :class:`ApprovalMode`, :class:`MutationEnforcement`,
  :class:`ExecutionStrategy` and capability names
  :class:`HarnessCapability`;
* :class:`HarnessCapabilities` -- unknown defaults false/0,
  :meth:`~HarnessCapabilities.supports` and
  :meth:`~HarnessCapabilities.best_strategy` (Full Autopilot requires
  read/write/exec + ``KCC_POLICY_GATE`` + approval none/never; unproven
  parallel degrades to serial);
* :class:`HarnessProbe`, :class:`HarnessTask` (consuming
  :class:`~kcc_autobuild.bridge.TaskHandoff` /
  :class:`~kcc_autobuild.bridge.ExecutionReport`) and
  :class:`HarnessError`;
* the abstract :class:`HarnessAdapter` contract.
"""

from __future__ import annotations

from kcc_autobuild.harnesses.base import HarnessAdapter
from kcc_autobuild.harnesses.models import (
    ApprovalMode,
    ExecutionStrategy,
    HarnessCapabilities,
    HarnessCapability,
    HarnessError,
    HarnessProbe,
    HarnessTask,
    MutationEnforcement,
)

__all__ = [
    "ApprovalMode",
    "MutationEnforcement",
    "ExecutionStrategy",
    "HarnessCapability",
    "HarnessCapabilities",
    "HarnessProbe",
    "HarnessTask",
    "HarnessError",
    "HarnessAdapter",
]
