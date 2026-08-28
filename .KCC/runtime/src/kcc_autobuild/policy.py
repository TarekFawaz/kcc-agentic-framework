"""Deterministic destructive-operation policy evaluator for autobuild.

Plan 04, Task 6 (Deterministic destructive-operation policy evaluator): the
Build Contract's destructive-action policy (Design Spec v1.2 sections 14.5,
18/E4 and 24 -- *destructive operations must be policy-classified before
execution*) is delivered to the runtime as a machine-readable, HMAC-SHA256
canonically signed :class:`PolicyBundle`. This module is the *pure decision
function* for that: no I/O, no wall clock, byte-identical output for
identical input.

The behavioral contract is owned by
:file:`.KCC/runtime/tests/test_policy.py`:

- :class:`Operation` is the immutable value object for one requested
  destructive/mutating call: ``operation`` (verb, e.g. ``deploy``/
  ``migrate``/``destroy``), ``resource`` (the exact target, e.g.
  ``prod/app``) and ``data_class`` (the data sensitivity classification).
  Exactness matters: a rule covers ONLY its exact triple.
- :func:`sign_policy_bundle` builds a :class:`PolicyBundle` whose signature
  is the HMAC-SHA256 of a **canonical** payload -- the format marker plus the
  rule triples sorted by ``(operation, resource, data_class)`` and JSON
  serialized with sorted keys -- so the signature is independent of rule
  ordering and the evaluator can verify any verifiably-equivalent bundle.
- :class:`PolicyEvaluator` refuses to construct over an unsigned
  (:class:`UnsignedPolicy`) or bad-signature (:class:`InvalidSignature`)
  bundle, rejects malformed/foreign bundles and any rule set containing
  duplicate triples (:class:`InvalidPolicyBundle`) -- the evaluator never
  interprets an untrusted policy (fail closed).
- :meth:`PolicyEvaluator.evaluate` is deterministic and exact-first:
  exact ``(operation, resource, data_class)`` rule match -> the rule's
  decision (ALLOWED / DENIED); the same ``operation`` with a mismatched
  ``resource`` and/or ``data_class`` -> AMBIGUOUS; an operation unlisted by
  every rule -> DENIED (nothing is allowed implicitly).

The gate that decides, audits and executes mutations lives in
:mod:`kcc_autobuild.tool_gate`; this module never executes anything.
"""

from __future__ import annotations

import hashlib
import hmac
import json
from dataclasses import dataclass
from enum import Enum
from typing import Iterable, Mapping

POLICY_BUNDLE_FORMAT = "kcc-autobuild-policy/1"
"""Canonical policy bundle format marker (signed; part of the payload)."""

_SIGNATURE_HEX_LENGTH = 64
"""Hex length of a SHA-256 HMAC digest (``hmac.hexdigest``)."""

_RULE_DECISIONS = ("ALLOWED", "DENIED")
"""The only decisions a rule may carry (never AMBIGUOUS: rules are exact)."""


class PolicyError(ValueError):
    """Base class for rejected policy bundles."""


class UnsignedPolicy(PolicyError):
    """Raised when the bundle carries no signature at all (fail closed)."""


class InvalidSignature(PolicyError):
    """Raised when the bundle signature is malformed or does not verify."""


class InvalidPolicyBundle(PolicyError):
    """Raised for malformed/foreign bundles or an ambiguous rule set."""


class PolicyDecision(str, Enum):
    """The deterministic answer for one requested operation.

    ``ALLOWED`` / ``DENIED`` come from an exact rule match; ``AMBIGUOUS``
    means an exact rule exists for the same operation under a different
    resource/data_class, so the intent cannot be resolved mechanically --
    the caller must escalate to KCC machine interpretation, never to a
    direct user prompt (spec sections 4.5/18; ruling R10: no extra gates).
    """

    ALLOWED = "ALLOWED"
    DENIED = "DENIED"
    AMBIGUOUS = "AMBIGUOUS"


@dataclass(frozen=True)
class Operation:
    """One requested destructive/mutating operation.

    ``operation`` is the verb, ``resource`` the exact target and
    ``data_class`` the data sensitivity classification. All three must be
    non-empty strings: wildcards/empty targets are never silently accepted,
    because policy is exact-match by design (an exact rule covers exactly
    one triple; everything else is AMBIGUOUS or DENIED).
    """

    operation: str
    resource: str
    data_class: str

    def __post_init__(self) -> None:
        object.__setattr__(self, "operation", _require_nonempty_text(self.operation, "operation"))
        object.__setattr__(self, "resource", _require_nonempty_text(self.resource, "resource"))
        object.__setattr__(self, "data_class", _require_nonempty_text(self.data_class, "data_class"))


