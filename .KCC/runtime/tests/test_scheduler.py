"""Behavioral contract for the dependency-closed wave scheduler.

Owned by ``test_scheduler.py`` (see the KCC x Superpowers Hybrid Framework
Plan 04, Task 3: Dependency-closed wave scheduler, in
``.superpowers/bootstrap/plans/2026-08-27-04-scheduler-budget-rate-policy.task-contracts.md``).

The scheduler is a pure decision function: given the tasks that have already
passed, the pending :class:`~kcc_autobuild.scheduler.TaskSpec` set, the money
:class:`~kcc_autobuild.budget.BudgetLedger` and the rate
:class:`~kcc_autobuild.rate_limit.RateCapacityLedger`, it returns the
:class:`~kcc_autobuild.scheduler.DispatchDecision` for the next wave. It
returns **only dependency-ready tasks**, in a deterministic sort, and it
simulates the remaining money and rate for the selected set WITHOUT
reserving anything -- the controller reserves the selected set exactly once
afterwards (no double reserve).

Prescribed scenario under test: T1/T2 each cost 3 with API demand 1, T3
depends on T1/T2, API capacity 1 => only T1 is dispatched.
"""

from __future__ import annotations

from decimal import Decimal

import pytest

from kcc_autobuild.budget import BudgetLedger
from kcc_autobuild.rate_limit import RateCapacityLedger, RateDemand
from kcc_autobuild.scheduler import DispatchDecision, Scheduler, TaskSpec


# --- Prescribed scenario: dependency closure + rate capacity ---------------


def test_prescribed_scenario_dispatches_only_t1():
    rate = RateCapacityLedger({"api": 1})
    budget = BudgetLedger(Decimal("10.00"))
    active = [
        TaskSpec(
            "T1", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)
        ),
        TaskSpec(
            "T3",
            depends_on=("T1", "T2"),
            budget_ceiling=Decimal("3"),
            rate_demands=(RateDemand("api"),),
        ),
        TaskSpec(
            "T2", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)
        ),
    ]
    decision = Scheduler.next_dispatch_set(passed=(), active=active, budget=budget, rate=rate)
    # T3 is not dependency-ready (needs T1 AND T2 passed). T1 and T2 are both
    # ready and both fit the money, but the API capacity of 1 unit admits
    # exactly one of them, so the deterministic (task-id sorted) wave is T1.
    assert decision.task_ids == ("T1",)
    assert decision.remaining_money == Decimal("7.00")
    assert decision.remaining_rate == {"api": 0}


# --- Determinism -------------------------------------------------------------


