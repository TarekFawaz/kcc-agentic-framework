"""Autonomy metrics + rollout gates (Plan 07, Task 4) -- tests.

Plan 07, Task 4 contract (local Plan07 task contracts file,
``### Task 4: Autonomy metrics + rollout gates``, plus the ## Global
Constraints and the approved Design Spec v1.2 section 26/27):

* ``EvaluationMetrics`` records the autonomy evidence of the
  30-scenario evaluation and the rollout evidence consumed by the
  gates; R1 requires 30/30 + zero stale-worker promotions + zero
  budget-cap breaches + zero policy violations; R2 requires R1 +
  ``staging_smoke_classes >= 3`` (web app, API-only, browser
  extension); R3 requires the base + the three staging classes +
  ``canary_projects >= 5`` + ``unplanned_post_lock_prompts = 0`` +
  ``rollback_drills >= 5`` + ``resume_drills >= 5`` + native harnesses
  include ``codex`` and ``dsh`` + ``harness_parity_runs_passed >= 3`` +
  ``dsh_live_smoke_passed = True``, and the latest DSH smoke has zero
  human prompts and zero secret findings.

* ``eligible_for(metrics, stage)`` is the fail-closed gate: R1/R2/R3
  are cumulative (R2 requires R1, R3 requires R2), every requirement is
  reported with a per-requirement verdict, and an unknown stage is
  refused instead of guessed.

Evidence honesty (Global Constraints: evaluation fidelity + rollout
honesty):

* The scenario-suite metrics are DERIVED from the real 30 runs
  (``ScenarioResult`` objects produced by the Task 3 runner) -- never
  declared: 30/30 comes from the catalog's expected states,
  stale-worker promotions from the durable event trace, budget-cap
  breaches from the ledger's provider truth vs hard cap, policy
  violations from the signed policy gate's audit trail + world truth,
  staging smoke classes from the real lifecycle transitions, resume
  drills from fresh-lease re-dispatches and unplanned post-lock prompts
  from the consolidated batch discipline (spec 18.1).
* R3's live-DSH evidence is a ``HarnessSmokeEvidence`` record
  (Plan 08, Task 7) -- generic CI never pretends live DSH exists, and a
  smoke with any human prompt or secret finding can never satisfy the
  gate even if a number claims otherwise.
* The canonical enum ``AUTO_PROVISION_AUTHORIZED`` is never renamed.

Written first (strict TDD red phase) before ``metrics.py`` exists.
"""

from __future__ import annotations

import dataclasses
import json
from datetime import datetime, timezone

import pytest
from pydantic import ValidationError

from kcc_autobuild.evaluation import SCENARIO_CATALOG
from kcc_autobuild.evaluation import metrics as METRICS  # noqa: N814
from kcc_autobuild.evaluation.runner import ScenarioResult, run_scenario
from kcc_autobuild.evaluation.scenarios import ProjectClass
from kcc_autobuild.harnesses.models import HarnessSmokeEvidence
from kcc_autobuild.models import DependencyStatus

# ---------------------------------------------------------------------------
# Shared evidence
# ---------------------------------------------------------------------------

NATIVE_HARNESSES = ("codex", "dsh")
PARITY_RUNS_PASSED = 3
CANARY_PROJECTS = 5
ROLLBACK_DRILLS = 5


def passing_dsh_smoke(**overrides) -> HarnessSmokeEvidence:
    """One passing live DSH smoke record (Plan 08, Task 7 semantics)."""
    values = dict(
        harness_id="dsh",
        runs_requested=3,
        runs_passed=3,
        status_probe_passed=True,
        authorized_mutation_passed=True,
        unauthorized_mutation_denied=True,
        human_prompts=0,
        secret_findings=0,
        evidence_refs=[
            "smoke://harness-status-probe",
            "smoke://authorized-mutation/kcc-policy-write",
            "smoke://authorized-mutation/kcc-policy-exec",
            "smoke://unauthorized-mutation-denied/raw-write",
            "smoke://unauthorized-mutation-denied/raw-bash",
        ],
        ran_at=datetime(2026, 8, 28, 12, 0, tzinfo=timezone.utc),
    )
    values.update(overrides)
    return HarnessSmokeEvidence(**values)


