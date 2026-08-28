"""Behavioral tests for the autobuild clickable prototype evidence layer.

Written first (strict TDD red phase) against the external behavior
contract of :mod:`kcc_autobuild.prototype` (KCC x Superpowers Hybrid
Framework Plan 02, Task 4; Design Spec v1.2 sections 2.2, 9.3, 9.5,
9.6, 14.1).

Binding semantics under test (Design Spec v1.2):

* a prototype is a **clickable** pre-lock artifact representing the
  primary journey and important states (section 9.6, experience goal
  2.2);
* it is **not production implementation** — that is rejected at
  construction;
* the primary journey is a contiguous click path from the entry screen
  to an exit screen, every interaction must navigate between existing
  screens, and the journey must not repeat or break;
* the screen/state inventory (section 9.5) declares the important
  states (loading / empty / error / success) each screen represents;
  states not represented anywhere are reported as evidence gaps;
* ``run_id`` is optional and, when present, must match the canonical
  run identity pattern (template-compatible, ruling R1 spirit).

These are evidence-quality validations, not gates: H1 Scope, H2
Prototype and final LOCK remain the only formal pre-build gates (R10);
prototype evidence feeds the H2 walkthrough and the Tier-1
``prototype_ref``, never a new approval step.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from kcc_autobuild.prototype import (
    Prototype,
    PrototypeEvaluation,
    PrototypeInteraction,
    PrototypeScreen,
    PrototypeState,
    evaluate_prototype,
)


def _screen(screen_id: str = "SCR-1", **overrides: object) -> PrototypeScreen:
    """A screen; no state overrides means the default state inventory."""
    defaults: dict[str, object] = {
        "id": screen_id,
        "name": f"Screen {screen_id}",
        "states": [PrototypeState.DEFAULT],
        "entry": False,
        "exit": False,
    }
    defaults.update(overrides)
    return PrototypeScreen(**defaults)


def _interaction(
    interaction_id: str = "I-1",
    source: str = "SCR-1",
    target: str = "SCR-2",
    action: str = "open-result",
) -> PrototypeInteraction:
    return PrototypeInteraction(
        id=interaction_id, source=source, action=action, target=target
    )


def _prototype(**overrides: object) -> Prototype:
    """A clickable prototype: SCR-1 (entry) opens SCR-2 (exit) or SCR-3 (error)."""
    defaults: dict[str, object] = {
        "run_id": "RUN-001",
        "title": "Upload demo",
        "artifact_ref": "prototypes/upload/index.html",
        "interactive": True,
        "production_implementation": False,
        "screens": [
            _screen("SCR-1", entry=True),
            _screen("SCR-2", exit=True),
            _screen("SCR-3", states=[PrototypeState.ERROR]),
        ],
        "interactions": [
            _interaction("I-1", "SCR-1", "SCR-2", "open-result"),
            _interaction("I-2", "SCR-1", "SCR-3", "trigger-failure"),
        ],
        "primary_journey": ["I-1"],
    }
    defaults.update(overrides)
    return Prototype(**defaults)


# ---------------------------------------------------------------------------
# PrototypeState / PrototypeScreen — spec 9.5 screen and state inventory
# ---------------------------------------------------------------------------


def test_state_enum_covers_important_states() -> None:
    """Section 9.5/9.6 important states are modeled (default + special)."""
    assert [state.value for state in PrototypeState] == [
        "DEFAULT",
        "LOADING",
        "EMPTY",
        "ERROR",
        "SUCCESS",
    ]


def test_screen_requires_nonempty_id_and_name() -> None:
    """Screens must be identifiable and named."""
    with pytest.raises(ValidationError, match="id must not be empty"):
        _screen("  ")
    with pytest.raises(ValidationError, match="name must not be empty"):
        _screen("SCR-1", name="")


def test_screen_states_default_to_default_state() -> None:
    """A screen without an explicit inventory still represents its normal state."""
    assert _screen("SCR-1").states == [PrototypeState.DEFAULT]
    assert _screen("SCR-1", states=[]).states == []


def test_screen_states_must_be_unique() -> None:
    """Duplicate state declarations are ambiguous and rejected."""
    with pytest.raises(ValidationError, match="states must not contain duplicates"):
        _screen("SCR-1", states=[PrototypeState.ERROR, PrototypeState.ERROR])


def test_interaction_requires_nonempty_id_source_action_target() -> None:
    """Every click has an identity, a source screen, an action and a target."""
    with pytest.raises(ValidationError, match="id must not be empty"):
        _interaction(interaction_id="")
    for field, value in (("source", ""), ("action", ""), ("target", "")):
        with pytest.raises(ValidationError, match=f"{field} must not be empty"):
            _interaction(**{field: value})


# ---------------------------------------------------------------------------
# Prototype — clickable artifact (spec 2.2 / 9.6)
# ---------------------------------------------------------------------------


def test_prototype_accepts_valid_clickable_artifact() -> None:
    """A clickable prototype with a journey, screens and interactions validates."""
    proto = _prototype()
    assert proto.title == "Upload demo"
    assert proto.artifact_ref == "prototypes/upload/index.html"
    assert proto.interactive is True
    assert proto.production_implementation is False
    assert len(proto.screens) == 3
    assert len(proto.interactions) == 2
    assert proto.primary_journey == ["I-1"]


def test_prototype_interactive_defaults_fail_closed() -> None:
    """interactive is opt-in: an artifact is not clickable until declared so."""
    proto = _prototype(interactive=False)
    assert proto.interactive is False


def test_prototype_rejects_production_implementation() -> None:
    """The prototype is a pre-lock artifact, never production implementation."""
    with pytest.raises(ValidationError, match="must not be production implementation"):
        _prototype(production_implementation=True)


def test_prototype_requires_title_and_artifact_ref() -> None:
    """A prototype evidence record names the artifact and its clickable ref."""
    with pytest.raises(ValidationError, match="title must not be empty"):
        _prototype(title=" ")
    with pytest.raises(ValidationError, match="artifact_ref must not be empty"):
        _prototype(artifact_ref="")


def test_prototype_screen_ids_must_be_unique() -> None:
    """Duplicate screen ids would make interactions ambiguous."""
    with pytest.raises(ValidationError, match="screen ids must be unique"):
        _prototype(screens=[_screen("SCR-1"), _screen("SCR-1", exit=True)])


def test_prototype_interaction_ids_must_be_unique() -> None:
    """Duplicate interaction ids are rejected."""
    with pytest.raises(ValidationError, match="interaction ids must be unique"):
        _prototype(interactions=[_interaction("I-1"), _interaction("I-1")])


def test_prototype_interaction_source_must_exist() -> None:
    """A click cannot originate from a screen that is not in the prototype."""
    with pytest.raises(ValidationError, match="does not reference an existing screen"):
        _prototype(interactions=[_interaction("I-9", source="SCR-99")])


def test_prototype_interaction_target_must_exist() -> None:
    """A click cannot navigate to a screen that is not in the prototype."""
    with pytest.raises(ValidationError, match="does not reference an existing screen"):
        _prototype(interactions=[_interaction("I-9", target="SCR-99")])


def test_prototype_journey_steps_must_exist() -> None:
    """The primary journey can only traverse interactions the prototype has."""
    with pytest.raises(ValidationError, match="does not reference an existing interaction"):
        _prototype(primary_journey=["I-9"])


def test_prototype_run_id_optional_and_validated_when_present() -> None:
    """run_id is optional; when present it must match the canonical pattern."""
    assert _prototype(run_id=None).run_id is None
    with pytest.raises(ValidationError, match="String should match pattern"):
        _prototype(run_id="../escape")


# ---------------------------------------------------------------------------
# evaluate_prototype — primary journey evidence
# ---------------------------------------------------------------------------


def test_evaluate_returns_typed_evaluation() -> None:
    """The evaluator returns a PrototypeEvaluation (not a bare dict)."""
    result = evaluate_prototype(_prototype())
    assert isinstance(result, PrototypeEvaluation)


def test_evaluate_complete_prototype_has_no_journey_problems() -> None:
    """A clickable prototype with a valid primary journey passes cleanly."""
    result = evaluate_prototype(_prototype())
    assert result.primary_journey_ok is True
    assert result.problems == []
    assert result.journey_screens == ["SCR-1", "SCR-2"]


def test_evaluate_journey_screens_preserve_click_order() -> None:
    """journey_screens lists the screens in first-click order along the path."""
    result = evaluate_prototype(
        _prototype(
            interactions=[
                _interaction("I-1", "SCR-1", "SCR-2", "open-result"),
                _interaction("I-2", "SCR-1", "SCR-3", "trigger-failure"),
            ],
            primary_journey=["I-2"],
        )
    )
    assert result.journey_screens == ["SCR-1", "SCR-3"]


def test_evaluate_non_interactive_artifact_is_a_problem() -> None:
    """A non-clickable artifact cannot support an H2 walkthrough."""
    result = evaluate_prototype(_prototype(interactive=False))
    assert "prototype is not interactive (must be a clickable artifact)" in result.problems


def test_evaluate_empty_prototype_reports_missing_evidence() -> None:
    """An empty artifact cannot represent any journey or state."""
    result = evaluate_prototype(
        _prototype(screens=[], interactions=[], primary_journey=[])
    )
    assert "prototype has no screens" in result.problems
    assert "prototype has no interactions" in result.problems
    assert "primary journey is empty" in result.problems
    assert result.primary_journey_ok is False


def test_evaluate_empty_primary_journey_is_a_problem() -> None:
    """No primary journey means no walkthrough evidence (section 9.6)."""
    result = evaluate_prototype(_prototype(primary_journey=[]))
    assert result.problems == ["primary journey is empty"]
    assert result.primary_journey_ok is False


def test_evaluate_journey_must_start_at_entry_screen() -> None:
    """The journey must start on the marked entry screen of the prototype."""
    proto = _prototype(
        screens=[_screen("SCR-1"), _screen("SCR-2", exit=True)],
        interactions=[
            _interaction("I-1", "SCR-1", "SCR-2", "open-result"),
        ],
        primary_journey=["I-1"],
    )
    result = evaluate_prototype(proto)
    assert result.primary_journey_ok is False
    assert result.problems == [
        "primary journey does not start at an entry screen (first screen 'SCR-1')"
    ]


def test_evaluate_discontinuous_journey_is_a_problem() -> None:
    """Each click must start where the previous click ended."""
    result = evaluate_prototype(_prototype(primary_journey=["I-1", "I-2"]))
    assert result.primary_journey_ok is False
    assert result.problems == [
        "primary journey is discontinuous at 'I-2': expected source 'SCR-2'"
    ]


def test_evaluate_repeated_journey_step_is_a_problem() -> None:
    """A primary journey must not loop over the same interaction."""
    result = evaluate_prototype(_prototype(primary_journey=["I-1", "I-2", "I-2"]))
    assert result.primary_journey_ok is False
    assert "primary journey repeats interaction 'I-2'" in result.problems


def test_evaluate_journey_must_end_on_exit_screen() -> None:
    """A journey ending mid-flow (screens with further clicks) is incomplete."""
    proto = _prototype(
        screens=[_screen("SCR-1", entry=True), _screen("SCR-2")],
        interactions=[
            _interaction("I-1", "SCR-1", "SCR-2", "open-result"),
            _interaction("I-2", "SCR-2", "SCR-1", "back"),
        ],
        primary_journey=["I-1"],
    )
    result = evaluate_prototype(proto)
    assert result.primary_journey_ok is False
    assert result.problems == [
        "primary journey does not end on an exit screen (last screen 'SCR-2')"
    ]


def test_evaluate_journey_ending_on_dead_end_screen_is_valid() -> None:
    """A screen with no further clicks is a natural exit of the journey."""
    proto = _prototype(
        screens=[_screen("SCR-1", entry=True), _screen("SCR-2")],
        interactions=[_interaction("I-1", "SCR-1", "SCR-2", "open-result")],
        primary_journey=["I-1"],
    )
    result = evaluate_prototype(proto)
    assert result.primary_journey_ok is True
    assert result.problems == []


def test_evaluate_problems_are_sorted_and_deterministic() -> None:
    """Problem output is sorted so identical prototypes give identical reports."""
    result = evaluate_prototype(_prototype(interactive=False, primary_journey=[]))
    assert result.problems == sorted(result.problems)
    assert result.problems == [
        "primary journey is empty",
        "prototype is not interactive (must be a clickable artifact)",
    ]


# ---------------------------------------------------------------------------
# evaluate_prototype — important state coverage (spec 9.5)
# ---------------------------------------------------------------------------


def test_evaluate_reports_unrepresented_important_states() -> None:
    """Special states (loading/empty/error/success) missing from the inventory are listed."""
    result = evaluate_prototype(_prototype())
    assert result.unrepresented_states == [
        PrototypeState.EMPTY,
        PrototypeState.LOADING,
        PrototypeState.SUCCESS,
    ]


def test_evaluate_represented_states_are_not_reported_missing() -> None:
    """States covered by any screen are not listed as evidence gaps."""
    proto = _prototype(
        screens=[
            _screen("SCR-1", entry=True),
            _screen("SCR-2", exit=True, states=[PrototypeState.SUCCESS]),
        ],
        interactions=[_interaction("I-1", "SCR-1", "SCR-2", "open-result")],
        primary_journey=["I-1"],
    )
    result = evaluate_prototype(proto)
    assert result.problems == []
    assert PrototypeState.SUCCESS not in result.unrepresented_states
    assert PrototypeState.DEFAULT not in result.unrepresented_states
