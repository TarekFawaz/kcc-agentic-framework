"""Behavioral contract for the autobuild money budget ledger.

Owned by ``test_budget.py`` (see the KCC x Superpowers Hybrid Framework
Plan 04, Task 1: Money reservations / wave shrinking, in
``.superpowers/bootstrap/plans/2026-08-27-04-scheduler-budget-rate-policy.task-contracts.md``).

All money arithmetic is :class:`decimal.Decimal` so budget checks are exact
(no binary float drift). Prescribed scenarios under test:

- a parallel subset of candidate demands fits under the hard cap
  (``choose_reservable`` is deterministic);
- reconcile of an unused reserve settles it into ``actual``;
- release returns the unused reservation and causes no spend.
"""

from decimal import Decimal

import pytest

from kcc_autobuild.budget import (
    BudgetBreach,
    BudgetLedger,
    DuplicateReservation,
    NonPositiveReservation,
    OverCapReservation,
)


def test_choose_reservable_parallel_subset_fits_under_hard_cap():
    ledger = BudgetLedger(Decimal("10.00"))
    demands = {
        "T3": Decimal("4.00"),
        "T1": Decimal("6.00"),
        "T4": Decimal("2.00"),
        "T2": Decimal("4.00"),
    }
    # Deterministic (task-id sorted) greedy selection: T1 + T2 fit exactly;
    # the remaining T3/T4 demands cannot fit and are left out of the wave.
    assert ledger.choose_reservable(demands) == {
        "T1": Decimal("6.00"),
        "T2": Decimal("4.00"),
    }
    # Repeated selection is byte-identical -- no map-iteration nondeterminism.
    assert ledger.choose_reservable(demands) == {
        "T1": Decimal("6.00"),
        "T2": Decimal("4.00"),
    }
    # Simulation never reserves: the ledger state is untouched.
    assert ledger.actual == Decimal("0.00")
    assert ledger.reserved == Decimal("0.00")
    assert ledger.available == Decimal("10.00")


def test_choose_reservable_respects_spent_and_reserved_capacity():
    ledger = BudgetLedger(Decimal("10.00"))
    ledger.reserve("T0", Decimal("6.00"))
    assert ledger.available == Decimal("4.00")
    assert ledger.choose_reservable(
        {"T1": Decimal("5.00"), "T2": Decimal("3.00"), "T3": Decimal("2.00")}
    ) == {"T2": Decimal("3.00")}
    # After the reserved wave settles as spend, only the remaining capacity
    # can be selected.
    ledger.reconcile(Decimal("6.00"))
    assert ledger.actual == Decimal("6.00")
    assert ledger.available == Decimal("4.00")
    assert ledger.choose_reservable(
        {"T1": Decimal("5.00"), "T2": Decimal("3.00")}
    ) == {"T2": Decimal("3.00")}


def test_choose_reservable_skips_nonpositive_demands():
    ledger = BudgetLedger(Decimal("10.00"))
    demands = {"T1": Decimal("5.00"), "T2": Decimal("0.00"), "T3": Decimal("-2.00")}
    assert ledger.choose_reservable(demands) == {"T1": Decimal("5.00")}


def test_budget_uses_decimal_arithmetic_without_float_drift():
    ledger = BudgetLedger(Decimal("0.30"))
    for task in ("T1", "T2", "T3"):
        ledger.reserve(task, Decimal("0.10"))
    assert ledger.reserved == Decimal("0.30")
    with pytest.raises(OverCapReservation):
        ledger.reserve("T4", Decimal("0.10"))


def test_reserved_and_available_are_derived():
    ledger = BudgetLedger(Decimal("10.00"), safety_margin=Decimal("1.50"))
    assert ledger.actual == Decimal("0.00")
    assert ledger.reserved == Decimal("0.00")
    assert ledger.available == Decimal("8.50")  # hard_cap - safety_margin
    ledger.reserve("T1", Decimal("4.00"))
    ledger.reserve("T2", Decimal("3.00"))
    assert ledger.reserved == Decimal("7.00")  # sum of reservations, derived
    assert ledger.available == Decimal("1.50")
    assert ledger.actual == Decimal("0.00")


