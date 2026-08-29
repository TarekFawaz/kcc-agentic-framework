"""Behavioral contract for the autobuild 30-scenario runner.

Plan 07, Task 3 contract (local Plan07 task contracts file,
``### Task 3: Scenario runner + all 30``, plus the ## Global Constraints
and the approved Design Spec v1.2 section 27):

* the runner module ``evaluation/runner.py`` exposes ``run_scenario``
  consuming the :class:`~kcc_autobuild.evaluation.Scenario` catalog,
  the deterministic :class:`~kcc_autobuild.evaluation.FakeWorld` and the
  production KCC controller APIs;
* the scenario ID -> injection mapping is explicit (``scenario1`` ..
  ``scenario30``) and behavior is NEVER inferred from the English
  scenario title -- the runner dispatches by the stable ID and only uses
  the title as the run record's display field;
* every post-LOCK scenario builds the REAL
  :class:`~kcc_autobuild.controller.AutobuildController` wired to the
  fake provider, the execution bridge, the fake CI, the fake clock and a
  temp-file SQLite :class:`~kcc_autobuild.store.RunStore`; the final
  state is produced by the controller + the production decision modules,
  never hardcoded (the runner source must not read
  ``scenario.expected_state`` at all);
* the run drives exactly the approved 30 scenarios in three
  parameterized test groups (IDs 1-10, 11-20, 21-30) and all 30 cases
  pass -- no skip, no xfail;
* mechanism assertions explicitly cover: scenario 18 (multiple
  post-lock blockers consolidated into ONE batched decision request),
  scenarios 20/28 (provider rate handling: transient 429 retried with
  backoff inside the attempt budget vs persistent 429 bounded by the
  retry distribution ending in HALTED -- no infinite retry), scenarios
  26/29 (false-pass handling: a pass without acceptance evidence never
  advances and the task re-executes; a forged chain of custody is
  rejected every time and the exhausted attempt budget halves the run),
  scenario 23 (recovery from TARGET-system truth after a migration
  commit crash -- the migration is applied exactly once, never repeated
  from pretender local state) and scenario 30 (an external store
  Tier-1 rejection routes to HALTED carrying the review reasons as the
  batched decision).

Written first (strict TDD red phase) before ``runner.py`` exists.
"""

from __future__ import annotations

import inspect
from pathlib import Path

import pytest

from kcc_autobuild.evaluation import SCENARIO_CATALOG, SCENARIOS_BY_ID, StoreDecision
from kcc_autobuild.models import LifecycleState
from kcc_autobuild.evaluation.runner import (
    RUN_ID,
    SCENARIO_DRIVERS,
    SCENARIO_INJECTIONS,
    ScenarioResult,
    run_scenario,
)

# ---------------------------------------------------------------------------
# The 30 approved cases: three parameterized groups (IDs 1-10, 11-20, 21-30).
# Every case asserts the run settles in the catalog's expected lifecycle
# state; no case is skipped and no case is expected to fail.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "number",
    range(1, 11),
    ids=[f"scenario{number}" for number in range(1, 11)],
)
def test_scenarios_1_to_10_settle_in_the_approved_state(
    number: int, tmp_path: Path
) -> None:
    scenario = SCENARIOS_BY_ID[f"scenario{number}"]
    result = run_scenario(scenario.id, db_path=tmp_path / "eval.db")
    assert isinstance(result, ScenarioResult)
    assert result.scenario_id == scenario.id
    assert result.final_state is scenario.expected_state, (
        scenario.id,
        scenario.expected_state,
        result.final_state,
        result.state_transitions,
        result.halt_batches,
    )


