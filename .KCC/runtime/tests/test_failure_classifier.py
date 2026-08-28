"""Behavioral contract for failure signature classification before retry.

Owned by ``test_failure_classifier.py`` (see the KCC x Superpowers Hybrid
Framework Plan 04, Task 5: Failure signature classification before retry, in
``.superpowers/bootstrap/plans/2026-08-27-04-scheduler-budget-rate-policy.task-contracts.md``).

The classifier is pure and deterministic: one
:class:`~kcc_autobuild.failure_classifier.FailureEvidence` observation maps to
the canonical :class:`~kcc_autobuild.models.FailureClass` taxonomy (pinned by
``test_execution_report.py``: AUTH/RATE/OUTAGE/BUG/DATA/ENV/CONTRACT/UNKNOWN,
never renamed), then to a
:class:`~kcc_autobuild.failure_classifier.FailureDecision` carrying
``next_action`` + ``confidence``, so the controller never blind-retries a
failed task.

Signature map (precedence: HTTP status first, then message signatures, then
repetition):

- AUTH: HTTP 401/403
- RATE: HTTP 429 first occurrence
- OUTAGE: HTTP 5xx, repeated 429, or repeated failures
- BUG: assertion signature
- DATA: validation signature
- ENV: missing-tool signature
- CONTRACT: policy signature
- UNKNOWN: no signature

Outage routing (``outage_route``): an authorized fallback is used first
(``USE_FALLBACK``); otherwise the run stays ``BLOCKED_RECHECK`` until the SLA
(default ``DEFAULT_SLA_SECONDS`` = 900 s) measured from the first failure in
the streak, then escalates as E7 (external provider unavailable with no
allowed fallback). Prescribed tests: the classification matrix, the
899 s / 900 s SLA boundary and fallback routing.
"""

from __future__ import annotations

import pytest

from kcc_autobuild.failure_classifier import (
    DEFAULT_SLA_SECONDS,
    REPEATED_THRESHOLD,
    FailureDecision,
    FailureEvidence,
    NextAction,
    NotOutage,
    classify,
    decide,
    outage_route,
)
from kcc_autobuild.models import FailureClass


# --- Classification matrix (prescribed) --------------------------------------
# One row per canonical failure class, using the contract's signatures:
# AUTH 401/403, RATE 429, OUTAGE repeated/5xx, BUG assertion, DATA validation,
# ENV missing tool, CONTRACT policy, UNKNOWN otherwise.

CLASSIFICATION_MATRIX = [
    pytest.param(FailureEvidence(status=401), FailureClass.AUTH, id="401"),
    pytest.param(FailureEvidence(status=403), FailureClass.AUTH, id="403"),
    pytest.param(
        FailureEvidence(status=401, message="invalid credentials"),
        FailureClass.AUTH,
        id="401-with-message",
    ),
    pytest.param(FailureEvidence(status=429), FailureClass.RATE, id="429-first"),
    pytest.param(
        FailureEvidence(status=429, message="rate limit exceeded"),
        FailureClass.RATE,
        id="429-transient",
    ),
    pytest.param(FailureEvidence(status=500), FailureClass.OUTAGE, id="500"),
    pytest.param(FailureEvidence(status=502), FailureClass.OUTAGE, id="502"),
    pytest.param(
        FailureEvidence(status=503, message="bad gateway"),
        FailureClass.OUTAGE,
        id="503",
    ),
    pytest.param(FailureEvidence(status=504), FailureClass.OUTAGE, id="504"),
    pytest.param(
        FailureEvidence(status=429, consecutive=2),
        FailureClass.OUTAGE,
        id="repeated-429-outage",
    ),
    pytest.param(
        FailureEvidence(status=429, consecutive=3),
        FailureClass.OUTAGE,
        id="triple-429-outage",
    ),
    pytest.param(
        FailureEvidence(message="AssertionError: expected 3, got 4"),
        FailureClass.BUG,
        id="assertionerror",
    ),
    pytest.param(
        FailureEvidence(message="assertion failed: a != b"),
        FailureClass.BUG,
        id="assertion",
    ),
    pytest.param(
        FailureEvidence(message="test_handoff.py:12: assert x is not None"),
        FailureClass.BUG,
        id="assert-statement",
    ),
    pytest.param(
        FailureEvidence(message="ValidationError: 1 validation error for Handoff"),
        FailureClass.DATA,
        id="validationerror",
    ),
    pytest.param(
        FailureEvidence(message="invalid value for field 'run_id'"),
        FailureClass.DATA,
        id="invalid",
    ),
    pytest.param(
        FailureEvidence(message="value is not valid"),
        FailureClass.DATA,
        id="not-valid",
    ),
    pytest.param(
        FailureEvidence(message="sh: 1: node: command not found"),
        FailureClass.ENV,
        id="command-not-found",
    ),
    pytest.param(
        FailureEvidence(message="terraform: no such file or directory"),
        FailureClass.ENV,
        id="no-such-file",
    ),
    pytest.param(
        FailureEvidence(message="ModuleNotFoundError: No module named 'requests'"),
        FailureClass.ENV,
        id="modulenotfound",
    ),
    pytest.param(
        FailureEvidence(message="git: not found"),
        FailureClass.ENV,
        id="not-found",
    ),
    pytest.param(
        FailureEvidence(message="DENIED by policy: destructive op not allowed"),
        FailureClass.CONTRACT,
        id="policy-denied",
    ),
    pytest.param(
        FailureEvidence(message="operation violates locked invariant"),
        FailureClass.CONTRACT,
        id="violates",
    ),
    pytest.param(FailureEvidence(), FailureClass.UNKNOWN, id="no-signal"),
    pytest.param(
        FailureEvidence(message="something odd happened"),
        FailureClass.UNKNOWN,
        id="gibberish",
    ),
    pytest.param(FailureEvidence(status=400), FailureClass.UNKNOWN, id="400-unmapped"),
    pytest.param(
        FailureEvidence(status=404, message="no such page"),
        FailureClass.UNKNOWN,
        id="404-unmapped",
    ),
]


