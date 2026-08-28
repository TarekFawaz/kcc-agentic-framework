"""Readiness evidence models and evaluation for the autobuild framework.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_readiness.py`
(see the KCC x Superpowers Hybrid Framework Plan 02, Task 2).

Evidence-backed readiness per Design Spec v1.2 sections 12-13 and the
binding plan rulings R2/R3/R7:

* evidence timestamps are timezone-aware (naive datetimes rejected) and
  normalized to UTC;
* a declared READY item is lockable only when the freshest *current*
  evidence for every required probe kind is ``pass`` — fresh ``fail``
  or ``unknown`` evidence, stale evidence, or missing evidence never
  satisfy READY, and a declared BLOCKER always prevents lock;
* the pack carries typed red-team findings (R2);
* fallback entries reference secrets only (``vault://``, ``env://`` or
  ``keychain://``): raw secrets are rejected and trigger scope /
  allowed function / data classes / regions must be nonempty.

Sections 13.1 and 15 of the spec make ``BLOCKERS == 0`` necessary but
not by itself sufficient: an empty pack has no evidence coverage and is
never ready.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from enum import Enum

from pydantic import Field, ValidationInfo, field_validator, model_validator

from kcc_autobuild.models import ReadinessStatus, StrictModel
from kcc_autobuild.providers.base import (
    EvidenceKind,
    EvidenceResult,
    ProbeResult,
)

SECRET_REF_PATTERN = r"^(vault|env|keychain)://[A-Za-z0-9][A-Za-z0-9._/-]*$"
"""Secret reference pattern: only ``vault://``, ``env://``, ``keychain://``."""

DEFAULT_EVIDENCE_TTL = timedelta(hours=24)
"""Default freshness window for evidence supporting a READY claim."""


def _require_nonempty(value: str, field_name: str) -> str:
    if not value.strip():
        raise ValueError(f"{field_name} must not be empty")
    return value


def _require_nonempty_strings(value: list[str], field_name: str) -> list[str]:
    if not value:
        raise ValueError(f"{field_name} must not be empty")
    if any(not entry.strip() for entry in value):
        raise ValueError(f"{field_name} entries must not be empty")
    return value