@pytest.fixture(scope="module")
def scenario_results(tmp_path_factory: pytest.TempPathFactory) -> list[ScenarioResult]:
    """Every real scenario run, executed once per module (deterministic)."""
    db_dir = tmp_path_factory.mktemp("kcc-metrics-runs")
    return [
        run_scenario(scenario.id, db_path=db_dir / f"{scenario.id}.db")
        for scenario in SCENARIO_CATALOG
    ]


@pytest.fixture(scope="module")
def full_metrics(scenario_results) -> "METRICS.EvaluationMetrics":
    """EvaluationMetrics collected from EVERY real run + full R3 evidence."""
    return METRICS.EvaluationMetrics.collect(
        scenario_results,
        canary_projects=CANARY_PROJECTS,
        rollback_drills=ROLLBACK_DRILLS,
        native_harnesses=NATIVE_HARNESSES,
        harness_parity_runs_passed=PARITY_RUNS_PASSED,
        dsh_smoke=passing_dsh_smoke(),
    )


def _synthetic_evidence(count: int = 30) -> tuple:
    """Deterministic scenario evidence for gate-logic tests (never a proof).

    Every scenario passed, staged and is drill-free; only the resume
    drills are present (scenario 25+), matching the suite's observable
    counts while staying independent from any real run.
    """
    classes = (
        ProjectClass.WEB_APPLICATION,
        ProjectClass.API_SERVICE,
        ProjectClass.BROWSER_EXTENSION,
    )
    return tuple(
        METRICS.ScenarioAutonomyEvidence(
            scenario_id=f"scenario{index}",
            project_class=classes[index % 3],
            passed=True,
            stale_worker_promotions=0,
            budget_cap_breach=False,
            policy_violation=False,
            staging_smoke=True,
            resume_drill=index >= 25,
            unplanned_post_lock_prompts=0,
        )
        for index in range(1, count + 1)
    )


def _full_metrics(**overrides) -> "METRICS.EvaluationMetrics":
    """An EvaluationMetrics with every gate requirement met (synthetic)."""
    values = dict(
        scenario_evidence=_synthetic_evidence(),
        canary_projects=CANARY_PROJECTS,
        rollback_drills=ROLLBACK_DRILLS,
        native_harnesses=NATIVE_HARNESSES,
        harness_parity_runs_passed=PARITY_RUNS_PASSED,
        dsh_smoke=passing_dsh_smoke(),
    )
    values.update(overrides)
    return METRICS.EvaluationMetrics(**values)


def _with_changed_evidence(metrics, transform) -> "METRICS.EvaluationMetrics":
    return metrics.model_copy(
        update={"scenario_evidence": tuple(transform(e) for e in metrics.scenario_evidence)}
    )


def _r1_metrics() -> "METRICS.EvaluationMetrics":
    """R1-met metrics whose staging evidence is missing (R2/R3 must deny)."""
    return _full_metrics(
        scenario_evidence=tuple(
            e.model_copy(update={"staging_smoke": False})
            for e in _synthetic_evidence()
        )
    )


def _unmet(eligibility) -> tuple[str, ...]:
    return tuple(check.requirement for check in eligibility.checks if not check.met)


# ---------------------------------------------------------------------------
# Derivation from the real 30-scenario evaluation
# ---------------------------------------------------------------------------


def test_collect_derives_30_of_30_from_the_real_runs(full_metrics) -> None:
    """R1 30/30: all exactly-30 approved scenarios settled in the expected state."""
    assert full_metrics.scenarios_total == 30
    assert full_metrics.scenarios_passed == 30
    assert [evidence.scenario_id for evidence in full_metrics.scenario_evidence] == [
        f"scenario{number}" for number in range(1, 31)
    ]
    assert all(evidence.passed for evidence in full_metrics.scenario_evidence)


