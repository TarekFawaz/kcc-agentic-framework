"""Behavioral tests for the autobuild readiness evidence layer.

Written first (strict TDD red phase) against the external behavior
contract of :mod:`kcc_autobuild.readiness` plus the provider validator
contracts in :mod:`kcc_autobuild.providers.base` and
:mod:`kcc_autobuild.providers.fake` (KCC x Superpowers Hybrid Framework
Plan 02, Task 2).

Binding semantics under test (rulings R2/R3, Design Spec v1.2 sections
12-13):

* Evidence timestamps are timezone-aware; naive datetimes are rejected
  and aware timestamps are normalized to UTC (R3/R7 direction).
* A READY item is lockable only with current evidence that actually
  supports readiness: the freshest fresh evidence for every required
  probe kind must be ``pass``.  Fresh ``fail`` / ``unknown`` (and stale
  or absent evidence) never satisfy READY; a declared BLOCKER always
  prevents lock.
* ReadinessPack carries typed red-team findings (R2).
* Fallback entries carry secret references only (``vault://`` /
  ``env://`` / ``keychain://``): raw secrets are rejected, and
  trigger scope / allowed function / data classes / regions are
  nonempty.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from pydantic import ValidationError

from kcc_autobuild.models import ReadinessStatus
from kcc_autobuild.providers.base import (
    EvidenceKind,
    EvidenceResult,
    ProbeResult,
    ProviderValidator,
)
from kcc_autobuild.providers.fake import FakeProvider
from kcc_autobuild.readiness import (
    FallbackEntry,
    EvidenceRecord,
    ReadinessEvaluation,
    ReadinessItem,
    ReadinessItemOutcome,
    ReadinessPack,
    RedTeamDisposition,
    RedTeamFinding,
    evaluate_readiness,
    record_evidence,
)

NOW = datetime(2026, 1, 2, 12, 0, 0, tzinfo=timezone.utc)
HOUR = timedelta(hours=1)
TTL = timedelta(hours=4)


def _record(
    kind: EvidenceKind,
    result: EvidenceResult = "pass",
    checked_at: datetime = NOW,
) -> EvidenceRecord:
    return EvidenceRecord(kind=kind, result=result, checked_at=checked_at)


def _item(
    item_id: str = "IT-001",
    provider: str = "provider-a",
    status: ReadinessStatus = ReadinessStatus.READY,
    required_kinds: list[EvidenceKind] | None = None,
    evidence: list[EvidenceRecord] | None = None,
    fallbacks: list[FallbackEntry] | None = None,
    evidence_ttl: timedelta = TTL,
) -> ReadinessItem:
    return ReadinessItem(
        id=item_id,
        provider=provider,
        status=status,
        required_kinds=required_kinds if required_kinds is not None else ["identity"],
        evidence=evidence if evidence is not None else [],
        fallbacks=fallbacks if fallbacks is not None else [],
        evidence_ttl=evidence_ttl,
    )


def test_ready_item_with_fresh_pass_evidence_is_ready() -> None:
    """Fresh pass evidence for every required kind supports READY."""
    pack = ReadinessPack(
        items=[
            _item(
                required_kinds=["identity", "quota"],
                evidence=[
                    _record("identity"),
                    _record("quota"),
                ],
            )
        ]
    )

    evaluation = evaluate_readiness(pack, now=NOW)

    assert isinstance(evaluation, ReadinessEvaluation)
    assert evaluation.ready is True
    assert evaluation.coverage_ok is True
    assert evaluation.blockers == []
    assert evaluation.open_red_team_findings == []
    outcome = evaluation.items[0]
    assert isinstance(outcome, ReadinessItemOutcome)
    assert outcome.item_id == "IT-001"
    assert outcome.status == ReadinessStatus.READY


def test_readiness_requires_fresh_pass_for_every_required_kind() -> None:
    """A required kind without fresh pass evidence remains unsatisfied."""
    pack = ReadinessPack(
        items=[
            _item(
                required_kinds=["identity", "quota"],
                evidence=[_record("identity")],
            )
        ]
    )

    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.ready is False
    assert evaluation.blockers == ["IT-001"]
    assert evaluation.items[0].status == ReadinessStatus.BLOCKER
    assert any("quota" in reason for reason in evaluation.items[0].reasons)


def test_declared_ready_without_evidence_blocks() -> None:
    """Evidence coverage is required: READY with no evidence is a blocker."""
    pack = ReadinessPack(items=[_item(required_kinds=["identity"])])

    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.ready is False
    assert evaluation.blockers == ["IT-001"]
    assert evaluation.items[0].status == ReadinessStatus.BLOCKER


def test_empty_pack_is_not_ready() -> None:
    """BLOCKERS==0 alone is insufficient; evidence coverage is required."""
    evaluation = evaluate_readiness(ReadinessPack(), now=NOW)

    assert evaluation.ready is False
    assert evaluation.coverage_ok is False
    assert evaluation.blockers == []
    assert evaluation.items == []


def test_fresh_fail_never_satisfies_readiness() -> None:
    """A fresh failing probe cannot silently satisfy READY."""
    pack = ReadinessPack(
        items=[_item(evidence=[_record("identity", "fail")])]
    )

    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.ready is False
    assert evaluation.blockers == ["IT-001"]
    assert evaluation.items[0].status == ReadinessStatus.BLOCKER


def test_fresh_unknown_never_satisfies_readiness() -> None:
    """A fresh unknown probe cannot silently satisfy READY."""
    pack = ReadinessPack(
        items=[_item(evidence=[_record("identity", "unknown")])]
    )

    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.ready is False
    assert evaluation.blockers == ["IT-001"]
    assert evaluation.items[0].status == ReadinessStatus.BLOCKER


def test_fresh_fail_after_pass_blocks() -> None:
    """The freshest fresh failure supersedes an older pass (fail-closed)."""
    pack = ReadinessPack(
        items=[
            _item(
                evidence=[
                    _record("identity", "pass", checked_at=NOW - 2 * HOUR),
                    _record("identity", "fail", checked_at=NOW - HOUR),
                ]
            )
        ]
    )

    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.ready is False
    assert evaluation.blockers == ["IT-001"]


def test_newer_pass_supersedes_older_fail() -> None:
    """A later fresh pass supersedes an earlier failure."""
    pack = ReadinessPack(
        items=[
            _item(
                evidence=[
                    _record("identity", "fail", checked_at=NOW - 2 * HOUR),
                    _record("identity", "pass", checked_at=NOW - HOUR),
                ]
            )
        ]
    )

    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.ready is True
    assert evaluation.blockers == []


def test_stale_pass_evidence_blocks() -> None:
    """Stale READY evidence cannot support a READY claim."""
    pack = ReadinessPack(
        items=[
            _item(
                evidence=[_record("identity", "pass", checked_at=NOW - 2 * HOUR)],
                evidence_ttl=HOUR,
            )
        ]
    )

    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.ready is False
    assert evaluation.blockers == ["IT-001"]
    assert evaluation.items[0].status == ReadinessStatus.BLOCKER


def test_future_dated_evidence_is_not_current() -> None:
    """Evidence checked after the evaluation instant is not fresh."""
    pack = ReadinessPack(
        items=[
            _item(evidence=[_record("identity", "pass", checked_at=NOW + HOUR)])
        ]
    )

    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.ready is False
    assert evaluation.blockers == ["IT-001"]


def test_declared_blocker_blocks_even_with_fresh_pass_evidence() -> None:
    """A declared BLOCKER prevents lock and is never cleared by evidence."""
    pack = ReadinessPack(
        items=[
            _item(
                status=ReadinessStatus.BLOCKER,
                evidence=[_record("identity")],
            )
        ]
    )

    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.ready is False
    assert evaluation.blockers == ["IT-001"]
    assert evaluation.items[0].status == ReadinessStatus.BLOCKER


def test_mitigated_and_accepted_risks_do_not_block_lock() -> None:
    """Known risks with declared dispositions are non-blocking (BLOCKERS==0 is
    necessary but not sufficient; risk items do not need pass evidence)."""
    pack = ReadinessPack(
        items=[
            _item(
                item_id="RISK-1",
                status=ReadinessStatus.RISK_MITIGATED,
                evidence=[_record("identity", "fail")],
            ),
            _item(
                item_id="RISK-2",
                status=ReadinessStatus.ACCEPTED_RISK,
            ),
        ]
    )

    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.ready is True
    assert evaluation.blockers == []
    statuses = {outcome.item_id: outcome.status for outcome in evaluation.items}
    assert statuses["RISK-1"] == ReadinessStatus.RISK_MITIGATED
    assert statuses["RISK-2"] == ReadinessStatus.ACCEPTED_RISK


def test_blockers_and_item_outcomes_are_sorted() -> None:
    """Evaluation output ordering is deterministic (sorted by item id)."""
    pack = ReadinessPack(
        items=[
            _item(item_id="IT-B", evidence=[]),
            _item(
                item_id="IT-A",
                status=ReadinessStatus.RISK_MITIGATED,
            ),
            _item(item_id="IT-C", evidence=[_record("identity", "fail")]),
        ]
    )

    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.blockers == ["IT-B", "IT-C"]
    assert [outcome.item_id for outcome in evaluation.items] == [
        "IT-A",
        "IT-B",
        "IT-C",
    ]


def test_naive_checked_at_rejected() -> None:
    """Evidence timestamps must be timezone-aware (R3)."""
    with pytest.raises(ValidationError):
        EvidenceRecord(
            kind="identity",
            result="pass",
            checked_at=datetime(2026, 1, 2, 12, 0, 0),
        )


def test_checked_at_normalized_to_utc() -> None:
    """Aware EvidenceRecord timestamps are normalized to UTC (R7 direction)."""
    record = EvidenceRecord(
        kind="identity",
        result="pass",
        checked_at=datetime(2026, 1, 2, 10, 0, 0, tzinfo=timezone(timedelta(hours=5))),
    )

    assert record.checked_at == datetime(2026, 1, 2, 5, 0, 0, tzinfo=timezone.utc)


def test_evaluate_readiness_rejects_naive_now() -> None:
    """The evaluation instant must be timezone-aware (R3)."""
    with pytest.raises(ValueError):
        evaluate_readiness(
            ReadinessPack(),
            now=datetime(2026, 1, 2, 12, 0, 0),
        )


def test_evaluate_readiness_defaults_now_to_utc() -> None:
    """Omitting now falls back to the current UTC instant (still aware)."""
    evaluation = evaluate_readiness(
        ReadinessPack(
            items=[
                _item(
                    evidence=[
                        _record("identity", checked_at=datetime.now(timezone.utc))
                    ]
                )
            ]
        )
    )

    assert evaluation.items[0].status == ReadinessStatus.READY


def test_open_red_team_finding_blocks_lock() -> None:
    """An open red-team finding prevents readiness (typed model, R2)."""
    pack = ReadinessPack(
        items=[_item(evidence=[_record("identity")])],
        red_team_findings=[
            RedTeamFinding(
                id="RT-001",
                summary="OAuth callback URL is not configured",
                disposition=RedTeamDisposition.OPEN,
                related_item_id="IT-001",
            )
        ],
    )

    assert isinstance(pack.red_team_findings[0], RedTeamFinding)
    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.ready is False
    assert evaluation.open_red_team_findings == ["RT-001"]


def test_resolved_and_disposed_red_team_findings_do_not_block() -> None:
    """RESOLVED/MITIGATED/ACCEPTED findings do not block lock."""
    pack = ReadinessPack(
        items=[_item(evidence=[_record("identity")])],
        red_team_findings=[
            RedTeamFinding(id="RT-1", summary="s1", disposition=RedTeamDisposition.RESOLVED),
            RedTeamFinding(id="RT-2", summary="s2", disposition=RedTeamDisposition.MITIGATED),
            RedTeamFinding(id="RT-3", summary="s3", disposition=RedTeamDisposition.ACCEPTED),
        ],
    )

    evaluation = evaluate_readiness(pack, now=NOW)

    assert evaluation.ready is True
    assert evaluation.open_red_team_findings == []


def test_red_team_finding_requires_summary_and_disposition() -> None:
    """Red-team findings must carry a summary and an explicit disposition."""
    with pytest.raises(ValidationError):
        RedTeamFinding(id="RT-1", summary="", disposition=RedTeamDisposition.OPEN)


def test_fallback_entry_rejects_empty_trigger_scope() -> None:
    """Fallback trigger scope must be nonempty (fallback-scope rule)."""
    with pytest.raises(ValidationError):
        FallbackEntry(
            provider="provider-b",
            trigger_scope="  ",
            allowed_function="send-email",
            data_classes_allowed=["public"],
            regions_allowed=["us-east-1"],
            credential_ref="vault://project/provider-b/fallback-token",
        )


def test_fallback_entry_rejects_empty_allowed_function() -> None:
    """The fallback function/operation must be nonempty."""
    with pytest.raises(ValidationError):
        FallbackEntry(
            provider="provider-b",
            trigger_scope="outage",
            allowed_function="",
            data_classes_allowed=["public"],
            regions_allowed=["us-east-1"],
            credential_ref="vault://project/provider-b/fallback-token",
        )


def test_fallback_entry_rejects_empty_data_classes() -> None:
    """At least one allowed data class is required."""
    with pytest.raises(ValidationError):
        FallbackEntry(
            provider="provider-b",
            trigger_scope="outage",
            allowed_function="send-email",
            data_classes_allowed=[],
            regions_allowed=["us-east-1"],
            credential_ref="vault://project/provider-b/fallback-token",
        )


def test_fallback_entry_rejects_empty_regions() -> None:
    """At least one allowed region is required (fallback-scope rule)."""
    with pytest.raises(ValidationError):
        FallbackEntry(
            provider="provider-b",
            trigger_scope="outage",
            allowed_function="send-email",
            data_classes_allowed=["public"],
            regions_allowed=[],
            credential_ref="vault://project/provider-b/fallback-token",
        )


def test_fallback_entry_rejects_raw_secret_credential_ref() -> None:
    """Raw secrets are rejected; artifacts may carry references only."""
    for raw in ("sk-live-9f8a", "AKIAIOSFODNN7EXAMPLE", "pa55w0rd", "none"):
        with pytest.raises(ValidationError):
            FallbackEntry(
                provider="provider-b",
                trigger_scope="outage",
                allowed_function="send-email",
                data_classes_allowed=["public"],
                regions_allowed=["us-east-1"],
                credential_ref=raw,
            )


@pytest.mark.parametrize(
    "ref",
    [
        "vault://project/provider/deploy-token",
        "env://DEPLOY_TOKEN",
        "keychain://service/account",
    ],
)
def test_fallback_entry_accepts_secret_references(ref: str) -> None:
    """vault://, env:// and keychain:// references are accepted."""
    entry = FallbackEntry(
        provider="provider-b",
        trigger_scope="outage",
        allowed_function="send-email",
        data_classes_allowed=["public"],
        regions_allowed=["us-east-1"],
        credential_ref=ref,
    )

    assert entry.credential_ref == ref