@dataclass(frozen=True)
class PolicyRule:
    """One exact rule of the destructive-action policy.

    ``decision`` must be ``ALLOWED`` or ``DENIED`` (canonical string or
    :class:`PolicyDecision`); a rule can never be explicitly AMBIGUOUS -- a
    rule states an exact decision for exactly one
    ``(operation, resource, data_class)`` triple, and duplicate triples in a
    bundle are rejected because two verdicts for one triple are
    nondeterministic.
    """

    operation: str
    resource: str
    data_class: str
    decision: PolicyDecision

    def __post_init__(self) -> None:
        object.__setattr__(self, "operation", _require_nonempty_text(self.operation, "operation"))
        object.__setattr__(self, "resource", _require_nonempty_text(self.resource, "resource"))
        object.__setattr__(self, "data_class", _require_nonempty_text(self.data_class, "data_class"))
        decision = self.decision
        if isinstance(decision, PolicyDecision):
            normalized = decision
        elif isinstance(decision, str) and decision in _RULE_DECISIONS:
            normalized = PolicyDecision(decision)
        else:
            raise ValueError(
                "policy rule decision must be ALLOWED or DENIED "
                f"(got {decision!r})"
            )
        if normalized is PolicyDecision.AMBIGUOUS:
            raise ValueError("a policy rule can never be explicitly AMBIGUOUS")
        object.__setattr__(self, "decision", normalized)


@dataclass(frozen=True)
class PolicyBundle:
    """A canonical signed destructive-action policy.

    ``format`` must be :data:`POLICY_BUNDLE_FORMAT` (the evaluator rejects
    foreign formats); ``rules`` are the exact-match rule set (duplicate
    triples rejected); ``signature`` is the lowercase hex HMAC-SHA256 of the
    canonical payload. The bundle itself is free-standing so a tampered/
    unsigned bundle can be *detected* -- only
    :class:`PolicyEvaluator` decides whether it is trustworthy.
    """

    format: str
    rules: tuple[PolicyRule, ...]
    signature: str | None

    def __post_init__(self) -> None:
        if not isinstance(self.format, str) or not self.format.strip():
            raise ValueError("policy bundle format must be a non-empty string")
        rules = tuple(self.rules)
        for rule in rules:
            if not isinstance(rule, PolicyRule):
                raise TypeError(
                    f"policy bundle rules must be PolicyRule, "
                    f"got {type(rule).__name__}"
                )
        object.__setattr__(self, "rules", rules)
        if self.signature is not None and not isinstance(self.signature, str):
            raise TypeError(
                f"policy bundle signature must be str or None, "
                f"got {type(self.signature).__name__}"
            )


def _require_nonempty_text(value: str, name: str) -> str:
    if not isinstance(value, str):
        raise TypeError(f"{name} must be a str, got {type(value).__name__}")
    if not value.strip():
        raise ValueError(f"{name} must be a non-empty string")
    return value


def _normalize_secret(secret: str | bytes) -> bytes:
    if isinstance(secret, str):
        return secret.encode("utf-8")
    if isinstance(secret, bytes):
        return secret
    raise TypeError(
        f"signing secret must be str or bytes, got {type(secret).__name__}"
    )


def _canonical_payload(bundle_format: str, rules: tuple[PolicyRule, ...]) -> bytes:
    """Deterministic byte serialization of the signed policy content.

    Rules are sorted by ``(operation, resource, data_class, decision)`` and
    the dict is serialized with sorted keys and no extra whitespace, so the
    signature is order-independent: verifiably-equivalent bundles always
    verify.
    """
    payload = {
        "format": bundle_format,
        "rules": [
            {
                "operation": rule.operation,
                "resource": rule.resource,
                "data_class": rule.data_class,
                "decision": rule.decision.value,
            }
            for rule in sorted(
                rules,
                key=lambda rule: (
                    rule.operation,
                    rule.resource,
                    rule.data_class,
                    rule.decision.value,
                ),
            )
        ],
    }
    return json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")


def _validate_unique_triples(rules: tuple[PolicyRule, ...]) -> None:
    seen: set[tuple[str, str, str]] = set()
    for rule in rules:
        triple = (rule.operation, rule.resource, rule.data_class)
        if triple in seen:
            raise InvalidPolicyBundle(
                f"duplicate rule for {triple!r}: one operation may have "
                "only one exact decision"
            )
        seen.add(triple)


