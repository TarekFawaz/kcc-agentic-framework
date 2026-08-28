"""Failure signature classification before autobuild retry.

Plan 04, Task 5 (Failure signature classification before retry): before the
controller retries a failed task it must classify the failure signature, so
the retry decision follows the failure class instead of blind retry. This
module is the *pure decision function* for that: no I/O, no wall clock unless
handed one, byte-identical output for identical input.

The behavioral contract is owned by
:file:`.KCC/runtime/tests/test_failure_classifier.py`:

- :class:`FailureEvidence` is the immutable observation of one failure in a
  streak: the optional HTTP ``status``, the raw ``message``, the
  ``consecutive`` (1 = first occurrence) count of identical-signature
  failures, and ``age_seconds`` since the first failure in the streak.
- :func:`classify` maps the evidence to the **canonical**
  :class:`~kcc_autobuild.models.FailureClass` taxonomy (AUTH/RATE/OUTAGE/
  BUG/DATA/ENV/CONTRACT/UNKNOWN -- pinned by ``test_execution_report.py``,
  never renamed), with deterministic precedence:
  HTTP status first (401/403 -> AUTH; 429 -> RATE, or OUTAGE once repeated;
  5xx -> OUTAGE), then message signatures in contract order
  (assertion -> BUG, validation -> DATA, missing tool -> ENV,
  policy -> CONTRACT), then repetition (``consecutive >=
  REPEATED_THRESHOLD`` with no other signature -> OUTAGE), else UNKNOWN.
  A repeated 429 is an outage (the :mod:`kcc_autobuild.rate_limit` ledger
  records each 429 before classification so the classifier can tell a
  transient rate limit from a repeated 429 outage) while a repeated
  assertion/auth failure keeps its identified class -- repetition never
  downgrades a definite signature.
- :class:`FailureDecision` is the answer the controller acts on:
  ``next_action`` (:class:`NextAction`) + ``confidence`` (0..1, fixed per
  signature so runs are reproducible), plus the canonical ``cls`` and a
  ``note`` naming the spec 18 exception (E6 for credentials, E7 for
  no-fallback outage).
- :func:`outage_route` routes an OUTAGE failure: an **already-authorized
  fallback** (the caller only passes authorized names; authorization is the
  policy layer's job, never this module's) is used first
  (``USE_FALLBACK``); otherwise the run is ``BLOCKED_RECHECK`` until the
  SLA -- ``sla_seconds``, default :data:`DEFAULT_SLA_SECONDS` (900 s),
  measured from the first failure in the streak -- then escalates as E7
  (external provider unavailable with no allowed fallback). Routing a
  non-outage failure through this path is a caller bug and fails closed
  (:class:`NotOutage`).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum
from typing import Mapping

from kcc_autobuild.models import FailureClass

REPEATED_THRESHOLD = 2
"""``consecutive`` count at which a failure streak counts as repeated."""

DEFAULT_SLA_SECONDS = 900
"""Default outage SLA in seconds before an unavailable provider escalates to E7."""

# Message-signature keyword sets, matched case-insensitively as substrings in
# the evidence message. The per-set order is meaningless; the precedence
# between categories is fixed by the classification order in ``classify``
# (contract order: BUG, DATA, ENV, CONTRACT).
_ASSERTION_SIGNATURES = ("assertionerror", "assertion", "assert ")
_VALIDATION_SIGNATURES = ("validationerror", "validation", "invalid", "not valid")
_MISSING_TOOL_SIGNATURES = (
    "command not found",
    "no such file or directory",
    "modulenotfounderror",
    "not found",
    "not installed",
    "missing tool",
)
_POLICY_SIGNATURES = (
    "policy",
    "not allowed",
    "not permitted",
    "denied",
    "forbidden",
    "violates",
)


def _matches(text: str, signatures: tuple[str, ...]) -> bool:
    return any(signature in text for signature in signatures)


class NextAction(str, Enum):
    """What the controller should do next for a classified failure.

    ``RETRY`` schedules another attempt (the run's attempt budget and the
    escalation ladder stay outside this module); ``USE_FALLBACK`` routes the
    work to an authorized alternative; ``BLOCKED_RECHECK`` waits for the SLA
    before rechecking the provider; ``ESCALATE`` stops and escalates to the
    spec 18 exception path (E-code in the decision note).
    """

    RETRY = "RETRY"
    USE_FALLBACK = "USE_FALLBACK"
    BLOCKED_RECHECK = "BLOCKED_RECHECK"
    ESCALATE = "ESCALATE"


class NotOutage(ValueError):
    """Raised when a non-OUTAGE failure is routed through the outage path."""


@dataclass(frozen=True)
class FailureEvidence:
    """One observed failure in a streak.

    ``status`` is the HTTP status code when the failure came from a provider
    or API (100..599); ``message`` is the raw failure text; ``consecutive``
    counts identical-signature failures in a row (1 = first occurrence);
    ``age_seconds`` is the time since the first failure in the streak (the
    SLA clock for outage rechecks). The value object validates itself at
    construction so the classifier can assume well-formed input.
    """

    status: int | None = None
    message: str = ""
    consecutive: int = 1
    age_seconds: float = 0.0

    def __post_init__(self) -> None:
        if self.status is not None:
            if isinstance(self.status, bool) or not isinstance(self.status, int):
                raise TypeError(
                    f"status must be an int or None, got {type(self.status).__name__}"
                )
            if not 100 <= self.status <= 599:
                raise ValueError(f"status must be in 100..599, got {self.status}")
        if not isinstance(self.message, str):
            raise TypeError(f"message must be a str, got {type(self.message).__name__}")
        if isinstance(self.consecutive, bool) or not isinstance(self.consecutive, int):
            raise TypeError(
                f"consecutive must be an int, got {type(self.consecutive).__name__}"
            )
        if self.consecutive < 1:
            raise ValueError(f"consecutive must be positive, got {self.consecutive}")
        if isinstance(self.age_seconds, bool) or not isinstance(
            self.age_seconds, (int, float)
        ):
            raise TypeError(
                f"age_seconds must be a number, got {type(self.age_seconds).__name__}"
            )
        age = float(self.age_seconds)
        if age < 0:
            raise ValueError(f"age_seconds must be non-negative, got {age}")
        object.__setattr__(self, "age_seconds", age)

    @property
    def repeated(self) -> bool:
        """Whether the streak has repeated (``consecutive >= REPEATED_THRESHOLD``)."""
        return self.consecutive >= REPEATED_THRESHOLD


@dataclass(frozen=True)
class FailureDecision:
    """The classifier's answer for one failure evidence.

    ``cls`` is the canonical classification; ``next_action`` and
    ``confidence`` (0..1, fixed per signature) are what the controller acts
    on; ``note`` carries human-readable context including the spec 18
    exception code when escalating.
    """

    cls: FailureClass
    next_action: NextAction
    confidence: float
    note: str = ""

    def __post_init__(self) -> None:
        if not isinstance(self.cls, FailureClass):
            raise TypeError(
                f"cls must be a FailureClass, got {type(self.cls).__name__}"
            )
        if not isinstance(self.next_action, NextAction):
            raise TypeError(
                f"next_action must be a NextAction, got {type(self.next_action).__name__}"
            )
        if isinstance(self.confidence, bool) or not isinstance(
            self.confidence, (int, float)
        ):
            raise TypeError(
                f"confidence must be a number, got {type(self.confidence).__name__}"
            )
        confidence = float(self.confidence)
        if not math.isfinite(confidence) or not 0.0 <= confidence <= 1.0:
            raise ValueError(f"confidence must be in 0..1, got {confidence}")
        object.__setattr__(self, "confidence", confidence)
        if not isinstance(self.note, str):
            raise TypeError(f"note must be a str, got {type(self.note).__name__}")


# Default per-class decision: retryable classes retry (the attempt budget and
# escalation ladder are the run's, not this module's); contract-external
# conditions escalate to the spec 18 exception path. Confidence is fixed per
# signature class so identical evidence always yields an identical decision.
_DEFAULT_DECISION: Mapping[FailureClass, tuple[NextAction, float, str]] = {
    FailureClass.AUTH: (
        NextAction.ESCALATE,
        0.95,
        "E6: credential revoked/expired and cannot be refreshed autonomously",
    ),
    FailureClass.RATE: (
        NextAction.RETRY,
        0.80,
        "transient rate limit; retry after backoff",
    ),
    FailureClass.BUG: (
        NextAction.RETRY,
        0.90,
        "deterministic assertion defect; retry enters systematic debugging",
    ),
    FailureClass.DATA: (
        NextAction.RETRY,
        0.85,
        "validation defect; retry after fixing the input",
    ),
    FailureClass.ENV: (
        NextAction.RETRY,
        0.90,
        "missing tool; provision it, then retry",
    ),
    FailureClass.CONTRACT: (
        NextAction.ESCALATE,
        0.90,
        "contract/policy violation; escalate for re-contracting",
    ),
    FailureClass.UNKNOWN: (
        NextAction.ESCALATE,
        0.40,
        "unrecognized failure signature; escalate to machine interpretation",
    ),
}


def classify(evidence: FailureEvidence) -> FailureClass:
    """Classify one failure evidence into the canonical taxonomy.

    Precedence, first match wins: HTTP status (401/403 -> AUTH; 429 ->
    RATE, or OUTAGE once repeated; 500..599 -> OUTAGE), message signatures
    in contract order (assertion -> BUG, validation -> DATA, missing tool
    -> ENV, policy -> CONTRACT), repetition (no other signature and
    ``repeated`` -> OUTAGE), else UNKNOWN. Unmapped statuses (e.g. 400/404)
    fall through to the message and repetition rules.
    """
    if not isinstance(evidence, FailureEvidence):
        raise TypeError(
            f"evidence must be a FailureEvidence, got {type(evidence).__name__}"
        )

    if evidence.status is not None:
        if evidence.status == 429:
            # A transient 429 is a rate limit; once the streak repeats it is
            # the provider signalling sustained pressure -- an outage.
            return FailureClass.OUTAGE if evidence.repeated else FailureClass.RATE
        if evidence.status in (401, 403):
            return FailureClass.AUTH
        if 500 <= evidence.status <= 599:
            return FailureClass.OUTAGE

    text = evidence.message.lower()
    if _matches(text, _ASSERTION_SIGNATURES):
        return FailureClass.BUG
    if _matches(text, _VALIDATION_SIGNATURES):
        return FailureClass.DATA
    if _matches(text, _MISSING_TOOL_SIGNATURES):
        return FailureClass.ENV
    if _matches(text, _POLICY_SIGNATURES):
        return FailureClass.CONTRACT
    if evidence.repeated:
        return FailureClass.OUTAGE
    return FailureClass.UNKNOWN


def outage_route(
    evidence: FailureEvidence,
    fallback: str | None = None,
    sla_seconds: int = DEFAULT_SLA_SECONDS,
) -> FailureDecision:
    """Route an OUTAGE failure: authorized fallback first, then SLA, then E7.

    ``fallback`` must already be an authorized alternative (authorization is
    decided by the policy layer, never here); if present it wins regardless
    of elapsed SLA time. Otherwise the run is BLOCKED_RECHECK while
    ``age_seconds < sla_seconds`` (default 900 s, measured from the first
    failure in the streak), and escalates as E7 -- external provider
    unavailable with no allowed fallback -- once the SLA has elapsed.
    Routing evidence that does not classify as OUTAGE fails closed.
    """
    cls = classify(evidence)
    if cls is not FailureClass.OUTAGE:
        raise NotOutage(f"cannot route a {cls.value} failure as an outage")

    if isinstance(sla_seconds, bool) or not isinstance(sla_seconds, int):
        raise TypeError(
            f"sla_seconds must be an int, got {type(sla_seconds).__name__}"
        )
    if sla_seconds < 1:
        raise ValueError(f"sla_seconds must be positive, got {sla_seconds}")

    if fallback is not None and not isinstance(fallback, str):
        raise TypeError(f"fallback must be a str or None, got {type(fallback).__name__}")
    if fallback and fallback.strip():
        name = fallback.strip()
        return FailureDecision(
            cls=FailureClass.OUTAGE,
            next_action=NextAction.USE_FALLBACK,
            confidence=0.85,
            note=f"authorized fallback '{name}' routes the outage",
        )

    if evidence.age_seconds < sla_seconds:
        return FailureDecision(
            cls=FailureClass.OUTAGE,
            next_action=NextAction.BLOCKED_RECHECK,
            confidence=0.75,
            note=f"no authorized fallback; recheck until SLA {sla_seconds}s, then E7",
        )
    return FailureDecision(
        cls=FailureClass.OUTAGE,
        next_action=NextAction.ESCALATE,
        confidence=0.90,
        note="E7: external provider unavailable with no allowed fallback",
    )


def decide(
    evidence: FailureEvidence,
    fallback: str | None = None,
    sla_seconds: int = DEFAULT_SLA_SECONDS,
) -> FailureDecision:
    """Classify and decide the next action for one failure evidence.

    OUTAGE evidence routes through :func:`outage_route` (fallback / SLA /
    E7); every other class takes its fixed default decision
    (``next_action`` + ``confidence``). Pure and deterministic: identical
    evidence always yields an identical decision, so the controller can act
    on it without re-reading the failure stream.
    """
    cls = classify(evidence)
    if cls is FailureClass.OUTAGE:
        return outage_route(evidence, fallback=fallback, sla_seconds=sla_seconds)
    next_action, confidence, note = _DEFAULT_DECISION[cls]
    return FailureDecision(
        cls=cls,
        next_action=next_action,
        confidence=confidence,
        note=note,
    )