def test_collect_derives_zero_stale_budget_and_policy_failures(
    full_metrics,
) -> None:
    """R1 controls: zero stale-worker promotions, zero breaches, zero violations.

    The suite itself proves the mechanisms (scenarios 19, 9, 18/27): a
    stale promotion is rejected (never accepted), the books settle before
    the cap is reached and every outside-policy operation is denied before
    execution -- so the observed failure counts are exactly zero.
    """
    assert full_metrics.stale_worker_promotions == 0
    assert full_metrics.budget_cap_breaches == 0
    assert full_metrics.policy_violations == 0
    # Scenario 9 IS the E3 halt: the breach was detected and prevented.
    scenario9 = next(
        e for e in full_metrics.scenario_evidence if e.scenario_id == "scenario9"
    )
    assert scenario9.budget_cap_breach is False
    # Scenario 19 IS the stale-worker test: the attempt was rejected.
    scenario19 = next(
        e for e in full_metrics.scenario_evidence if e.scenario_id == "scenario19"
    )
    assert scenario19.stale_worker_promotions == 0


def test_collect_derives_the_three_named_staging_smoke_classes(
    full_metrics,
) -> None:
    """R2 staging evidence: web app, API-only and browser extension all staged."""
    classes = set(full_metrics.staging_smoke_classes)
    assert len(classes) >= 3
    assert {
        ProjectClass.WEB_APPLICATION,
        ProjectClass.API_SERVICE,
        ProjectClass.BROWSER_EXTENSION,
    } <= classes
    # Deterministic order by canonical value.
    assert full_metrics.staging_smoke_classes == tuple(
        sorted(classes, key=lambda cls: cls.value)
    )


def test_collect_derives_resume_drills_and_zero_unplanned_prompts(
    full_metrics,
) -> None:
    """R3 resume-drill evidence from the suite's real durable resumes."""
    assert full_metrics.resume_drills >= 5
    assert full_metrics.unplanned_post_lock_prompts == 0


def test_collect_keeps_recorded_rollout_evidence_verbatim(full_metrics) -> None:
    """Recorded rollout evidence is preserved exactly (never extrapolated)."""
    assert full_metrics.canary_projects == CANARY_PROJECTS
    assert full_metrics.rollback_drills == ROLLBACK_DRILLS
    assert full_metrics.native_harnesses == NATIVE_HARNESSES
    assert full_metrics.harness_parity_runs_passed == PARITY_RUNS_PASSED
    assert full_metrics.dsh_smoke is not None
    assert full_metrics.dsh_smoke.passed is True


def test_collect_is_deterministic(scenario_results) -> None:
    """The same runs always produce the identical metrics record."""
    first = METRICS.EvaluationMetrics.collect(scenario_results)
    second = METRICS.EvaluationMetrics.collect(scenario_results)
    assert first == second
    assert first.scenario_evidence == second.scenario_evidence


def test_collect_rejects_unknown_or_duplicate_scenario_ids(
    scenario_results,
) -> None:
    """Fail closed: a result outside the approved catalog is never folded in."""
    unknown = dataclasses.replace(scenario_results[0], scenario_id="scenario99")
    with pytest.raises(KeyError):
        METRICS.EvaluationMetrics.collect([unknown])
    duplicate = [
        scenario_results[0],
        dataclasses.replace(scenario_results[0], scenario_id="scenario1"),
        *scenario_results[1:],
    ]
    with pytest.raises(ValueError):
        METRICS.EvaluationMetrics.collect(duplicate)


# ---------------------------------------------------------------------------
# Gate logic: R1
# ---------------------------------------------------------------------------


def test_r1_eligible_on_full_evidence(full_metrics) -> None:
    eligibility = METRICS.eligible_for(full_metrics, METRICS.RolloutStage.R1)
    assert eligibility.eligible is True
    assert eligibility.stage is METRICS.RolloutStage.R1
    assert _unmet(eligibility) == ()


def test_r1_denies_a_missing_scenario(full_metrics) -> None:
    partial = full_metrics.model_copy(
        update={"scenario_evidence": full_metrics.scenario_evidence[:29]}
    )
    eligibility = METRICS.eligible_for(partial, METRICS.RolloutStage.R1)
    assert eligibility.eligible is False
    assert "scenarios_30_of_30" in _unmet(eligibility)


