"""Behavioral contract for the deterministic autobuild FakeWorld.

Plan 07, Task 2 contract (local Plan07 task contracts file,
``### Task 2: Deterministic FakeWorld``, plus the ## Global Constraints
and the approved Design Spec v1.2 section 27):

* ``evaluation fake_world.py`` creates the deterministic FakeWorld used
  by the scenario runner (Task 3) to drive the *real* controller over
  the 30 approved scenarios;
* FakeWorld exposes ``inject()``, ``advance()``, ``emit_report()``,
  ``provider_call()``, ``ci_verify()`` and a deterministic event
  history;
* the world uses a deterministic fake clock only -- no wall clock, no
  sleep;
* injection flags include store approval/rejection, worker partition,
  migration commit-before-crash, billing lag and CI outage;
* ``emit_report()`` builds the *real* runtime ExecutionReport model
  (``kcc_autobuild.bridge.ExecutionReport``), so report validation is
  the production validation.

The Global Constraints that govern the evaluation fidelity apply here
too: the world is pure deterministic simulation with explicit injection
surfaces, so a scenario's behavior is always driven by an explicit
injection (never inferred from an English title), and scenario runs can
never be made to pass by tweaking the world -- the world only produces
the deterministic exogenous facts the controller consumes.

Written first (strict TDD red phase) before ``fake_world.py`` exists.
"""

from __future__ import annotations

import inspect
from datetime import datetime, timedelta, timezone

import pytest
from pydantic import ValidationError

from kcc_autobuild.bridge import (
    AcceptanceEvidence,
    ExecutionReport,
    ExecutionStatus,
    FailureInfo,
    OutputInfo,
    UsageInfo,
)
from kcc_autobuild.evaluation import FakeWorld
from kcc_autobuild.evaluation.fake_world import (
    BillingRecord,
    CIResult,
    DEFAULT_EPOCH,
    DEFAULT_TICK,
    INJECTION_FLAGS,
    MigrationCrashError,
    MigrationResult,
    ProviderCallResult,
    StoreDecision,
    WorldEvent,
)
from kcc_autobuild.models import FailureClass


def _ac(acceptance_id: str = "AC-001-1") -> list[AcceptanceEvidence]:
    return [
        AcceptanceEvidence(
            acceptance_id=acceptance_id,
            test_ids=["T-001"],
            evidence_refs=["artifacts/t-001.xml"],
        )
    ]


def _passed_evidence() -> list[AcceptanceEvidence]:
    return _ac()


# ---------------------------------------------------------------------------
# Deterministic fake clock
# ---------------------------------------------------------------------------


def test_default_epoch_is_fixed_and_timezone_aware() -> None:
    """Two worlds start at the same deterministic instant (no wall clock)."""
    first = FakeWorld()
    second = FakeWorld()
    assert first.now == second.now == DEFAULT_EPOCH
    assert first.now.tzinfo is not None
    assert first.now.utcoffset() == timedelta(0)
    assert first.now == datetime(2026, 1, 1, tzinfo=timezone.utc)


def test_custom_epoch_must_be_aware() -> None:
    world = FakeWorld(epoch=datetime(2026, 6, 15, 12, 0, tzinfo=timezone.utc))
    assert world.now == datetime(2026, 6, 15, 12, 0, tzinfo=timezone.utc)
    with pytest.raises(ValueError):
        FakeWorld(epoch=datetime(2026, 6, 15, 12, 0))


def test_advance_seconds_moves_clock_exactly() -> None:
    world = FakeWorld()
    advanced = world.advance(seconds=120)
    assert advanced == DEFAULT_EPOCH + timedelta(seconds=120)
    assert world.now == DEFAULT_EPOCH + timedelta(seconds=120)
    assert world.advance(seconds=30) == DEFAULT_EPOCH + timedelta(seconds=150)


