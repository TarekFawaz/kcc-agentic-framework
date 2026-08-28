"""Clickable prototype evidence models and evaluation for autobuild.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_prototype.py`
(see the KCC x Superpowers Hybrid Framework Plan 02, Task 4).

Implements the Clickable Prototype of Design Spec v1.2 sections 2.2,
9.3-9.6 and its place in section 14.1 (``prototype_ref``) and the
section 15 LOCK surface ("prototype approved"), with the binding plan
rulings:

* R10 — prototype evidence validation is not a gate: H1 Scope, H2
  Prototype walkthrough and final LOCK remain the only formal pre-build
  gates.  These checks produce the evidence the H2 walkthrough and the
  Tier-1 ``prototype_ref`` consume, nothing more.
* R1 — ``run_id`` is optional and validated against the canonical run
  identity pattern when present (template-compatible, same as the trace
  graph).

A :class:`Prototype` is a *clickable* pre-lock artifact: it names the
artifact reference, declares the screen/state inventory (section 9.5)
and the interactions between screens, and identifies the **primary
journey** — the happy-path click chain a user walks through (sections
2.2, 9.6).  It is explicitly **not** production implementation and
never interactivity-by-default: a prototype only counts as interactive
when declared so (fail-closed, matching the authority/budget defaults
of the contract layer).

:func:`evaluate_prototype` reports the walkthrough evidence quality:
whether the primary journey is a contiguous click path from the entry
screen to an exit screen, plus missing evidence such as unrepresented
important states (loading/empty/error/success, section 9.5).
"""

from __future__ import annotations

from enum import Enum

from pydantic import Field, ValidationInfo, field_validator, model_validator

from kcc_autobuild.models import RUN_ID_PATTERN, StrictModel


def _require_nonempty(value: str, name: str) -> str:
    if not value.strip():
        raise ValueError(f"{name} must not be empty")
    return value


class PrototypeState(str, Enum):
    """State a prototype screen can represent (spec section 9.5/9.6).

    ``DEFAULT`` is the normal state every screen represents; LOADING,
    EMPTY, ERROR and SUCCESS are the important states the prototype
    should inventory when the product has them.
    """

    DEFAULT = "DEFAULT"
    LOADING = "LOADING"
    EMPTY = "EMPTY"
    ERROR = "ERROR"
    SUCCESS = "SUCCESS"


class PrototypeScreen(StrictModel):
    """One screen of the clickable prototype.

    ``states`` declares which important states (section 9.5) this
    screen represents; ``entry`` marks the screen the primary journey
    starts on and ``exit`` marks a screen the primary journey may end
    on (a screen without any outgoing interaction is always a natural
    exit).
    """

    id: str
    name: str
    states: list[PrototypeState] = Field(default_factory=lambda: [PrototypeState.DEFAULT])
    entry: bool = False
    exit: bool = False

    @field_validator("id", "name")
    @classmethod
    def _required_text(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)

    @field_validator("states")
    @classmethod
    def _states_unique(cls, value: list[PrototypeState]) -> list[PrototypeState]:
        if len(value) != len(set(value)):
            raise ValueError("screen states must not contain duplicates")
        return value


class PrototypeInteraction(StrictModel):
    """One clickable interaction between two prototype screens.

    ``source`` is the screen the user is on, ``action`` names the user
    action (e.g. ``upload-pdf``, ``open-result``) and ``target`` is the
    screen the click navigates to.
    """

    id: str
    source: str
    action: str
    target: str

    @field_validator("id", "source", "action", "target")
    @classmethod
    def _required_text(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)


class Prototype(StrictModel):
    """A validated clickable prototype evidence artifact (spec sections
    2.2, 9.6).

    ``artifact_ref`` locates the clickable artifact (URL or path) and
    ``interactive`` must be declared — a prototype does not count as a
    clickable artifact until it is (fail-closed).
    ``production_implementation`` is rejected outright: the prototype
    is a pre-lock artifact used to validate interaction, information
    structure and user experience, never the production implementation
    (section 9.6).

    ``primary_journey`` is the ordered list of interaction ids a user
    traverses from the entry screen to an exit screen.
    """

    run_id: str | None = Field(default=None, pattern=RUN_ID_PATTERN)
    title: str
    artifact_ref: str
    interactive: bool = False
    production_implementation: bool = False
    screens: list[PrototypeScreen] = Field(default_factory=list)
    interactions: list[PrototypeInteraction] = Field(default_factory=list)
    primary_journey: list[str] = Field(default_factory=list)

    @field_validator("title", "artifact_ref")
    @classmethod
    def _required_text(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)

    @field_validator("production_implementation")
    @classmethod
    def _not_production(cls, value: bool) -> bool:
        if value:
            raise ValueError("a prototype must not be production implementation")
        return value

    @field_validator("primary_journey")
    @classmethod
    def _journey_entries_not_blank(cls, value: list[str]) -> list[str]:
        for step in value:
            _require_nonempty(step, "primary_journey step")
        return value

    @model_validator(mode="after")
    def _reference_integrity(self) -> Prototype:
        """Screens/interactions are unique and all references exist."""
        screen_ids = [screen.id for screen in self.screens]
        if len(screen_ids) != len(set(screen_ids)):
            raise ValueError("prototype screen ids must be unique")
        interaction_ids = [interaction.id for interaction in self.interactions]
        if len(interaction_ids) != len(set(interaction_ids)):
            raise ValueError("prototype interaction ids must be unique")

        known_screens = set(screen_ids)
        for interaction in self.interactions:
            if interaction.source not in known_screens:
                raise ValueError(
                    f"interaction '{interaction.id}' source '{interaction.source}' "
                    "does not reference an existing screen"
                )
            if interaction.target not in known_screens:
                raise ValueError(
                    f"interaction '{interaction.id}' target '{interaction.target}' "
                    "does not reference an existing screen"
                )

        known_interactions = set(interaction_ids)
        for step in self.primary_journey:
            if step not in known_interactions:
                raise ValueError(
                    f"primary journey step '{step}' does not reference an "
                    "existing interaction"
                )
        return self


