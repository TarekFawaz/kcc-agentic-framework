"""Behavioral contract for the adaptive provider rate capacity ledger.

Owned by ``test_rate_limit.py`` (see the KCC x Superpowers Hybrid Framework
Plan 04, Task 2: Adaptive provider rate capacity, in
``.superpowers/bootstrap/plans/2026-08-27-04-scheduler-budget-rate-policy.task-contracts.md``).

Provider rate capacity is an integer-unit budget per provider, analogous to
the money :class:`~kcc_autobuild.budget.BudgetLedger`, with one adaptive
twist: an observed HTTP 429 halves the provider's effective capacity (floor
of 1 unit) **before** the failure is classified as a rate limit / outage, so
burst absorption shrinks as the provider signals pressure. Prescribed
scenarios under test:

- a 429 observation halves effective capacity 4 -> 2 (minimum 1);
- a provider with capacity 1 makes tasks T1/T2 (each needing 1 unit) choose
  only T1 -- ``choose_reservable`` is deterministic.
"""

from __future__ import annotations

import pytest

from kcc_autobuild.rate_limit import (
    DuplicateReservation,
    NonPositiveUnits,
    OverCapacityReservation,
    RateCapacityLedger,
    RateDemand,
)


# --- Observed 429 halves effective capacity (minimum 1) ---------------------


def test_observed_429_halves_effective_capacity():
    ledger = RateCapacityLedger({"api": 4})
    assert ledger.effective_limit("api") == 4
    ledger.observe_429("api")
    assert ledger.observed_429 == {"api": 1}
    assert ledger.effective_limit("api") == 2


def test_observed_429_never_goes_below_one():
    ledger = RateCapacityLedger({"api": 1})
    assert ledger.effective_limit("api") == 1
    ledger.observe_429("api")
    ledger.observe_429("api")
    assert ledger.observed_429 == {"api": 2}
    assert ledger.effective_limit("api") == 1  # floor of 1, never 0


def test_repeated_429s_halve_stepwise_to_the_floor():
    ledger = RateCapacityLedger({"api": 8})
    ledger.observe_429("api")
    assert ledger.effective_limit("api") == 4
    ledger.observe_429("api")
    assert ledger.effective_limit("api") == 2
    ledger.observe_429("api")
    assert ledger.effective_limit("api") == 1
    ledger.observe_429("api")
    assert ledger.effective_limit("api") == 1


# --- choose_reservable: greedy, deterministic, simulates only ---------------


def test_provider_capacity_one_selects_only_t1():
    ledger = RateCapacityLedger({"api": 1})
    demands = {"T1": RateDemand("api"), "T2": RateDemand("api")}
    assert ledger.choose_reservable(demands) == {"T1": RateDemand("api")}
    # Repeated selection is byte-identical -- no map-iteration nondeterminism.
    assert ledger.choose_reservable(demands) == {"T1": RateDemand("api")}
    # Simulation never reserves: the ledger state is untouched.
    assert ledger.reservations == {}
    assert ledger.used("api") == 0


def test_choose_reservable_respects_per_provider_capacity():
    ledger = RateCapacityLedger({"api": 4, "docs": 2})
    demands = {
        "T2": RateDemand("api", 2),
        "T1": RateDemand("api", 1),
        "T3": RateDemand("docs", 3),
        "T4": RateDemand("docs", 1),
    }
    # Deterministic (task-id sorted) greedy selection: T1 + T2 fit the api
    # capacity; T3 needs 3 docs units but only 2 fit, so the independently
    # fitting T4 is still selected.
    assert ledger.choose_reservable(demands) == {
        "T1": RateDemand("api", 1),
        "T2": RateDemand("api", 2),
        "T4": RateDemand("docs", 1),
    }
    assert ledger.reservations == {}


def test_choose_reservable_skips_nothing_that_fits_exactly_at_capacity():
    ledger = RateCapacityLedger({"api": 2})
    demands = {"T1": RateDemand("api", 2), "T2": RateDemand("api", 1)}
    assert ledger.choose_reservable(demands) == {"T1": RateDemand("api", 2)}


def test_choose_reservable_unknown_provider_is_a_configuration_error():
    ledger = RateCapacityLedger({"api": 4})
    with pytest.raises(KeyError):
        ledger.choose_reservable({"T1": RateDemand("mystery", 1)})


