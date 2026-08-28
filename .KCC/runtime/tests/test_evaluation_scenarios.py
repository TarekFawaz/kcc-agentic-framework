"""Completeness tests for the approved 30-scenario autobuild evaluation catalog.

Plan 07, Task 1 contract (local Plan07 task contracts file, ``### Task 1``,
plus the ## Global Constraints and the approved Design Spec v1.2 section 27):

* ``evaluation scenarios.py`` encodes exactly 30 unique, immutable
  scenarios with stable IDs and expected states used by later tasks
  (FakeWorld injection mapping, scenario runner, autonomy metrics);
* scenario 4 is corrected to
  ``browser extension external API resumes after interrupted session``;
* the exact catalog includes the pinned entries scenario 13 worker
  partition crash mid-wave => DONE, scenario 15 locked provider change =>
  HALTED, scenario 16 Tier2 substitution => DONE, scenario 21 Tier1
  deviation => HALTED, scenario 23 migration commit-crash => DONE,
  scenario 25 pause/resume => BUILDING, scenario 30 store rejection
  Tier1 => HALTED;
* the completeness test asserts catalog length exactly 30 and unique IDs.

The first eighteen scenarios are the Design Spec v1.2 section 27 minimum
scenario suite, in order, with scenario 4 carrying the contract's
correction.  Written first (strict TDD red phase) before any catalog
implementation exists.
"""

from __future__ import annotations

import re
from types import MappingProxyType

import pytest
from pydantic import ValidationError

from kcc_autobuild.evaluation import SCENARIOS_BY_ID, SCENARIO_CATALOG
from kcc_autobuild.evaluation.scenarios import ProjectClass, Scenario
from kcc_autobuild.models import DependencyStatus, LifecycleState

EXPECTED_COUNT = 30

# Design Spec v1.2 section 27 "Minimum scenario suite" (items 1..18),
# normalized to the catalog's lowercase title style; item 4 carries the
# contract's correction rather than the draft wording.
SPEC_27_MINIMUM_SUITE: tuple[str, ...] = (
    "low-risk internal crud tool with no external provider",
    "public web app with oauth database storage and email",
    "payment-enabled application using sandbox and live separation",
    "browser extension external API resumes after interrupted session",
    "api-only service with ci cd and no ui prototype requirement",
    "mobile app with app-store account dependency and external review wait",
    "provider credential with insufficient scope discovered before lock",
    "credential revoked after lock",
    "budget cap reached during implementation",
    "production migration requiring rollback safeguards",
    "external provider outage with an approved fallback",
    "external provider outage with no approved fallback",
    "worker partition crash mid-wave",
    "red-team discovers an oauth callback or webhook gap missed by the planner",
    "locked provider change",
    "Tier2 substitution",
    "orphan requirement missing test-id or production validation before lock",
    "multiple post-lock blockers consolidated into one decision batch",
)

# Contract-pinned catalog entries: scenario number -> (exact title, expected state).
PINNED_SECTIONS: dict[int, tuple[str, LifecycleState]] = {
    13: ("worker partition crash mid-wave", LifecycleState.DONE),
    15: ("locked provider change", LifecycleState.HALTED),
    16: ("Tier2 substitution", LifecycleState.DONE),
    21: ("Tier1 deviation", LifecycleState.HALTED),
    23: ("migration commit-crash", LifecycleState.DONE),
    25: ("pause/resume", LifecycleState.BUILDING),
    30: ("store rejection Tier1", LifecycleState.HALTED),
}

SCENARIO_4_TITLE = "browser extension external API resumes after interrupted session"

# Stable ID shape: scenario1 .. scenario30 (no zero padding, no separator).
ID_PATTERN = re.compile(r"^scenario(?:[1-9]|[12][0-9]|30)$")


def _by_number() -> dict[int, Scenario]:
    return {index: scenario for index, scenario in enumerate(SCENARIO_CATALOG, start=1)}


def test_catalog_length_is_exactly_30() -> None:
    """The catalog must contain exactly the approved 30 scenarios."""
    assert len(SCENARIO_CATALOG) == EXPECTED_COUNT


def test_ids_are_unique() -> None:
    """Every scenario must have a distinct stable ID."""
    ids = [scenario.id for scenario in SCENARIO_CATALOG]
    assert len(ids) == len(set(ids)) == EXPECTED_COUNT


def test_ids_match_position_stably() -> None:
    """Stable IDs: the 1-based position is the ID number (scenario1..scenario30)."""
    for index, scenario in enumerate(SCENARIO_CATALOG, start=1):
        assert scenario.id == f"scenario{index}", (index, scenario.id)
        assert ID_PATTERN.fullmatch(scenario.id), scenario.id