def sign_policy_bundle(
    rules: Iterable[PolicyRule],
    secret: str | bytes,
    *,
    bundle_format: str = POLICY_BUNDLE_FORMAT,
) -> PolicyBundle:
    """Sign ``rules`` into a canonical :class:`PolicyBundle`.

    The signature covers the canonical payload (format + sorted rule
    triples); duplicate triples and non-:class:`PolicyRule` entries are
    rejected here so a bundle is either signable and unambiguous or not
    produced at all.
    """
    parsed = tuple(rules)
    for rule in parsed:
        if not isinstance(rule, PolicyRule):
            raise TypeError(
                f"policy rules must be PolicyRule, got {type(rule).__name__}"
            )
    _validate_unique_triples(parsed)
    # The bundle itself is canonical: rules are stored in canonical order so
    # verifiably-equivalent bundles are value-equal as well as same-signed.
    canonically_ordered = tuple(
        sorted(
            parsed,
            key=lambda rule: (
                rule.operation,
                rule.resource,
                rule.data_class,
                rule.decision.value,
            ),
        )
    )
    key = _normalize_secret(secret)
    digest = hmac.new(
        key, _canonical_payload(bundle_format, canonically_ordered), hashlib.sha256
    )
    return PolicyBundle(
        format=bundle_format,
        rules=canonically_ordered,
        signature=digest.hexdigest(),
    )


class PolicyEvaluator:
    """Deterministic evaluator for one verified :class:`PolicyBundle`.

    Construction is the trust boundary: an unsigned bundle raises
    :class:`UnsignedPolicy`, a malformed/mismatched or tampered signature
    raises :class:`InvalidSignature`, and a foreign format or ambiguous rule
    set raises :class:`InvalidPolicyBundle` -- no evaluation happens unless
    the signature verifies against the caller's secret (the contract-
    issuer/controller secret, tracked as a reference, never a log value).

    ``evaluate`` is exact-match first and never guesses:

    - exact ``(operation, resource, data_class)`` -> the rule's decision;
    - rule exists for the same ``operation`` under a different resource
      and/or data_class -> AMBIGUOUS (cannot be resolved mechanically);
    - no rule for that operation at all -> DENIED (implicit is forbidden).
    """

    def __init__(self, bundle: PolicyBundle, secret: str | bytes) -> None:
        if not isinstance(bundle, PolicyBundle):
            raise TypeError(
                f"bundle must be a PolicyBundle, got {type(bundle).__name__}"
            )
        if bundle.format != POLICY_BUNDLE_FORMAT:
            raise InvalidPolicyBundle(
                f"unsupported policy bundle format {bundle.format!r} "
                f"(expected {POLICY_BUNDLE_FORMAT!r})"
            )
        _validate_unique_triples(bundle.rules)
        key = _normalize_secret(secret)
        signature = bundle.signature
        if signature is None or (isinstance(signature, str) and not signature):
            raise UnsignedPolicy("policy bundle is unsigned")
        if (
            not isinstance(signature, str)
            or len(signature) != _SIGNATURE_HEX_LENGTH
            or any(char not in "0123456789abcdefABCDEF" for char in signature)
        ):
            raise InvalidSignature("policy bundle signature is malformed")
        expected = hmac.new(
            key, _canonical_payload(bundle.format, bundle.rules), hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(signature, expected):
            raise InvalidSignature("policy bundle signature does not verify")
        self.bundle = bundle
        self._secret_key = key
        self._by_triple: Mapping[tuple[str, str, str], PolicyDecision] = {
            (rule.operation, rule.resource, rule.data_class): rule.decision
            for rule in bundle.rules
        }
        self._listed_operations = frozenset(
            rule.operation for rule in bundle.rules
        )

    def evaluate(self, operation: Operation) -> PolicyDecision:
        """Classify ``operation``: ALLOWED / DENIED (exact) or AMBIGUOUS."""
        if not isinstance(operation, Operation):
            raise TypeError(
                f"operation must be an Operation, got {type(operation).__name__}"
            )
        exact = self._by_triple.get(
            (operation.operation, operation.resource, operation.data_class)
        )
        if exact is not None:
            return exact
        if operation.operation in self._listed_operations:
            return PolicyDecision.AMBIGUOUS
        return PolicyDecision.DENIED
