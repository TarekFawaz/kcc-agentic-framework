"""Build Contract models and lock enforcement for the autobuild framework.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_contract.py`
(KCC x Superpowers Hybrid Framework Plan 02, Task 3).

Implements the P3 Build Contract of Design Spec v1.2 section 14 and the
final LOCK surface of section 15, with the binding plan rulings:

* R4 — the canonical dependency status ``AUTO_PROVISION_AUTHORIZED``
  (from :mod:`kcc_autobuild.models`) is referenced here and never
  renamed; auto-provision authorization must be bounded by the approved
  provider whitelist.
* R6 — every Tier-1 fallback-whitelist provider must be backed by a
  matching validated readiness fallback entry before lock; approved
  fallbacks cannot exist only on paper.
* R7 — lock time (``locked_at``) is timezone-aware and normalized to
  UTC; the canonical contract hash covers the Tier-1 JSON only, so
  Tier-2 engineering detail may evolve without invalidating the lock.

Structure (two-tier, section 14): :class:`Tier1Invariants` holds every
locked decision — including the authority envelope, money policy,
destructive-action policy of sections 14.3-14.5 and the production
deployment surface (``production_target`` plus the locked
:class:`RolloutClass` the deployment coordinator must use) — while
:class:`Tier2Details` holds the autonomous engineering detail that may
change without user interruption.  The locked contract additionally
carries the validated trace graph, readiness evidence pack and the
§14.6 resume protocol sources of truth that the final LOCK decision
depends on (sections 13, 15).

:func:`lock_contract` is the only path to a locked contract: it
re-checks trace/readiness gating, authority/budget/destructive
safeguards and the R6 fallback backing, records a UTC ``locked_at`` and
stores the Tier-1 canonical hash plus the Tier-2 digest.  A Tier-1
change therefore requires a contract revision and a fresh lock, while
Tier-2 changes never invalidate the canonical hash (R7).
"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from enum import Enum
from typing import Any

from pydantic import BaseModel, Field, ValidationInfo, field_validator, model_validator

from kcc_autobuild.models import DependencyStatus, LifecycleState, StrictModel
from kcc_autobuild.readiness import (
    SECRET_REF_PATTERN,
    ReadinessPack,
    evaluate_readiness,
)
from kcc_autobuild.trace import TraceGraph, validate_trace_coverage

CONTRACT_HASH_PATTERN = r"^[0-9a-f]{64}$"
"""Canonical 64-character lower-case hex SHA-256 fingerprint."""


def _require_nonempty(value: str, name: str) -> str:
    if not value.strip():
        raise ValueError(f"{name} must not be empty")
    return value


def _require_nonempty_strings(value: list[str], name: str) -> list[str]:
    if any(not entry.strip() for entry in value):
        raise ValueError(f"{name} entries must not be empty")
    return value


def _unique_strings(value: list[str], name: str) -> list[str]:
    _require_nonempty_strings(value, name)
    if len(value) != len(set(value)):
        raise ValueError(f"{name} must not contain duplicates")
    return value


class ProviderEntry(StrictModel):
    """One provider on the approved Tier-1 whitelist.

    ``paid`` marks providers whose usage must stay within a positive
    per-provider spend cap; free providers need no cap.
    """

    provider: str
    paid: bool = False

    @field_validator("provider")
    @classmethod
    def _provider_not_blank(cls, value: str) -> str:
        return _require_nonempty(value, "provider")


class AuthorityEnvelope(StrictModel):
    """Explicit authorization granted by the contract (spec 14.3, 15).

    Everything defaults to *not* authorized (fail-closed).  The
    auto-provision classification uses the canonical repository enum
    (R4): ``AUTO_PROVISION_AUTHORIZED`` grants bounded auto-provision
    inside the approved providers *and* approved accounts (both are
    enforced at lock), while ``USER_MUST_PROVIDE`` keeps it on the
    user.  ``auto_debug`` records the AUTONOMY ``auto-debug
    authorized`` row of the section 15 LOCK surface.

    Credential references only: raw secrets are rejected (spec section
    24; ``vault://``, ``env://`` or ``keychain://``).
    """

    auto_provision_status: DependencyStatus = DependencyStatus.USER_MUST_PROVIDE
    auto_provision_providers: list[str] = Field(default_factory=list)
    approved_accounts: list[str] = Field(default_factory=list)
    credential_refs: list[str] = Field(default_factory=list)
    dependency_installation: bool = False
    environment_creation: bool = False
    cicd_configuration: bool = False
    database_migration: bool = False
    dns_changes: bool = False
    approved_dns_zones: list[str] = Field(default_factory=list)
    staging_deployment: bool = False
    production_deployment: bool = False
    rollback: bool = False
    monitoring_setup: bool = False
    secret_reference_usage: bool = False
    bounded_spend: bool = False
    auto_debug: bool = False

    @field_validator("auto_provision_providers", "approved_accounts")
    @classmethod
    def _provider_and_account_lists(
        cls, value: list[str], info: ValidationInfo
    ) -> list[str]:
        return _unique_strings(value, info.field_name)

    @field_validator("approved_dns_zones")
    @classmethod
    def _dns_zones(cls, value: list[str]) -> list[str]:
        return _unique_strings(value, "approved_dns_zones")

    @field_validator("credential_refs")
    @classmethod
    def _credential_refs_are_secret_references(
        cls, value: list[str]
    ) -> list[str]:
        _unique_strings(value, "credential_refs")
        for ref in value:
            if not re.fullmatch(SECRET_REF_PATTERN, ref):
                raise ValueError(
                    "credential_refs entries must be secret references "
                    "(vault://, env:// or keychain://)"
                )
        return value


class MoneyPolicy(StrictModel):
    """Budget policy of the contract (spec 14.4).

    Limits default to *hard*: hard-cap breaches halt autonomous
    progression.  Amounts are integer minor units of ``currency``.
    Per-provider spend caps must be strictly positive when present.
    """

    hard_limits: bool = True
    currency: str = "USD"
    one_time_build_budget: int | None = None
    per_provider_caps: dict[str, int] = Field(default_factory=dict)
    monthly_infrastructure_cap: int | None = None
    model_token_cap: int | None = None

    @field_validator("currency")
    @classmethod
    def _currency_not_blank(cls, value: str) -> str:
        return _require_nonempty(value, "currency")

    @field_validator("per_provider_caps")
    @classmethod
    def _caps_positive(cls, value: dict[str, int]) -> dict[str, int]:
        for provider, cap in value.items():
            _require_nonempty(provider, "per_provider_caps provider")
            if cap <= 0:
                raise ValueError(
                    f"per_provider_caps[{provider!r}] must be strictly positive"
                )
        return value

    @field_validator(
        "one_time_build_budget", "monthly_infrastructure_cap", "model_token_cap"
    )
    @classmethod
    def _optional_caps_positive(cls, value: int | None) -> int | None:
        if value is not None and value <= 0:
            raise ValueError("budget caps must be strictly positive when set")
        return value


class DestructiveAction(str, Enum):
    """Classification of destructive operations (spec 14.5)."""

    REVERSIBLE_AUTONOMOUS = "REVERSIBLE_AUTONOMOUS"
    REVERSIBLE_WITH_ROLLBACK_REQUIRED = "REVERSIBLE_WITH_ROLLBACK_REQUIRED"
    IRREVERSIBLE_WHITELISTED = "IRREVERSIBLE_WHITELISTED"
    IRREVERSIBLE_NOT_AUTHORIZED = "IRREVERSIBLE_NOT_AUTHORIZED"


class DestructiveOperationRule(StrictModel):
    """One destructive operation classified by the contract policy.

    ``REVERSIBLE_WITH_ROLLBACK_REQUIRED`` operations must define a
    rollback path before lock; ``IRREVERSIBLE_WHITELISTED`` operations
    require the verified backup safeguard (``backup_required``).
    """

    operation: str
    classification: DestructiveAction
    rollback_path: str | None = None
    backup_required: bool = False

    @field_validator("operation")
    @classmethod
    def _operation_not_blank(cls, value: str) -> str:
        return _require_nonempty(value, "operation")

    @field_validator("rollback_path")
    @classmethod
    def _rollback_path_not_blank(
        cls, value: str | None
    ) -> str | None:
        if value is not None:
            _require_nonempty(value, "rollback_path")
        return value


class RolloutClass(str, Enum):
    """The rollout class locked into Tier 1 for production deployment.

    The strategy a production deployment may use is a material
    production decision (spec 14.1 locked invariant ``deployment
    authority``; spec 14.3 authority envelope: ``production
    deployment`` / ``rollback``), so the contract locks it into Tier 1:

    ``CANARY`` -- deploy to production through a canary gate: the
    post-deploy health check decides between DEPLOYED and an immediate
    rollback.  ``DIRECT`` -- expose directly to production (still
    health-checked; on failure the same rollback path applies).

    The deployment coordinator and the deployment adapter of Plan 05
    Task 3 consume exactly this vocabulary (see
    :mod:`kcc_autobuild.deployment`) -- the contract model owns the
    canonical members, never a parallel copy.
    """

    CANARY = "CANARY"
    DIRECT = "DIRECT"


class Tier2Details(StrictModel):
    """Autonomous engineering detail (spec 14.2).

    These entries may change after lock without user interruption as
    long as Tier-1 invariants hold; changes are tracked via the Tier-2
    digest and do not affect the canonical Tier-1 hash (R7).
    """

    component_boundaries: list[str] = Field(default_factory=list)
    internal_api_shapes: list[str] = Field(default_factory=list)
    helper_libraries: list[str] = Field(default_factory=list)
    db_indexes: list[str] = Field(default_factory=list)
    error_wording: str | None = None
    internal_refactors: list[str] = Field(default_factory=list)
    test_organization: list[str] = Field(default_factory=list)
    minor_dependency_changes: list[str] = Field(default_factory=list)
    observability_thresholds: list[str] = Field(default_factory=list)
    css_layout_detail: str | None = None
    staging_provider: str | None = None

    @field_validator(
        "component_boundaries",
        "internal_api_shapes",
        "helper_libraries",
        "db_indexes",
        "internal_refactors",
        "test_organization",
        "minor_dependency_changes",
        "observability_thresholds",
    )
    @classmethod
    def _detail_lists(
        cls, value: list[str], info: ValidationInfo
    ) -> list[str]:
        return _require_nonempty_strings(value, info.field_name)

    @field_validator(
        "error_wording", "css_layout_detail", "staging_provider"
    )
    @classmethod
    def _detail_strings(
        cls, value: str | None, info: ValidationInfo
    ) -> str | None:
        if value is not None:
            _require_nonempty(value, info.field_name)
        return value


class ResumeProtocol(StrictModel):
    """Restart/resume source of truth (spec §14.6).

    A resumed session continues from this durable state instead of
    repeating completed work from conversational memory.  It is
    execution state, not a locked decision: it starts empty, is updated
    by the runtime after lock, and is excluded from both the Tier-1
    canonical hash (R7) and the Tier-2 digest.
    """

    lifecycle_state: LifecycleState | None = None
    current_task: str | None = None
    completed_task_commits: list[str] = Field(default_factory=list)
    test_results: list[str] = Field(default_factory=list)
    review_state: str | None = None
    outstanding_findings: list[str] = Field(default_factory=list)
    attempt_counters: dict[str, int] = Field(default_factory=dict)
    spend_so_far: dict[str, int] = Field(default_factory=dict)
    deviations: list[str] = Field(default_factory=list)
    contract_version: str | None = None

    @field_validator("current_task", "review_state", "contract_version")
    @classmethod
    def _optional_text(
        cls, value: str | None, info: ValidationInfo
    ) -> str | None:
        if value is not None:
            _require_nonempty(value, info.field_name)
        return value

    @field_validator(
        "completed_task_commits", "test_results", "outstanding_findings", "deviations"
    )
    @classmethod
    def _detail_entries(
        cls, value: list[str], info: ValidationInfo
    ) -> list[str]:
        return _require_nonempty_strings(value, info.field_name)

    @field_validator("attempt_counters", "spend_so_far")
    @classmethod
    def _non_negative_amounts(
        cls, value: dict[str, int], info: ValidationInfo
    ) -> dict[str, int]:
        for key, amount in value.items():
            _require_nonempty(key, f"{info.field_name} key")
            if amount < 0:
                raise ValueError(f"{info.field_name} values must not be negative")
        return value


class Tier1Invariants(StrictModel):
    """Locked Tier-1 invariants (spec 14.1).

    Every material decision that a Tier-1 change would revise lives
    here — including the authority envelope, money policy and
    destructive-action policy of sections 14.3-14.5, the production
    deployment surface and the outcome-based Definition of Done — so the
    canonical hash (R7) covers exactly the locked content.
    """

    product_scope: str
    non_goals: list[str] = Field(default_factory=list)
    primary_user_journeys: list[str] = Field(default_factory=list)
    ux_direction: str | None = None
    prototype_ref: str | None = None
    provider_whitelist: list[ProviderEntry] = Field(default_factory=list)
    fallback_whitelist: list[str] = Field(default_factory=list)
    auth_model: str | None = None
    core_data_entities: list[str] = Field(default_factory=list)
    security_constraints: list[str] = Field(default_factory=list)
    authority: AuthorityEnvelope
    money: MoneyPolicy
    destructive_policy: list[DestructiveOperationRule] = Field(
        default_factory=list
    )
    production_target: str | None = None
    rollout_class: RolloutClass | None = None
    definition_of_done: str
    definition_of_done_ids: list[str]
    requires_rollback_evidence: bool = False

    @field_validator("product_scope", "definition_of_done")
    @classmethod
    def _required_text(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)

    @field_validator("definition_of_done_ids")
    @classmethod
    def _definition_of_done_ids_required_and_unique(
        cls, value: list[str]
    ) -> list[str]:
        """The production-outcome set that gates DONE (spec 21).

        The default Definition of Done is outcome-based, so the locked
        contract must name at least one production validation outcome;
        the set is unique and every entry non-empty.
        """
        unique = _unique_strings(value, "definition_of_done_ids")
        if not unique:
            raise ValueError(
                "definition_of_done_ids must name at least one "
                "production outcome (the Definition of Done is "
                "outcome-based, spec 21)"
            )
        return unique

    @field_validator("non_goals", "primary_user_journeys")
    @classmethod
    def _required_lists(cls, value: list[str], info: ValidationInfo) -> list[str]:
        return _require_nonempty_strings(value, info.field_name)

    @field_validator("fallback_whitelist")
    @classmethod
    def _fallback_whitelist_unique(cls, value: list[str]) -> list[str]:
        return _unique_strings(value, "fallback_whitelist")

    @field_validator("core_data_entities", "security_constraints")
    @classmethod
    def _entity_and_security_lists(
        cls, value: list[str], info: ValidationInfo
    ) -> list[str]:
        return _require_nonempty_strings(value, info.field_name)

    @field_validator("provider_whitelist")
    @classmethod
    def _whitelist_unique(cls, value: list[ProviderEntry]) -> list[ProviderEntry]:
        providers = [entry.provider for entry in value]
        if len(providers) != len(set(providers)):
            raise ValueError("provider_whitelist must not contain duplicates")
        return value

    @field_validator("ux_direction", "prototype_ref", "auth_model")
    @classmethod
    def _optional_text(
        cls, value: str | None, info: ValidationInfo
    ) -> str | None:
        if value is not None:
            _require_nonempty(value, info.field_name)
        return value

    @field_validator("production_target")
    @classmethod
    def _production_target_not_blank(cls, value: str | None) -> str | None:
        if value is not None:
            _require_nonempty(value, "production_target")
        return value

    @field_validator("rollout_class")
    @classmethod
    def _rollout_class_is_canonical(
        cls, value: RolloutClass | None
    ) -> RolloutClass | None:
        if value is not None and not isinstance(value, RolloutClass):
            raise ValueError(
                "rollout_class must be a canonical rollout class "
                "(CANARY or DIRECT)"
            )
        return value

    @field_validator("destructive_policy")
    @classmethod
    def _destructive_operations_unique(
        cls, value: list[DestructiveOperationRule]
    ) -> list[DestructiveOperationRule]:
        operations = [rule.operation for rule in value]
        if len(operations) != len(set(operations)):
            raise ValueError("destructive_policy operations must be unique")
        return value


class BuildContract(StrictModel):
    """The machine- and human-readable two-tier Build Contract (spec 14).

    ``locked_at`` must be timezone-aware and is normalized to UTC (R7);
    ``contract_hash`` is the canonical Tier-1 hash and ``tier2_hash``
    the Tier-2 digest, both stored by :func:`lock_contract`.  ``resume``
    carries the §14.6 restart/resume sources of truth; it is execution
    state and is not part of either hash.  A locked contract is only
    constructible with hashes matching its content — the stored hash
    set cannot be forged by a direct constructor call.
    """

    contract_version: str = "1.0"
    tier1: Tier1Invariants
    tier2: Tier2Details = Field(default_factory=Tier2Details)
    trace: TraceGraph = Field(default_factory=TraceGraph)
    readiness: ReadinessPack = Field(default_factory=ReadinessPack)
    resume: ResumeProtocol = Field(default_factory=ResumeProtocol)
    locked_at: datetime | None = None
    contract_hash: str | None = None
    tier2_hash: str | None = None

    @field_validator("contract_version")
    @classmethod
    def _version_not_blank(cls, value: str) -> str:
        return _require_nonempty(value, "contract_version")

    @field_validator("locked_at")
    @classmethod
    def _locked_at_must_be_aware_utc(cls, value: datetime | None) -> datetime | None:
        if value is None:
            return None
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("locked_at must be timezone-aware")
        return value.astimezone(timezone.utc)

    @field_validator("contract_hash", "tier2_hash")
    @classmethod
    def _hashes_are_hex(cls, value: str | None, info: ValidationInfo) -> str | None:
        if value is None:
            return None
        if not re.fullmatch(CONTRACT_HASH_PATTERN, value):
            raise ValueError(f"{info.field_name} must be a 64-char hex sha256")
        return value

    @model_validator(mode="after")
    def _locked_state_must_be_consistent(self) -> "BuildContract":
        """A locked contract is only constructible with matching lock hashes.

        Prevents forging a locked contract with hand-picked hashes: the
        stored Tier-1 hash must equal the canonical hash of the locked
        Tier-1 invariants and the Tier-2 hash must equal the Tier-2
        digest.  :func:`lock_contract` is the only path that stores a
        consistent hash set.
        """
        if self.locked_at is None:
            if self.contract_hash is not None or self.tier2_hash is not None:
                raise ValueError(
                    "lock hashes require a lock time (locked_at is not set)"
                )
            return self
        if self.contract_hash is None or self.tier2_hash is None:
            raise ValueError("a locked contract must store both lock hashes")
        if self.contract_hash != tier1_canonical_hash(self):
            raise ValueError(
                "contract_hash does not match the canonical Tier-1 hash"
            )
        if self.tier2_hash != tier2_digest(self):
            raise ValueError("tier2_hash does not match the Tier-2 digest")
        return self


class ContractLockError(ValueError):
    """Raised when :func:`lock_contract` refuses to lock a contract.

    Carries every failing gate in :attr:`reasons` so a single revision
    can address the whole set instead of one failure at a time.
    """

    def __init__(self, reasons: list[str]) -> None:
        self.reasons = list(reasons)
        super().__init__("; ".join(self.reasons))


def _canonicalize(value: Any) -> Any:
    """Normalize a JSON-safe value for canonical hashing.

    Dict keys are sorted and list order is discarded (contract list
    fields are semantically sets), so the canonical hash is insensitive
    to incidental insertion order and identical across processes.
    """
    if isinstance(value, dict):
        return {key: _canonicalize(item) for key, item in sorted(value.items())}
    if isinstance(value, list):
        return sorted((_canonicalize(item) for item in value), key=json.dumps)
    return value


def _canonical_json(model: BaseModel) -> str:
    """Deterministic JSON: sorted keys, normalized list order, compact separators."""
    return json.dumps(
        _canonicalize(model.model_dump(mode="json")),
        sort_keys=True,
        separators=(",", ":"),
    )


def tier1_canonical_hash(contract: BuildContract) -> str:
    """Canonical lock hash: SHA-256 over the Tier-1 JSON only (R7).

    Tier-2 detail, trace/readiness evidence and lock metadata never
    change this hash; any Tier-1 change does.
    """
    return hashlib.sha256(
        _canonical_json(contract.tier1).encode("utf-8")
    ).hexdigest()


def tier2_digest(contract: BuildContract) -> str:
    """Digest of the autonomous engineering detail (spec 14.2).

    Stable for identical Tier-2 content and sensitive to any Tier-2
    change (including staging provider detail); it is not the canonical
    lock hash.
    """
    return hashlib.sha256(
        _canonical_json(contract.tier2).encode("utf-8")
    ).hexdigest()


def _check_trace(contract: BuildContract) -> list[str]:
    coverage = validate_trace_coverage(contract.trace)
    if coverage.orphans:
        return [f"trace orphans: {', '.join(coverage.orphans)}"]
    return []


def _check_readiness(contract: BuildContract, now_utc: datetime) -> list[str]:
    evaluation = evaluate_readiness(contract.readiness, now=now_utc)
    reasons: list[str] = []
    if not evaluation.coverage_ok:
        reasons.append("readiness pack has no evidence coverage")
    if evaluation.blockers:
        reasons.append(f"readiness blockers: {', '.join(evaluation.blockers)}")
    if evaluation.open_red_team_findings:
        reasons.append(
            "open red team findings: "
            + ", ".join(evaluation.open_red_team_findings)
        )
    return reasons


def _check_authority(contract: BuildContract) -> list[str]:
    authority = contract.tier1.authority
    if authority.auto_provision_status != DependencyStatus.AUTO_PROVISION_AUTHORIZED:
        return []
    reasons: list[str] = []
    if not authority.auto_provision_providers:
        reasons.append("auto-provision is authorized without approved providers")
    if not authority.approved_accounts:
        reasons.append("auto-provision is authorized without approved accounts")
    whitelist = {entry.provider for entry in contract.tier1.provider_whitelist}
    reasons.extend(
        f"auto-provision provider '{provider}' is not on the provider whitelist"
        for provider in authority.auto_provision_providers
        if provider not in whitelist
    )
    return reasons


def _check_money(contract: BuildContract) -> list[str]:
    caps = contract.tier1.money.per_provider_caps
    return [
        f"paid provider '{entry.provider}' has no spend cap"
        for entry in contract.tier1.provider_whitelist
        if entry.paid and caps.get(entry.provider, 0) <= 0
    ]


def _check_production_target(contract: BuildContract) -> list[str]:
    if (
        contract.tier1.authority.production_deployment
        and not contract.tier1.production_target
    ):
        return ["production deployment is authorized without a production target"]
    return []


def _check_rollout_class(contract: BuildContract) -> list[str]:
    if (
        contract.tier1.authority.production_deployment
        and contract.tier1.rollout_class is None
    ):
        return [
            "production deployment is authorized without a locked rollout class"
        ]
    return []


def _check_destructive_policy(contract: BuildContract) -> list[str]:
    reasons: list[str] = []
    for rule in contract.tier1.destructive_policy:
        if (
            rule.classification == DestructiveAction.REVERSIBLE_WITH_ROLLBACK_REQUIRED
            and not rule.rollback_path
        ):
            reasons.append(
                f"destructive operation '{rule.operation}' requires a rollback path"
            )
        elif (
            rule.classification == DestructiveAction.IRREVERSIBLE_WHITELISTED
            and not rule.backup_required
        ):
            reasons.append(
                f"destructive operation '{rule.operation}' requires verified backup"
            )
    return reasons


def _check_fallback_whitelist(contract: BuildContract) -> list[str]:
    whitelist = {entry.provider for entry in contract.tier1.provider_whitelist}
    fallback_providers = {
        fallback.provider
        for item in contract.readiness.items
        for fallback in item.fallbacks
    }
    reasons: list[str] = []
    for provider in contract.tier1.fallback_whitelist:
        if provider not in whitelist:
            reasons.append(
                f"fallback provider '{provider}' is not on the provider whitelist"
            )
        elif provider not in fallback_providers:
            reasons.append(
                f"fallback provider '{provider}' has no validated "
                "readiness fallback entry"
            )
    return reasons


def lock_contract(
    contract: BuildContract,
    *,
    now: datetime | None = None,
) -> BuildContract:
    """Lock a Build Contract or raise :class:`ContractLockError`.

    Checks, in aggregate (all failures reported at once):

    * the contract is not already locked;
    * the trace graph has no orphan requirements;
    * readiness is evidence-backed and ready (current pass evidence;
      no declared blockers; no open red-team findings);
    * ``AUTO_PROVISION_AUTHORIZED`` auto-provision is bounded by the
      approved provider whitelist and the approved accounts (R4,
      spec §14.3);
    * every paid whitelist provider has a positive spend cap;
    * production deployment authority names a production target;
    * production deployment authority locks the rollout class
      (``CANARY`` / ``DIRECT``) the deployment must use (spec 14.1 /
      14.3; consumed by the deployment coordinator);
    * ``REVERSIBLE_WITH_ROLLBACK_REQUIRED`` operations define a
      rollback path and ``IRREVERSIBLE_WHITELISTED`` operations define
      the verified backup safeguard;
    * every Tier-1 fallback-whitelist provider is backed by a validated
      readiness fallback entry (R6).

    On success ``locked_at`` is the UTC-normalized lock instant (R7)
    and the contract stores its Tier-1 canonical hash and Tier-2
    digest.  The contract is mutated in place and returned.
    """
    if contract.contract_hash is not None or contract.locked_at is not None:
        raise ContractLockError(["contract is already locked"])
    if now is None:
        now = datetime.now(timezone.utc)
    elif now.tzinfo is None or now.utcoffset() is None:
        raise ContractLockError(["lock time (now) must be timezone-aware"])
    now_utc = now.astimezone(timezone.utc)

    reasons: list[str] = []
    reasons.extend(_check_trace(contract))
    reasons.extend(_check_readiness(contract, now_utc))
    reasons.extend(_check_authority(contract))
    reasons.extend(_check_money(contract))
    reasons.extend(_check_production_target(contract))
    reasons.extend(_check_rollout_class(contract))
    reasons.extend(_check_destructive_policy(contract))
    reasons.extend(_check_fallback_whitelist(contract))
    if reasons:
        raise ContractLockError(reasons)

    # The lock fields form one atomic, mutually-consistent set; the
    # after-model validator (re-run per field because StrictModel
    # enables validate_assignment) only ever sees the complete set.
    object.__setattr__(contract, "locked_at", now_utc)
    object.__setattr__(contract, "contract_hash", tier1_canonical_hash(contract))
    object.__setattr__(contract, "tier2_hash", tier2_digest(contract))
    return contract
