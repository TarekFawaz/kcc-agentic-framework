"""Money-reservation budget ledger for autobuild waves.

Plan 04, Task 1 (Money reservations / wave shrinking): the controller
reserves money for the selected wave set exactly once (the scheduler only
simulates; it never reserves), and the ledger enforces the hard cap for
that reservation and reconciles provider truth afterwards.

All amounts are :class:`decimal.Decimal` so cap checks are exact. The
behavioral contract is owned by :file:`.KCC/runtime/tests/test_budget.py`:

- ``hard_cap`` / ``safety_margin`` / ``actual`` / ``reservations`` are the
  ledger state; ``reserved`` (sum of reservations) and ``available``
  (``hard_cap - safety_margin - actual - reserved``) are derived.
- ``choose_reservable`` deterministically selects the subset of candidate
  demands that fits in ``available`` (sorted by task id, greedy).
- ``reserve`` rejects duplicate task ids, nonpositive amounts and any
  reservation that would go over the cap.
- ``reconcile`` settles every outstanding reservation into ``actual`` and
  halts (raises :class:`BudgetBreach`) when the provider-reported actual
  breaches the hard cap; settlement is applied before the halt so a retry
  never double-charges.
- ``release`` returns the unused reservation to the pool with no spend.
"""

from __future__ import annotations

from decimal import Decimal
from typing import Mapping


class BudgetError(ValueError):
    """Base class for rejected budget operations."""


class DuplicateReservation(BudgetError):
    """Raised when a task id already holds a reservation."""


class NonPositiveReservation(BudgetError):
    """Raised when a reservation amount is zero or negative."""


class OverCapReservation(BudgetError):
    """Raised when a reservation would exceed the available capacity."""


class BudgetBreach(RuntimeError):
    """Halt signal: the provider-reported actual breached the hard cap.

    The control plane catches this to freeze the wave (E3 -- hard budget
    cap would be exceeded) after the ledger books are settled.
    """

    def __init__(self, provider_actual: Decimal, hard_cap: Decimal) -> None:
        self.provider_actual = provider_actual
        self.hard_cap = hard_cap
        super().__init__(
            f"provider actual {provider_actual} breaches hard cap {hard_cap}"
        )


class BudgetLedger:
    """Exact Decimal accounting of money reserved and spent per wave."""

    def __init__(
        self,
        hard_cap: Decimal,
        safety_margin: Decimal = Decimal("0"),
    ) -> None:
        self.hard_cap = Decimal(hard_cap)
        self.safety_margin = Decimal(safety_margin)
        if self.safety_margin < 0:
            raise ValueError("safety_margin must not be negative")
        self.actual = Decimal("0")
        self.reservations: dict[str, Decimal] = {}

    @property
    def reserved(self) -> Decimal:
        """Total money currently reserved (derived from ``reservations``)."""
        total = Decimal("0")
        for amount in self.reservations.values():
            total += amount
        return total

    @property
    def available(self) -> Decimal:
        """Money that can still be reserved or spent.

        Derived as ``hard_cap - safety_margin - actual - reserved``: the
        safety margin is deliberately held back so spending can never run
        straight into the hard cap and trip an avoidable breach.
        """
        return self.hard_cap - self.safety_margin - self.actual - self.reserved

    def choose_reservable(
        self, demands: Mapping[str, Decimal]
    ) -> dict[str, Decimal]:
        """Deterministically select the subset of demands that fits the cap.

        Demands are considered in ascending task-id order (stable tie-break
        for equal amounts) and each demand is selected only if it still fits
        in the remaining available capacity. Nonpositive demands can never
        be reserved and are skipped. The ledger is left untouched: this is
        a simulation; the controller reserves the selected set afterwards.
        """
        selected: dict[str, Decimal] = {}
        remaining = self.available
        for task_id in sorted(demands):
            amount = Decimal(demands[task_id])
            if amount <= 0:
                continue
            if amount <= remaining:
                selected[task_id] = amount
                remaining -= amount
        return selected

    def reserve(self, task_id: str, amount: Decimal) -> None:
        """Reserve ``amount`` for ``task_id`` exactly once.

        Rejected with :class:`DuplicateReservation` when the task already
        holds a reservation, :class:`NonPositiveReservation` when the amount
        is not positive, and :class:`OverCapReservation` when the amount
        would push reserved plus spent beyond the available capacity.
        """
        if task_id in self.reservations:
            raise DuplicateReservation(f"task {task_id!r} already reserved")
        amount = Decimal(amount)
        if amount <= 0:
            raise NonPositiveReservation(f"amount {amount} must be positive")
        if amount > self.available:
            raise OverCapReservation(
                f"reservation {amount} exceeds available {self.available}"
            )
        self.reservations[task_id] = amount

    def release(self, task_id: str) -> Decimal:
        """Release the unused reservation for ``task_id`` (no spend).

        Returns the released amount so the caller can record it. Raises
        :class:`KeyError` when the task holds no reservation -- releasing
        twice is a bug, not a no-op (no double reserve).
        """
        return self.reservations.pop(task_id)

    def reconcile(self, provider_actual: Decimal) -> Decimal:
        """Settle outstanding reservations as spend and check the hard cap.

        Every outstanding reservation is released from ``reservations`` and
        moved into ``actual`` (the reserved money is confirmed as spent and
        is no longer available). Then, if the provider-reported actual
        breaches the hard cap, the ledger halts by raising
        :class:`BudgetBreach`; settlement is applied first so the books are
        never left half-applied and a retry cannot double-charge.

        Returns the settled ``actual``.
        """
        settled = self.reserved
        self.actual += settled
        self.reservations.clear()
        provider_actual = Decimal(provider_actual)
        if provider_actual > self.hard_cap:
            raise BudgetBreach(provider_actual, self.hard_cap)
        return self.actual