@pytest.mark.parametrize(
    "number",
    range(11, 21),
    ids=[f"scenario{number}" for number in range(11, 21)],
)
def test_scenarios_11_to_20_settle_in_the_approved_state(
    number: int, tmp_path: Path
) -> None:
    scenario = SCENARIOS_BY_ID[f"scenario{number}"]
    result = run_scenario(scenario.id, db_path=tmp_path / "eval.db")
    assert isinstance(result, ScenarioResult)
    assert result.scenario_id == scenario.id
    assert result.final_state is scenario.expected_state, (
        scenario.id,
        scenario.expected_state,
        result.final_state,
        result.state_transitions,
        result.halt_batches,
    )


@pytest.mark.parametrize(
    "number",
    range(21, 31),
    ids=[f"scenario{number}" for number in range(21, 31)],
)
def test_scenarios_21_to_30_settle_in_the_approved_state(
    number: int, tmp_path: Path
) -> None:
    scenario = SCENARIOS_BY_ID[f"scenario{number}"]
    result = run_scenario(scenario.id, db_path=tmp_path / "eval.db")
    assert isinstance(result, ScenarioResult)
    assert result.scenario_id == scenario.id
    assert result.final_state is scenario.expected_state, (
        scenario.id,
        scenario.expected_state,
        result.final_state,
        result.state_transitions,
        result.halt_batches,
    )


# ---------------------------------------------------------------------------
# Explicit scenario-ID -> injection mapping (evaluation fidelity)
# ---------------------------------------------------------------------------


def test_injection_mapping_is_keyed_by_scenario_id_and_covers_all_30() -> None:
    """The runner drives behavior through an explicit scenario-ID mapping."""
    expected_ids = frozenset(scenario.id for scenario in SCENARIO_CATALOG)
    assert len(SCENARIO_INJECTIONS) == 30
    assert frozenset(SCENARIO_INJECTIONS) == expected_ids
    assert frozenset(SCENARIO_DRIVERS) == expected_ids
    assert len(SCENARIO_DRIVERS) == 30


def test_runner_never_dispatch_behavior_from_the_english_title() -> None:
    """The scenario title must never drive control flow (source-level proof).

    The title is used exactly once: as the display field of the durable
    run record. No lower/upper-cased lookup, no ``expected_state`` read:
    final states are produced by the controller and the production
    decision modules, never hardcoded from the catalog.
    """
    from kcc_autobuild.evaluation import runner as module

    source = inspect.getsource(module)
    assert "title.lower" not in source
    assert "title.upper" not in source
    assert "title.startswith" not in source
    assert "expected_state" not in source
    assert source.count(".title") == 1


def test_run_scenario_rejects_unknown_scenario_ids_fail_closed(tmp_path: Path) -> None:
    """An ID outside the approved catalog is refused -- no fuzzy guessing."""
    with pytest.raises(KeyError):
        run_scenario("scenario99", db_path=tmp_path / "eval.db")


# ---------------------------------------------------------------------------
# Real controller wiring (no hardcoded outcomes)
# ---------------------------------------------------------------------------


def test_run_scenario_wires_the_real_controller_onto_temp_sqlite(
    tmp_path: Path,
) -> None:
    """The run is driven by the production controller over a temp SQLite store."""
    db_path = tmp_path / "run.db"
    result = run_scenario("scenario1", db_path=db_path)
    assert db_path.exists()
    kinds = [event.kind for event in result.run_events]
    assert "run.created" in kinds
    assert "task.dispatch" in kinds
    assert "task.passed" in kinds
    assert "wave.complete" in kinds
    # The run record lives in the temp SQLite store (durable, not memory).
    assert result.run_id == RUN_ID
    assert result.final_state is LifecycleState.DONE
    # The lifecycle chain was walked through the real state machine.
    transitions = list(result.state_transitions)
    assert ("BUILDING", "STAGING_VALIDATED") in [
        (origin, target) for origin, target, _reason in transitions
    ]
    assert ("PRODUCTION_VALIDATED", "DONE") in [
        (origin, target) for origin, target, _reason in transitions
    ]


