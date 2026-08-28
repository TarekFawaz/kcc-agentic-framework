"""Behavioral tests for the autobuild Build Contract layer.

Written first (strict TDD red phase) against the external behavior
contract of :mod:`kcc_autobuild.contract` (KCC x Superpowers Hybrid
Framework Plan 02, Task 3; Design Spec v1.2 sections 14-15; binding
plan rulings R4/R6/R7).

Binding semantics under test:

* R4 — ``AUTO_PROVISION_AUTHORIZED`` (canonical dependency status from
  :mod:`kcc_autobuild.models`) must never be renamed; the contract
  references it, and auto-provision authorization must be bounded by
  the approved provider whitelist.
* R6 — every Tier-1 fallback-whitelist provider must be backed by a
  matching validated readiness fallback entry before lock.
* R7 — lock time is timezone-aware and normalized to UTC; the
  canonical contract hash covers the Tier-1 JSON only, so Tier-2
  engineering detail (including staging provider detail) may evolve
  without invalidating the lock.

Lock gating (Design Spec v1.2 sections 14.1-14.5, 15):

* trace orphans and unready/unevidenced readiness block lock;
* every paid whitelist provider requires a positive spend cap;
* a production-deployment authority requires a production target;
* destructive operations classified ``REVERSIBLE_WITH_ROLLBACK_REQUIRED``
  require a rollback path and ``IRREVERSIBLE_WHITELISTED`` require a
  verified backup safeguard;
* plaintext credentials are rejected (secret references only).

Round 2 (post-review hardening, review feedback of 3030691):

* the R6 core gate branch is tested directly: a *whitelisted* fallback
  provider with no validated readiness fallback entry blocks lock, and
  a validated fallback for a different provider cannot stand in;
* ``AUTO_PROVISION_AUTHORIZED`` must also be bounded to approved
  accounts (spec §14.3) — recorded and enforced at lock;
* the canonical hash is insensitive to Tier-1 list insertion order;
* a locked contract is not forgeable: the stored lock hashes must
  match the contract content or construction is rejected;
* the §15 AUTONOMY row ``auto-debug`` authorization is recorded on the
  authority envelope (a Tier-1 invariant);
* the §14.6 resume protocol sources of truth are modeled (execution
  state, excluded from both canonical hashes).
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone

import pytest
from pydantic import ValidationError

from kcc_autobuild.contract import (
    AuthorityEnvelope,
    BuildContract,
    ContractLockError,
    DestructiveAction,
    DestructiveOperationRule,
    MoneyPolicy,
    ProviderEntry,
    ResumeProtocol,
    Tier1Invariants,
    Tier2Details,
    lock_contract,
    tier1_canonical_hash,
    tier2_digest,
)
from kcc_autobuild.models import DependencyStatus, LifecycleState, ReadinessStatus
from kcc_autobuild.readiness import (
    EvidenceRecord,
    FallbackEntry,
    ReadinessItem,
    ReadinessPack,
)
from kcc_autobuild.trace import TraceEdge, TraceGraph, TraceNode

NOW = datetime(2026, 1, 2, 12, 0, 0, tzinfo=timezone.utc)
TTL = timedelta(hours=4)
HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")


# ---------------------------------------------------------------------------
# Helpers (a minimally valid, lockable contract by default)
# ---------------------------------------------------------------------------


def _trace() -> TraceGraph:
    """A trace where REQ-001 reaches both AC and PROD coverage."""
    return TraceGraph(
        nodes=[
            TraceNode(id="REQ-001", kind="requirement"),
            TraceNode(id="IMPL-01", kind="implementation"),
            TraceNode(id="AC-001", kind="acceptance"),
            TraceNode(id="PROD-001", kind="production_validation"),
        ],
        edges=[
            TraceEdge(source="REQ-001", target="IMPL-01"),
            TraceEdge(source="IMPL-01", target="AC-001"),
            TraceEdge(source="IMPL-01", target="PROD-001"),
        ],
    )


def _fallback(
    provider: str = "provider-a",
    credential_ref: str = "vault://acme/service/token",
) -> FallbackEntry:
    return FallbackEntry(
        provider=provider,
        trigger_scope="deploy",
        allowed_function="deploy_app",
        data_classes_allowed=["public"],
        regions_allowed=["us-east-1"],
        credential_ref=credential_ref,
    )


def _item(
    provider: str = "provider-a",
    fallbacks: list[FallbackEntry] | None = None,
) -> ReadinessItem:
    return ReadinessItem(
        id="IT-001",
        provider=provider,
        status=ReadinessStatus.READY,
        required_kinds=["identity"],
        evidence=[
            EvidenceRecord(
                kind="identity",
                result="pass",
                checked_at=NOW,
                resource_ids=["resource-1"],
                scopes=["scopes:read"],
            )
        ],
        fallbacks=[] if fallbacks is None else fallbacks,
        evidence_ttl=TTL,
    )


def _pack(
    items: list[ReadinessItem] | None = None,
) -> ReadinessPack:
    return ReadinessPack(items=[_item()] if items is None else items)


def _authority(**kwargs: object) -> AuthorityEnvelope:
    defaults: dict[str, object] = {
        "auto_provision_status": DependencyStatus.NOT_REQUIRED,
    }
    defaults.update(kwargs)
    return AuthorityEnvelope(**defaults)


def _money(**kwargs: object) -> MoneyPolicy:
    defaults: dict[str, object] = {"per_provider_caps": {"provider-a": 50_000}}
    defaults.update(kwargs)
    return MoneyPolicy(**defaults)


def _tier1(**kwargs: object) -> Tier1Invariants:
    defaults: dict[str, object] = {
        "product_scope": "internal CLI analysis tool",
        "non_goals": ["no public API"],
        "primary_user_journeys": ["run one analysis end to end"],
        "provider_whitelist": [ProviderEntry(provider="provider-a", paid=True)],
        "fallback_whitelist": [],
        "authority": _authority(),
        "money": _money(),
        "production_target": "https://app.internal.example.com",
        "definition_of_done": (
            "analysis output is produced end to end and validated in staging"
        ),
    }
    defaults.update(kwargs)
    return Tier1Invariants(**defaults)


def _contract(**kwargs: object) -> BuildContract:
    defaults: dict[str, object] = {
        "tier1": _tier1(),
        "tier2": Tier2Details(
            staging_provider="provider-a",
            helper_libraries=["lib-x"],
        ),
        "trace": _trace(),
        "readiness": _pack(),
    }
    defaults.update(kwargs)
    return BuildContract(**defaults)


def _lock_reasons(contract: BuildContract, **kwargs: object) -> list[str]:
    with pytest.raises(ContractLockError) as excinfo:
        lock_contract(contract, **kwargs)
    return excinfo.value.reasons


# ---------------------------------------------------------------------------
# Model construction and validation
# ---------------------------------------------------------------------------


def test_build_contract_constructs_with_locked_invariants() -> None:
    """A full contract constructs and exposes both contract tiers."""
    contract = _contract()
    assert isinstance(contract.tier1, Tier1Invariants)
    assert isinstance(contract.tier2, Tier2Details)
    assert contract.tier1.product_scope == "internal CLI analysis tool"
    assert contract.tier1.provider_whitelist[0].provider == "provider-a"
    assert contract.tier1.money.per_provider_caps == {"provider-a": 50_000}


def test_tier1_requires_product_scope() -> None:
    """An empty product scope cannot be a locked invariant."""
    with pytest.raises(ValidationError):
        _tier1(product_scope="")


def test_tier1_requires_definition_of_done() -> None:
    """The Definition of Done is a mandatory locked invariant."""
    with pytest.raises(ValidationError):
        _tier1(definition_of_done="  ")


def test_provider_entry_defaults_to_not_paid() -> None:
    """Whitelist providers are free-tier by default; paid is explicit."""
    entry = ProviderEntry(provider="free-provider")
    assert entry.paid is False


def test_money_policy_rejects_non_positive_caps() -> None:
    """Per-provider spend caps must be strictly positive."""
    for cap in (0, -5):
        with pytest.raises(ValidationError):
            _money(per_provider_caps={"provider-a": cap})


def test_money_policy_defaults_to_hard_limits() -> None:
    """Limits default to hard: breaches halt autonomous progression."""
    assert MoneyPolicy().hard_limits is True


def test_authority_default_auto_provision_is_fail_closed() -> None:
    """Without explicit authorization auto-provision stays fail-closed."""
    envelope = AuthorityEnvelope()
    assert envelope.auto_provision_status == DependencyStatus.USER_MUST_PROVIDE
    assert envelope.auto_provision_providers == []


def test_duplicate_whitelist_providers_rejected() -> None:
    """A whitelist cannot register the same provider twice."""
    with pytest.raises(ValidationError):
        _tier1(
            provider_whitelist=[
                ProviderEntry(provider="provider-a"),
                ProviderEntry(provider="provider-a"),
            ]
        )


# ---------------------------------------------------------------------------
# R7 — timezone-aware lock time
# ---------------------------------------------------------------------------


def test_build_contract_rejects_naive_locked_at() -> None:
    """``locked_at`` must be timezone-aware (R7)."""
    with pytest.raises(ValidationError):
        BuildContract(
            tier1=_tier1(),
            locked_at=datetime(2026, 1, 2, 12, 0, 0),
        )


def test_build_contract_normalizes_locked_at_to_utc() -> None:
    """Aware ``locked_at`` values are normalized to UTC (R7)."""
    twin = _contract()
    contract = _contract(
        locked_at=datetime(
            2026, 1, 2, 17, 30, 0, tzinfo=timezone(timedelta(hours=5, minutes=30))
        ),
        contract_hash=tier1_canonical_hash(twin),
        tier2_hash=tier2_digest(twin),
    )
    assert contract.locked_at == NOW
    assert contract.locked_at.utcoffset() == timedelta(0)


def test_build_contract_rejects_non_hex_hash() -> None:
    """Stored hashes are pinned to the canonical 64-hex format."""
    with pytest.raises(ValidationError):
        BuildContract(tier1=_tier1(), contract_hash="not-a-sha256")


def test_lock_rejects_naive_now() -> None:
    """Locking at a naive instant is rejected (R7)."""
    reasons = _lock_reasons(_contract(), now=datetime(2026, 1, 2, 12, 0, 0))
    assert any("timezone-aware" in reason for reason in reasons)


def test_lock_normalizes_locked_at_to_utc() -> None:
    """A non-UTC aware ``now`` locks at the same instant normalized to UTC."""
    now = datetime(
        2026, 1, 2, 17, 30, 0, tzinfo=timezone(timedelta(hours=5, minutes=30))
    )
    locked = lock_contract(_contract(), now=now)
    assert locked.locked_at == NOW
    assert locked.locked_at.utcoffset() == timedelta(0)


def test_lock_without_explicit_now_uses_utc() -> None:
    """Omitted ``now`` defaults to the current UTC instant."""
    # Non-blocking item: the test must not depend on wall-clock freshness.
    pack = ReadinessPack(
        items=[
            ReadinessItem(
                id="IT-001",
                provider="provider-a",
                status=ReadinessStatus.RISK_MITIGATED,
                required_kinds=["identity"],
            )
        ]
    )
    locked = lock_contract(_contract(readiness=pack))
    assert locked.locked_at is not None
    assert locked.locked_at.utcoffset() == timedelta(0)


# ---------------------------------------------------------------------------
# Hashing: Tier-2 digest and Tier-1-only canonical hash (R7)
# ---------------------------------------------------------------------------


def test_tier2_digest_is_stable() -> None:
    """The same Tier-2 detail digests to the same 64-hex value."""
    contract = _contract()
    assert tier2_digest(contract) == tier2_digest(_contract())
    assert HASH_PATTERN.fullmatch(tier2_digest(contract)) is not None


def test_tier2_digest_changes_when_staging_provider_changes() -> None:
    """A Tier-2 provider change changes the Tier-2 digest."""
    first = _contract()
    second = _contract(tier2=Tier2Details(staging_provider="provider-b"))
    assert tier2_digest(first) != tier2_digest(second)


def test_tier2_digest_changes_on_any_tier2_change() -> None:
    """Any autonomous detail change is reflected in the Tier-2 digest."""
    first = _contract()
    second = _contract(tier2=Tier2Details(helper_libraries=["lib-y"]))
    assert tier2_digest(first) != tier2_digest(second)


def test_canonical_hash_ignores_tier2_detail() -> None:
    """The canonical lock hash is Tier-1 only (R7): Tier-2 changes are free."""
    first = _contract()
    second = _contract(
        tier2=Tier2Details(
            staging_provider="provider-b",
            helper_libraries=["lib-y", "lib-z"],
        )
    )
    assert tier1_canonical_hash(first) == tier1_canonical_hash(second)


def test_canonical_hash_ignores_trace_and_readiness() -> None:
    """Trace graph and readiness evidence are not part of the Tier-1 hash."""
    first = _contract()
    second = _contract(trace=TraceGraph(), readiness=ReadinessPack())
    assert tier1_canonical_hash(first) == tier1_canonical_hash(second)


def test_canonical_hash_changes_when_tier1_changes() -> None:
    """Any Tier-1 invariant change invalidates the canonical hash."""
    first = _contract()
    second = _contract(tier1=_tier1(product_scope="a different product build"))
    assert tier1_canonical_hash(first) != tier1_canonical_hash(second)


def test_canonical_hash_is_order_independent() -> None:
    """Cap insertion order must not affect the canonical hash."""
    first = _contract(
        tier1=_tier1(
            money=_money(
                per_provider_caps={"provider-a": 100, "provider-b": 200}
            )
        )
    )
    second = _contract(
        tier1=_tier1(
            money=_money(
                per_provider_caps={"provider-b": 200, "provider-a": 100}
            )
        )
    )
    assert tier1_canonical_hash(first) == tier1_canonical_hash(second)


def test_canonical_hash_is_insensitive_to_tier1_list_order() -> None:
    """Reordering Tier-1 list fields must not change the canonical hash.

    Tier-1 list fields are semantically sets (whitelists, journeys,
    policies); incidental insertion order is not a contract revision.
    """

    def tier1(reversed_order: bool) -> Tier1Invariants:
        def pick(values: list[object]) -> list[object]:
            return list(reversed(values)) if reversed_order else list(values)

        return _tier1(
            non_goals=pick(["no public API", "no authz"]),
            primary_user_journeys=pick(["j1", "j2"]),
            provider_whitelist=pick(
                [
                    ProviderEntry(provider="provider-a", paid=True),
                    ProviderEntry(provider="provider-b"),
                ]
            ),
            fallback_whitelist=pick(["provider-a", "provider-b"]),
            security_constraints=pick(["c1", "c2"]),
            destructive_policy=pick(
                [
                    DestructiveOperationRule(
                        operation="op:one",
                        classification=DestructiveAction.REVERSIBLE_AUTONOMOUS,
                    ),
                    DestructiveOperationRule(
                        operation="op:two",
                        classification=DestructiveAction.REVERSIBLE_AUTONOMOUS,
                    ),
                ]
            ),
        )

    assert tier1_canonical_hash(_contract(tier1=tier1(False))) == (
        tier1_canonical_hash(_contract(tier1=tier1(True)))
    )


# ---------------------------------------------------------------------------
# Locked-state integrity (a locked contract cannot be forged)
# ---------------------------------------------------------------------------


def test_locked_at_without_hashes_is_rejected() -> None:
    """A lock time without its lock hashes is not a valid locked state."""
    with pytest.raises(ValidationError):
        _contract(locked_at=NOW)


def test_lock_hashes_without_locked_at_are_rejected() -> None:
    """Lock hashes without a lock time are not a valid locked state."""
    with pytest.raises(ValidationError):
        _contract(contract_hash="0" * 64, tier2_hash="0" * 64)


def test_locked_state_requires_matching_canonical_hash() -> None:
    """A forged lock hash inconsistent with the Tier-1 content is rejected."""
    with pytest.raises(ValidationError):
        _contract(
            locked_at=NOW,
            contract_hash="0" * 64,
            tier2_hash="0" * 64,
        )


def test_locked_state_round_trips_through_validation() -> None:
    """A legitimately locked contract revalidates with identical hashes."""
    locked = lock_contract(_contract(), now=NOW)
    rebuilt = BuildContract.model_validate(locked.model_dump())
    assert rebuilt.contract_hash == locked.contract_hash
    assert rebuilt.tier2_hash == locked.tier2_hash
    assert rebuilt.locked_at == locked.locked_at


# ---------------------------------------------------------------------------
# §14.6 — resume protocol sources of truth
# ---------------------------------------------------------------------------


def test_resume_protocol_defaults_to_empty_sources_of_truth() -> None:
    """The resume protocol starts empty; nothing is presumed completed."""
    protocol = ResumeProtocol()
    assert protocol.lifecycle_state is None
    assert protocol.current_task is None
    assert protocol.completed_task_commits == []
    assert protocol.test_results == []
    assert protocol.review_state is None
    assert protocol.outstanding_findings == []
    assert protocol.attempt_counters == {}
    assert protocol.spend_so_far == {}
    assert protocol.deviations == []
    assert protocol.contract_version is None


def test_contract_records_resume_sources_of_truth() -> None:
    """The §14.6 restart/resume sources of truth are modeled on the contract."""
    contract = _contract(
        resume=ResumeProtocol(
            lifecycle_state=LifecycleState.BUILDING,
            current_task="implement T03",
            completed_task_commits=["ab" * 20],
            test_results=["unit: 63 passed"],
            review_state="clean",
            outstanding_findings=["one minor finding"],
            attempt_counters={"task-retries": 1},
            spend_so_far={"provider-a": 5000},
            deviations=["staging_provider selected"],
            contract_version="1.0",
        )
    )
    assert contract.resume.lifecycle_state is LifecycleState.BUILDING
    assert contract.resume.current_task == "implement T03"
    assert contract.resume.completed_task_commits == ["ab" * 20]
    assert contract.resume.spend_so_far == {"provider-a": 5000}
    assert contract.resume.contract_version == "1.0"


def test_resume_state_does_not_affect_canonical_lock_hashes() -> None:
    """Resume state is execution state, not a locked hash decision (R7)."""
    first = _contract()
    second = _contract(resume=ResumeProtocol(current_task="resumed mid-build"))
    assert tier1_canonical_hash(first) == tier1_canonical_hash(second)
    assert tier2_digest(first) == tier2_digest(second)


def test_resume_rejects_negative_counters_and_spend() -> None:
    """Attempt counters and spend-so-far cannot be negative."""
    with pytest.raises(ValidationError):
        ResumeProtocol(attempt_counters={"task-retries": -1})
    with pytest.raises(ValidationError):
        ResumeProtocol(spend_so_far={"provider-a": -1})


# ---------------------------------------------------------------------------
# Locking success
# ---------------------------------------------------------------------------


def test_lock_records_canonical_hash_and_utc_lock_time() -> None:
    """A passable contract locks with the Tier-1 hash and UTC lock time."""
    contract = _contract()
    locked = lock_contract(contract, now=NOW)
    assert locked is contract
    assert locked.locked_at == NOW
    assert locked.contract_hash == tier1_canonical_hash(contract)
    assert HASH_PATTERN.fullmatch(locked.contract_hash) is not None
    assert locked.tier2_hash == tier2_digest(contract)


def test_lock_refuses_a_second_lock() -> None:
    """An already locked contract cannot be locked again."""
    locked = lock_contract(_contract(), now=NOW)
    reasons = _lock_reasons(locked, now=NOW)
    assert any("already locked" in reason for reason in reasons)


def test_contract_lock_error_carries_reasons() -> None:
    """ContractLockError aggregates all gating failures."""
    error = ContractLockError(["first failure", "second failure"])
    assert error.reasons == ["first failure", "second failure"]
    assert "first failure" in str(error)
    assert "second failure" in str(error)


# ---------------------------------------------------------------------------
# Trace / readiness gating
# ---------------------------------------------------------------------------


def test_lock_blocks_trace_orphans() -> None:
    """Requirements without AC+PROD coverage block lock."""
    orphan_trace = TraceGraph(
        nodes=[
            TraceNode(id="REQ-001", kind="requirement"),
            TraceNode(id="AC-001", kind="acceptance"),
        ],
        edges=[TraceEdge(source="REQ-001", target="AC-001")],
    )
    reasons = _lock_reasons(_contract(trace=orphan_trace), now=NOW)
    assert any("orphan" in reason and "REQ-001" in reason for reason in reasons)


def test_lock_blocks_declared_readiness_blocker() -> None:
    """A declared BLOCKER in the readiness pack prevents lock."""
    blocked = ReadinessPack(
        items=[
            ReadinessItem(
                id="IT-001",
                provider="provider-a",
                status=ReadinessStatus.BLOCKER,
                required_kinds=["identity"],
                evidence=[
                    EvidenceRecord(kind="identity", result="pass", checked_at=NOW)
                ],
            )
        ]
    )
    reasons = _lock_reasons(_contract(readiness=blocked), now=NOW)
    assert any("blocker" in reason and "IT-001" in reason for reason in reasons)


def test_lock_blocks_empty_readiness_pack() -> None:
    """No evidence coverage means no lock even without declared blockers."""
    contract = _contract(trace=TraceGraph(), readiness=ReadinessPack())
    reasons = _lock_reasons(contract, now=NOW)
    assert any("evidence coverage" in reason for reason in reasons)


def test_lock_blocks_fresh_failing_evidence() -> None:
    """A fresh failing probe cannot silently pass the lock gate."""
    failing = ReadinessPack(
        items=[
            ReadinessItem(
                id="IT-001",
                provider="provider-a",
                status=ReadinessStatus.READY,
                required_kinds=["identity"],
                evidence=[
                    EvidenceRecord(kind="identity", result="fail", checked_at=NOW)
                ],
            )
        ]
    )
    reasons = _lock_reasons(_contract(readiness=failing), now=NOW)
    assert any("blocker" in reason and "IT-001" in reason for reason in reasons)


# ---------------------------------------------------------------------------
# Authority / money / production target gating
# ---------------------------------------------------------------------------


def test_lock_requires_spend_cap_for_paid_provider() -> None:
    """A paid whitelist provider without a cap blocks lock (hard limits)."""
    reasons = _lock_reasons(
        _contract(tier1=_tier1(money=_money(per_provider_caps={}))),
        now=NOW,
    )
    assert any(
        "paid provider" in reason and "provider-a" in reason for reason in reasons
    )


def test_lock_allows_free_provider_without_cap() -> None:
    """Free (unpaid) providers require no spend cap."""
    contract = _contract(
        tier1=_tier1(
            provider_whitelist=[ProviderEntry(provider="provider-a")],
        )
    )
    locked = lock_contract(contract, now=NOW)
    assert locked.contract_hash == tier1_canonical_hash(contract)


def test_lock_requires_production_target_when_authorized() -> None:
    """Production deployment authority requires a defined production target."""
    reasons = _lock_reasons(
        _contract(
            tier1=_tier1(
                authority=_authority(production_deployment=True),
                production_target=None,
            )
        ),
        now=NOW,
    )
    assert any("production target" in reason for reason in reasons)


def test_lock_succeeds_with_production_target() -> None:
    """With a target in place, production deployment authority locks."""
    contract = _contract(
        tier1=_tier1(authority=_authority(production_deployment=True))
    )
    locked = lock_contract(contract, now=NOW)
    assert locked.contract_hash == tier1_canonical_hash(contract)


# ---------------------------------------------------------------------------
# Destructive-action policy gating
# ---------------------------------------------------------------------------


def test_lock_requires_rollback_path_for_rollback_required() -> None:
    """REVERSIBLE_WITH_ROLLBACK_REQUIRED must define a rollback path."""
    reasons = _lock_reasons(
        _contract(
            tier1=_tier1(
                destructive_policy=[
                    DestructiveOperationRule(
                        operation="db:migrate",
                        classification=DestructiveAction.REVERSIBLE_WITH_ROLLBACK_REQUIRED,
                    )
                ]
            )
        ),
        now=NOW,
    )
    assert any(
        "rollback path" in reason and "db:migrate" in reason
        for reason in reasons
    )


def test_lock_succeeds_with_rollback_path() -> None:
    """A destructive op with a defined rollback path satisfies the gate."""
    contract = _contract(
        tier1=_tier1(
            destructive_policy=[
                DestructiveOperationRule(
                    operation="db:migrate",
                    classification=DestructiveAction.REVERSIBLE_WITH_ROLLBACK_REQUIRED,
                    rollback_path="db:rollback --step=prev",
                )
            ]
        )
    )
    locked = lock_contract(contract, now=NOW)
    assert locked.contract_hash == tier1_canonical_hash(contract)


def test_lock_requires_backup_for_irreversible_whitelisted() -> None:
    """IRREVERSIBLE_WHITELISTED requires the verified backup safeguard."""
    reasons = _lock_reasons(
        _contract(
            tier1=_tier1(
                destructive_policy=[
                    DestructiveOperationRule(
                        operation="dns:cut-over",
                        classification=DestructiveAction.IRREVERSIBLE_WHITELISTED,
                    )
                ]
            )
        ),
        now=NOW,
    )
    assert any("backup" in reason and "dns:cut-over" in reason for reason in reasons)


def test_lock_allows_reversible_autonomous_without_rollback() -> None:
    """Plainly reversible operations need no extra safeguards."""
    contract = _contract(
        tier1=_tier1(
            destructive_policy=[
                DestructiveOperationRule(
                    operation="staging:redeploy",
                    classification=DestructiveAction.REVERSIBLE_AUTONOMOUS,
                )
            ]
        )
    )
    locked = lock_contract(contract, now=NOW)
    assert locked.contract_hash == tier1_canonical_hash(contract)


def test_destructive_action_values_pinned() -> None:
    """Destructive action classifications are pinned (Design Spec v1.2 §14.5)."""
    assert [member.value for member in DestructiveAction] == [
        "REVERSIBLE_AUTONOMOUS",
        "REVERSIBLE_WITH_ROLLBACK_REQUIRED",
        "IRREVERSIBLE_WHITELISTED",
        "IRREVERSIBLE_NOT_AUTHORIZED",
    ]


# ---------------------------------------------------------------------------
# R6 — fallback whitelist backed by validated readiness fallbacks
# ---------------------------------------------------------------------------


def test_r6_fallback_whitelist_requires_validated_entry() -> None:
    """An approved fallback cannot exist only on paper (R6).

    ``provider-b`` is on the approved provider whitelist, so the lock
    must reach the R6 core gate: a whitelisted fallback provider with
    no validated readiness fallback entry blocks lock.
    """
    reasons = _lock_reasons(
        _contract(
            tier1=_tier1(
                fallback_whitelist=["provider-b"],
                provider_whitelist=[
                    ProviderEntry(provider="provider-a", paid=True),
                    ProviderEntry(provider="provider-b"),
                ],
            )
        ),
        now=NOW,
    )
    assert any(
        "provider-b" in reason
        and "no validated readiness fallback entry" in reason
        for reason in reasons
    )


def test_r6_fallback_for_other_provider_does_not_satisfy_whitelist() -> None:
    """A validated fallback for a different provider cannot stand in (R6)."""
    reasons = _lock_reasons(
        _contract(
            tier1=_tier1(
                fallback_whitelist=["provider-b"],
                provider_whitelist=[
                    ProviderEntry(provider="provider-a", paid=True),
                    ProviderEntry(provider="provider-b"),
                ],
            ),
            readiness=_pack(items=[_item(fallbacks=[_fallback("provider-a")])]),
        ),
        now=NOW,
    )
    assert any(
        "provider-b" in reason
        and "no validated readiness fallback entry" in reason
        for reason in reasons
    )


def test_r6_fallback_whitelist_satisfied_by_validated_entry() -> None:
    """A validated readiness fallback entry backs the whitelist approval."""
    contract = _contract(
        tier1=_tier1(
            fallback_whitelist=["provider-b"],
            provider_whitelist=[
                ProviderEntry(provider="provider-a", paid=True),
                ProviderEntry(provider="provider-b"),
            ],
        ),
        readiness=_pack(items=[_item(fallbacks=[_fallback("provider-b")])]),
    )
    locked = lock_contract(contract, now=NOW)
    assert locked.contract_hash == tier1_canonical_hash(contract)


def test_r6_fallback_provider_must_be_on_whitelist() -> None:
    """A fallback provider outside the provider whitelist is not approved."""
    reasons = _lock_reasons(
        _contract(
            tier1=_tier1(
                fallback_whitelist=["provider-b"],
                provider_whitelist=[ProviderEntry(provider="provider-a", paid=True)],
            ),
            readiness=_pack(items=[_item(fallbacks=[_fallback("provider-b")])]),
        ),
        now=NOW,
    )
    assert any(("provider-b" in reason and "whitelist" in reason) for reason in reasons)


# ---------------------------------------------------------------------------
# R4 — canonical AUTO_PROVISION_AUTHORIZED and bounded auto-provision
# ---------------------------------------------------------------------------


def test_auto_provision_authorized_is_canonical_and_never_renamed() -> None:
    """The canonical dependency status name is pinned (R4)."""
    assert "AUTO_PROVISION_AUTHORIZED" in DependencyStatus.__members__
    assert DependencyStatus.AUTO_PROVISION_AUTHORIZED.value == (
        "AUTO_PROVISION_AUTHORIZED"
    )
    envelope = AuthorityEnvelope(
        auto_provision_status=DependencyStatus.AUTO_PROVISION_AUTHORIZED
    )
    assert envelope.auto_provision_status is DependencyStatus.AUTO_PROVISION_AUTHORIZED


def test_auto_provision_authorized_requires_bounded_providers() -> None:
    """AUTO_PROVISION_AUTHORIZED without approved providers blocks lock."""
    reasons = _lock_reasons(
        _contract(
            tier1=_tier1(
                authority=_authority(
                    auto_provision_status=DependencyStatus.AUTO_PROVISION_AUTHORIZED
                )
            )
        ),
        now=NOW,
    )
    assert any("approved providers" in reason for reason in reasons)


def test_auto_provision_authorized_requires_whitelisted_providers() -> None:
    """Auto-provision must be bounded by the provider whitelist (R4)."""
    reasons = _lock_reasons(
        _contract(
            tier1=_tier1(
                authority=_authority(
                    auto_provision_status=DependencyStatus.AUTO_PROVISION_AUTHORIZED,
                    auto_provision_providers=["not-approved-provider"],
                    approved_accounts=["acme-prod"],
                )
            )
        ),
        now=NOW,
    )
    assert any("whitelist" in reason for reason in reasons)


def test_auto_provision_authorized_requires_approved_accounts() -> None:
    """AUTO_PROVISION_AUTHORIZED must be bounded to approved accounts
    (spec §14.3 auto-provisioning within approved accounts/providers).
    """
    reasons = _lock_reasons(
        _contract(
            tier1=_tier1(
                authority=_authority(
                    auto_provision_status=DependencyStatus.AUTO_PROVISION_AUTHORIZED,
                    auto_provision_providers=["provider-a"],
                )
            )
        ),
        now=NOW,
    )
    assert any("approved accounts" in reason for reason in reasons)


def test_auto_provision_authorized_within_whitelist_locks() -> None:
    """Auto-provision bounded to whitelisted providers/accounts is lockable."""
    contract = _contract(
        tier1=_tier1(
            authority=_authority(
                auto_provision_status=DependencyStatus.AUTO_PROVISION_AUTHORIZED,
                auto_provision_providers=["provider-a"],
                approved_accounts=["acme-prod"],
            )
        )
    )
    locked = lock_contract(contract, now=NOW)
    assert locked.contract_hash == tier1_canonical_hash(contract)


# ---------------------------------------------------------------------------
# §15 AUTONOMY row — auto-debug authorization
# ---------------------------------------------------------------------------


def test_authority_auto_debug_defaults_to_not_authorized() -> None:
    """The §15 ``auto-debug authorized`` row starts fail-closed."""
    assert AuthorityEnvelope().auto_debug is False


def test_auto_debug_authorization_is_recorded_on_lock() -> None:
    """The §15 AUTONOMY LOCK row is representable on a locked contract."""
    contract = _contract(tier1=_tier1(authority=_authority(auto_debug=True)))
    locked = lock_contract(contract, now=NOW)
    assert locked.tier1.authority.auto_debug is True
    assert locked.contract_hash == tier1_canonical_hash(contract)


def test_auto_debug_authorization_is_a_tier1_invariant() -> None:
    """Toggling auto-debug authorization revises a Tier-1 decision."""
    first = _contract()
    second = _contract(tier1=_tier1(authority=_authority(auto_debug=True)))
    assert tier1_canonical_hash(first) != tier1_canonical_hash(second)


# ---------------------------------------------------------------------------
# Plaintext credentials are rejected
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "ref",
    ["sk-live-abc123", "AKIAIOSFODNN7EXAMPLE", "correct-horse-battery-staple"],
)
def test_authority_rejects_plaintext_credentials(ref: str) -> None:
    """Only secret references may be attached to the contract (spec §24)."""
    with pytest.raises(ValidationError):
        _authority(credential_refs=[ref])


@pytest.mark.parametrize(
    "ref",
    [
        "vault://acme/prod/deploy-token",
        "env://DEPLOY_TOKEN",
        "keychain://acme/deploy",
    ],
)
def test_authority_accepts_secret_references(ref: str) -> None:
    """vault://, env:// and keychain:// references are accepted."""
    envelope = _authority(credential_refs=[ref])
    assert envelope.credential_refs == [ref]


