"""Approved 30-scenario evaluation catalog for the autobuild framework.

Plan 07, Task 1 (``### Task 1: Encode the 30 approved scenarios`` of the
local Plan07 task contracts, plus its ## Global Constraints and the
approved Design Spec v1.2, section 27 ``Framework Validation /
Evaluation Scenarios``).

The catalog encodes exactly 30 unique, immutable scenarios with stable
IDs (``scenario1`` .. ``scenario30``) and expected lifecycle states used
by later tasks:

* scenarios 1..18 are the Design Spec v1.2 section 27 minimum scenario
  suite, in order, with scenario 4 carrying the contract's correction
  (``browser extension external API resumes after interrupted session``)
  instead of the draft wording;
* scenarios 19..30 extend the suite to the control-plane behaviors the
  framework must prove (stale-worker fencing, rate handling, Tier-1/Tier-2
  deviation handling, billing lag, migration target truth, pause/resume,
  false-pass prevention, destructive-action policy, store rejection and
  rollback-drill readiness);
* the contract-pinned entries are exactly: scenario 13 worker partition
  crash mid-wave => DONE; scenario 15 locked provider change => HALTED;
  scenario 16 Tier2 substitution => DONE; scenario 21 Tier1 deviation =>
  HALTED; scenario 23 migration commit-crash => DONE; scenario 25
  pause/resume => BUILDING; scenario 30 store rejection Tier1 => HALTED.

The catalog is pure data — the runner must map a scenario ID to its
injection explicitly and must never infer behavior from the English
title.  Instances are frozen and the container is a tuple, so no task
can rewrite the approved suite.
"""

from __future__ import annotations

from enum import Enum
from types import MappingProxyType
from typing import Mapping

from pydantic import BaseModel, ConfigDict, Field

from kcc_autobuild.models import LifecycleState


class ProjectClass(str, Enum):
    """Project classes of Design Spec v1.2 section 6.1.

    Values are the normalized identifiers consumed by the rollout gates:
    ``staging_smoke_classes >= 3`` (web app, API-only, browser
    extension) counts the classes of scenarios that reached staging
    validation.
    """

    WEB_APPLICATION = "web-app"
    MOBILE_APPLICATION = "mobile-app"
    API_SERVICE = "api-only"
    INTERNAL_TOOL = "internal-tool"
    BROWSER_EXTENSION = "browser-extension"
    CLI_LOCAL_AUTOMATION = "cli-local-automation"
    DATA_PIPELINE = "data-pipeline"
    EXTERNAL_INTEGRATION_HEAVY = "external-integration-heavy"


class Scenario(BaseModel):
    """One approved evaluation scenario (immutable catalog entry).

    ``id`` is the stable identifier (``scenario1`` .. ``scenario30``);
    ``title`` is the approved English name; ``project_class`` is the
    Design Spec v1.2 section 6.1 class of the project under test;
    ``expected_state`` is the lifecycle state the run must settle in
    when the control-plane rules hold; ``description`` states the
    scenario and the observable control-plane rule it proves.
    """

    model_config = ConfigDict(frozen=True, extra="forbid", validate_assignment=True)

    id: str
    title: str
    project_class: ProjectClass
    expected_state: LifecycleState
    description: str = Field(min_length=1)

    @property
    def number(self) -> int:
        """1-based scenario number derived from the stable ID."""
        return int(self.id.removeprefix("scenario"))


def _scenario(
    number: int,
    title: str,
    project_class: ProjectClass,
    expected_state: LifecycleState,
    description: str,
) -> Scenario:
    return Scenario(
        id=f"scenario{number}",
        title=title,
        project_class=project_class,
        expected_state=expected_state,
        description=description,
    )