def test_safety_margin_must_not_be_negative():
    with pytest.raises(ValueError):
        BudgetLedger(Decimal("10.00"), safety_margin=Decimal("-1.00"))


def test_reserve_rejects_duplicate():
    ledger = BudgetLedger(Decimal("10.00"))
    ledger.reserve("T1", Decimal("3.00"))
    with pytest.raises(DuplicateReservation):
        ledger.reserve("T1", Decimal("1.00"))
    assert ledger.reservations == {"T1": Decimal("3.00")}
    assert ledger.available == Decimal("7.00")


def test_reserve_rejects_nonpositive_amount():
    ledger = BudgetLedger(Decimal("10.00"))
    for bad in (Decimal("0.00"), Decimal("-1.00")):
        with pytest.raises(NonPositiveReservation):
            ledger.reserve("T1", bad)
    assert ledger.reservations == {}
    assert ledger.available == Decimal("10.00")


def test_reserve_rejects_over_cap():
    ledger = BudgetLedger(Decimal("10.00"))
    ledger.reserve("T1", Decimal("6.00"))
    with pytest.raises(OverCapReservation):
        ledger.reserve("T2", Decimal("5.00"))  # only 4.00 remains available
    # The rejected reservation leaves the ledger untouched.
    assert ledger.reservations == {"T1": Decimal("6.00")}
    assert ledger.reserved == Decimal("6.00")
    assert ledger.available == Decimal("4.00")


def test_reconcile_of_an_unused_reserve():
    ledger = BudgetLedger(Decimal("10.00"))
    ledger.reserve("T1", Decimal("4.00"))
    assert ledger.reserved == Decimal("4.00")
    assert ledger.actual == Decimal("0.00")
    # The provider reported no spend; reconcile still settles the unused
    # (never released) reservation into actual and does not halt.
    settled = ledger.reconcile(Decimal("0.00"))
    assert settled == Decimal("4.00")
    assert ledger.reservations == {}
    assert ledger.reserved == Decimal("0.00")
    assert ledger.actual == Decimal("4.00")
    assert ledger.available == Decimal("6.00")


def test_reconcile_halts_when_provider_actual_breaches_hard_cap():
    ledger = BudgetLedger(Decimal("10.00"))
    ledger.reserve("T1", Decimal("3.00"))
    with pytest.raises(BudgetBreach) as excinfo:
        ledger.reconcile(Decimal("10.01"))
    assert excinfo.value.provider_actual == Decimal("10.01")
    assert excinfo.value.hard_cap == Decimal("10.00")
    # Settlement was applied before the halt signal, so retrying cannot
    # double-charge the reservation.
    assert ledger.actual == Decimal("3.00")
    assert ledger.reserved == Decimal("0.00")


def test_reconcile_does_not_halt_at_exactly_the_hard_cap():
    ledger = BudgetLedger(Decimal("10.00"))
    ledger.reserve("T1", Decimal("3.00"))
    assert ledger.reconcile(Decimal("10.00")) == Decimal("3.00")
    assert ledger.actual == Decimal("3.00")


def test_release_causes_no_spend():
    ledger = BudgetLedger(Decimal("10.00"))
    ledger.reserve("T1", Decimal("4.00"))
    ledger.reserve("T2", Decimal("2.00"))
    assert ledger.release("T1") == Decimal("4.00")
    # The unused reservation is returned: actual does not move.
    assert ledger.actual == Decimal("0.00")
    assert ledger.reserved == Decimal("2.00")
    assert ledger.available == Decimal("8.00")  # released money is usable again


def test_release_of_unknown_reservation_raises():
    ledger = BudgetLedger(Decimal("10.00"))
    with pytest.raises(KeyError):
        ledger.release("T1")