def test_advance_default_tick_is_deterministic() -> None:
    world = FakeWorld()
    assert world.advance() == DEFAULT_EPOCH + DEFAULT_TICK
    assert world.advance() == DEFAULT_EPOCH + DEFAULT_TICK * 2


def test_advance_to_absolute_datetime() -> None:
    world = FakeWorld()
    target = DEFAULT_EPOCH + timedelta(hours=2)
    assert world.advance(to=target) == target
    assert world.now == target


def test_advance_never_goes_backwards() -> None:
    world = FakeWorld()
    world.advance(seconds=100)
    frozen = world.now
    with pytest.raises(ValueError):
        world.advance(seconds=0)
    with pytest.raises(ValueError):
        world.advance(seconds=-1)
    with pytest.raises(ValueError):
        world.advance(to=frozen)
    with pytest.raises(ValueError):
        world.advance(to=frozen - timedelta(seconds=1))
    with pytest.raises(ValueError):
        world.advance(to=datetime(2026, 1, 1, 12, 0))  # naive target
    # Rejected advances leave the clock untouched.
    assert world.now == frozen


def test_advance_rejects_mixed_and_conflicting_orders() -> None:
    world = FakeWorld()
    with pytest.raises(ValueError):
        world.advance(seconds=10, to=DEFAULT_EPOCH + timedelta(hours=1))
    assert world.now == DEFAULT_EPOCH


def test_fake_world_uses_no_wall_clock_and_no_sleep() -> None:
    """The world must never read the real clock or sleep.

    Contract: "deterministic fake clock only, no sleep". The module
    source must not call any wall-clock/time source.
    """
    from kcc_autobuild.evaluation import fake_world as module

    source = inspect.getsource(module)
    for forbidden in (
        "time.sleep",
        "time.time(",
        "time.monotonic(",
        "time.perf_counter(",
        "datetime.now(",
        "datetime.utcnow(",
        "date.today(",
    ):
        assert forbidden not in source, f"module must not use {forbidden}"


# ---------------------------------------------------------------------------
# Event history
# ---------------------------------------------------------------------------


def test_every_action_records_an_ordered_event() -> None:
    world = FakeWorld()
    world.advance(seconds=5)
    world.inject("ci_outage", seconds=30)
    world.ci_verify()
    world.provider_call("llm")
    world.emit_report(
        run_id="RUN-1",
        task_id="T-1",
        attempt=1,
        status=ExecutionStatus.PASSED,
        acceptance_evidence=_passed_evidence(),
    )
    world.store_submit("browser-extension-v1")
    world.migrate("m-001")

    kinds = [event.kind for event in world.events]
    assert kinds == [
        "clock.advance",
        "inject",
        "ci.verify",
        "provider.call",
        "report.emit",
        "store.submit",
        "migration.commit",
    ]
    assert [event.seq for event in world.events] == list(
        range(1, len(world.events) + 1)
    )


def test_event_carries_the_fake_time_it_happened() -> None:
    world = FakeWorld()
    world.advance(seconds=100)
    world.inject("store_rejection", reason="Tier-1 policy")
    event = world.events[-1]
    assert event.at == DEFAULT_EPOCH + timedelta(seconds=100)
    assert event.payload["flag"] == "store_rejection"
    assert event.payload["reason"] == "Tier-1 policy"
    assert isinstance(event, WorldEvent)
    assert isinstance(event.at, datetime)


def test_events_are_immutable_and_history_is_a_snapshot() -> None:
    world = FakeWorld()
    world.inject("store_approval")
    events = world.events
    assert isinstance(events, tuple)
    with pytest.raises(ValidationError):
        world.events[0].kind = "mutated"  # type: ignore[misc]
    world.inject("ci_outage", seconds=1)
    # The old snapshot is unchanged; the world grew.
    assert len(events) == 1
    assert len(world.events) == 2