def test_fallback_entry_defaults_switch_revalidation_required() -> None:
    """Switching to a fallback requires revalidation unless overridden."""
    entry = FallbackEntry(
        provider="provider-b",
        trigger_scope="outage",
        allowed_function="send-email",
        data_classes_allowed=["public"],
        regions_allowed=["us-east-1"],
        credential_ref="env://FALLBACK_TOKEN",
    )
    assert entry.switch_revalidation_required is True

    entry = entry.model_copy(update={"switch_revalidation_required": False})
    assert entry.switch_revalidation_required is False


def test_fallback_entries_attach_to_readiness_items() -> None:
    """Fallback entries are part of the readiness pack via their item."""
    fallback = FallbackEntry(
        provider="provider-b",
        trigger_scope="outage",
        allowed_function="send-email",
        data_classes_allowed=["public"],
        regions_allowed=["us-east-1"],
        credential_ref="env://FALLBACK_TOKEN",
    )
    pack = ReadinessPack(
        items=[_item(fallbacks=[fallback])],
    )

    assert pack.items[0].fallbacks == [fallback]


def test_readiness_pack_rejects_duplicate_item_ids() -> None:
    """Item ids must be unique within a pack."""
    with pytest.raises(ValidationError):
        ReadinessPack(
            items=[
                _item(item_id="IT-001"),
                _item(item_id="IT-001", status=ReadinessStatus.RISK_MITIGATED),
            ]
        )


