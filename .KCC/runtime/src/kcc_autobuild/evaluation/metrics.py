"""Autonomy metrics + rollout gates for the autobuild framework.

Plan 07, Task 4 (``### Task 4: Autonomy metrics + rollout gates`` of the
local Plan07 task contracts, plus its ## Global Constraints and the
approved Design Spec v1.2 sections 18.2/26/27).

The module owns two things:

1. :class:`EvaluationMetrics` -- the immutable, machine-readable record
   of the framework's autonomy evidence.  The scenario-suite part is
   DERIVED by :meth:`EvaluationMetrics.collect` from the real
   ``ScenarioResult`` objects the Task 3 runner produced (evaluation
   fidelity: nothing is declared, everything is observed); the
   rollout/harness part is recorded verbatim from the rollout and live
   exercises (rollout honesty: generic CI never pretends live DSH
   exists, and the live DSH smoke evidence is a
   :class:`~kcc_autobuild.harnesses.models.HarnessSmokeEvidence` record
   whose ``passed`` verdict is derived, never asserted).
2. :func:`eligible_for` -- the fail-closed rollout gate over three
   cumulative stages:

   * **R1** requires 30/30 (exactly the 30 approved evaluation
     scenarios settle in their expected states) with zero stale-worker
     promotions, zero budget-cap breaches and zero policy violations.
   * **R2** requires R1 plus ``staging_smoke_classes >= 3`` covering the
     three named project classes (web app, API-only, browser
     extension).
   * **R3** requires R2 plus ``canary_projects >= 5``,
     ``unplanned_post_lock_prompts = 0``, ``rollback_drills >= 5``,
     ``resume_drills >= 5``, native harnesses including ``codex`` and
     ``dsh``, ``harness_parity_runs_passed >= 3`` and a passed live DSH
     smoke whose latest run has zero human prompts and zero secret
     findings.

Evidence definitions (each is observable, never inferred from a
scenario name):

* ``passed`` -- the run settled in the catalog's expected lifecycle
  state (the catalog is the durable authority; ``scenarios_total`` is
  the evidence count, exactly 30 for the approved suite).
* ``stale_worker_promotions`` -- a worker result from a superseded
  lease generation accepted by the controller.  The durable event trace
  exposes it as a terminal task event (``task.passed`` /
  ``task.failed`` / ``task.blocked``) whose generation is below the
  latest dispatch generation for the same task: a fenced worker's
  result never advances the wave.  Scenario 19 observes the rejected
  promotion (the runner counts the attempt); scenarios 4/13/23/25/26
  observe interrupted sessions re-executing on fresh lease generations;
  the accepted count is what the gate measures and is zero exactly when
  every attempt was rejected before promotion.
* ``budget_cap_breach`` -- settled provider actuals above the run's
  hard cap **without** the E3 halt at settlement.  A
  ``budget.breach`` event means the ledger settled the books first and
  the run halted (BLOCKED) -- the cap held, the breach was prevented
  (scenario 9).  A breach is counted only when the spend exceeded the
  cap and the control plane did NOT stop (the ledger's provider-truth
  reconciliation is the ground truth, never the report's claim).
* ``policy_violation`` -- an operation outside the signed
  destructive-action policy executed.  The policy gate audits every
  evaluation (ALLOWED/DENIED/AMBIGUOUS) BEFORE the executor runs and
  DENIED never reaches the executor; the world's durable ``migration``
  events show what actually executed.  An executed migration outside the
  signed ALLOWED resources is a violation; a simulated
  ``migration.commit_crash`` is exogenous target-system truth (scenario
  23), not a control-plane action.  Scenarios 18/27 observe the DENIED
  attempts; the executed count is what the gate measures.
* ``staging_smoke`` -- the run passed staging validation through the
  real lifecycle (the ``BUILDING -> STAGING_VALIDATED`` transition).
* ``resume_drill`` -- the run re-dispatched a task from durable state on
  a fresh lease generation after an interruption (partition, crash,
  fence or pause) -- the scenario suite itself is the resume-drill
  evidence.
* ``unplanned_post_lock_prompts`` -- post-lock human decision requests
  outside the planned consolidated channel (spec 18.1).  The runner's
  single ``halt_batches`` entry per settled run IS that planned channel;
  every batch beyond the first is an unplanned drip prompt.
* Recorded rollout evidence (``canary_projects``, ``rollback_drills``,
  ``native_harnesses``, ``harness_parity_runs_passed``, ``dsh_smoke``)
  is the count/record captured by the rollout exercises and by the
  harness/parity conformance runs -- it is preserved verbatim and the
  gate reads it as evidence, never as a claim.

R3 authority policy (documented in
``docs/autobuild/rollout.md``): an R3-eligible gate *proposes* the R3
production authority by default (the user may opt out before LOCK); the
runtime still requires the production authority to be present in the
locked Build Contract -- :func:`eligible_for` never grants authority, it
only answers the metrics question.

The behavioral contract is owned by
:file:`.KCC/runtime/tests/test_evaluation_metrics.py`.
"""