def test_r1_denies_a_failing_scenario() -> None:
    metrics = _full_metrics()
    changed = _with_changed_evidence(
        metrics,
        lambda e: e if not e.scenario_id == "scenario1" else e.model_copy(
            update={"passed": False}
        ),
    )
    eligibility = METRICS.eligible_for(changed, METRICS.RolloutStage.R1)
    assert eligibility.eligible is False
    assert "scenarios_30_of_30" in _unmet(eligibility)


def test_r1_denies_a_stale_worker_promotion() -> None:
    metrics = _full_metrics()
    changed = _with_changed_evidence(
        metrics,
        lambda e: e if not e.scenario_id == "scenario1" else e.model_copy(
            update={"stale_worker_promotions": 1}
        ),
    )
    eligibility = METRICS.eligible_for(changed, METRICS.RolloutStage.R1)
    assert eligibility.eligible is False
    assert "stale_worker_promotions_zero" in _unmet(eligibility)


def test_r1_denies_a_budget_cap_breach() -> None:
    metrics = _full_metrics()
    changed = _with_changed_evidence(
        metrics,
        lambda e: e if not e.scenario_id == "scenario1" else e.model_copy(
            update={"budget_cap_breach": True}
        ),
    )
    eligibility = METRICS.eligible_for(changed, METRICS.RolloutStage.R1)
    assert eligibility.eligible is False
    assert "budget_cap_breaches_zero" in _unmet(eligibility)


def test_r1_denies_a_policy_violation() -> None:
    metrics = _full_metrics()
    changed = _with_changed_evidence(
        metrics,
        lambda e: e if not e.scenario_id == "scenario1" else e.model_copy(
            update={"policy_violation": True}
        ),
    )
    eligibility = METRICS.eligible_for(changed, METRICS.RolloutStage.R1)
    assert eligibility.eligible is False
    assert "policy_violations_zero" in _unmet(eligibility)


# ---------------------------------------------------------------------------
# Gate logic: R2 (cumulative)
# ---------------------------------------------------------------------------


def test_r2_eligible_on_full_evidence(full_metrics) -> None:
    eligibility = METRICS.eligible_for(full_metrics, METRICS.RolloutStage.R2)
    assert eligibility.eligible is True
    assert _unmet(eligibility) == ()


def test_r2_requires_r1() -> None:
    """R1 failing -> R2 fails with the R1 requirements listed."""
    metrics = _full_metrics()
    changed = _with_changed_evidence(
        metrics,
        lambda e: e if not e.scenario_id == "scenario1" else e.model_copy(
            update={"passed": False}
        ),
    )
    eligibility = METRICS.eligible_for(changed, METRICS.RolloutStage.R2)
    assert eligibility.eligible is False
    assert "scenarios_30_of_30" in _unmet(eligibility)


def test_r2_denies_when_a_named_staging_class_never_staged() -> None:
    metrics = _full_metrics()
    changed = _with_changed_evidence(
        metrics,
        lambda e: e if e.project_class is not ProjectClass.WEB_APPLICATION
        else e.model_copy(update={"staging_smoke": False}),
    )
    eligibility = METRICS.eligible_for(changed, METRICS.RolloutStage.R2)
    assert eligibility.eligible is False
    assert "staging_smoke_classes_three" in _unmet(eligibility)
    assert "staging_smoke_classes_named" in _unmet(eligibility)


def test_r2_denies_when_all_named_classes_never_staged() -> None:
    """The named classes are a hard requirement; other classes do not substitute."""
    metrics = _full_metrics()
    changed = _with_changed_evidence(
        metrics,
        lambda e: e
        if e.project_class
        not in (ProjectClass.WEB_APPLICATION,
                ProjectClass.API_SERVICE,
                ProjectClass.BROWSER_EXTENSION)
        else e.model_copy(update={"staging_smoke": False}),
    )
    eligibility = METRICS.eligible_for(changed, METRICS.RolloutStage.R2)
    assert eligibility.eligible is False
    assert "staging_smoke_classes_named" in _unmet(eligibility)