class PrototypeEvaluation(StrictModel):
    """Result of :func:`evaluate_prototype`.

    ``primary_journey_ok`` is the walkthrough verdict: the primary
    journey is nonempty, starts on an entry screen, is contiguous
    (each click starts where the previous ended), never repeats an
    interaction, and ends on an exit screen (marked or a dead end).
    ``problems`` are the sorted evidence-quality findings and
    ``unrepresented_states`` the sorted special states (section 9.5)
    no screen declares; ``journey_screens`` lists the screens in
    first-occurrence click order for the H2 walkthrough.
    """

    primary_journey_ok: bool
    problems: list[str] = Field(default_factory=list)
    unrepresented_states: list[PrototypeState] = Field(default_factory=list)
    journey_screens: list[str] = Field(default_factory=list)


def evaluate_prototype(prototype: Prototype) -> PrototypeEvaluation:
    """Evaluate the clickable prototype evidence quality.

    Deterministic output: problems are sorted and the special-state
    report is sorted by state value.  This is evidence for the H2
    prototype walkthrough and the Tier-1 ``prototype_ref`` — it
    introduces no gate of its own (R10).
    """
    problems: list[str] = []
    if not prototype.interactive:
        problems.append("prototype is not interactive (must be a clickable artifact)")
    if not prototype.screens:
        problems.append("prototype has no screens")
    if not prototype.interactions:
        problems.append("prototype has no interactions")

    journey_problems: list[str] = []
    journey_screens: list[str] = []
    if not prototype.primary_journey:
        journey_problems.append("primary journey is empty")
    else:
        interactions_by_id = {
            interaction.id: interaction for interaction in prototype.interactions
        }
        screens_by_id = {screen.id: screen for screen in prototype.screens}
        first = interactions_by_id[prototype.primary_journey[0]]
        journey_screens.append(first.source)
        seen_steps: set[str] = set()
        for step in prototype.primary_journey:
            if step in seen_steps:
                journey_problems.append(f"primary journey repeats interaction '{step}'")
            seen_steps.add(step)
            interaction = interactions_by_id[step]
            journey_screens.append(interaction.target)

        if not screens_by_id[first.source].entry:
            journey_problems.append(
                f"primary journey does not start at an entry screen "
                f"(first screen '{first.source}')"
            )
        for previous, step in zip(
            prototype.primary_journey, prototype.primary_journey[1:]
        ):
            expected = interactions_by_id[previous].target
            actual = interactions_by_id[step].source
            if actual != expected:
                journey_problems.append(
                    f"primary journey is discontinuous at '{step}': "
                    f"expected source '{expected}'"
                )
        last = interactions_by_id[prototype.primary_journey[-1]]
        end_screen = screens_by_id[last.target]
        has_outgoing = any(
            interaction.source == end_screen.id for interaction in prototype.interactions
        )
        if not (end_screen.exit or not has_outgoing):
            journey_problems.append(
                f"primary journey does not end on an exit screen "
                f"(last screen '{end_screen.id}')"
            )

    represented: set[PrototypeState] = {
        state for screen in prototype.screens for state in screen.states
    }
    unrepresented = sorted(
        (
            state
            for state in PrototypeState
            if state is not PrototypeState.DEFAULT and state not in represented
        ),
        key=lambda state: state.value,
    )
    return PrototypeEvaluation(
        primary_journey_ok=not journey_problems,
        problems=sorted(problems + journey_problems),
        unrepresented_states=unrepresented,
        journey_screens=_dedupe(journey_screens),
    )


def _dedupe(values: list[str]) -> list[str]:
    """First-occurrence dedupe preserving order."""
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value not in seen:
            seen.add(value)
            result.append(value)
    return result