def test_readiness_pack_rejects_duplicate_red_team_finding_ids() -> None:
    """Red-team finding ids must be unique within a pack."""
    with pytest.raises(ValidationError):
        ReadinessPack(
            red_team_findings=[
                RedTeamFinding(id="RT-1", summary="s1", disposition=RedTeamDisposition.OPEN),
                RedTeamFinding(id="RT-1", summary="s2", disposition=RedTeamDisposition.RESOLVED),
            ]
        )


def test_readiness_item_requires_nonempty_unique_required_kinds() -> None:
    """Required probe kinds must be declared and unique (fail-closed)."""
    with pytest.raises(ValidationError):
        _item(required_kinds=[])
    with pytest.raises(ValidationError):
        _item(required_kinds=["identity", "identity"])


def test_readiness_item_rejects_non_positive_evidence_ttl() -> None:
    """The freshness window must be strictly positive."""
    with pytest.raises(ValidationError):
        _item(evidence_ttl=timedelta(0))


def test_readiness_item_rejects_unknown_evidence_kinds() -> None:
    """Evidence kinds are exactly identity/permissions/quota/smoke_probe."""
    with pytest.raises(ValidationError):
        _record("deploy-token")  # type: ignore[arg-type]


def test_fake_provider_implements_validator_contract() -> None:
    """FakeProvider supplies all four ProviderValidator probes."""
    provider: ProviderValidator = FakeProvider(
        name="fake-provider-a",
        identity=ProbeResult(status="pass", principal="acct-001", scopes=["read"]),
        permissions=ProbeResult(status="pass", scopes=["read", "write"]),
        quota=ProbeResult(status="pass", quota="1000/min"),
        smoke_probe=ProbeResult(status="pass", mode="sandbox"),
    )

    assert provider.identity().status == "pass"
    assert provider.identity().principal == "acct-001"
    assert provider.permissions().scopes == ["read", "write"]
    assert provider.quota().quota == "1000/min"
    assert provider.smoke_probe().mode == "sandbox"


