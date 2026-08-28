"""Decision Log models and evaluation for the autobuild framework.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_decision_log.py`
(see the KCC x Superpowers Hybrid Framework Plan 02, Task 4).

Implements the Decision Log of Design Spec v1.2 sections 9.7, 11, 23
and 24, with the binding plan rulings:

* R10 — these are evidence-quality validations, not gates: H1 Scope,
  H2 Prototype and final LOCK remain the only formal pre-build gates.
* R4 — no authority/decision content here renames the canonical
  ``AUTO_PROVISION_AUTHORIZED`` dependency status (it stays in
  :mod:`kcc_autobuild.models`); locked invariants recorded here are
  *references* to Tier-1 contract content, evaluated for internal
  consistency only.

A :class:`DecisionEntry` records one material choice with its ID,
problem/context, recommended choice, alternatives considered, rejected
alternatives, rationale, cost/risk implications and the decision tier
(section 11): ``LOCKED_INVARIANT`` decisions become Tier-1 contract
content while ``AUTONOMOUS_DETAIL`` decisions remain Tier-2 autonomous
engineering detail.  Per section 24 the log stores secret *references*
only (``vault://``, ``env://`` or ``keychain://``) — raw secrets are
rejected.  The log is the anti-re-litigation record: fresh agents read
it instead of re-deciding (section 11, 16.2).

:func:`evaluate_decision_log` reports the decision evidence quality:
tier-id lists for the contract handoff (Task 5) plus problems such as
conflicting locked invariants for the same decision area.  An empty log
is reported as an evidence gap — material choices remain unmade.
"""

from __future__ import annotations

import re
from collections import defaultdict
from enum import Enum

from pydantic import Field, ValidationInfo, field_validator, model_validator

from kcc_autobuild.models import RUN_ID_PATTERN, StrictModel
from kcc_autobuild.readiness import SECRET_REF_PATTERN

DECISION_ID_PATTERN = r"^DEC-[A-Za-z0-9][A-Za-z0-9-]*$"
"""Canonical decision identity pattern (single source of truth).

A decision id must start with DEC- followed by an alphanumeric character
and any mix of alphanumerics and single hyphens.
"""


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


class DecisionTier(str, Enum):
    """Tier of a recorded decision (spec section 11).

    ``LOCKED_INVARIANT`` decisions become Tier-1 contract content: a
    change requires contract revision and re-lock (section 14.1).
    ``AUTONOMOUS_DETAIL`` decisions remain Tier-2 autonomous engineering
    detail that may change without user interruption within the Tier-1
    invariants (section 14.2).
    """

    LOCKED_INVARIANT = "LOCKED_INVARIANT"
    AUTONOMOUS_DETAIL = "AUTONOMOUS_DETAIL"


class DecisionEntry(StrictModel):
    """One material decision recorded in the Decision Log (spec section 11).

    ``recommended`` is the single winning choice: it may not also appear
    in ``alternatives`` (considered-but-not-winner) or ``rejected``
    (considered-and-ruled-out), and the alternatives/rejected buckets
    are disjoint so an option can never be both viable and discarded.
    ``area`` names the decision area (e.g. auth, hosting, database,
    storage, payments, email/SMS, queues, analytics, monitoring, search,
    AI provider/model, CDN/DNS, CI/CD — section 9.7) when the decision
    belongs to one.

    ``credential_refs`` stores secret references only (spec section 24):
    raw secrets are rejected before they can reach a durable artifact.
    """

    id: str = Field(pattern=DECISION_ID_PATTERN)
    problem: str
    recommended: str
    alternatives: list[str] = Field(default_factory=list)
    rejected: list[str] = Field(default_factory=list)
    rationale: str
    cost_risk: str
    tier: DecisionTier
    area: str | None = None
    credential_refs: list[str] = Field(default_factory=list)

    @field_validator("problem", "recommended", "rationale", "cost_risk")
    @classmethod
    def _required_text(cls, value: str, info: ValidationInfo) -> str:
        return _require_nonempty(value, info.field_name)

    @field_validator("alternatives", "rejected")
    @classmethod
    def _option_lists(cls, value: list[str], info: ValidationInfo) -> list[str]:
        return _unique_strings(value, info.field_name)

    @field_validator("area")
    @classmethod
    def _area_optional_not_blank(cls, value: str | None) -> str | None:
        if value is not None:
            _require_nonempty(value, "area")
        return value

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

    @model_validator(mode="after")
    def _choice_buckets_are_consistent(self) -> DecisionEntry:
        """The recommended winner and the option buckets must be disjoint."""
        if self.recommended in self.rejected:
            raise ValueError("recommended must not appear in rejected alternatives")
        if self.recommended in self.alternatives:
            raise ValueError("recommended must not appear in alternatives")
        overlap = set(self.alternatives) & set(self.rejected)
        if overlap:
            raise ValueError("alternatives and rejected must not overlap")
        return self


class DecisionLog(StrictModel):
    """The continuously updated record of material choices (spec section 11).

    ``run_id`` is optional and validated against the canonical run
    identity pattern when present, so the log stays template-compatible
    with the per-run artifacts of the approved YAML shape.
    """

    run_id: str | None = Field(default=None, pattern=RUN_ID_PATTERN)
    entries: list[DecisionEntry] = Field(default_factory=list)

    @model_validator(mode="after")
    def _unique_entry_ids(self) -> DecisionLog:
        ids = [entry.id for entry in self.entries]
        if len(ids) != len(set(ids)):
            raise ValueError("decision entry ids must be unique")
        return self


class DecisionLogEvaluation(StrictModel):
    """Result of :func:`evaluate_decision_log`.

    ``locked_invariant_ids`` and ``autonomous_detail_ids`` are the
    sorted decision ids per tier (the Tier-1/Tier-2 handoff view);
    ``problems`` holds the sorted evidence-quality findings: an empty
    log (no decision evidence yet) or conflicting locked invariants for
    the same decision area (a Tier-1 re-lock would be required).
    """

    problems: list[str] = Field(default_factory=list)
    locked_invariant_ids: list[str] = Field(default_factory=list)
    autonomous_detail_ids: list[str] = Field(default_factory=list)


def evaluate_decision_log(log: DecisionLog) -> DecisionLogEvaluation:
    """Evaluate decision evidence quality of a Decision Log.

    Deterministic output: tier id lists and problems are sorted.  A
    locked invariant may not conflict with another locked invariant for
    the same decision area — two different recommendations for one area
    cannot both be Tier-1 content.  Autonomous-detail entries never
    conflict: they remain Tier-2 and may refine an area freely.
    """
    problems: list[str] = []
    if not log.entries:
        problems.append("decision log has no entries")

    recommendations_by_area: dict[str, set[str]] = defaultdict(set)
    for entry in log.entries:
        if entry.tier is DecisionTier.LOCKED_INVARIANT and entry.area is not None:
            recommendations_by_area[entry.area].add(entry.recommended)
    problems.extend(
        f"conflicting locked invariant decisions for area '{area}'"
        for area in sorted(recommendations_by_area)
        if len(recommendations_by_area[area]) > 1
    )

    return DecisionLogEvaluation(
        problems=sorted(problems),
        locked_invariant_ids=sorted(
            entry.id
            for entry in log.entries
            if entry.tier is DecisionTier.LOCKED_INVARIANT
        ),
        autonomous_detail_ids=sorted(
            entry.id
            for entry in log.entries
            if entry.tier is DecisionTier.AUTONOMOUS_DETAIL
        ),
    )