def test_identical_scripts_produce_identical_history() -> None:
    """Determinism: same script on two worlds gives byte-identical histories."""

    def script() -> tuple[list[dict], list[dict]]:
        world = FakeWorld()
        world.advance(seconds=10)
        world.inject("worker_partition", task_id="T-2", wave="W1")
        world.inject("billing_lag", seconds=600)
        world.provider_call("llm")
        world.provider_call("llm")
        world.ci_verify("ci/123")
        world.emit_report(
            run_id="RUN-1",
            task_id="T-2",
            attempt=2,
            status=ExecutionStatus.PASSED,
            lease_id="lease-9",
            acceptance_evidence=_passed_evidence(),
        )
        world.emit_report(
            run_id="RUN-1",
            task_id="T-2",
            attempt=3,
            status=ExecutionStatus.PASSED,
            lease_id="lease-10",
            acceptance_evidence=_passed_evidence(),
        )
        world.store_submit("v2")
        world.migrate("m-003")
        events = [event.model_dump() for event in world.events]
        reports = [report.model_dump() for report in world.reports]
        return events, reports

    assert script() == script()


# ---------------------------------------------------------------------------
# inject()
# ---------------------------------------------------------------------------


def test_injected_flags_are_exactly_the_contract_surface() -> None:
    """The five contract flags plus the provider-fault flags are recognized."""
    for flag in (
        "store_approval",
        "store_rejection",
        "worker_partition",
        "migration_commit_before_crash",
        "billing_lag",
        "ci_outage",
    ):
        assert flag in INJECTION_FLAGS, flag
    # Provider faults are also part of the world (rate/outage scenarios).
    assert "provider_rate_limit" in INJECTION_FLAGS
    assert "provider_outage" in INJECTION_FLAGS


def test_inject_unknown_flag_is_rejected_without_event() -> None:
    world = FakeWorld()
    with pytest.raises(ValueError):
        world.inject("mystery_flag")
    with pytest.raises(ValueError):
        world.inject("", task_id="T-1")
    assert world.events == ()


def test_inject_requires_flag_parameters() -> None:
    world = FakeWorld()
    with pytest.raises(ValueError):
        world.inject("worker_partition")  # task_id required
    with pytest.raises(ValueError):
        world.inject("worker_partition", task_id="")  # non-empty required
    with pytest.raises(ValueError):
        world.inject("billing_lag", seconds=0)
    with pytest.raises(ValueError):
        world.inject("billing_lag", seconds=-5)
    with pytest.raises(ValueError):
        world.inject("ci_outage", seconds=-1)
    with pytest.raises(ValueError):
        world.inject("store_rejection", reason="")
    with pytest.raises(ValueError):
        world.inject("provider_rate_limit", seconds=60)  # provider_key required
    with pytest.raises(ValueError):
        world.inject("provider_outage", provider_key="llm", seconds=0)
    with pytest.raises(ValueError):
        world.inject("store_approval", unexpected=True)  # no parameters allowed
    with pytest.raises(ValueError):
        world.inject("ci_outage", seconds=30, unknown=1)
    assert world.events == ()


def test_inject_returns_the_recorded_event() -> None:
    world = FakeWorld()
    event = world.inject("worker_partition", task_id="T-9", wave="W2")
    assert isinstance(event, WorldEvent)
    assert event.seq == 1
    assert event.kind == "inject"
    assert world.events == (event,)


def test_store_rejection_then_approval_honours_injection_order() -> None:
    world = FakeWorld()
    # Default: the external store approves (no rejection injected).
    assert world.store_submit("v1").status == "approved"
    world.inject("store_rejection", reason="invalid manifest")
    rejected = world.store_submit("v2")
    assert rejected.status == "rejected"
    assert rejected.reasons == ("invalid manifest",)
    world.inject("store_approval")
    assert world.store_submit("v3").status == "approved"
    assert world.store_submit("v3").reasons == ()


# ---------------------------------------------------------------------------
# provider_call()
# ---------------------------------------------------------------------------