@pytest.mark.parametrize("evidence,expected", CLASSIFICATION_MATRIX)
def test_classification_matrix(evidence: FailureEvidence, expected: FailureClass):
    assert classify(evidence) is expected


def test_classification_uses_canonical_failure_class_enum():
    # The classifier must emit the canonical taxonomy members (pinned by
    # test_execution_report.py) -- never a copy or a renamed taxonomy.
    result = classify(FailureEvidence(status=503))
    assert isinstance(result, FailureClass)
    assert result in {
        FailureClass.AUTH,
        FailureClass.RATE,
        FailureClass.OUTAGE,
        FailureClass.BUG,
        FailureClass.DATA,
        FailureClass.ENV,
        FailureClass.CONTRACT,
        FailureClass.UNKNOWN,
    }


# --- Precedence and repetition ------------------------------------------------


def test_http_status_wins_over_message_signature():
    # A 403 with a policy-sounding message is still an authorization failure:
    # the status is the machine-verifiable signal.
    assert (
        classify(FailureEvidence(status=403, message="DENIED by policy: not allowed"))
        is FailureClass.AUTH
    )
    assert (
        classify(FailureEvidence(status=502, message="AssertionError: boom"))
        is FailureClass.OUTAGE
    )


def test_message_precedence_follows_contract_order():
    # BUG (assertion) beats DATA (validation) beats ENV (missing tool).
    assert (
        classify(FailureEvidence(message="AssertionError: validation failed"))
        is FailureClass.BUG
    )
    assert (
        classify(FailureEvidence(message="ValidationError: module not found"))
        is FailureClass.DATA
    )


def test_repeated_429_becomes_outage_only_when_repeated():
    assert classify(FailureEvidence(status=429, consecutive=1)) is FailureClass.RATE
    assert classify(FailureEvidence(status=429, consecutive=2)) is FailureClass.OUTAGE


def test_repetition_does_not_downgrade_a_definite_signature():
    # Repeated assertion failures are still a bug (the defect is identified);
    # repetition only upgrades ambiguous/HTTP failures to OUTAGE.
    assert (
        classify(FailureEvidence(message="AssertionError: still broken", consecutive=2))
        is FailureClass.BUG
    )
    # Repeated auth failures are still a credential problem, not an outage.
    assert classify(FailureEvidence(status=401, consecutive=2)) is FailureClass.AUTH


def test_repeated_unsignatured_failure_is_outage():
    assert (
        classify(FailureEvidence(message="timeout waiting for provider", consecutive=2))
        is FailureClass.OUTAGE
    )
    assert classify(FailureEvidence(consecutive=3)) is FailureClass.OUTAGE


def test_repeated_threshold_is_two():
    assert REPEATED_THRESHOLD == 2
    assert FailureEvidence(consecutive=1).repeated is False
    assert FailureEvidence(consecutive=2).repeated is True