from __future__ import annotations

from decimal import Decimal
from enum import Enum
from typing import Iterable, Iterator

from pydantic import ConfigDict, Field, field_validator

from kcc_autobuild.evaluation.runner import ScenarioResult
from kcc_autobuild.evaluation.scenarios import ProjectClass, SCENARIOS_BY_ID
from kcc_autobuild.harnesses.models import HarnessSmokeEvidence
from kcc_autobuild.models import StrictModel

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------


class RolloutStage(str, Enum):
    """Cumulative rollout stages of the autonomy gates (canonical, lowercase).

    ``R1`` is the evaluation baseline, ``R2`` adds the staging-smoke
    coverage of the three named project classes and ``R3`` adds the
    rollout, drill, harness-parity and live DSH smoke evidence.
    """

    R1 = "r1"
    R2 = "r2"
    R3 = "r3"


# ---------------------------------------------------------------------------
# Per-scenario autonomy evidence
# ---------------------------------------------------------------------------


class ScenarioAutonomyEvidence(StrictModel):
    """Autonomy evidence of ONE evaluation scenario (frozen, derived).

    Fields are the observable facts the gates consume; every field is
    derived by :meth:`EvaluationMetrics.collect` from the durable
    ``ScenarioResult`` trace.  ``unplanned_post_lock_prompts`` is the
    number of extra (drip) decision requests this run produced beyond
    the single consolidated batch.
    """

    model_config = ConfigDict(frozen=True)

    scenario_id: str = Field(min_length=1)
    project_class: ProjectClass
    passed: bool
    stale_worker_promotions: int = Field(ge=0)
    budget_cap_breach: bool
    policy_violation: bool
    staging_smoke: bool
    resume_drill: bool
    unplanned_post_lock_prompts: int = Field(ge=0)


# ---------------------------------------------------------------------------
# Rollout eligibility record
# ---------------------------------------------------------------------------


class GateCheck(StrictModel):
    """One requirement verdict of a rollout stage (machine readable)."""

    model_config = ConfigDict(frozen=True)

    requirement: str = Field(min_length=1)
    met: bool
    detail: str = Field(min_length=1)


class RolloutEligibility(StrictModel):
    """The fail-closed verdict of :func:`eligible_for`.

    ``checks`` carries EVERY requirement of the stage (met and unmet)
    so no gap is silent; ``eligible`` is derived as all checks met.
    """

    model_config = ConfigDict(frozen=True)

    stage: RolloutStage
    eligible: bool
    checks: tuple[GateCheck, ...] = ()

    @property
    def unmet_requirements(self) -> tuple[str, ...]:
        return tuple(check.requirement for check in self.checks if not check.met)


# ---------------------------------------------------------------------------
# Metrics record
# ---------------------------------------------------------------------------


REQUIRED_STAGING_CLASSES: frozenset[ProjectClass] = frozenset(
    {
        ProjectClass.WEB_APPLICATION,
        ProjectClass.API_SERVICE,
        ProjectClass.BROWSER_EXTENSION,
    }
)
"""The three named staging smoke classes of the R2/R3 gate (design spec 6.1)."""

REQUIRED_NATIVE_HARNESSES: frozenset[str] = frozenset({"codex", "dsh"})
"""Native harnesses the R3 gate requires (capability contract, Plan 08)."""