def test_provider_call_success_is_deterministic_and_records_usage() -> None:
    world = FakeWorld()
    first = world.provider_call("deepseek")
    second = world.provider_call("deepseek")
    assert isinstance(first, ProviderCallResult)
    assert first.ok is True
    assert first.status == "ok"
    assert first.provider_key == "deepseek"
    assert first.usage is not None
    assert first.usage.tokens == 1000
    assert first.usage.cost_usd == 0.01
    assert first.usage.provider_calls == 1
    assert first.call_id != second.call_id  # deterministic unique sequence ids
    assert first.at == world.now == DEFAULT_EPOCH
    # Successful calls appear in the settled provider actuals.
    assert world.provider_actuals("deepseek") == (first.usage, second.usage)


def test_provider_call_honours_max_tokens_deterministically() -> None:
    world = FakeWorld()
    result = world.provider_call("deepseek", max_tokens=2500)
    assert result.usage.tokens == 2500
    with pytest.raises(ValueError):
        world.provider_call("deepseek", max_tokens=0)
    with pytest.raises(ValueError):
        world.provider_call("deepseek", max_tokens=-1)
    with pytest.raises(ValueError):
        world.provider_call("deepseek", max_tokens=100.5)


def test_provider_rate_limit_flag_throttles_after_calls() -> None:
    world = FakeWorld()
    world.inject(
        "provider_rate_limit", provider_key="llm", after_calls=2, seconds=60
    )
    assert world.provider_call("llm").status == "ok"
    assert world.provider_call("llm").status == "ok"
    billed_before = world.provider_actuals("llm")
    limited = world.provider_call("llm")
    assert limited.status == "rate_limited"
    assert limited.ok is False
    assert limited.usage is None
    assert limited.retry_after == 60.0
    # No usage is billed for a throttled call (provider actuals unchanged).
    assert world.provider_actuals("llm") == billed_before
    world.advance(seconds=60)
    assert world.provider_call("llm").status == "ok"


def test_provider_rate_limit_does_not_leak_across_providers() -> None:
    world = FakeWorld()
    world.inject("provider_rate_limit", provider_key="llm", seconds=30)
    assert world.provider_call("other").status == "ok"
    assert world.provider_call("llm").status == "rate_limited"


def test_provider_outage_flag_returns_outage_then_recovers() -> None:
    world = FakeWorld()
    world.inject("provider_outage", provider_key="llm", seconds=90)
    down = world.provider_call("llm")
    assert down.status == "outage"
    assert down.ok is False
    assert down.usage is None
    assert world.provider_actuals("llm") == ()
    world.advance(seconds=90)
    assert world.provider_call("llm").status == "ok"


# ---------------------------------------------------------------------------
# ci_verify()
# ---------------------------------------------------------------------------


def test_ci_verify_passes_by_default() -> None:
    world = FakeWorld()
    result = world.ci_verify()
    assert isinstance(result, CIResult)
    assert result.status == "passed"
    assert result.ref is None
    assert world.ci_verify("ci/runs/42").status == "passed"
    assert world.ci_verify("ci/runs/42").check_id != result.check_id


def test_ci_outage_flag_blocks_verification_then_auto_heals() -> None:
    world = FakeWorld()
    world.inject("ci_outage", seconds=45)
    assert world.ci_verify("ci/runs/42").status == "outage"
    world.advance(seconds=45)
    assert world.ci_verify("ci/runs/42").status == "passed"


# ---------------------------------------------------------------------------
# emit_report() -- real ExecutionReport models
# ---------------------------------------------------------------------------