# ---------------------------------------------------------------------------
# Gate logic: R3 (R1 + R2 + rollout + harness evidence)
# ---------------------------------------------------------------------------


def test_r3_eligible_on_full_evidence(full_metrics) -> None:
    eligibility = METRICS.eligible_for(full_metrics, METRICS.RolloutStage.R3)
    assert eligibility.eligible is True
    assert _unmet(eligibility) == ()


def test_r3_requires_r2() -> None:
    r1_only = _r1_metrics()
    assert METRICS.eligible_for(r1_only, METRICS.RolloutStage.R1).eligible is True
    eligibility = METRICS.eligible_for(r1_only, METRICS.RolloutStage.R3)
    assert eligibility.eligible is False
    assert "staging_smoke_classes_three" in _unmet(eligibility)


def test_r3_requires_canary_projects() -> None:
    eligibility = METRICS.eligible_for(
        _full_metrics(canary_projects=4), METRICS.RolloutStage.R3
    )
    assert eligibility.eligible is False
    assert "canary_projects_five" in _unmet(eligibility)


def test_r3_requires_zero_unplanned_post_lock_prompts() -> None:
    metrics = _full_metrics()
    changed = _with_changed_evidence(
        metrics,
        lambda e: e.model_copy(update={"unplanned_post_lock_prompts": 1}),
    )
    eligibility = METRICS.eligible_for(changed, METRICS.RolloutStage.R3)
    assert eligibility.eligible is False
    assert "unplanned_post_lock_prompts_zero" in _unmet(eligibility)


def test_r3_requires_rollback_drills() -> None:
    eligibility = METRICS.eligible_for(
        _full_metrics(rollback_drills=4), METRICS.RolloutStage.R3
    )
    assert eligibility.eligible is False
    assert "rollback_drills_five" in _unmet(eligibility)


def test_r3_requires_resume_drills() -> None:
    metrics = _full_metrics()
    changed = _with_changed_evidence(
        metrics,
        lambda e: e.model_copy(update={"resume_drill": False}),
    )
    eligibility = METRICS.eligible_for(changed, METRICS.RolloutStage.R3)
    assert eligibility.eligible is False
    assert "resume_drills_five" in _unmet(eligibility)


def test_r3_requires_codex_and_dsh_native_harnesses() -> None:
    eligibility = METRICS.eligible_for(
        _full_metrics(native_harnesses=("dsh",)), METRICS.RolloutStage.R3
    )
    assert eligibility.eligible is False
    assert "native_harnesses_codex_dsh" in _unmet(eligibility)


def test_r3_requires_harness_parity_runs() -> None:
    eligibility = METRICS.eligible_for(
        _full_metrics(harness_parity_runs_passed=2),
        METRICS.RolloutStage.R3,
    )
    assert eligibility.eligible is False
    assert "harness_parity_runs_passed_three" in _unmet(eligibility)


def test_r3_requires_a_passed_live_dsh_smoke() -> None:
    eligibility = METRICS.eligible_for(
        _full_metrics(dsh_smoke=None), METRICS.RolloutStage.R3
    )
    assert eligibility.eligible is False
    assert "dsh_live_smoke_passed" in _unmet(eligibility)


def test_r3_denies_a_smoke_with_any_human_prompt_or_secret() -> None:
    """R3 honesty: a smoke with a human prompt or a secret finding never passes.

    Generic CI must never pretend live DSH exists: the gate checks the
    recorded fields explicitly, and ``HarnessSmokeEvidence.passed`` is
    derived so an inconsistent record cannot claim success.
    """
    prompted = passing_dsh_smoke(human_prompts=1)
    leaked = passing_dsh_smoke(secret_findings=1)
    assert prompted.passed is False
    assert leaked.passed is False
    for smoke in (prompted, leaked):
        eligibility = METRICS.eligible_for(
            _full_metrics(dsh_smoke=smoke), METRICS.RolloutStage.R3
        )
        assert eligibility.eligible is False
        assert "dsh_live_smoke_passed" in _unmet(eligibility)