class EvaluationMetrics(StrictModel):
    """Immutable autonomy metrics + rollout evidence record.

    The scenario-suite metrics are DERIVED properties of
    :attr:`scenario_evidence` (never independent knobs); the remaining
    fields are the recorded rollout/harness evidence, preserved verbatim.
    """

    model_config = ConfigDict(frozen=True)

    scenario_evidence: tuple[ScenarioAutonomyEvidence, ...] = ()
    canary_projects: int = Field(default=0, ge=0)
    rollback_drills: int = Field(default=0, ge=0)
    native_harnesses: tuple[str, ...] = ()
    harness_parity_runs_passed: int = Field(default=0, ge=0)
    dsh_smoke: HarnessSmokeEvidence | None = None

    @field_validator("scenario_evidence")
    @classmethod
    def _scenario_evidence_unique_and_known(
        cls, value: tuple[ScenarioAutonomyEvidence, ...]
    ) -> tuple[ScenarioAutonomyEvidence, ...]:
        seen: set[str] = set()
        checked: list[ScenarioAutonomyEvidence] = []
        for evidence in value:
            if evidence.scenario_id in seen:
                raise ValueError(
                    f"duplicate scenario evidence for {evidence.scenario_id!r}"
                )
            if evidence.scenario_id not in SCENARIOS_BY_ID:
                raise ValueError(
                    f"unknown scenario {evidence.scenario_id!r} -- evidence "
                    "outside the approved catalog is never folded in"
                )
            seen.add(evidence.scenario_id)
            checked.append(evidence)
        return tuple(checked)

    @field_validator("native_harnesses")
    @classmethod
    def _native_harnesses_canonical(cls, value: tuple[str, ...]) -> tuple[str, ...]:
        for harness_id in value:
            if not isinstance(harness_id, str) or not harness_id.strip():
                raise ValueError("native_harnesses entries must not be blank")
            if harness_id != harness_id.lower():
                raise ValueError(
                    f"native harness {harness_id!r} must be a lowercase id"
                )
        if len(value) != len(set(value)):
            raise ValueError("native_harnesses must not contain duplicates")
        return value

    # -- derived scenario-suite metrics ---------------------------------------

    @property
    def scenarios_total(self) -> int:
        """Number of scenario evidence records (exactly 30 for the approved suite)."""
        return len(self.scenario_evidence)

    @property
    def scenarios_passed(self) -> int:
        """Scenarios that settled in the catalog's expected lifecycle state."""
        return sum(1 for evidence in self.scenario_evidence if evidence.passed)

    @property
    def stale_worker_promotions(self) -> int:
        """Stale-worker results accepted by the controller (zero when fenced)."""
        return sum(
            evidence.stale_worker_promotions for evidence in self.scenario_evidence
        )

    @property
    def budget_cap_breaches(self) -> int:
        """Runs that spent beyond the hard cap without the E3 halt."""
        return sum(
            1 for evidence in self.scenario_evidence if evidence.budget_cap_breach
        )

    @property
    def policy_violations(self) -> int:
        """Outside-policy operations that executed (zero when the gate holds)."""
        return sum(
            1 for evidence in self.scenario_evidence if evidence.policy_violation
        )

    @property
    def staging_smoke_classes(self) -> tuple[ProjectClass, ...]:
        """Distinct project classes that passed staging validation (canonical order)."""
        classes = {
            evidence.project_class
            for evidence in self.scenario_evidence
            if evidence.staging_smoke
        }
        return tuple(sorted(classes, key=lambda cls: cls.value))

    @property
    def resume_drills(self) -> int:
        """Runs that resumed a task from durable state on a fresh lease."""
        return sum(1 for evidence in self.scenario_evidence if evidence.resume_drill)

    @property
    def unplanned_post_lock_prompts(self) -> int:
        """Post-lock decision requests outside the consolidated batch channel."""
        return sum(
            evidence.unplanned_post_lock_prompts
            for evidence in self.scenario_evidence
        )

    # -- collection -----------------------------------------------------------

    @classmethod
    def collect(
        cls,
        scenario_results: Iterable[ScenarioResult],
        *,
        canary_projects: int = 0,
        rollback_drills: int = 0,
        native_harnesses: Iterable[str] = (),
        harness_parity_runs_passed: int = 0,
        dsh_smoke: HarnessSmokeEvidence | None = None,
    ) -> EvaluationMetrics:
        """Derive the scenario-suite metrics from the real evaluation runs.

        The scenario evidence is ordered by the stable scenario number
        (deterministic); unknown scenario ids raise :class:`KeyError` and
        duplicate ids raise :class:`ValueError` (fail closed: a result
        outside the approved catalog is never folded into the metrics).
        The rollout/harness evidence is recorded verbatim.
        """
        evidence = tuple(
            sorted(
                _evaluate(scenario_results),
                key=lambda item: int(item.scenario_id.removeprefix("scenario")),
            )
        )
        return cls(
            scenario_evidence=evidence,
            canary_projects=canary_projects,
            rollback_drills=rollback_drills,
            native_harnesses=tuple(native_harnesses),
            harness_parity_runs_passed=harness_parity_runs_passed,
            dsh_smoke=dsh_smoke,
        )


# ---------------------------------------------------------------------------
# Per-run derivation (evidence, not declaration)
# ---------------------------------------------------------------------------