class EvidenceRecord(StrictModel):
    """One timezone-aware evidence record produced by a provider probe.

    ``checked_at`` must be timezone-aware; aware timestamps are
    normalized to UTC (R3/R7).  ``result`` is the probe verdict and no
    raw secret may appear anywhere on the record — the pack stores
    references only.
    """

    kind: EvidenceKind
    checked_at: datetime
    result: EvidenceResult
    principal: str | None = None
    resource_ids: list[str] = Field(default_factory=list)
    scopes: list[str] = Field(default_factory=list)
    mode: str | None = None
    quota: str | None = None
    shared_account: bool = False

    @field_validator("checked_at")
    @classmethod
    def _checked_at_must_be_aware_utc(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("checked_at must be timezone-aware")
        return value.astimezone(timezone.utc)

    @field_validator("principal", "mode", "quota")
    @classmethod
    def _optional_strings_not_blank(
        cls, value: str | None, info: ValidationInfo
    ) -> str | None:
        if value is not None:
            _require_nonempty(value, info.field_name)
        return value

    @field_validator("resource_ids", "scopes")
    @classmethod
    def _lists_not_blank(
        cls, value: list[str], info: ValidationInfo
    ) -> list[str]:
        return _require_nonempty_strings(value, info.field_name)


def record_evidence(
    kind: EvidenceKind,
    probe: ProbeResult,
    checked_at: datetime,
) -> EvidenceRecord:
    """Convert a provider probe result into a typed evidence record."""
    return EvidenceRecord(
        kind=kind,
        checked_at=checked_at,
        result=probe.status,
        principal=probe.principal,
        resource_ids=probe.resource_ids,
        scopes=probe.scopes,
        mode=probe.mode,
        quota=probe.quota,
        shared_account=probe.shared_account,
    )


class RedTeamDisposition(str, Enum):
    """Disposition of a red-team readiness finding.

    ``OPEN`` findings block lock; the other dispositions are recorded
    and non-blocking (they surface in the consolidated risk view).
    """

    OPEN = "OPEN"
    RESOLVED = "RESOLVED"
    MITIGATED = "MITIGATED"
    ACCEPTED = "ACCEPTED"


class RedTeamFinding(StrictModel):
    """A typed red-team readiness finding and its disposition (R2)."""

    id: str
    summary: str
    disposition: RedTeamDisposition
    related_item_id: str | None = None

    @field_validator("id", "summary")
    @classmethod
    def _required_text(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)

    @field_validator("related_item_id")
    @classmethod
    def _optional_link(cls, value: str | None) -> str | None:
        if value is not None:
            _require_nonempty(value, "related_item_id")
        return value


class FallbackEntry(StrictModel):
    """An approved provider fallback route.

    ``credential_ref`` is a secret reference only (``vault://``,
    ``env://`` or ``keychain://``) — raw secrets are rejected.  The
    trigger scope, allowed function, allowed data classes and allowed
    regions must all be nonempty so an approved fallback cannot exist
    only on paper (ruling R6 groundwork).
    """

    provider: str
    trigger_scope: str
    allowed_function: str
    data_classes_allowed: list[str]
    regions_allowed: list[str]
    credential_ref: str
    switch_revalidation_required: bool = True

    @field_validator("provider", "trigger_scope", "allowed_function")
    @classmethod
    def _required_text(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)

    @field_validator("data_classes_allowed", "regions_allowed")
    @classmethod
    def _required_lists(cls, value: list[str], info: ValidationInfo) -> list[str]:
        return _require_nonempty_strings(value, info.field_name)

    @field_validator("credential_ref")
    @classmethod
    def _credential_ref_is_secret_reference(cls, value: str) -> str:
        _require_nonempty(value, "credential_ref")
        if not re.fullmatch(SECRET_REF_PATTERN, value):
            raise ValueError(
                "credential_ref must be a secret reference "
                "(vault://, env:// or keychain://)"
            )
        return value


class ReadinessItem(StrictModel):
    """One readiness subject: an external provider/dependency along with
    its evidence, approved fallbacks and declared disposition.

    ``required_kinds`` declares which probe kinds must have current
    pass evidence for a READY claim to hold.  ``evidence_ttl`` is the
    freshness window: evidence older than the window (or dated after
    the evaluation instant) is not current.
    """

    id: str
    provider: str
    status: ReadinessStatus
    required_kinds: list[EvidenceKind]
    evidence: list[EvidenceRecord] = Field(default_factory=list)
    fallbacks: list[FallbackEntry] = Field(default_factory=list)
    evidence_ttl: timedelta = DEFAULT_EVIDENCE_TTL

    @field_validator("id", "provider")
    @classmethod
    def _required_text(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)

    @field_validator("required_kinds")
    @classmethod
    def _required_kinds_unique(
        cls, value: list[EvidenceKind], info: ValidationInfo
    ) -> list[EvidenceKind]:
        _require_nonempty_strings(value, info.field_name)
        if len(value) != len(set(value)):
            raise ValueError("required_kinds must not contain duplicates")
        return value

    @field_validator("evidence_ttl")
    @classmethod
    def _evidence_ttl_positive(cls, value: timedelta) -> timedelta:
        if value <= timedelta(0):
            raise ValueError("evidence_ttl must be strictly positive")
        return value


class ReadinessPack(StrictModel):
    """The consolidated evidence-backed readiness pack.

    Contains dependency readiness items plus typed red-team findings and
    dispositions (R2).  Item ids and finding ids must be unique.
    """

    items: list[ReadinessItem] = Field(default_factory=list)
    red_team_findings: list[RedTeamFinding] = Field(default_factory=list)

    @model_validator(mode="after")
    def _unique_ids(self) -> ReadinessPack:
        item_ids = [item.id for item in self.items]
        if len(item_ids) != len(set(item_ids)):
            raise ValueError("readiness item ids must be unique")
        finding_ids = [finding.id for finding in self.red_team_findings]
        if len(finding_ids) != len(set(finding_ids)):
            raise ValueError("red team finding ids must be unique")
        return self


class ReadinessItemOutcome(StrictModel):
    """Evaluation result for one readiness item."""

    item_id: str
    status: ReadinessStatus
    reasons: list[str] = Field(default_factory=list)


class ReadinessEvaluation(StrictModel):
    """Result of :func:`evaluate_readiness`.

    ``ready`` is the lockable verdict: evidence coverage exists, no
    item is classified BLOCKER and no red-team finding stays OPEN.
    ``blockers`` and ``open_red_team_findings`` are sorted ids;
    ``items`` are sorted by item id, all for deterministic output.
    """

    ready: bool
    coverage_ok: bool
    blockers: list[str] = Field(default_factory=list)
    open_red_team_findings: list[str] = Field(default_factory=list)
    items: list[ReadinessItemOutcome] = Field(default_factory=list)


def _is_current(record: EvidenceRecord, now: datetime, ttl: timedelta) -> bool:
    """True when the record was checked within the freshness window."""
    age = now - record.checked_at
    return timedelta(0) <= age <= ttl


def _current_pass_kinds(item: ReadinessItem, now: datetime) -> set[str]:
    """Probe kinds satisfied by current evidence (freshest wins, fail-closed).

    For each required kind the most recently checked current record
    decides: it must be ``pass``.  On an exact timestamp tie the
    non-pass record wins so a concurrent failure never passes LOCK.
    """
    satisfied: set[str] = set()
    for kind in item.required_kinds:
        current = [
            record
            for record in item.evidence
            if record.kind == kind and _is_current(record, now, item.evidence_ttl)
        ]
        if not current:
            continue
        latest = max(current, key=lambda record: (record.checked_at, record.result != "pass"))
        if latest.result == "pass":
            satisfied.add(kind)
    return satisfied


def _evaluate_item(item: ReadinessItem, now: datetime) -> ReadinessItemOutcome:
    if item.status == ReadinessStatus.READY:
        satisfied = _current_pass_kinds(item, now)
        missing = [kind for kind in item.required_kinds if kind not in satisfied]
        if missing:
            return ReadinessItemOutcome(
                item_id=item.id,
                status=ReadinessStatus.BLOCKER,
                reasons=[f"missing fresh pass evidence for: {', '.join(missing)}"],
            )
        return ReadinessItemOutcome(
            item_id=item.id,
            status=ReadinessStatus.READY,
            reasons=[f"fresh pass evidence for: {', '.join(item.required_kinds)}"],
        )
    if item.status == ReadinessStatus.BLOCKER:
        return ReadinessItemOutcome(
            item_id=item.id,
            status=ReadinessStatus.BLOCKER,
            reasons=["declared blocker"],
        )
    if item.status == ReadinessStatus.RISK_MITIGATED:
        return ReadinessItemOutcome(
            item_id=item.id,
            status=ReadinessStatus.RISK_MITIGATED,
            reasons=["declared risk mitigated"],
        )
    if item.status == ReadinessStatus.ACCEPTED_RISK:
        return ReadinessItemOutcome(
            item_id=item.id,
            status=ReadinessStatus.ACCEPTED_RISK,
            reasons=["declared accepted risk"],
        )
    raise AssertionError(f"unhandled readiness status: {item.status!r}")


def evaluate_readiness(
    pack: ReadinessPack,
    *,
    now: datetime | None = None,
) -> ReadinessEvaluation:
    """Evaluate the evidence-backed readiness of a readiness pack.

    ``now`` is the evaluation instant; it must be timezone-aware when
    provided and defaults to the current UTC instant (R3).  A READY
    claim holds only with current pass evidence (fresh fail/unknown
    never satisfies it), declared blockers prevent lock, and the pack
    must contain evidence coverage at all.
    """
    if now is None:
        now = datetime.now(timezone.utc)
    elif now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("now must be timezone-aware")
    now_utc = now.astimezone(timezone.utc)

    outcomes = [
        _evaluate_item(item, now_utc)
        for item in sorted(pack.items, key=lambda entry: entry.id)
    ]
    blockers = [
        outcome.item_id
        for outcome in outcomes
        if outcome.status == ReadinessStatus.BLOCKER
    ]
    open_findings = sorted(
        finding.id
        for finding in pack.red_team_findings
        if finding.disposition == RedTeamDisposition.OPEN
    )
    coverage_ok = bool(pack.items)
    return ReadinessEvaluation(
        ready=coverage_ok and not blockers and not open_findings,
        coverage_ok=coverage_ok,
        blockers=blockers,
        open_red_team_findings=open_findings,
        items=outcomes,
    )