def test_r3_requires_r1_and_r2_controls_verbatim() -> None:
    """A metrics doc failing an R1 control cannot reach R3."""
    metrics = _full_metrics()
    changed = _with_changed_evidence(
        metrics,
        lambda e: e if not e.scenario_id == "scenario9"
        else e.model_copy(update={"budget_cap_breach": True}),
    )
    eligibility = METRICS.eligible_for(changed, METRICS.RolloutStage.R3)
    assert eligibility.eligible is False
    assert "budget_cap_breaches_zero" in _unmet(eligibility)


# ---------------------------------------------------------------------------
# Fail-closed model / gate behavior
# ---------------------------------------------------------------------------


def test_unknown_stage_fails_closed(full_metrics) -> None:
    with pytest.raises(ValueError):
        METRICS.eligible_for(full_metrics, "r4")
    with pytest.raises(ValueError):
        METRICS.eligible_for(full_metrics, "PRODUCTION")


def test_stages_are_canonical_lowercase() -> None:
    assert METRICS.RolloutStage("r1") is METRICS.RolloutStage.R1
    assert METRICS.RolloutStage.R3.value == "r3"


def test_metrics_model_is_strict_and_immutable() -> None:
    with pytest.raises(ValidationError):
        METRICS.EvaluationMetrics.model_validate(
            {"scenario_evidence": (), "surprise": True}
        )
    metrics = _full_metrics()
    with pytest.raises(ValidationError):
        metrics.canary_projects = 0  # type: ignore[misc]
    with pytest.raises(ValidationError):
        METRICS.EvaluationMetrics(
            scenario_evidence=(),
            canary_projects=-1,
            rollback_drills=0,
            native_harnesses=(),
            harness_parity_runs_passed=0,
        )
    with pytest.raises(ValidationError):
        METRICS.EvaluationMetrics(
            scenario_evidence=(),
            canary_projects=0,
            rollback_drills=0,
            native_harnesses=("Codex",),
            harness_parity_runs_passed=0,
        )
    with pytest.raises(ValidationError):
        METRICS.EvaluationMetrics(
            scenario_evidence=(),
            canary_projects=0,
            rollback_drills=0,
            native_harnesses=(),
            harness_parity_runs_passed=-3,
        )


def test_eligibility_is_a_machine_readable_record(full_metrics) -> None:
    eligibility = METRICS.eligible_for(full_metrics, METRICS.RolloutStage.R3)
    payload = eligibility.model_dump(mode="json")
    assert payload["stage"] == "r3"
    assert payload["eligible"] is True
    assert len(payload["checks"]) >= 10
    round_trip = json.loads(json.dumps(payload))
    assert round_trip["eligible"] is True


def test_eligibility_reports_every_requirement_with_a_verdict() -> None:
    metrics = METRICS.EvaluationMetrics(
        scenario_evidence=tuple(
            e.model_copy(update={"resume_drill": False, "unplanned_post_lock_prompts": 1})
            for e in _synthetic_evidence()
        ),
        canary_projects=0,
        rollback_drills=0,
        native_harnesses=(),
        harness_parity_runs_passed=0,
        dsh_smoke=None,
    )
    eligibility = METRICS.eligible_for(metrics, METRICS.RolloutStage.R3)
    assert eligibility.eligible is False
    unmet = _unmet(eligibility)
    # Every R3-only requirement is reported unmet (nothing silent).
    for requirement in (
        "canary_projects_five",
        "unplanned_post_lock_prompts_zero",
        "rollback_drills_five",
        "resume_drills_five",
        "native_harnesses_codex_dsh",
        "harness_parity_runs_passed_three",
        "dsh_live_smoke_passed",
    ):
        assert requirement in unmet
    # Satisfied base checks are reported as met (both sides visible).
    met = tuple(check.requirement for check in eligibility.checks if check.met)
    assert "policy_violations_zero" in met


def test_canonical_auto_provision_enum_unchanged() -> None:
    """Global constraint: canonical enum AUTO_PROVISION_AUTHORIZED must never be renamed."""
    assert DependencyStatus.AUTO_PROVISION_AUTHORIZED.value == "AUTO_PROVISION_AUTHORIZED"