# Design Spec v1.2 section 27 items 1..18, in order; item 4 carries the
# Plan 07 correction in place of the draft wording.
SCENARIO_CATALOG: tuple[Scenario, ...] = (
    _scenario(
        1,
        "low-risk internal crud tool with no external provider",
        ProjectClass.INTERNAL_TOOL,
        LifecycleState.DONE,
        "Internal CRUD tool with no external provider: the fast-lane "
        "discovery and build complete without provider, credential or "
        "store ceremony and the run reaches DONE.",
    ),
    _scenario(
        2,
        "public web app with oauth database storage and email",
        ProjectClass.WEB_APPLICATION,
        LifecycleState.DONE,
        "Public web application with OAuth, database, storage and email: "
        "full journey/prototype discovery, de-risk and readiness evidence "
        "complete and the run is DONE with production validation.",
    ),
    _scenario(
        3,
        "payment-enabled application using sandbox and live separation",
        ProjectClass.WEB_APPLICATION,
        LifecycleState.DONE,
        "Payment-enabled application with sandbox/live separation: "
        "staging uses sandbox credentials, production uses live "
        "credentials and the run is DONE without live/pay money exposure.",
    ),
    _scenario(
        4,
        "browser extension external API resumes after interrupted session",
        ProjectClass.BROWSER_EXTENSION,
        LifecycleState.DONE,
        "Browser extension with an external API whose session is "
        "interrupted mid-build: durable resume state must reconstruct the "
        "run and finish it, never repeat completed work, and end DONE "
        "(corrected from the draft wording, Plan 07 Task 1).",
    ),
    _scenario(
        5,
        "api-only service with ci cd and no ui prototype requirement",
        ProjectClass.API_SERVICE,
        LifecycleState.DONE,
        "API-only service with CI/CD and no UI prototype requirement: "
        "the prototype walkthrough is skipped for the non-user-facing "
        "project, staging/production validation pass and the run is DONE.",
    ),
    _scenario(
        6,
        "mobile app with app-store account dependency and external review wait",
        ProjectClass.MOBILE_APPLICATION,
        LifecycleState.EXTERNAL_WAIT,
        "Mobile app depending on an app-store account whose review is "
        "externally pending: the run must model the app-store review as "
        "an external wait (never a false completion) and settle "
        "EXTERNAL_WAIT while the review is pending.",
    ),
    _scenario(
        7,
        "provider credential with insufficient scope discovered before lock",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.BLOCKED,
        "A provider credential with insufficient scope is discovered "
        "before LOCK: readiness evaluation must fail closed, the contract "
        "must not lock and the run must settle BLOCKED until the scope "
        "is corrected.",
    ),
    _scenario(
        8,
        "credential revoked after lock",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.HALTED,
        "A provider credential is revoked after LOCK and cannot be "
        "refreshed autonomously (E6): the run must halt HALTED with the "
        "consolidated decision request rather than retry or fake success.",
    ),
    _scenario(
        9,
        "budget cap reached during implementation",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.BLOCKED,
        "The hard budget cap is reached during implementation (E3): the "
        "books must settle first, the run halts BLOCKED with zero "
        "budget-cap breaches and no double-charged retry.",
    ),
    _scenario(
        10,
        "production migration requiring rollback safeguards",
        ProjectClass.WEB_APPLICATION,
        LifecycleState.DONE,
        "A production migration with approved rollback safeguards: the "
        "migration rehearses on staging, carries the recovery path and "
        "completes straight to DONE.",
    ),
    _scenario(
        11,
        "external provider outage with an approved fallback",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.DONE,
        "An external provider outage with an already-authorized fallback "
        "(E7 with fallback): the outage routes to the approved fallback "
        "and the run completes DONE.",
    ),
    _scenario(
        12,
        "external provider outage with no approved fallback",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.HALTED,
        "An external provider outage with no approved fallback (E7): the "
        "SLA window rechecks, then escalates to HALTED with the "
        "consolidated decision — never a false completion.",
    ),
    _scenario(
        13,
        "worker partition crash mid-wave",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.DONE,
        "A worker partitions/crashes halfway through a parallel wave: the "
        "controller fences the lost lease, a fresh worker re-executes the "
        "task from durable state, the wave completes and the run is DONE.",
    ),
    _scenario(
        14,
        "red-team discovers an oauth callback or webhook gap missed by the planner",
        ProjectClass.WEB_APPLICATION,
        LifecycleState.BLOCKED,
        "The red-team readiness review discovers an OAuth callback or "
        "webhook gap the planner missed: the run must not LOCK, the gap is "
        "resolved pre-lock (configuration is a human/account action) and "
        "the run settles BLOCKED until then.",
    ),
    _scenario(
        15,
        "locked provider change",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.HALTED,
        "A fresh subagent attempts to change a locked provider after LOCK: "
        "the locked Tier-1 provider selection must not be redecisable; the "
        "attempt is blocked and the run halts HALTED with the consolidated "
        "decision (contract re-lock) rather than silently accepting the "
        "change.",
    ),
    _scenario(
        16,
        "Tier2 substitution",
        ProjectClass.WEB_APPLICATION,
        LifecycleState.DONE,
        "A technical implementation detail changes post-LOCK (Tier-2 "
        "substitution): the change is inside the Tier-2 autonomy envelope, "
        "is implemented and logged autonomously, and the run is DONE — "
        "no user interruption.",
    ),
    _scenario(
        17,
        "orphan requirement missing test-id or production validation before lock",
        ProjectClass.WEB_APPLICATION,
        LifecycleState.BLOCKED,
        "A requirement with a missing Test-ID or production validation is "
        "an orphan (spec 10.3): the orphan rule blocks LOCK, the run must "
        "not build it and settles BLOCKED until the trace chain is closed.",
    ),
    _scenario(
        18,
        "multiple post-lock blockers consolidated into one decision batch",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.HALTED,
        "Multiple contract-external blockers arise after LOCK (E1..E7 "
        "mix): they must be consolidated into ONE batched decision request "
        "(spec 18.1) and the run settles HALTED carrying every reason — "
        "never one-by-one drip questions.",
    ),
    _scenario(
        19,
        "stale worker promotion attempt after lease fence",
        ProjectClass.API_SERVICE,
        LifecycleState.DONE,
        "A stale worker attempts to promote a result after its lease was "
        "fenced: the promotion must be rejected (zero stale-worker "
        "promotions), the task re-executes fresh and the run is DONE.",
    ),
    _scenario(
        20,
        "provider rate limit during parallel wave",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.DONE,
        "A provider rate limit is hit during a parallel wave (RATE): the "
        "controller throttles and retries with backoff within the attempt "
        "budget, all tasks pass and the run is DONE.",
    ),
    _scenario(
        21,
        "Tier1 deviation",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.HALTED,
        "A fresh worker attempts a Tier-1 invariant deviation after LOCK "
        "(E8-class pressure): the deviation is rejected, the run halts "
        "HALTED with the consolidated decision and only a re-contract may "
        "change the invariant — never a silent deviation.",
    ),
    _scenario(
        22,
        "provider billing lag during budget enforcement",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.DONE,
        "Provider billing lags reported spend during budget enforcement: "
        "settlement reconciles provider actuals against the hard cap "
        "(zero budget-cap breaches), the books settle and the run is DONE.",
    ),
    _scenario(
        23,
        "migration commit-crash",
        ProjectClass.WEB_APPLICATION,
        LifecycleState.DONE,
        "The build crashes after a migration commit: resume must recover "
        "from TARGET-system truth (the migration already committed), not "
        "from pretender local state, and the run is DONE.",
    ),
    _scenario(
        24,
        "ci outage during staging validation",
        ProjectClass.API_SERVICE,
        LifecycleState.BLOCKED,
        "The CI runner is unavailable during staging validation: the "
        "runner must not be replaced by a local pretend-pass; the run "
        "settles BLOCKED with an auto-recheck until real CI evidence "
        "returns.",
    ),
    _scenario(
        25,
        "pause/resume",
        ProjectClass.WEB_APPLICATION,
        LifecycleState.BUILDING,
        "The operator pauses the run mid-build and later resumes it "
        "(--pause / --resume): PAUSED -> RESUMING -> BUILDING from durable "
        "state with no completed task repeated, observed at BUILDING.",
    ),
    _scenario(
        26,
        "execution report false pass without acceptance evidence",
        ProjectClass.API_SERVICE,
        LifecycleState.DONE,
        "A worker reports PASS without acceptance criteria, Test IDs or "
        "evidence refs: the evidence verifier rejects the report "
        "(counts as a failed attempt), the task re-executes and the run is "
        "DONE — a false pass never advances.",
    ),
    _scenario(
        27,
        "destructive action outside approved policy",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.HALTED,
        "A destructive operation outside the classified destructive-action "
        "policy is requested after LOCK (E4): the operation is denied, the "
        "run halts HALTED with the consolidated decision and nothing "
        "irreversible happens.",
    ),
    _scenario(
        28,
        "provider rate limit exhausts retry budget",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.HALTED,
        "Persistent provider rate limiting exhausts the self-heal attempt "
        "budget (RATE, retry distribution): the escalation ladder ends in "
        "exception evaluation and the run halts HALTED — no infinite retry.",
    ),
    _scenario(
        29,
        "repeated false-pass chain of custody forgery",
        ProjectClass.EXTERNAL_INTEGRATION_HEAVY,
        LifecycleState.HALTED,
        "A worker repeatedly submits invalid pass evidence (fabricated "
        "chain of custody): verification fails closed every time, the "
        "attempt budget is exhausted and the run halts HALTED with the "
        "consolidated decision — forgery never advances the wave.",
    ),
    _scenario(
        30,
        "store rejection Tier1",
        ProjectClass.BROWSER_EXTENSION,
        LifecycleState.HALTED,
        "The extension store REJECTS the submission with Tier-1 impact: "
        "the rejection routes to HALTED carrying the review reasons as the "
        "batched decision (contract revision + re-lock), never a "
        "non-Tier-1 build loop and never a false completion.",
    ),
)

SCENARIOS_BY_ID: Mapping[str, Scenario] = MappingProxyType(
    {scenario.id: scenario for scenario in SCENARIO_CATALOG}
)