def test_classifier_is_deterministic():
    evidence = FailureEvidence(status=429, message="rate limit exceeded", consecutive=2)
    assert classify(evidence) is classify(evidence)
    assert decide(evidence) == decide(evidence)


def test_classify_rejects_non_evidence():
    for bad in (None, 503, {"status": 503}, "503"):
        with pytest.raises(TypeError):
            classify(bad)  # type: ignore[arg-type]


# --- FailureEvidence value object ----------------------------------------------


def test_failure_evidence_defaults():
    evidence = FailureEvidence()
    assert evidence.status is None
    assert evidence.message == ""
    assert evidence.consecutive == 1
    assert evidence.age_seconds == 0.0
    assert evidence.repeated is False


def test_failure_evidence_is_immutable():
    evidence = FailureEvidence(status=503)
    with pytest.raises(AttributeError):
        evidence.status = 500  # type: ignore[misc]


def test_failure_evidence_rejects_bad_status():
    for bad in (99, 600, 0, -1):
        with pytest.raises(ValueError):
            FailureEvidence(status=bad)
    for bad in (True, "503", 503.5):
        with pytest.raises(TypeError):
            FailureEvidence(status=bad)  # type: ignore[arg-type]
    # The HTTP range is bounded so a typo'd status can never classify silently.
    assert FailureEvidence(status=100).status == 100
    assert FailureEvidence(status=599).status == 599


def test_failure_evidence_rejects_bad_message():
    for bad in (None, 42, ["boom"], b"boom"):
        with pytest.raises(TypeError):
            FailureEvidence(message=bad)  # type: ignore[arg-type]
    assert FailureEvidence().message == ""


def test_failure_evidence_rejects_bad_consecutive():
    for bad in (0, -1, -100):
        with pytest.raises(ValueError):
            FailureEvidence(consecutive=bad)
    for bad in (True, 1.5, "2"):
        with pytest.raises(TypeError):
            FailureEvidence(consecutive=bad)  # type: ignore[arg-type]


def test_failure_evidence_rejects_bad_age():
    for bad in (-1, -0.001, -100.0):
        with pytest.raises(ValueError):
            FailureEvidence(age_seconds=bad)
    for bad in (True, "900", [900]):
        with pytest.raises(TypeError):
            FailureEvidence(age_seconds=bad)  # type: ignore[arg-type]
    # int and float ages are both accepted; the value is normalized to float.
    assert FailureEvidence(age_seconds=899).age_seconds == 899.0
    assert FailureEvidence(age_seconds=900.0).age_seconds == 900.0


# --- Decision: next_action + confidence ----------------------------------------


DECISION_TABLE = [
    pytest.param(
        FailureEvidence(status=401),
        NextAction.ESCALATE,
        0.95,
        id="AUTH",
    ),
    pytest.param(
        FailureEvidence(status=429),
        NextAction.RETRY,
        0.80,
        id="RATE",
    ),
    pytest.param(
        FailureEvidence(message="AssertionError: x != y"),
        NextAction.RETRY,
        0.90,
        id="BUG",
    ),
    pytest.param(
        FailureEvidence(message="ValidationError: bad value"),
        NextAction.RETRY,
        0.85,
        id="DATA",
    ),
    pytest.param(
        FailureEvidence(message="command not found: node"),
        NextAction.RETRY,
        0.90,
        id="ENV",
    ),
    pytest.param(
        FailureEvidence(message="denied by policy: not allowed"),
        NextAction.ESCALATE,
        0.90,
        id="CONTRACT",
    ),
    pytest.param(
        FailureEvidence(message="mystery condition"),
        NextAction.ESCALATE,
        0.40,
        id="UNKNOWN",
    ),
]


@pytest.mark.parametrize("evidence,next_action,confidence", DECISION_TABLE)
def test_decision_table(evidence: FailureEvidence, next_action: NextAction, confidence: float):
    decision = decide(evidence)
    assert decision.cls is classify(evidence)
    assert decision.next_action is next_action
    assert decision.confidence == confidence


def test_auth_decision_names_the_e6_exception():
    # Spec 18: E6 = credential revoked/expired and cannot be refreshed
    # autonomously; retrying a 401/403 blindly burns attempts.
    decision = decide(FailureEvidence(status=403))
    assert decision.next_action is NextAction.ESCALATE
    assert "E6" in decision.note


def test_decide_routes_outage_through_outage_route():
    evidence = FailureEvidence(status=503, age_seconds=899)
    assert decide(evidence).next_action is NextAction.BLOCKED_RECHECK
    assert decide(evidence, fallback="backup-llm").next_action is NextAction.USE_FALLBACK
    assert decide(FailureEvidence(status=503, age_seconds=900)).next_action is (
        NextAction.ESCALATE
    )