def test_contract_rejects_plaintext_fallback_credential() -> None:
    """A raw secret inside a readiness fallback entry is rejected."""
    with pytest.raises(ValidationError):
        _contract(
            readiness=_pack(
                items=[
                    _item(fallbacks=[_fallback(credential_ref="sk-live-abc123")])
                ]
            )
        )


def test_contract_accepts_reference_backed_fallback_credential() -> None:
    """A validated secret-reference fallback entry is accepted."""
    contract = _contract(
        readiness=_pack(items=[_item(fallbacks=[_fallback()])]),
    )
    locked = lock_contract(contract, now=NOW)
    assert locked.contract_hash == tier1_canonical_hash(contract)


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------


def test_lock_reports_all_gating_failures_at_once() -> None:
    """lock_contract aggregates every failing gate into one error."""
    contract = _contract(
        tier1=_tier1(
            provider_whitelist=[ProviderEntry(provider="paid-provider", paid=True)],
            fallback_whitelist=["provider-b"],
            authority=_authority(
                auto_provision_status=DependencyStatus.AUTO_PROVISION_AUTHORIZED,
                production_deployment=True,
            ),
            money=_money(per_provider_caps={}),
            production_target=None,
            destructive_policy=[
                DestructiveOperationRule(
                    operation="db:drop",
                    classification=DestructiveAction.REVERSIBLE_WITH_ROLLBACK_REQUIRED,
                )
            ],
        ),
        trace=TraceGraph(
            nodes=[
                TraceNode(id="REQ-001", kind="requirement"),
                TraceNode(id="AC-001", kind="acceptance"),
            ],
            edges=[TraceEdge(source="REQ-001", target="AC-001")],
        ),
    )
    reasons = _lock_reasons(contract, now=NOW)
    assert any("orphan" in reason for reason in reasons)
    assert any("paid-provider" in reason for reason in reasons)
    assert any("production target" in reason for reason in reasons)
    assert any("rollback path" in reason for reason in reasons)
    assert any("provider-b" in reason for reason in reasons)
    assert any("approved providers" in reason for reason in reasons)
    assert any("approved accounts" in reason for reason in reasons)