def _evaluate(results: Iterable[ScenarioResult]) -> Iterator[ScenarioAutonomyEvidence]:
    for result in results:
        scenario = SCENARIOS_BY_ID[result.scenario_id]  # KeyError: fail closed
        yield ScenarioAutonomyEvidence(
            scenario_id=result.scenario_id,
            project_class=scenario.project_class,
            passed=result.final_state is scenario.expected_state,
            stale_worker_promotions=_accepted_stale_promotions(result),
            budget_cap_breach=_budget_cap_breach(result),
            policy_violation=result.policy_violations > 0,
            staging_smoke=_staging_smoke(result),
            resume_drill=_resume_drill(result),
            unplanned_post_lock_prompts=_unplanned_prompts(result),
        )


def _accepted_stale_promotions(result: ScenarioResult) -> int:
    """Terminal task events on a superseded lease generation (accepted stale)."""
    latest: dict[str, int] = {}
    for event in result.run_events:
        if event.kind == "task.dispatch":
            task_id = event.payload["task_id"]
            generation = int(event.payload.get("generation", 0))
            latest[task_id] = max(latest.get(task_id, 0), generation)
    accepted = 0
    for event in result.run_events:
        if event.kind in ("task.passed", "task.failed", "task.blocked"):
            task_id = event.payload["task_id"]
            generation = int(event.payload.get("generation", 0))
            if generation < latest.get(task_id, 0):
                accepted += 1
    return accepted


def _budget_cap_breach(result: ScenarioResult) -> bool:
    """Settled spend above the hard cap that was NOT halted at settlement."""
    halted = any(event.kind == "budget.breach" for event in result.run_events)
    settled = Decimal(str(result.provider_actual_cost))
    return settled > result.budget_cap and not halted


def _staging_smoke(result: ScenarioResult) -> bool:
    """The run passed staging validation through the real lifecycle."""
    return any(
        target == "STAGING_VALIDATED" for _origin, target, _reason in result.state_transitions
    )


def _resume_drill(result: ScenarioResult) -> bool:
    """A task re-dispatched from durable state on a fresh lease generation."""
    return any(
        event.kind == "task.dispatch"
        and int(event.payload.get("generation", 0)) >= 2
        for event in result.run_events
    )


def _unplanned_prompts(result: ScenarioResult) -> int:
    """Decision requests beyond the single consolidated batch (spec 18.1)."""
    return max(0, len(result.halt_batches) - 1)


# ---------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------


def eligible_for(
    metrics: EvaluationMetrics,
    stage: RolloutStage | str,
) -> RolloutEligibility:
    """Evaluate one cumulative rollout stage against the evidence.

    ``stage`` may be a :class:`RolloutStage` member or its canonical
    lowercase value; anything else (e.g. ``"r4"``, ``"production"``)
    raises :class:`ValueError` -- an unknown stage is refused, never
    guessed.  Every requirement of the target stage is reported with a
    met/unmet verdict; R2 includes the R1 requirements and R3 includes
    the R1 and R2 requirements.
    """
    if isinstance(stage, RolloutStage):
        resolved = stage
    elif isinstance(stage, str):
        try:
            resolved = RolloutStage(stage)
        except ValueError:
            raise ValueError(f"unknown rollout stage {stage!r}") from None
    else:
        raise TypeError(f"stage must be a RolloutStage, got {type(stage).__name__}")

    checks: list[GateCheck] = []
    _r1_checks(metrics, checks)
    if resolved is not RolloutStage.R1:
        _r2_checks(metrics, checks)
    if resolved is RolloutStage.R3:
        _r3_checks(metrics, checks)
    return RolloutEligibility(
        stage=resolved,
        eligible=all(check.met for check in checks),
        checks=tuple(checks),
    )


def _r1_checks(
    metrics: EvaluationMetrics, checks: list[GateCheck]
) -> None:
    total = metrics.scenarios_total
    passed = metrics.scenarios_passed
    checks.append(
        GateCheck(
            requirement="scenarios_30_of_30",
            met=total == 30 and passed == 30,
            detail=f"{passed}/{total} approved evaluation scenarios settled "
            "in their expected lifecycle states (contract: exactly 30/30)",
        )
    )
    stale = metrics.stale_worker_promotions
    checks.append(
        GateCheck(
            requirement="stale_worker_promotions_zero",
            met=stale == 0,
            detail=f"{stale} stale-worker promotions accepted "
            "(contract: zero; a fenced lease's result never advances the wave)",
        )
    )
    breaches = metrics.budget_cap_breaches
    checks.append(
        GateCheck(
            requirement="budget_cap_breaches_zero",
            met=breaches == 0,
            detail=f"{breaches} budget-cap breach(es) (contract: zero; "
            "the books settle before the cap and the run halts on E3)",
        )
    )
    violations = metrics.policy_violations
    checks.append(
        GateCheck(
            requirement="policy_violations_zero",
            met=violations == 0,
            detail=f"{violations} outside-policy operation(s) executed "
            "(contract: zero; the signed policy gate denies before execution)",
        )
    )