def test_fallback_is_ignored_for_non_outage_failures():
    # Only an outage may be routed to a fallback; a transient 429 retries.
    assert decide(FailureEvidence(status=429), fallback="backup-llm").next_action is (
        NextAction.RETRY
    )


def test_decision_confidence_is_normalized_in_unit_range():
    assert 0.0 <= decide(FailureEvidence()).confidence <= 1.0


def test_failure_decision_is_immutable():
    decision = decide(FailureEvidence(status=503))
    with pytest.raises(AttributeError):
        decision.note = "rewritten"  # type: ignore[misc]


def test_failure_decision_rejects_bad_values():
    with pytest.raises(TypeError):
        FailureDecision(cls="BUG", next_action=NextAction.RETRY, confidence=0.9)  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        FailureDecision(cls=FailureClass.BUG, next_action="RETRY", confidence=0.9)  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        FailureDecision(cls=FailureClass.BUG, next_action=NextAction.RETRY, confidence=True)  # type: ignore[arg-type]
    for bad in (-0.01, 1.01, float("nan"), float("inf")):
        with pytest.raises(ValueError):
            FailureDecision(
                cls=FailureClass.BUG, next_action=NextAction.RETRY, confidence=bad
            )


# --- outage_route: fallback first, SLA then E7 (prescribed) -------------------


def test_default_sla_is_900_seconds():
    assert DEFAULT_SLA_SECONDS == 900


def test_authorized_fallback_is_used_first():
    for age in (0, 899, 900, 100_000):
        decision = outage_route(
            FailureEvidence(status=503, age_seconds=age), fallback="backup-llm"
        )
        assert decision.cls is FailureClass.OUTAGE
        assert decision.next_action is NextAction.USE_FALLBACK
        assert decision.confidence == 0.85
        assert "backup-llm" in decision.note


def test_blind_fallback_is_not_authorized():
    # Whitespace only is not an authorized fallback; the SLA path applies.
    decision = outage_route(
        FailureEvidence(status=503, age_seconds=0), fallback="   "
    )
    assert decision.next_action is NextAction.BLOCKED_RECHECK


def test_sla_boundary_899_seconds_is_blocked_recheck():
    decision = outage_route(FailureEvidence(status=503, age_seconds=899))
    assert decision.cls is FailureClass.OUTAGE
    assert decision.next_action is NextAction.BLOCKED_RECHECK
    assert decision.confidence == 0.75


def test_sla_boundary_900_seconds_escalates_e7():
    # Spec 18: E7 = external provider unavailable with no allowed fallback.
    decision = outage_route(FailureEvidence(status=503, age_seconds=900))
    assert decision.next_action is NextAction.ESCALATE
    assert decision.confidence == 0.90
    assert decision.note == "E7: external provider unavailable with no allowed fallback"


def test_sla_boundary_exact_floats():
    assert outage_route(
        FailureEvidence(status=502, age_seconds=899.999)
    ).next_action is NextAction.BLOCKED_RECHECK
    assert outage_route(
        FailureEvidence(status=502, age_seconds=900.0)
    ).next_action is NextAction.ESCALATE


def test_custom_sla_seconds_moves_the_boundary():
    evidence_59 = FailureEvidence(status=503, age_seconds=59)
    evidence_60 = FailureEvidence(status=503, age_seconds=60)
    assert outage_route(evidence_59, sla_seconds=60).next_action is (
        NextAction.BLOCKED_RECHECK
    )
    assert outage_route(evidence_60, sla_seconds=60).next_action is NextAction.ESCALATE


def test_outage_route_rejects_non_outage_evidence():
    # Routing a non-outage failure through the outage path is a caller bug:
    # fail closed rather than guess (e.g. never route a transient 429).
    for evidence in (
        FailureEvidence(status=429),
        FailureEvidence(message="AssertionError: x"),
        FailureEvidence(message="mystery"),
    ):
        with pytest.raises(NotOutage):
            outage_route(evidence)


def test_outage_route_validates_sla_seconds():
    evidence = FailureEvidence(status=503, age_seconds=0)
    for bad in (0, -1, -900):
        with pytest.raises(ValueError):
            outage_route(evidence, sla_seconds=bad)
    for bad in (True, 900.0, "900"):
        with pytest.raises(TypeError):
            outage_route(evidence, sla_seconds=bad)  # type: ignore[arg-type]
