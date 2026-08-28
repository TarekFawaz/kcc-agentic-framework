"""Adaptive provider rate capacity ledger for autobuild waves.

Plan 04, Task 2 (Adaptive provider rate capacity): the controller reserves
provider rate units for the selected wave set exactly once (the scheduler
only simulates; it never reserves), and the ledger enforces the per-provider
effective capacity for that reservation. An observed HTTP 429 halves the
provider's effective capacity (floor of 1 unit) **before** the failure is
classified as a rate limit / outage, so burst absorption shrinks as the
provider signals pressure; the 429 observation count is kept so the failure
classifier can later distinguish a transient rate limit from a repeated
429 outage.

The behavioral contract is owned by
:file:`.KCC/runtime/tests/test_rate_limit.py`:

- ``limits`` / ``observed_429`` / ``reservations`` are the ledger state;
  ``effective_limit`` (``limits[key] >> 429-count``, floor 1) and ``used``
  (sum of reserved units per provider) are derived.
- ``choose_reservable`` deterministically selects the subset of candidate
  demands that fits the per-provider effective capacity (sorted by task id,
  greedy) without mutating the ledger -- a simulation; the controller
  reserves the selected set afterwards.
- ``reserve`` rejects duplicate task ids and any reservation beyond the
  provider's effective capacity; ``release`` returns the unused reservation
  with no spend.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping


class RateError(ValueError):
    """Base class for rejected rate-capacity operations."""


class NonPositiveUnits(RateError):
    """Raised when a demand requests zero or negative units."""


class DuplicateReservation(RateError):
    """Raised when a task id already holds a rate reservation."""


class OverCapacityReservation(RateError):
    """Raised when a reservation exceeds the provider's effective capacity."""


@dataclass(frozen=True)
class RateDemand:
    """A task's request for ``units`` of one provider's rate capacity.

    ``units`` defaults to 1 so a bare ``RateDemand("api")`` expresses a
    single unit of provider ``api``. Demands are immutable value objects;
    they validate themselves at construction so ledger code can assume
    well-formed input.
    """

    provider_key: str
    units: int = 1

    def __post_init__(self) -> None:
        if not self.provider_key:
            raise ValueError("provider_key must be a non-empty string")
        if not isinstance(self.units, int) or isinstance(self.units, bool):
            raise TypeError(f"units must be an int, got {type(self.units).__name__}")
        if self.units < 1:
            raise NonPositiveUnits(f"units {self.units} must be positive")