@pytest.mark.parametrize(
    "kind",
    ["identity", "permissions", "quota", "smoke_probe"],
)
def test_fake_provider_defaults_every_probe_to_unknown(kind: EvidenceKind) -> None:
    """Unconfigured probes are unknown (fail-closed default)."""
    provider = FakeProvider()

    probe = getattr(provider, kind)()

    assert probe.status == "unknown"
    assert probe.detail == ""
    assert probe.principal is None
    assert probe.resource_ids == []
    assert probe.scopes == []
    assert probe.mode is None
    assert probe.quota is None
    assert probe.shared_account is False


def test_record_evidence_maps_probe_result_to_evidence_record() -> None:
    """Probe outputs map into typed, timezone-aware evidence records."""
    probe = ProbeResult(
        status="pass",
        principal="acct-001",
        resource_ids=["bucket-01"],
        scopes=["read"],
        mode="sandbox",
        quota="1000/min",
        shared_account=True,
    )

    record = record_evidence("permissions", probe, checked_at=NOW)

    assert isinstance(record, EvidenceRecord)
    assert record.kind == "permissions"
    assert record.result == "pass"
    assert record.principal == "acct-001"
    assert record.resource_ids == ["bucket-01"]
    assert record.scopes == ["read"]
    assert record.mode == "sandbox"
    assert record.quota == "1000/min"
    assert record.shared_account is True
    assert record.checked_at == NOW


def test_record_evidence_rejects_naive_checked_at() -> None:
    """Evidence produced from probes is timezone-aware (R3)."""
    with pytest.raises(ValidationError):
        record_evidence(
            "identity",
            ProbeResult(status="pass"),
            checked_at=datetime(2026, 1, 2, 12, 0, 0),
        )


class _StructuralValidator:
    """Minimal structural ProviderValidator for the duck-typing test."""

    def identity(self) -> ProbeResult:
        return ProbeResult(status="pass")

    def permissions(self) -> ProbeResult:
        return ProbeResult(status="unknown")

    def quota(self) -> ProbeResult:
        return ProbeResult(status="unknown")

    def smoke_probe(self) -> ProbeResult:
        return ProbeResult(status="unknown")


def test_structural_validator_usable_via_protocol() -> None:
    """Duck-typed providers satisfy the probe contract without subclassing."""
    validator: ProviderValidator = _StructuralValidator()

    assert validator.identity().status == "pass"
    assert callable(validator.permissions)
    assert callable(validator.quota)
    assert callable(validator.smoke_probe)