def test_by_id_exposes_every_scenario_once() -> None:
    """The by-ID lookup must be complete, consistent and read-only."""
    assert len(SCENARIOS_BY_ID) == EXPECTED_COUNT
    assert set(SCENARIOS_BY_ID) == {scenario.id for scenario in SCENARIO_CATALOG}
    for scenario in SCENARIO_CATALOG:
        assert SCENARIOS_BY_ID[scenario.id] is scenario
    with pytest.raises(TypeError):
        SCENARIOS_BY_ID["scenario1"] = Scenario(  # type: ignore[index]
            id="scenario1",
            title="mutated",
            project_class=ProjectClass.INTERNAL_TOOL,
            expected_state=LifecycleState.DONE,
            description="must stay immutable",
        )


def test_first_eighteen_scenarios_are_the_spec_27_minimum_suite() -> None:
    """Scenarios 1..18 are Design Spec v1.2 section 27, in order, with #4 corrected."""
    for number, expected_title in enumerate(SPEC_27_MINIMUM_SUITE, start=1):
        scenario = SCENARIO_CATALOG[number - 1]
        assert scenario.title == expected_title, (number, scenario.title)
        assert scenario.id == f"scenario{number}"


def test_scenario_4_correction() -> None:
    """Scenario 4 must carry the contract's correction verbatim."""
    scenario = _by_number()[4]
    assert scenario.title == SCENARIO_4_TITLE
    assert "resumes" in scenario.title.split()
    assert scenario.expected_state is LifecycleState.DONE


@pytest.mark.parametrize(
    "number,title,state",
    [
        (number, title, state)
        for number, (title, state) in sorted(PINNED_SECTIONS.items())
    ],
    ids=[f"scenario-{number}" for number in sorted(PINNED_SECTIONS)],
)
def test_pinned_catalog_entries(
    number: int, title: str, state: LifecycleState
) -> None:
    """Every contract-pinned entry exists at its number with its exact state."""
    scenario = _by_number()[number]
    assert scenario.title == title, (number, scenario.title)
    assert scenario.expected_state is state, (number, scenario.expected_state)


def test_pinned_expected_states_are_declared_in_catalog() -> None:
    """Each pinned expected state must appear on at least the pinned scenario."""
    for number, (_title, state) in PINNED_SECTIONS.items():
        assert state in {scenario.expected_state for scenario in SCENARIO_CATALOG}
        assert _by_number()[number].expected_state is state


def test_project_classes_cover_the_staging_smoke_classes() -> None:
    """Project classes must include the three R2 staging smoke classes.

    Plan 07 Task 4 gates rollout on ``staging_smoke_classes >= 3`` (web
    app, API-only, browser extension), so the catalog must classify
    those projects with exactly those class values.
    """
    class_values = {scenario.project_class.value for scenario in SCENARIO_CATALOG}
    assert "web-app" in class_values
    assert "api-only" in class_values
    assert "browser-extension" in class_values


def test_catalog_and_entries_are_immutable() -> None:
    """The catalog container and every scenario are immutable."""
    assert isinstance(SCENARIO_CATALOG, tuple)
    for scenario in SCENARIO_CATALOG:
        assert isinstance(scenario, Scenario)
        with pytest.raises(ValidationError):
            scenario.title = "mutated"  # type: ignore[misc]
        with pytest.raises(ValidationError):
            scenario.expected_state = LifecycleState.HALTED  # type: ignore[misc]


def test_expected_states_are_real_lifecycle_states() -> None:
    """Every expected state must be a LifecycleState member the controller uses."""
    for scenario in SCENARIO_CATALOG:
        assert isinstance(scenario.expected_state, LifecycleState)
        assert LifecycleState(scenario.expected_state.value) is scenario.expected_state


def test_catalog_is_deterministic_and_ordered() -> None:
    """The catalog is ordered by stable ID; IDs and titles are non-empty."""
    for index, scenario in enumerate(SCENARIO_CATALOG, start=1):
        assert scenario.title.strip()
        assert scenario.description.strip()
        assert scenario.id == f"scenario{index}"
    assert SCENARIO_CATALOG == tuple(SCENARIO_CATALOG)


def test_canonical_auto_provision_enum_unchanged() -> None:
    """Global constraint: canonical enum AUTO_PROVISION_AUTHORIZED must never be renamed."""
    assert DependencyStatus.AUTO_PROVISION_AUTHORIZED.value == "AUTO_PROVISION_AUTHORIZED"