def test_emit_report_builds_the_real_runtime_execution_report() -> None:
    world = FakeWorld()
    report = world.emit_report(
        run_id="RUN-1",
        task_id="T-1",
        attempt=1,
        status=ExecutionStatus.PASSED,
        lease_id="lease-1",
        workspace_id="ws-1",
        acceptance_evidence=_passed_evidence(),
        usage=UsageInfo(tokens=500, cost_usd=0.005, provider_calls=1),
        outputs=[OutputInfo(kind="file", ref="src/app.py", commit="abc123")],
    )
    assert isinstance(report, ExecutionReport)
    assert report.run_id == "RUN-1"
    assert report.task_id == "T-1"
    assert report.attempt == 1
    assert report.status is ExecutionStatus.PASSED
    assert report.lease_id == "lease-1"
    assert report.workspace_id == "ws-1"
    assert report.acceptance_evidence[0].acceptance_id == "AC-001-1"
    assert report.usage.cost_usd == 0.005
    assert report.outputs[0].commit == "abc123"
    assert world.reports == (report,)
    assert world.events[-1].kind == "report.emit"


def test_emit_report_derives_deterministic_lease_and_workspace_ids() -> None:
    world = FakeWorld()
    first = world.emit_report(
        run_id="RUN-1",
        task_id="T-1",
        attempt=1,
        status="passed",
        acceptance_evidence=_passed_evidence(),
    )
    second = FakeWorld().emit_report(
        run_id="RUN-1",
        task_id="T-1",
        attempt=1,
        status="passed",
        acceptance_evidence=_passed_evidence(),
    )
    assert first.lease_id == second.lease_id
    assert first.workspace_id == second.workspace_id
    assert first.lease_id == "lease-RUN-1-T-1-1"
    assert first.workspace_id == "workspace-RUN-1-T-1-1"


def test_emit_report_passed_requires_acceptance_evidence() -> None:
    """A passed report without AC/Test-ID/evidence is rejected fail-closed."""
    world = FakeWorld()
    with pytest.raises(ValidationError):
        world.emit_report(
            run_id="RUN-1", task_id="T-1", attempt=1, status="passed"
        )


def test_emit_report_failure_requires_a_classified_failure() -> None:
    world = FakeWorld()
    with pytest.raises(ValidationError):
        world.emit_report(
            run_id="RUN-1", task_id="T-1", attempt=1, status="failed"
        )
    failed = world.emit_report(
        run_id="RUN-1",
        task_id="T-1",
        attempt=1,
        status="failed",
        failure=FailureInfo(cls=FailureClass.RATE, message="429 after N calls"),
    )
    assert failed.failure.cls is FailureClass.RATE
    # Failed reports carry no acceptance evidence that could bypass closure.
    assert failed.acceptance_evidence == []


def test_emit_report_partitioned_worker_crashes_once_then_recovers() -> None:
    world = FakeWorld()
    world.inject("worker_partition", task_id="T-1", wave="W1")
    lost = world.emit_report(
        run_id="RUN-1",
        task_id="T-1",
        attempt=1,
        status="passed",
        acceptance_evidence=_passed_evidence(),
    )
    assert lost is None  # the worker partitioned: no report ever arrives
    assert world.reports == ()
    assert [event.kind for event in world.events] == ["inject", "worker.partition"]
    crash = world.events[-1]
    assert crash.payload["task_id"] == "T-1"
    assert crash.payload["wave"] == "W1"
    assert crash.payload["attempt"] == 1
    # A fresh worker re-executes the same task from durable state: the
    # partition is one-shot, so the retry report is delivered.
    delivered = world.emit_report(
        run_id="RUN-1",
        task_id="T-1",
        attempt=2,
        status="passed",
        acceptance_evidence=_passed_evidence(),
    )
    assert isinstance(delivered, ExecutionReport)
    assert delivered.attempt == 2
    assert len(world.reports) == 1


def test_worker_partition_only_affects_the_named_task() -> None:
    world = FakeWorld()
    world.inject("worker_partition", task_id="T-1")
    other = world.emit_report(
        run_id="RUN-1",
        task_id="T-2",
        attempt=1,
        status="passed",
        acceptance_evidence=_passed_evidence(),
    )
    assert isinstance(other, ExecutionReport)


# ---------------------------------------------------------------------------
# Migration commit-before-crash
# ---------------------------------------------------------------------------


