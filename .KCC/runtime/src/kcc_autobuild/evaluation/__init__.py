"""Autobuild evaluation harness package.

Owns the deterministic evaluation artifacts of Plan 07 (Evaluation +
Rollout): the approved 30-scenario catalog (``scenarios.py``, Task 1),
the deterministic FakeWorld (``fake_world.py``, Task 2), the scenario
runner (Task 3) and the autonomy metrics / rollout gates (Task 4).  The
catalog below is the durable contract for every later task: it must
never be edited to make a scenario pass — the runtime is what passes.
"""

from kcc_autobuild.evaluation.fake_world import (
    BillingRecord,
    CIResult,
    FakeWorld,
    MigrationCrashError,
    MigrationResult,
    ProviderCallResult,
    StoreDecision,
    WorldEvent,
)
from kcc_autobuild.evaluation.scenarios import (
    SCENARIOS_BY_ID,
    SCENARIO_CATALOG,
    ProjectClass,
    Scenario,
)

__all__ = [
    "BillingRecord",
    "CIResult",
    "FakeWorld",
    "MigrationCrashError",
    "MigrationResult",
    "ProviderCallResult",
    "SCENARIOS_BY_ID",
    "SCENARIO_CATALOG",
    "StoreDecision",
    "WorldEvent",
    "ProjectClass",
    "Scenario",
]
