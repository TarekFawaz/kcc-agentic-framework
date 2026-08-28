"""Behavioral tests for the autobuild Decision Log layer.

Written first (strict TDD red phase) against the external behavior
contract of :mod:`kcc_autobuild.decision_log` (KCC x Superpowers Hybrid
Framework Plan 02, Task 4; Design Spec v1.2 sections 9.7, 11, 23, 24).

Binding semantics under test (Design Spec v1.2):

* every entry carries a decision ID, problem/context, recommended
  choice, alternatives considered, rejected alternatives, rationale,
  cost/risk implications and the tier of the decision (locked
  invariant vs autonomous detail, section 11);
* the recommended choice is the single winner: it may not also appear
  in the alternatives or the rejected alternatives, and the
  alternatives/rejected buckets are disjoint;
* ``LOCKED_INVARIANT`` decisions map to Tier-1 contract content and
  ``AUTONOMOUS_DETAIL`` decisions remain Tier-2 autonomous engineering
  detail — a locked invariant must not conflict with another locked
  invariant for the same decision area;
* the Decision Log never stores raw secrets: credential references
  must be ``vault://``, ``env://`` or ``keychain://`` (section 24);
* ``run_id`` is optional and, when present, must match the canonical
  run identity pattern (template-compatible, ruling R1 spirit).

These are evidence-quality validations, not gates: H1 Scope, H2
Prototype and final LOCK remain the only formal pre-build gates (R10).
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from kcc_autobuild.decision_log import (
    DECISION_ID_PATTERN,
    DecisionEntry,
    DecisionLog,
    DecisionLogEvaluation,
    DecisionTier,
    evaluate_decision_log,
)


def _entry(**overrides: object) -> DecisionEntry:
    """A minimally valid decision entry; override any field per test."""
    defaults: dict[str, object] = {
        "id": "DEC-001",
        "problem": "Choose an object storage vendor for user uploads",
        "recommended": "provider-a",
        "alternatives": ["provider-b", "provider-c"],
        "rejected": ["provider-d"],
        "rationale": "provider-a meets regional and budget constraints",
        "cost_risk": "provider-a adds operational burden; S3-compatible API limits lock-in",
        "tier": DecisionTier.LOCKED_INVARIANT,
        "area": "storage",
        "credential_refs": ["vault://acme/storage/token"],
    }
    defaults.update(overrides)
    return DecisionEntry(**defaults)


def _log(*entries: DecisionEntry) -> DecisionLog:
    return DecisionLog(entries=list(entries))


# ---------------------------------------------------------------------------
# DecisionEntry — spec section 11 field contract
# ---------------------------------------------------------------------------


def test_entry_accepts_all_spec_fields() -> None:
    """Every section 11 field round-trips on a valid entry."""
    entry = _entry()
    assert entry.id == "DEC-001"
    assert entry.problem == "Choose an object storage vendor for user uploads"
    assert entry.recommended == "provider-a"
    assert entry.alternatives == ["provider-b", "provider-c"]
    assert entry.rejected == ["provider-d"]
    assert entry.rationale.startswith("provider-a")
    assert entry.cost_risk.startswith("provider-a")
    assert entry.tier is DecisionTier.LOCKED_INVARIANT
    assert entry.area == "storage"
    assert entry.credential_refs == ["vault://acme/storage/token"]


def test_tier_enum_has_locked_invariant_and_autonomous_detail() -> None:
    """Section 11 distinguishes locked invariants from autonomous detail."""
    assert DecisionTier.LOCKED_INVARIANT.value == "LOCKED_INVARIANT"
    assert DecisionTier.AUTONOMOUS_DETAIL.value == "AUTONOMOUS_DETAIL"


def test_entry_accepts_autonomous_detail_tier() -> None:
    """An autonomous-detail decision is a distinct, valid classification."""
    entry = _entry(
        id="DEC-002", tier=DecisionTier.AUTONOMOUS_DETAIL, area=None
    )
    assert entry.tier is DecisionTier.AUTONOMOUS_DETAIL
    assert entry.area is None


def test_entry_id_requires_canonical_pattern() -> None:
    """Decision ids must match DEC-<alphanumeric>[-<alphanumeric>]*."""
    assert DECISION_ID_PATTERN.startswith("^DEC-")
    for bad in ("DEC-", "dec-001", "001", "DEC--1", "DEC-aa_bb"):
        with pytest.raises(ValidationError):
            _entry(id=bad)


def test_entry_id_pattern_accepts_hyphenated_ids() -> None:
    """Hyphenated decision ids are valid; ids must not be blank."""
    assert _entry(id="DEC-AUTH-001").id == "DEC-AUTH-001"
    with pytest.raises(ValidationError):
        _entry(id="")


def test_entry_required_text_must_not_be_blank() -> None:
    """problem/recommended/rationale/cost_risk are non-optional and non-blank."""
    for field in ("problem", "recommended", "rationale", "cost_risk"):
        with pytest.raises(ValidationError, match=f"{field} must not be empty"):
            _entry(**{field: "   "})


def test_entry_area_optional_but_not_blank() -> None:
    """area defaults to None and must be non-blank when provided."""
    assert _entry(area=None).area is None
    with pytest.raises(ValidationError, match="area must not be empty"):
        _entry(area="  ")


def test_entry_option_lists_must_not_contain_blank_entries() -> None:
    """alternatives/rejected entries are non-blank (empty lists are fine)."""
    assert _entry(alternatives=[], rejected=[]).alternatives == []
    with pytest.raises(ValidationError, match="alternatives entries must not be empty"):
        _entry(alternatives=["provider-b", " "])
    with pytest.raises(ValidationError, match="rejected entries must not be empty"):
        _entry(rejected=[""])


def test_entry_option_lists_must_not_contain_duplicates() -> None:
    """Within-list duplicates are ambiguous and rejected."""
    with pytest.raises(ValidationError, match="alternatives must not contain duplicates"):
        _entry(alternatives=["provider-b", "provider-b"])
    with pytest.raises(ValidationError, match="rejected must not contain duplicates"):
        _entry(rejected=["provider-d", "provider-d"])


def test_entry_alternatives_and_rejected_are_disjoint() -> None:
    """A considered option cannot be both an alternative and rejected."""
    with pytest.raises(ValidationError, match="alternatives and rejected"):
        _entry(alternatives=["provider-b"], rejected=["provider-b"])


def test_entry_recommended_not_in_rejected() -> None:
    """The recommended choice cannot also be a rejected alternative."""
    with pytest.raises(ValidationError, match="recommended"):
        _entry(rejected=["provider-a"])


def test_entry_recommended_not_in_alternatives() -> None:
    """The recommended choice is the single winner, not an alternative."""
    with pytest.raises(ValidationError, match="recommended"):
        _entry(alternatives=["provider-a", "provider-b"])


# ---------------------------------------------------------------------------
# DecisionEntry — secret handling (spec section 24)
# ---------------------------------------------------------------------------


def test_entry_credential_refs_accept_secret_references_only() -> None:
    """vault://, env:// and keychain:// references are all accepted."""
    for ref in (
        "vault://acme/storage/token",
        "env://ACME_STORAGE_TOKEN",
        "keychain://acme/storage",
    ):
        assert _entry(credential_refs=[ref]).credential_refs == [ref]