def test_scenario_runs_are_deterministic(tmp_path: Path) -> None:
    """Two identical runs produce identical world traces and final states."""
    first = run_scenario("scenario2", db_path=tmp_path / "a.db")
    second = run_scenario("scenario2", db_path=tmp_path / "b.db")
    assert first.final_state is second.final_state
    assert first.task_states == second.task_states
    assert first.world_events == second.world_events
    assert first.state_transitions == second.state_transitions


# ---------------------------------------------------------------------------
# Scenario 4 / 13: interrupted sessions resume from durable state
# ---------------------------------------------------------------------------


def test_scenario4_resumes_an_interrupted_session_without_repeating_work(
    tmp_path: Path,
) -> None:
    result = run_scenario("scenario4", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.DONE
    # The interrupted task re-executes on a fresh lease generation.
    t1_dispatches = [
        event
        for event in result.run_events
        if event.kind == "task.dispatch" and event.payload["task_id"] == "T-1"
    ]
    t2_dispatches = [
        event
        for event in result.run_events
        if event.kind == "task.dispatch" and event.payload["task_id"] == "T-2"
    ]
    assert len(t1_dispatches) == 1  # completed work is never repeated
    assert [event.payload["generation"] for event in t2_dispatches] == [1, 2]
    passed = [
        event.payload
        for event in result.run_events
        if event.kind == "task.passed"
    ]
    assert [payload["task_id"] for payload in passed] == ["T-1", "T-2"]
    assert passed[-1]["attempt"] == 2


def test_scenario13_fences_the_partitioned_worker_and_reexecutes_mid_wave(
    tmp_path: Path,
) -> None:
    result = run_scenario("scenario13", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.DONE
    assert any(event.kind == "worker.partition" for event in result.world_events)
    frozen = [
        event
        for event in result.run_events
        if event.kind == "task.frozen" and event.payload["task_id"] == "T-1"
    ]
    assert frozen, "the lost worker's lease must be fenced by the stale sweep"
    passed = {
        event.payload["task_id"]: event.payload["attempt"]
        for event in result.run_events
        if event.kind == "task.passed"
    }
    assert passed == {"T-1": 2, "T-2": 1}
    assert all(state == "PASSED" for _task, state in result.task_states)


# ---------------------------------------------------------------------------
# Scenario 18: human blockers consolidate into ONE batched decision request
# ---------------------------------------------------------------------------


def test_scenario18_consolidates_post_lock_blockers_into_one_batch(
    tmp_path: Path,
) -> None:
    result = run_scenario("scenario18", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.HALTED
    # Exactly ONE consolidated decision batch carrying every reason.
    assert len(result.halt_batches) == 1
    batch = result.halt_batches[0]
    assert len(batch) >= 3, batch
    assert any("E7" in reason or "OUTAGE" in reason.upper() for reason in batch)
    assert any("E4" in reason or "POLICY" in reason.upper() for reason in batch)
    assert any("RATE" in reason.upper() for reason in batch)
    # Exactly one transition to HALTED: never one-by-one drip questions.
    halted = [
        (origin, target, reason)
        for origin, target, reason in result.state_transitions
        if target == "HALTED"
    ]
    assert len(halted) == 1
    # The blockers were all observed before the single halt.
    rejection_kinds = {event.kind for event in result.run_events}
    assert "report.rejected" in rejection_kinds or "task.failed" in rejection_kinds


# ---------------------------------------------------------------------------
# Scenarios 20 / 28: provider rate handling
# ---------------------------------------------------------------------------


def test_scenario20_retries_the_transient_429_with_backoff_inside_the_attempt(
    tmp_path: Path,
) -> None:
    result = run_scenario("scenario20", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.DONE
    assert result.rate_limited_calls == 1
    assert result.rate_429_observed == 1
    # The wave completed: every task passed without halting.
    assert all(state == "PASSED" for _task, state in result.task_states)
    assert result.halt_batches == ()


def test_scenario28_stops_at_the_retry_bound_no_infinite_retry(tmp_path: Path) -> None:
    result = run_scenario("scenario28", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.HALTED
    # The retry distribution is bounded: exactly the configured backoff
    # window is consumed, one failure report, then the escalation ladder.
    assert result.rate_limited_calls == 5
    calls = [
        event
        for event in result.world_events
        if event.kind == "provider.call" and event.payload["provider_key"] == "llm"
    ]
    assert len(calls) == 5  # no infinite retry: the bound is exact
    assert all(
        event.payload["status"] == "rate_limited" for event in calls
    )
    assert len(result.halt_batches) == 1
    assert any("RATE" in reason.upper() for reason in result.halt_batches[0])


# ---------------------------------------------------------------------------
# Scenarios 26 / 29: false-pass handling
# ---------------------------------------------------------------------------


def test_scenario26_false_pass_never_advances_and_the_task_reexecutes(
    tmp_path: Path,
) -> None:
    result = run_scenario("scenario26", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.DONE
    # The false-pass attempt never entered the world: only the valid
    # re-execution produced a report (on a fresh lease generation).
    emitted = [
        event.payload["attempt"]
        for event in result.world_events
        if event.kind == "report.emit"
    ]
    assert emitted == [2]
    passed = [
        event.payload
        for event in result.run_events
        if event.kind == "task.passed"
    ]
    assert len(passed) == 1
    assert passed[0]["attempt"] == 2  # attempt 1 never passed
    assert [("T-1", "PASSED")] == [
        (task, state) for task, state in result.task_states
    ]


def test_scenario29_rejects_every_forged_report_and_halts_on_exhaustion(
    tmp_path: Path,
) -> None:
    result = run_scenario("scenario29", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.HALTED
    assert result.rejected_reports == 3
    rejected = [
        event
        for event in result.run_events
        if event.kind == "report.rejected"
    ]
    assert len(rejected) == 3
    # Forgery never advances the wave: zero tasks passed.
    assert all(
        event.kind != "task.passed" for event in result.run_events
    )
    assert len(result.halt_batches) == 1
    batch = result.halt_batches[0]
    assert any("commit" in reason.lower() or "evidence" in reason.lower()
               for reason in batch)


# ---------------------------------------------------------------------------
# Scenario 23: migration target truth
# ---------------------------------------------------------------------------


def test_scenario23_recovers_from_target_truth_and_applies_the_migration_once(
    tmp_path: Path,
) -> None:
    result = run_scenario("scenario23", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.DONE
    # TARGET-system truth: the migration is committed exactly once even
    # though the process crashed right after the commit.
    assert result.target_state == ("schema-023",)
    migrations = [
        event
        for event in result.world_events
        if event.kind in ("migration.commit", "migration.commit_crash")
    ]
    assert [event.kind for event in migrations] == ["migration.commit_crash"]
    # The resumed worker trusted target truth: it never re-applied the
    # migration (no second migration event of any kind).
    assert len(migrations) == 1
    passed = [
        event.payload
        for event in result.run_events
        if event.kind == "task.passed"
    ]
    assert passed[-1]["attempt"] == 2


# ---------------------------------------------------------------------------
# Scenario 30: external store Tier-1 rejection
# ---------------------------------------------------------------------------


def test_scenario30_tier1_store_rejection_halts_with_the_review_reasons(
    tmp_path: Path,
) -> None:
    result = run_scenario("scenario30", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.HALTED
    # The external store's verdict is the ground truth of the rejection.
    assert isinstance(result.store_decision, StoreDecision)
    assert result.store_decision.status == "rejected"
    assert result.store_decision.reasons == ("submission rejected by store review",)
    assert len(result.halt_batches) == 1
    batch = result.halt_batches[0]
    assert any(
        "submission rejected by store review" in reason for reason in batch
    )
    # The review-batch route is the production routing function's Tier-1
    # verdict: one halt carrying the reasons, never a build loop.
    assert result.state_transitions[-1][1] == "HALTED"


# ---------------------------------------------------------------------------
# Supporting mechanism proofs (pause/resume, stale fencing, CI, pre-lock)
# ---------------------------------------------------------------------------


def test_scenario25_pause_retains_and_resume_redispatches_without_double_reserve(
    tmp_path: Path,
) -> None:
    result = run_scenario("scenario25", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.BUILDING
    t1_dispatches = [
        event
        for event in result.run_events
        if event.kind == "task.dispatch" and event.payload["task_id"] == "T-1"
    ]
    t2_dispatches = [
        event
        for event in result.run_events
        if event.kind == "task.dispatch" and event.payload["task_id"] == "T-2"
    ]
    assert len(t1_dispatches) == 1  # completed work is never repeated
    assert [event.payload["generation"] for event in t2_dispatches] == [1, 2]
    assert t2_dispatches[1].payload["resumed"] is True
    # The retained reservation was never released: the money booked for the
    # paused task is identical on the re-dispatch (no double reserve).
    assert (
        t2_dispatches[0].payload["money_reserved"]
        == t2_dispatches[1].payload["money_reserved"]
    )
    frozen = [
        event
        for event in result.run_events
        if event.kind == "task.frozen" and event.payload["task_id"] == "T-2"
    ]
    assert frozen and frozen[0].payload["retained"] is True
    # The paused task never completed: only T-1's pre-pause pass exists.
    passed_tasks = [
        event.payload["task_id"]
        for event in result.run_events
        if event.kind == "task.passed"
    ]
    assert passed_tasks == ["T-1"]


def test_scenario19_rejects_the_stale_worker_promotion_after_fence(
    tmp_path: Path,
) -> None:
    result = run_scenario("scenario19", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.DONE
    assert result.stale_promotions == 1
    # The fenced attempt never advanced; the fresh attempt did.
    passed = [
        event.payload
        for event in result.run_events
        if event.kind == "task.passed"
    ]
    assert passed[-1]["attempt"] == 2


def test_scenario24_never_pretends_local_ci_passed_during_outage(
    tmp_path: Path,
) -> None:
    result = run_scenario("scenario24", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.BLOCKED
    assert any(
        event.kind == "ci.verify" and event.payload["status"] == "outage"
        for event in result.world_events
    )
    transitions = [
        (origin, target) for origin, target, _reason in result.state_transitions
    ]
    assert ("BUILDING", "STAGING_VALIDATED") not in transitions
    assert result.block_reasons, "the block must carry the evidence gap"


def test_scenario7_and_14_and_17_never_lock_or_build_pre_lock(tmp_path: Path) -> None:
    for scenario_id in ("scenario7", "scenario14", "scenario17"):
        result = run_scenario(scenario_id, db_path=tmp_path / f"{scenario_id}.db")
        assert result.final_state is LifecycleState.BLOCKED, scenario_id
        assert not any(
            event.kind == "task.dispatch" for event in result.run_events
        ), scenario_id
        transitions = [
            (origin, target) for origin, target, _reason in result.state_transitions
        ]
        assert ("READINESS", "LOCKED") not in transitions, scenario_id
        assert ("CONTRACT_REVIEW", "LOCKED") not in transitions, scenario_id
        assert result.block_reasons, scenario_id


def test_scenario17_blocks_the_orphan_requirement_by_trace_truth(
    tmp_path: Path,
) -> None:
    result = run_scenario("scenario17", db_path=tmp_path / "eval.db")
    assert result.final_state is LifecycleState.BLOCKED
    assert any("orphan" in reason.lower() for reason in result.block_reasons)


def test_canonical_auto_provision_enum_unchanged() -> None:
    """Global constraint: canonical enum AUTO_PROVISION_AUTHORIZED must never be renamed."""
    from kcc_autobuild.models import DependencyStatus

    assert DependencyStatus.AUTO_PROVISION_AUTHORIZED.value == "AUTO_PROVISION_AUTHORIZED"