def _r2_checks(
    metrics: EvaluationMetrics, checks: list[GateCheck]
) -> None:
    classes = metrics.staging_smoke_classes
    checks.append(
        GateCheck(
            requirement="staging_smoke_classes_three",
            met=len(classes) >= 3,
            detail=f"staging smoke classes observed: "
            f"{len(classes)} ({', '.join(cls.value for cls in classes) or 'none'}) "
            "(contract: >= 3)",
        )
    )
    missing = sorted(
        REQUIRED_STAGING_CLASSES - set(classes), key=lambda cls: cls.value
    )
    checks.append(
        GateCheck(
            requirement="staging_smoke_classes_named",
            met=not missing,
            detail=f"required staging smoke classes missing: "
            f"{', '.join(cls.value for cls in missing) or 'none'} "
            "(contract: web app, API-only, browser extension)",
        )
    )


def _r3_checks(
    metrics: EvaluationMetrics, checks: list[GateCheck]
) -> None:
    canary = metrics.canary_projects
    checks.append(
        GateCheck(
            requirement="canary_projects_five",
            met=canary >= 5,
            detail=f"{canary} project(s) exercised a canary rollout gate "
            "(contract: >= 5)",
        )
    )
    prompts = metrics.unplanned_post_lock_prompts
    checks.append(
        GateCheck(
            requirement="unplanned_post_lock_prompts_zero",
            met=prompts == 0,
            detail=f"{prompts} unplanned post-lock prompt(s) "
            "(contract: zero; all decision requests ride the consolidated batch)",
        )
    )
    drills = metrics.rollback_drills
    checks.append(
        GateCheck(
            requirement="rollback_drills_five",
            met=drills >= 5,
            detail=f"{drills} rollback drill(s) completed "
            "(contract: >= 5)",
        )
    )
    resumes = metrics.resume_drills
    checks.append(
        GateCheck(
            requirement="resume_drills_five",
            met=resumes >= 5,
            detail=f"{resumes} resume drill(s) completed "
            "(contract: >= 5)",
        )
    )
    native = metrics.native_harnesses
    missing = sorted(REQUIRED_NATIVE_HARNESSES - set(native))
    checks.append(
        GateCheck(
            requirement="native_harnesses_codex_dsh",
            met=not missing,
            detail=f"required native harnesses missing: "
            f"{', '.join(missing) or 'none'} "
            "(contract: native harnesses include codex and dsh)",
        )
    )
    parity = metrics.harness_parity_runs_passed
    checks.append(
        GateCheck(
            requirement="harness_parity_runs_passed_three",
            met=parity >= 3,
            detail=f"{parity} cross-harness parity run(s) passed "
            "(contract: >= 3)",
        )
    )
    smoke = metrics.dsh_smoke
    smoke_ok = (
        smoke is not None
        and smoke.passed
        and smoke.human_prompts == 0
        and smoke.secret_findings == 0
    )
    if smoke is None:
        smoke_detail = (
            "NO fresh live DSH smoke evidence recorded "
            "(generic CI never pretends live DSH exists)"
        )
    else:
        smoke_detail = (
            f"{smoke.runs_passed}/{smoke.runs_requested} runs passed, "
            f"status probe "
            f"{'passed' if smoke.status_probe_passed else 'failed'}, "
            f"authorized mutation "
            f"{'passed' if smoke.authorized_mutation_passed else 'failed'}, "
            f"direct mutation denied: "
            f"{'yes' if smoke.unauthorized_mutation_denied else 'no'}, "
            f"{smoke.human_prompts} human prompt(s), "
            f"{smoke.secret_findings} secret finding(s)"
        )
    checks.append(
        GateCheck(
            requirement="dsh_live_smoke_passed",
            met=smoke_ok,
            detail=(
                "live DSH smoke evidence: "
                + smoke_detail
                + " (contract: passed with zero human prompts and "
                "zero secret findings)"
            ),
        )
    )


__all__ = [
    "EvaluationMetrics",
    "GateCheck",
    "REQUIRED_NATIVE_HARNESSES",
    "REQUIRED_STAGING_CLASSES",
    "RolloutEligibility",
    "RolloutStage",
    "ScenarioAutonomyEvidence",
    "eligible_for",
]