def test_next_dispatch_set_is_deterministic():
    budget = BudgetLedger(Decimal("10.00"))
    rate = RateCapacityLedger({"api": 2, "docs": 2})
    specs = [
        TaskSpec("T2", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
        TaskSpec("T1", budget_ceiling=Decimal("2"), rate_demands=(RateDemand("docs"),)),
    ]
    first = Scheduler.next_dispatch_set((), specs, budget, rate)
    # Shuffled input order yields a byte-identical decision: task-id sort.
    shuffled = Scheduler.next_dispatch_set((), list(reversed(specs)), budget, rate)
    assert first == shuffled
    assert first == DispatchDecision(
        task_ids=("T1", "T2"),
        remaining_money=Decimal("5.00"),
        remaining_rate={"api": 1, "docs": 1},
    )
    # Repeated calls are byte-identical -- no map-iteration nondeterminism.
    assert Scheduler.next_dispatch_set((), specs, budget, rate) == first


# --- Dependency readiness ----------------------------------------------------


def test_dependency_gates_readiness():
    budget = BudgetLedger(Decimal("20.00"))
    rate = RateCapacityLedger({"api": 4})
    active = [
        TaskSpec("T1", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
        TaskSpec(
            "T2",
            depends_on=("T1",),
            budget_ceiling=Decimal("3"),
            rate_demands=(RateDemand("api"),),
        ),
    ]
    # T2 waits for T1: with nothing passed only T1 is ready.
    assert Scheduler.next_dispatch_set((), active, budget, rate).task_ids == ("T1",)
    # After T1 passes, T2 becomes dependency-ready and joins the next wave.
    assert Scheduler.next_dispatch_set(("T1",), active, budget, rate).task_ids == (
        "T2",
    )


def test_stale_dependent_waves_accumulate():
    budget = BudgetLedger(Decimal("10.00"))
    rate = RateCapacityLedger({"api": 2})
    active = [
        TaskSpec("T1", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
        TaskSpec("T2", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
        TaskSpec(
            "T3",
            depends_on=("T1", "T2"),
            budget_ceiling=Decimal("3"),
            rate_demands=(RateDemand("api"),),
        ),
    ]
    # With both dependencies passed, T3 joins the wave alongside any remaining
    # ready tasks in deterministic task-id order.
    decision = Scheduler.next_dispatch_set(("T1", "T2"), active, budget, rate)
    assert decision.task_ids == ("T3",)
    assert decision.remaining_money == Decimal("7.00")


def test_unknown_dependency_is_a_configuration_error():
    budget = BudgetLedger(Decimal("10.00"))
    rate = RateCapacityLedger({"api": 1})
    active = [
        TaskSpec(
            "T3",
            depends_on=("T9",),
            budget_ceiling=Decimal("3"),
            rate_demands=(RateDemand("api"),),
        )
    ]
    # A dependency that is neither passed nor pending is a broken run
    # contract: the scheduler refuses to guess rather than hang the wave.
    with pytest.raises(KeyError):
        Scheduler.next_dispatch_set((), active, budget, rate)


def test_dependency_cycle_is_simply_not_ready():
    budget = BudgetLedger(Decimal("10.00"))
    rate = RateCapacityLedger({"api": 2})
    active = [
        TaskSpec("T1", depends_on=("T2",), budget_ceiling=Decimal("3")),
        TaskSpec("T2", depends_on=("T1",), budget_ceiling=Decimal("3")),
    ]
    # A cycle never becomes dependency-ready; the wave stays empty (leases and
    # timeouts in the controller handle the stuck run, not the scheduler).
    assert Scheduler.next_dispatch_set((), active, budget, rate).task_ids == ()


# --- Money simulation --------------------------------------------------------


def test_budget_ceiling_shrinks_the_wave_to_what_fits():
    budget = BudgetLedger(Decimal("5.00"))
    rate = RateCapacityLedger({"api": 4})
    active = [
        TaskSpec("T1", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
        TaskSpec("T2", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
    ]
    decision = Scheduler.next_dispatch_set((), active, budget, rate)
    assert decision.task_ids == ("T1",)  # T2 needs 3 but only 2 remain
    assert decision.remaining_money == Decimal("2.00")


def test_budget_ceiling_fits_exactly_at_the_remaining_money():
    budget = BudgetLedger(Decimal("6.00"))
    rate = RateCapacityLedger({"api": 4})
    active = [
        TaskSpec("T1", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
        TaskSpec("T2", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
    ]
    decision = Scheduler.next_dispatch_set((), active, budget, rate)
    assert decision.task_ids == ("T1", "T2")
    assert decision.remaining_money == Decimal("0.00")


def test_money_is_simulated_from_the_ledger_available():
    budget = BudgetLedger(Decimal("10.00"))
    budget.reserve("T0", Decimal("4.00"))  # already reserved by the controller
    rate = RateCapacityLedger({"api": 4})
    active = [
        TaskSpec("T1", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
        TaskSpec("T2", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
    ]
    decision = Scheduler.next_dispatch_set((), active, budget, rate)
    # Simulation starts at available (10 - 4 = 6), so both fit exactly.
    assert decision.task_ids == ("T1", "T2")
    assert decision.remaining_money == Decimal("0.00")


def test_money_simulation_is_decimal_exact():
    budget = BudgetLedger(Decimal("0.30"))
    rate = RateCapacityLedger({"api": 3})
    active = [
        TaskSpec("T1", budget_ceiling=Decimal("0.10"), rate_demands=(RateDemand("api"),)),
        TaskSpec("T2", budget_ceiling=Decimal("0.10"), rate_demands=(RateDemand("api"),)),
        TaskSpec("T3", budget_ceiling=Decimal("0.10"), rate_demands=(RateDemand("api"),)),
    ]
    decision = Scheduler.next_dispatch_set((), active, budget, rate)
    assert decision.task_ids == ("T1", "T2", "T3")
    assert decision.remaining_money == Decimal("0.00")  # no float drift


# --- Rate simulation ---------------------------------------------------------


def test_rate_capacity_limits_the_wave():
    budget = BudgetLedger(Decimal("10.00"))
    rate = RateCapacityLedger({"api": 1})
    active = [
        TaskSpec("T1", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
        TaskSpec("T2", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
    ]
    decision = Scheduler.next_dispatch_set((), active, budget, rate)
    assert decision.task_ids == ("T1",)
    assert decision.remaining_rate == {"api": 0}
    assert decision.remaining_money == Decimal("7.00")


def test_rate_simulation_never_goes_negative():
    budget = BudgetLedger(Decimal("10.00"))
    rate = RateCapacityLedger({"api": 1})
    active = [
        TaskSpec(
            "T1",
            budget_ceiling=Decimal("3"),
            rate_demands=(RateDemand("api", 2),),
        )
    ]
    decision = Scheduler.next_dispatch_set((), active, budget, rate)
    assert decision.task_ids == ()
    assert decision.remaining_rate == {"api": 1}  # untouched


def test_rate_simulation_uses_effective_capacity_after_429():
    budget = BudgetLedger(Decimal("10.00"))
    rate = RateCapacityLedger({"api": 4})
    rate.observe_429("api")  # effective capacity 4 -> 2
    active = [
        TaskSpec(
            f"T{i}", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)
        )
        for i in (1, 2, 3)
    ]
    decision = Scheduler.next_dispatch_set((), active, budget, rate)
    assert decision.task_ids == ("T1", "T2")  # halved capacity admits two
    assert decision.remaining_rate == {"api": 0}


def test_multi_provider_demands_must_all_fit_jointly():
    budget = BudgetLedger(Decimal("10.00"))
    rate = RateCapacityLedger({"api": 1, "docs": 1})
    active = [
        TaskSpec(
            "T1",
            budget_ceiling=Decimal("3"),
            rate_demands=(RateDemand("api"), RateDemand("docs")),
        ),
        TaskSpec("T2", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("docs"),)),
    ]
    decision = Scheduler.next_dispatch_set((), active, budget, rate)
    # T1 needs api+docs together and fits; T2 then has no docs capacity left.
    assert decision.task_ids == ("T1",)
    assert decision.remaining_rate == {"api": 0, "docs": 0}


def test_unknown_provider_is_a_configuration_error():
    budget = BudgetLedger(Decimal("10.00"))
    rate = RateCapacityLedger({"api": 4})
    active = [TaskSpec("T1", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("mystery"),))]
    with pytest.raises(KeyError):
        Scheduler.next_dispatch_set((), active, budget, rate)


# --- The scheduler simulates, it never reserves -------------------------------


def test_scheduler_never_reserves():
    budget = BudgetLedger(Decimal("10.00"))
    rate = RateCapacityLedger({"api": 2})
    active = [
        TaskSpec("T1", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
        TaskSpec("T2", budget_ceiling=Decimal("3"), rate_demands=(RateDemand("api"),)),
    ]
    decision = Scheduler.next_dispatch_set((), active, budget, rate)
    assert decision.task_ids == ("T1", "T2")
    # Simulation only: the ledgers are byte-for-byte untouched.
    assert budget.reservations == {}
    assert budget.reserved == Decimal("0.00")
    assert budget.available == Decimal("10.00")
    assert rate.reservations == {}
    assert rate.used("api") == 0
    # The controller reserves the selected set exactly once afterwards; the
    # simulated remaining money/rate tell it what is left for the next wave.
    budget.reserve("T1", Decimal("3.00"))
    budget.reserve("T2", Decimal("3.00"))
    rate.reserve("T1", RateDemand("api"))
    rate.reserve("T2", RateDemand("api"))
    assert budget.available == Decimal("4.00")
    assert rate.used("api") == 2


# --- Value objects -----------------------------------------------------------


def test_task_spec_defaults_and_validation():
    spec = TaskSpec("T1", budget_ceiling=Decimal("3"))
    assert spec.id == "T1"
    assert spec.depends_on == ()
    assert spec.budget_ceiling == Decimal("3")
    assert spec.rate_demands == ()
    # An explicit budget ceiling is mandatory: no task may slip into a wave
    # with an implicit, un-contracted cost.
    with pytest.raises(TypeError):
        TaskSpec("T1")  # type: ignore[call-arg]
    # depends_on normalizes to a tuple so the spec stays hashable/frozen.
    assert TaskSpec("T2", depends_on=["T1"], budget_ceiling=Decimal("2")).depends_on == ("T1",)
    for bad_ceiling in (Decimal("0"), Decimal("-1")):
        with pytest.raises(ValueError):
            TaskSpec("T1", budget_ceiling=bad_ceiling)
    with pytest.raises(ValueError):
        TaskSpec("", budget_ceiling=Decimal("1"))
    with pytest.raises(ValueError):
        TaskSpec("T1", depends_on=("",), budget_ceiling=Decimal("1"))


def test_task_spec_rejects_duplicate_provider_demands():
    with pytest.raises(ValueError):
        TaskSpec(
            "T1",
            budget_ceiling=Decimal("3"),
            rate_demands=(RateDemand("api", 1), RateDemand("api", 1)),
        )


def test_task_spec_is_immutable():
    spec = TaskSpec("T1", budget_ceiling=Decimal("3"))
    with pytest.raises(AttributeError):
        spec.id = "T2"  # type: ignore[misc]


def test_dispatch_decision_fields_and_immutability():
    decision = Scheduler.next_dispatch_set(
        (), [], BudgetLedger(Decimal("5.00")), RateCapacityLedger({"api": 2})
    )
    assert decision.task_ids == ()
    assert decision.remaining_money == Decimal("5.00")
    assert decision.remaining_rate == {"api": 2}
    with pytest.raises(AttributeError):
        decision.task_ids = ("T1",)  # type: ignore[misc]
