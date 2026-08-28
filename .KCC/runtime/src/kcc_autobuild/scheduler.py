"""Dependency-closed wave scheduler for autobuild tasks.

Plan 04, Task 3 (Dependency-closed wave scheduler): the controller owns task
and wave scheduling, and it reserves money/rate for the selected wave set
exactly once afterwards. This module is the *pure decision function* for
that: it only simulates -- it never reserves (no double reserve).

Plan 08, Task 2 (Capability registry + generic compatibility mode): the
scheduler's harness decision consumes capability/strategy only, never a
hardcoded CLI name list.  :meth:`Scheduler.select_harness` picks the
harness for the next dispatch from the registry's probe outcomes
(detected + capability score + minimum strategy), and
:meth:`Scheduler.next_dispatch_set` carries that choice on the wave as
``DispatchDecision.harness_id`` -- the controller dispatches the wave on
the proven capability/strategy, not on a bare CLI name.

The behavioral contract is owned by :file:`.KCC/runtime/tests/test_scheduler.py`:

- :class:`TaskSpec` is a frozen value object describing one pending task
  (``id``, ``depends_on``, ``budget_ceiling``, ``rate_demands``).
- :class:`Scheduler.next_dispatch_set` takes the already-passed task ids,
  the pending :class:`TaskSpec` set, the money
  :class:`~kcc_autobuild.budget.BudgetLedger` and the rate
  :class:`~kcc_autobuild.rate_limit.RateCapacityLedger`, and returns a
  :class:`DispatchDecision` for the next wave:
  - **only dependency-ready tasks** (every ``depends_on`` id has passed);
  - a **deterministic sort** (task id ascending, greedy) so identical inputs
    always yield an identical wave;
  - the **simulated remaining money/rate** after the selected set, computed
    from the ledgers' derived available/effective state without mutating
    them;
  - the optional **capability-selected harness** (``harness`` argument)
    whose id is carried on the decision as ``harness_id``.

A task whose dependency or provider demand is unknown (neither passed nor
pending; provider absent from the rate limits) is a broken run contract and
raises :class:`KeyError` -- the scheduler refuses to guess. Dependency
cycles are simply never ready.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Iterable, Mapping

from kcc_autobuild.budget import BudgetLedger
from kcc_autobuild.harnesses.models import ExecutionStrategy
from kcc_autobuild.harnesses.registry import HarnessRegistry, HarnessSelection
from kcc_autobuild.rate_limit import RateCapacityLedger, RateDemand


def _as_tuple(items: Iterable[str], what: str) -> tuple[str, ...]:
    """Normalize an iterable of identifiers into a validated tuple."""
    parsed: list[str] = []
    for item in items:
        if not isinstance(item, str) or not item:
            raise ValueError(f"{what} entries must be non-empty strings")
        parsed.append(item)
    return tuple(parsed)


@dataclass(frozen=True)
class TaskSpec:
    """One task competing for a slot in the next dispatch wave.

    ``budget_ceiling`` is the maximum the task may cost; the scheduler uses
    it as the simulated reservation amount (the controller reserves exactly
    this later). ``rate_demands`` are the provider units the task needs at
    once; duplicate provider demands are rejected because a task occupies
    one combined slot per provider.
    """

    id: str
    budget_ceiling: Decimal
    depends_on: tuple[str, ...] = ()
    rate_demands: tuple[RateDemand, ...] = ()

    def __post_init__(self) -> None:
        if not isinstance(self.id, str) or not self.id:
            raise ValueError("id must be a non-empty string")
        ceiling = Decimal(self.budget_ceiling)
        if ceiling <= 0:
            raise ValueError(f"budget_ceiling must be positive, got {ceiling}")
        object.__setattr__(self, "budget_ceiling", ceiling)
        object.__setattr__(self, "depends_on", _as_tuple(self.depends_on, "depends_on"))
        demands: list[RateDemand] = []
        providers: set[str] = set()
        for demand in self.rate_demands:
            if not isinstance(demand, RateDemand):
                raise TypeError(
                    f"rate_demands entries must be RateDemand, "
                    f"got {type(demand).__name__}"
                )
            if demand.provider_key in providers:
                raise ValueError(
                    f"duplicate rate demand for provider {demand.provider_key!r}"
                )
            providers.add(demand.provider_key)
            demands.append(demand)
        object.__setattr__(self, "rate_demands", tuple(demands))


@dataclass(frozen=True)
class DispatchDecision:
    """The next wave as the scheduler simulated it.

    ``task_ids`` are the selected tasks in deterministic dispatch order
    (task id ascending). ``remaining_money`` / ``remaining_rate`` are the
    simulated leftovers for the next wave -- the ledgers themselves are
    untouched; the controller reserves the selected set exactly once.
    ``harness_id`` is the capability-selected harness the wave will
    dispatch on (``None`` when no harness decision was supplied): the
    scheduler consumes capability/strategy, never a hardcoded CLI name.
    """

    task_ids: tuple[str, ...]
    remaining_money: Decimal
    remaining_rate: Mapping[str, int]
    harness_id: str | None = None


class Scheduler:
    """Stateless, pure dependency-closed wave scheduler.

    No ledger is ever mutated: every call is a simulation, so identical
    inputs produce byte-identical decisions and the controller alone decides
    when to reserve.  The harness decision consumes capability/strategy
    only (Plan 08, Task 2) -- never a hardcoded CLI name list.
    """

    @staticmethod
    def select_harness(
        registry: HarnessRegistry,
        *,
        requested: str | None = None,
        min_strategy: ExecutionStrategy = ExecutionStrategy.LOCAL,
    ) -> HarnessSelection:
        """Decide which harness the next dispatch runs on (capability-only).

        Consumes the :class:`HarnessRegistry` probe outcomes: only
        detected harnesses are candidates, ranked by their capability
        score and bounded by ``min_strategy``; ``requested`` (when set)
        must be detected and usable or the call raises
        :class:`~kcc_autobuild.harnesses.HarnessError` (fail closed,
        never a silent fallback).  No CLI name preference exists here --
        the decision is made from proven capabilities/strategy alone.
        """
        if not isinstance(registry, HarnessRegistry):
            raise TypeError(
                f"registry must be a HarnessRegistry, got {type(registry).__name__}"
            )
        return registry.select(requested=requested, min_strategy=min_strategy)

    @staticmethod
    def next_dispatch_set(
        passed: Iterable[str],
        active: Iterable[TaskSpec],
        budget: BudgetLedger,
        rate: RateCapacityLedger,
        *,
        harness: HarnessSelection | None = None,
    ) -> DispatchDecision:
        """Select the next dependency-closed, budget/rate-constrained wave.

        ``passed`` are the task ids whose evidence has been verified
        (dependencies are satisfied only by passed tasks -- a task never
        joins the same wave as its dependencies). ``active`` are the pending
        :class:`TaskSpec` candidates. The result contains only dependency-
        ready tasks in deterministic (task id ascending) order, each fitting
        in the money and rate remaining after the previously selected tasks.

        ``harness`` is the capability-selected harness for the wave (see
        :meth:`select_harness`); its id is carried on the decision as
        ``harness_id`` so the wave dispatches on proven
        capability/strategy rather than a hardcoded CLI name.
        """
        if harness is not None and not isinstance(harness, HarnessSelection):
            raise TypeError(
                f"harness must be a HarnessSelection, got {type(harness).__name__}"
            )
        if not isinstance(budget, BudgetLedger):
            raise TypeError(
                f"budget must be a BudgetLedger, got {type(budget).__name__}"
            )
        if not isinstance(rate, RateCapacityLedger):
            raise TypeError(
                f"rate must be a RateCapacityLedger, got {type(rate).__name__}"
            )

        passed_ids = set(passed)
        active_specs: dict[str, TaskSpec] = {}
        for spec in active:
            if not isinstance(spec, TaskSpec):
                raise TypeError(
                    f"active entries must be TaskSpec, got {type(spec).__name__}"
                )
            active_specs[spec.id] = spec

        # Validate the task universe first: every dependency must be either
        # already passed or still pending, and every demanded provider must
        # be a configured rate limit. Broken contracts raise before any
        # dispatch is considered (fail closed, no guessing).
        known = passed_ids | set(active_specs)
        for spec in active_specs.values():
            for dependency in spec.depends_on:
                if dependency not in known:
                    raise KeyError(
                        f"task {spec.id!r} depends on unknown task {dependency!r}"
                    )
            for demand in spec.rate_demands:
                if demand.provider_key not in rate.limits:
                    raise KeyError(demand.provider_key)

        # Simulation scratch space, derived from -- never written to -- the
        # ledgers.
        money_remaining = budget.available
        rate_remaining = {
            provider_key: rate.effective_limit(provider_key)
            for provider_key in rate.limits
        }

        selected: list[str] = []
        for task_id in sorted(active_specs):
            spec = active_specs[task_id]
            if task_id in passed_ids:
                continue  # already verified; never re-dispatched
            if any(dependency not in passed_ids for dependency in spec.depends_on):
                continue  # not dependency-ready
            if spec.budget_ceiling > money_remaining:
                continue  # does not fit the remaining money
            if any(
                demand.units > rate_remaining[demand.provider_key]
                for demand in spec.rate_demands
            ):
                continue  # does not fit the remaining rate capacity
            # The task fits: simulate the reservation without reserving.
            selected.append(task_id)
            money_remaining -= spec.budget_ceiling
            for demand in spec.rate_demands:
                rate_remaining[demand.provider_key] -= demand.units

        return DispatchDecision(
            task_ids=tuple(selected),
            remaining_money=money_remaining,
            remaining_rate=rate_remaining,
            harness_id=harness.harness_id if harness is not None else None,
        )