def test_entry_credential_refs_reject_raw_secrets() -> None:
    """Raw secrets (and any non-reference string) are rejected per section 24."""
    for ref in ("sk-live-1234", "https://vault.example/secret", "ACME_TOKEN"):
        with pytest.raises(ValidationError, match="secret references"):
            _entry(credential_refs=[ref])


def test_entry_credential_refs_must_be_unique() -> None:
    """Duplicate credential references add no information and are rejected."""
    with pytest.raises(ValidationError, match="credential_refs must not contain duplicates"):
        _entry(credential_refs=["vault://a/1", "vault://a/1"])


# ---------------------------------------------------------------------------
# DecisionLog — structure
# ---------------------------------------------------------------------------


def test_log_requires_unique_entry_ids() -> None:
    """Two entries with the same decision id would re-litigate the same choice."""
    with pytest.raises(ValidationError, match="entry ids must be unique"):
        _log(_entry(), _entry(id="DEC-001", problem="other problem"))


def test_log_run_id_optional_and_validated_when_present() -> None:
    """run_id is optional; when present it must match the canonical pattern."""
    assert _log().run_id is None
    assert _log(_entry()).run_id is None
    log = DecisionLog(run_id="RUN-001", entries=[_entry()])
    assert log.run_id == "RUN-001"