def test_migration_commit_before_crash_commits_target_truth_then_crashes() -> None:
    world = FakeWorld()
    world.inject("migration_commit_before_crash")
    with pytest.raises(MigrationCrashError) as excinfo:
        world.migrate("m-001")
    result = excinfo.value.result
    assert isinstance(result, MigrationResult)
    assert result.migration == "m-001"
    assert result.committed is True
    assert result.crashed_after_commit is True
    assert result.target_revision == 1
    # TARGET-system truth: the migration IS committed even though the
    # process crashed immediately afterwards (scenario 23).
    assert world.target_state == ("m-001",)
    assert world.target_revision == 1
    assert world.events[-1].kind == "migration.commit_crash"
    assert world.events[-1].payload["migration"] == "m-001"


def test_migration_crash_is_one_shot_and_arming_can_be_named() -> None:
    world = FakeWorld()
    world.inject("migration_commit_before_crash", migration="m-002")
    # A different migration commits normally and does not consume the arming.
    assert world.migrate("m-001").crashed_after_commit is False
    with pytest.raises(MigrationCrashError):
        world.migrate("m-002")
    # Arming is consumed: the next migration commits normally.
    assert world.migrate("m-003").crashed_after_commit is False
    assert world.target_state == ("m-001", "m-002", "m-003")
    assert world.target_revision == 3


def test_migrate_without_arming_commits_cleanly() -> None:
    world = FakeWorld()
    result = world.migrate("m-000")
    assert result.committed is True
    assert result.crashed_after_commit is False
    assert world.target_state == ("m-000",)
    assert world.events[-1].kind == "migration.commit"


# ---------------------------------------------------------------------------
# Billing lag
# ---------------------------------------------------------------------------


def test_billing_lag_hides_provider_actuals_until_settled() -> None:
    world = FakeWorld()
    world.inject("billing_lag", seconds=3600)
    usage = world.provider_call("llm").usage
    assert usage is not None
    # The provider billed nothing visible yet: actuals are empty (pending).
    assert world.provider_actuals("llm") == ()
    # The billing record carries the lagged effective time.
    (record,) = world.billing
    assert isinstance(record, BillingRecord)
    assert record.effective_at == DEFAULT_EPOCH + timedelta(seconds=3600)
    world.advance(seconds=3600)
    assert world.provider_actuals("llm") == (usage,)


def test_billing_records_are_deterministic_and_filterable() -> None:
    world = FakeWorld()
    world.provider_call("A")
    world.provider_call("B")
    world.provider_call("A")
    assert [record.provider_key for record in world.billing] == ["A", "B", "A"]
    assert len(world.provider_actuals("A")) == 2
    assert len(world.provider_actuals()) == 3


# ---------------------------------------------------------------------------
# Store approval/rejection
# ---------------------------------------------------------------------------


def test_store_submit_records_deterministic_decisions() -> None:
    world = FakeWorld()
    world.inject("store_rejection", reason="manifest does not declare permissions")
    first = world.store_submit("browser-extension-1.0")
    second = world.store_submit("browser-extension-1.1")
    assert isinstance(first, StoreDecision)
    assert first.status == "rejected"
    assert first.reasons == ("manifest does not declare permissions",)
    assert first.submission_id != second.submission_id
    assert first.at == DEFAULT_EPOCH
    assert [event.kind for event in world.events] == ["inject", "store.submit", "store.submit"]


def test_store_submit_defaults_to_approval_before_any_injection() -> None:
    world = FakeWorld()
    decision = world.store_submit("v1")
    assert decision.status == "approved"
    assert decision.reasons == ()


# ---------------------------------------------------------------------------
# Global constraint: the canonical enum is untouched.
# ---------------------------------------------------------------------------


def test_canonical_auto_provision_enum_unchanged() -> None:
    from kcc_autobuild.models import DependencyStatus

    assert DependencyStatus.AUTO_PROVISION_AUTHORIZED.value == "AUTO_PROVISION_AUTHORIZED"
