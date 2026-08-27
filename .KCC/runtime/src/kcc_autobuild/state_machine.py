"""Lifecycle transition enforcement for the autobuild runtime.

Behavioral contract owned by .KCC/runtime/tests/test_state_machine.py
(see the KCC x Superpowers Hybrid Framework Plan 01, Task 2).

Transitions are fail-closed: a target is only reachable when explicitly
declared in TRANSITIONS, and any other attempt raises InvalidTransition.
"""

from __future__ import annotations

from kcc_autobuild.models import LifecycleState


class InvalidTransition(ValueError):
    """Raised when a lifecycle transition is not permitted."""


TRANSITIONS: dict[LifecycleState, frozenset[LifecycleState]] = {
    LifecycleState.INTAKE: frozenset(
        {LifecycleState.DISCOVERY, LifecycleState.ABANDONED}
    ),
    LifecycleState.DISCOVERY: frozenset(
        {LifecycleState.PROTOTYPE_REVIEW, LifecycleState.ARCHITECTURE, LifecycleState.ABANDONED}
    ),
    LifecycleState.PROTOTYPE_REVIEW: frozenset(
        {LifecycleState.DISCOVERY, LifecycleState.ARCHITECTURE, LifecycleState.ABANDONED}
    ),
    LifecycleState.ARCHITECTURE: frozenset(
        {LifecycleState.DE_RISK, LifecycleState.DISCOVERY, LifecycleState.ABANDONED}
    ),
    LifecycleState.DE_RISK: frozenset(
        {LifecycleState.READINESS, LifecycleState.BLOCKED, LifecycleState.ARCHITECTURE, LifecycleState.ABANDONED}
    ),
    LifecycleState.READINESS: frozenset(
        {LifecycleState.CONTRACT_REVIEW, LifecycleState.BLOCKED, LifecycleState.DE_RISK, LifecycleState.ABANDONED}
    ),
    LifecycleState.CONTRACT_REVIEW: frozenset(
        {LifecycleState.LOCKED, LifecycleState.READINESS, LifecycleState.ABANDONED}
    ),
    LifecycleState.LOCKED: frozenset(
        {LifecycleState.BUILDING, LifecycleState.PAUSED, LifecycleState.ABANDONED}
    ),
    LifecycleState.BUILDING: frozenset(
        {LifecycleState.STAGING_VALIDATED, LifecycleState.BLOCKED, LifecycleState.PAUSED, LifecycleState.HALTED, LifecycleState.ROLLING_BACK, LifecycleState.ABANDONED}
    ),
    LifecycleState.STAGING_VALIDATED: frozenset(
        {LifecycleState.DEPLOYED, LifecycleState.BUILDING, LifecycleState.PAUSED, LifecycleState.HALTED, LifecycleState.ABANDONED}
    ),
    LifecycleState.DEPLOYED: frozenset(
        {LifecycleState.PRODUCTION_VALIDATED, LifecycleState.EXTERNAL_WAIT, LifecycleState.ROLLING_BACK, LifecycleState.BLOCKED, LifecycleState.HALTED}
    ),
    LifecycleState.EXTERNAL_WAIT: frozenset(
        {LifecycleState.PRODUCTION_VALIDATED, LifecycleState.BUILDING, LifecycleState.HALTED, LifecycleState.ABANDONED}
    ),
    LifecycleState.PRODUCTION_VALIDATED: frozenset(
        {LifecycleState.DONE, LifecycleState.ROLLING_BACK, LifecycleState.HALTED}
    ),
    LifecycleState.BLOCKED: frozenset(
        {LifecycleState.RESUMING, LifecycleState.HALTED, LifecycleState.ABANDONED}
    ),
    LifecycleState.PAUSED: frozenset(
        {LifecycleState.RESUMING, LifecycleState.ABANDONED}
    ),
    LifecycleState.RESUMING: frozenset(
        {LifecycleState.BUILDING, LifecycleState.DE_RISK, LifecycleState.READINESS, LifecycleState.EXTERNAL_WAIT, LifecycleState.ROLLING_BACK, LifecycleState.HALTED}
    ),
    LifecycleState.ROLLING_BACK: frozenset(
        {LifecycleState.BUILDING, LifecycleState.STAGING_VALIDATED, LifecycleState.HALTED, LifecycleState.PAUSED}
    ),
    LifecycleState.HALTED: frozenset(
        {LifecycleState.CONTRACT_REVIEW, LifecycleState.RESUMING, LifecycleState.ABANDONED}
    ),
    LifecycleState.DONE: frozenset(),
    LifecycleState.ABANDONED: frozenset(),
}


def allowed_targets(current: LifecycleState) -> frozenset[LifecycleState]:
    """Return the set of states reachable directly from current."""
    return TRANSITIONS[current]


def assert_transition(current: LifecycleState, target: LifecycleState) -> None:
    """Assert that current -> target is a declared lifecycle transition.

    Raises:
        InvalidTransition: if target is not an allowed target of current.
    """
    if target not in allowed_targets(current):
        raise InvalidTransition(
            f"invalid lifecycle transition: {current.value} -> {target.value}"
        )