def test_log_rejects_invalid_run_id() -> None:
    """Non-canonical run ids are rejected before any artifact is stored."""
    with pytest.raises(ValidationError, match="String should match pattern"):
        DecisionLog(run_id="../escape", entries=[_entry()])


# ---------------------------------------------------------------------------
# evaluate_decision_log
# ---------------------------------------------------------------------------


def test_evaluate_returns_typed_evaluation() -> None:
    """The evaluator returns a DecisionLogEvaluation (not a bare dict)."""
    result = evaluate_decision_log(_log(_entry()))
    assert isinstance(result, DecisionLogEvaluation)


def test_evaluate_splits_tier_ids_sorted() -> None:
    """Locked invariants and autonomous detail are reported as sorted id lists."""
    result = evaluate_decision_log(
        _log(
            _entry(),
            _entry(
                id="DEC-002",
                tier=DecisionTier.AUTONOMOUS_DETAIL,
                area="storage",
                recommended="provider-c",
                alternatives=["provider-b"],
            ),
        )
    )
    assert result.locked_invariant_ids == ["DEC-001"]
    assert result.autonomous_detail_ids == ["DEC-002"]
    assert result.problems == []


def test_evaluate_empty_log_reports_missing_decision_evidence() -> None:
    """An empty Decision Log carries no decision evidence (section 9.7)."""
    result = evaluate_decision_log(_log())
    assert result.problems == ["decision log has no entries"]
    assert result.locked_invariant_ids == []
    assert result.autonomous_detail_ids == []


def test_evaluate_conflicting_locked_invariants_same_area() -> None:
    """Two locked invariants deciding the same area differently conflict."""
    result = evaluate_decision_log(
        _log(
            _entry(),
            _entry(
                id="DEC-002",
                tier=DecisionTier.LOCKED_INVARIANT,
                area="storage",
                recommended="provider-b",
                alternatives=["provider-c"],
            ),
        )
    )
    assert result.problems == [
        "conflicting locked invariant decisions for area 'storage'"
    ]


def test_evaluate_identical_locked_invariants_do_not_conflict() -> None:
    """The same recommendation in the same area is consistent, not a conflict."""
    result = evaluate_decision_log(
        _log(
            _entry(),
            _entry(
                id="DEC-002",
                tier=DecisionTier.LOCKED_INVARIANT,
                area="storage",
            ),
        )
    )
    assert result.problems == []


def test_evaluate_different_areas_do_not_conflict() -> None:
    """Different decision areas are independent locked invariances."""
    result = evaluate_decision_log(
        _log(_entry(), _entry(id="DEC-002", area="hosting", recommended="host-b"))
    )
    assert result.problems == []


def test_evaluate_autonomous_detail_never_conflicts_with_invariant() -> None:
    """Autonomous detail may refine the same area without re-litigating LOCK."""
    result = evaluate_decision_log(
        _log(
            _entry(),
            _entry(
                id="DEC-002",
                tier=DecisionTier.AUTONOMOUS_DETAIL,
                area="storage",
                recommended="provider-c",
                alternatives=["provider-b"],
            ),
        )
    )
    assert result.problems == []


def test_evaluate_area_ignored_for_conflicts_when_absent() -> None:
    """Entries without an area cannot be grouped, so no conflict is reported."""
    result = evaluate_decision_log(
        _log(
            _entry(area=None),
            _entry(
                id="DEC-002",
                tier=DecisionTier.LOCKED_INVARIANT,
                area=None,
                recommended="provider-b",
                alternatives=["provider-c"],
            ),
        )
    )
    assert result.problems == []


def test_evaluate_problems_are_sorted_and_deterministic() -> None:
    """Problem output is sorted so identical logs give identical reports."""
    result = evaluate_decision_log(_log())
    assert result.problems == sorted(result.problems)
    with_entries = evaluate_decision_log(
        _log(
            _entry(),
            _entry(
                id="DEC-002",
                area="hosting",
                recommended="host-b",
                alternatives=["host-c"],
            ),
            _entry(
                id="DEC-003",
                area="hosting",
                recommended="host-d",
                alternatives=["host-b"],
            ),
        )
    )
    assert with_entries.problems == [
        "conflicting locked invariant decisions for area 'hosting'"
    ]