# --- RateDemand value object ------------------------------------------------


def test_rate_demand_defaults_and_validation():
    demand = RateDemand("api")
    assert demand.provider_key == "api"
    assert demand.units == 1
    assert RateDemand("api", 3).units == 3
    for bad_units in (0, -1):
        with pytest.raises(NonPositiveUnits):
            RateDemand("api", bad_units)
    with pytest.raises(ValueError):
        RateDemand("", 1)
    # Demands are immutable value objects (FrozenInstanceError is an
    # AttributeError subclass).
    with pytest.raises(AttributeError):
        demand.units = 2  # type: ignore[misc]


# --- Ledger state: limits, effective_limit, used ---------------------------


def test_limits_are_public_and_capacity_must_be_positive():
    ledger = RateCapacityLedger({"api": 4, "docs": 2})
    assert ledger.limits == {"api": 4, "docs": 2}
    with pytest.raises(ValueError):
        RateCapacityLedger({"api": 0})
    with pytest.raises(ValueError):
        RateCapacityLedger({"api": -1})


def test_effective_limit_and_used_are_derived_per_provider():
    ledger = RateCapacityLedger({"api": 4, "docs": 2})
    ledger.reserve("T1", RateDemand("api", 1))
    ledger.reserve("T2", RateDemand("docs", 2))
    assert ledger.reservations == {
        "T1": RateDemand("api", 1),
        "T2": RateDemand("docs", 2),
    }
    assert ledger.used("api") == 1
    assert ledger.used("docs") == 2
    assert ledger.effective_limit("api") == 4
    assert ledger.effective_limit("docs") == 2
    with pytest.raises(KeyError):
        ledger.used("mystery")
    with pytest.raises(KeyError):
        ledger.effective_limit("mystery")
    with pytest.raises(KeyError):
        ledger.observe_429("mystery")


# --- can_fit -----------------------------------------------------------------


def test_can_fit_against_effective_capacity():
    ledger = RateCapacityLedger({"api": 4})
    assert ledger.can_fit("api")  # one unit by default
    assert ledger.can_fit("api", 4)
    assert not ledger.can_fit("api", 5)
    ledger.reserve("T1", RateDemand("api", 3))
    assert ledger.can_fit("api", 1)
    assert not ledger.can_fit("api", 2)
    # Halving after a reservation shrinks the capacity under the used units.
    ledger.observe_429("api")
    assert ledger.effective_limit("api") == 2
    assert not ledger.can_fit("api", 1)
    with pytest.raises(KeyError):
        ledger.can_fit("mystery", 1)
    with pytest.raises(NonPositiveUnits):
        ledger.can_fit("api", 0)


# --- reserve / release --------------------------------------------------------


def test_reserve_rejects_duplicate():
    ledger = RateCapacityLedger({"api": 4})
    ledger.reserve("T1", RateDemand("api", 1))
    with pytest.raises(DuplicateReservation):
        ledger.reserve("T1", RateDemand("api", 1))
    assert ledger.reservations == {"T1": RateDemand("api", 1)}
    assert ledger.used("api") == 1


def test_reserve_rejects_over_capacity():
    ledger = RateCapacityLedger({"api": 2})
    ledger.reserve("T1", RateDemand("api", 1))
    with pytest.raises(OverCapacityReservation):
        ledger.reserve("T2", RateDemand("api", 2))  # only 1 unit remains
    # The rejected reservation leaves the ledger untouched.
    assert ledger.reservations == {"T1": RateDemand("api", 1)}
    assert ledger.used("api") == 1
    assert ledger.can_fit("api", 1)
    assert not ledger.can_fit("api", 2)


def test_release_returns_the_demand_and_causes_no_spend():
    ledger = RateCapacityLedger({"api": 4})
    ledger.reserve("T1", RateDemand("api", 2))
    ledger.reserve("T2", RateDemand("api", 1))
    assert ledger.release("T1") == RateDemand("api", 2)
    # The unused reservation is returned: used does not grow, capacity is
    # usable again.
    assert ledger.used("api") == 1
    assert ledger.can_fit("api", 3)
    with pytest.raises(KeyError):
        ledger.release("T1")  # releasing twice is a bug, not a no-op