class RateCapacityLedger:
    """Integer-unit rate capacity accounting, one reservation per task.

    Adapted from the money :class:`~kcc_autobuild.budget.BudgetLedger`:
    the controller reserves units for the chosen tasks exactly once, and
    the ledger is the sole authority on whether a task's provider demand
    fits the currently effective (possibly 429-degraded) capacity.
    """

    def __init__(self, limits: Mapping[str, int]) -> None:
        parsed: dict[str, int] = {}
        for provider_key, capacity in limits.items():
            if not isinstance(capacity, int) or isinstance(capacity, bool):
                raise TypeError(
                    f"limit for {provider_key!r} must be an int, "
                    f"got {type(capacity).__name__}"
                )
            if capacity < 1:
                raise ValueError(
                    f"limit for {provider_key!r} must be positive, got {capacity}"
                )
            parsed[provider_key] = capacity
        self.limits = parsed
        self.observed_429: dict[str, int] = {}
        self.reservations: dict[str, RateDemand] = {}

    def effective_limit(self, provider_key: str) -> int:
        """Provider capacity after any observed 429 halvings, floor 1.

        ``limits`` keeps the configured baseline; each observed 429
        right-shifts it once (``max(1, limit >> count)``) so effective
        capacity can never drop below 1 unit.
        """
        base = self.limits[provider_key]
        return max(1, base >> self.observed_429.get(provider_key, 0))

    def observe_429(self, provider_key: str) -> None:
        """Record a provider HTTP 429 before outage classification.

        Each observation halves ``effective_limit`` (minimum 1); the count
        is kept as public state so the failure classifier can decide later
        whether repeated 429s constitute an outage.
        """
        if provider_key not in self.limits:
            raise KeyError(provider_key)
        self.observed_429[provider_key] = self.observed_429.get(provider_key, 0) + 1

    def used(self, provider_key: str) -> int:
        """Units currently reserved against ``provider_key`` (derived)."""
        if provider_key not in self.limits:
            raise KeyError(provider_key)
        total = 0
        for demand in self.reservations.values():
            if demand.provider_key == provider_key:
                total += demand.units
        return total

    def can_fit(self, provider_key: str, units: int = 1) -> bool:
        """Whether ``units`` more can be reserved for ``provider_key``.

        A single reserved unit is the default, mirroring
        :class:`RateDemand`. Nonpositive requests are rejected, not treated
        as fitting.
        """
        if not isinstance(units, int) or isinstance(units, bool):
            raise TypeError(f"units must be an int, got {type(units).__name__}")
        if units < 1:
            raise NonPositiveUnits(f"units {units} must be positive")
        return self.used(provider_key) + units <= self.effective_limit(provider_key)

    def choose_reservable(
        self, demands: Mapping[str, RateDemand]
    ) -> dict[str, RateDemand]:
        """Deterministically select the subset of demands that fits capacity.

        Demands are considered in ascending task-id order (stable tie-break)
        and each task is selected only if its demand still fits in the
        remaining effective capacity of its provider. Unknown providers are
        configuration errors and raise :class:`KeyError`. The ledger is left
        untouched: this is a simulation; the controller reserves the selected
        set afterwards.
        """
        selected: dict[str, RateDemand] = {}
        # Scratch accounting per provider: base reservations plus what the
        # simulation has already selected. Never written to the ledger.
        simulated: dict[str, int] = {}
        for task_id in sorted(demands):
            demand = demands[task_id]
            if not isinstance(demand, RateDemand):
                raise TypeError(
                    f"demand for {task_id!r} must be a RateDemand, "
                    f"got {type(demand).__name__}"
                )
            if demand.units < 1:
                raise NonPositiveUnits(f"units {demand.units} must be positive")
            provider_key = demand.provider_key
            if provider_key not in self.limits:
                raise KeyError(provider_key)
            used = self.used(provider_key) + simulated.get(provider_key, 0)
            if used + demand.units <= self.effective_limit(provider_key):
                selected[task_id] = demand
                simulated[provider_key] = simulated.get(provider_key, 0) + demand.units
        return selected

    def reserve(self, task_id: str, demand: RateDemand) -> None:
        """Reserve ``demand`` for ``task_id`` exactly once.

        Rejected with :class:`DuplicateReservation` when the task already
        holds a reservation and :class:`OverCapacityReservation` when the
        demand would push the provider's reserved units beyond its effective
        capacity. Unknown providers are configuration errors and raise
        :class:`KeyError`.
        """
        if task_id in self.reservations:
            raise DuplicateReservation(f"task {task_id!r} already reserved")
        if not isinstance(demand, RateDemand):
            raise TypeError(
                f"demand must be a RateDemand, got {type(demand).__name__}"
            )
        if demand.units < 1:
            raise NonPositiveUnits(f"units {demand.units} must be positive")
        provider_key = demand.provider_key
        if provider_key not in self.limits:
            raise KeyError(provider_key)
        if self.used(provider_key) + demand.units > self.effective_limit(provider_key):
            raise OverCapacityReservation(
                f"reservation {demand.units} for {provider_key!r} exceeds "
                f"effective capacity {self.effective_limit(provider_key)}"
            )
        self.reservations[task_id] = demand

    def release(self, task_id: str) -> RateDemand:
        """Release the unused reservation for ``task_id`` (no spend).

        Returns the released :class:`RateDemand` so the caller can record
        it. Raises :class:`KeyError` when the task holds no reservation --
        releasing twice is a bug, not a no-op (no double reserve).
        """
        return self.reservations.pop(task_id)
