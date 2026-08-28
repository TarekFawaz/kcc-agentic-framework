"""Behavioral contract for the deterministic destructive-operation policy evaluator.

Owned by ``test_policy.py`` (see the KCC x Superpowers Hybrid Framework Plan 04,
Task 6: Deterministic destructive-operation policy evaluator, in
``.superpowers/bootstrap/plans/2026-08-27-04-scheduler-budget-rate-policy.task-contracts.md``).

Classifies a requested destructive/mutating :class:`Operation` against the
Build Contract's destructive-action policy (Design Spec v1.2 sections 14.5,
18/E4 and 24: *destructive operations must be policy-classified before
execution*): a canonical -- order-independent, deterministic -- HMAC-SHA256
signed :class:`PolicyBundle` is the machine-readable policy, and the
:class:`PolicyEvaluator` refuses to evaluate an unsigned or corrupted bundle
(fail closed, never evaluate an untrusted policy).

Decision rules, in order:

- exact rule match (``operation``+``resource``+``data_class`` equal to one
  rule's triple) -> the rule's decision, ALLOWED or DENIED;
- same ``operation`` but mismatched ``resource`` and/or ``data_class``
  (rule exists for that operation, no exact match) -> AMBIGUOUS;
- operation unlisted by every rule -> DENIED.

The evaluator is pure and deterministic: identical (bundle, operation) input
yields the identical decision, and the canonical serialization makes the
signature independent of rule ordering.
"""

from __future__ import annotations

import pytest

from kcc_autobuild.policy import (
    POLICY_BUNDLE_FORMAT,
    InvalidPolicyBundle,
    InvalidSignature,
    Operation,
    PolicyBundle,
    PolicyDecision,
    PolicyEvaluator,
    PolicyRule,
    UnsignedPolicy,
    sign_policy_bundle,
)

SECRET = "unit-test-policy-secret"

ALLOW_DEPLOY_PUBLIC = PolicyRule("deploy", "prod/app", "PUBLIC", PolicyDecision.ALLOWED)
DENY_DEPLOY_PERSONAL = PolicyRule("deploy", "prod/app", "PERSONAL", PolicyDecision.DENIED)


# --- Signing / canonical bundle ---------------------------------------------


def test_signed_bundle_verifies_and_allows_exact_rule():
    bundle = sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], SECRET)
    evaluator = PolicyEvaluator(bundle, SECRET)
    assert evaluator.evaluate(Operation("deploy", "prod/app", "PUBLIC")) is (
        PolicyDecision.ALLOWED
    )


def test_signed_bundle_verifies_and_denies_exact_deny_rule():
    bundle = sign_policy_bundle([DENY_DEPLOY_PERSONAL], SECRET)
    evaluator = PolicyEvaluator(bundle, SECRET)
    assert evaluator.evaluate(Operation("deploy", "prod/app", "PERSONAL")) is (
        PolicyDecision.DENIED
    )


def test_policy_bundle_is_frozen_and_carries_canonical_format():
    bundle = sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], SECRET)
    assert bundle.format == POLICY_BUNDLE_FORMAT
    assert bundle.signature
    with pytest.raises(Exception):
        bundle.rules = ()  # type: ignore[misc]


def test_canonical_signature_is_order_independent():
    other = PolicyRule("migrate", "prod/db", "PERSONAL", PolicyDecision.DENIED)
    first = sign_policy_bundle([ALLOW_DEPLOY_PUBLIC, other], SECRET)
    shuffled = sign_policy_bundle([other, ALLOW_DEPLOY_PUBLIC], SECRET)
    # Shuffled rule order yields the byte-identical signature: the canonical
    # serialization sorts by (operation, resource, data_class).
    assert first.signature == shuffled.signature
    assert first == shuffled
    # Both orderings verify and evaluate identically.
    for bundle in (first, shuffled):
        evaluator = PolicyEvaluator(bundle, SECRET)
        assert evaluator.evaluate(Operation("deploy", "prod/app", "PUBLIC")) is (
            PolicyDecision.ALLOWED
        )
        assert evaluator.evaluate(Operation("migrate", "prod/db", "PERSONAL")) is (
            PolicyDecision.DENIED
        )


def test_empty_bundle_is_valid_and_denies_every_operation():
    bundle = sign_policy_bundle([], SECRET)
    evaluator = PolicyEvaluator(bundle, SECRET)
    assert evaluator.evaluate(Operation("deploy", "prod/app", "PUBLIC")) is (
        PolicyDecision.DENIED
    )
    assert evaluator.evaluate(Operation("destroy", "prod/db", "ANY")) is (
        PolicyDecision.DENIED
    )


# --- Constructor rejects unsigned / bad-signature bundles -------------------


def test_unsigned_bundle_is_rejected():
    bundle = PolicyBundle(
        format=POLICY_BUNDLE_FORMAT,
        rules=(ALLOW_DEPLOY_PUBLIC,),
        signature="",
    )
    with pytest.raises(UnsignedPolicy):
        PolicyEvaluator(bundle, SECRET)


def test_bundle_without_signature_attribute_is_rejected():
    bundle = PolicyBundle(
        format=POLICY_BUNDLE_FORMAT,
        rules=(ALLOW_DEPLOY_PUBLIC,),
        signature=None,  # type: ignore[arg-type]
    )
    with pytest.raises(UnsignedPolicy):
        PolicyEvaluator(bundle, SECRET)


def test_malformed_signature_is_rejected():
    bundle = PolicyBundle(
        format=POLICY_BUNDLE_FORMAT,
        rules=(ALLOW_DEPLOY_PUBLIC,),
        signature="deadbeef",
    )
    with pytest.raises(InvalidSignature):
        PolicyEvaluator(bundle, SECRET)


def test_wrong_secret_is_rejected_as_bad_signature():
    bundle = sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], "someone-elses-secret")
    with pytest.raises(InvalidSignature):
        PolicyEvaluator(bundle, SECRET)


def test_tampered_rules_are_rejected():
    bundle = sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], SECRET)
    # Rules swapped after signing: the stored signature no longer covers them.
    forged = PolicyBundle(
        format=POLICY_BUNDLE_FORMAT,
        rules=(DENY_DEPLOY_PERSONAL,),
        signature=bundle.signature,
    )
    with pytest.raises(InvalidSignature):
        PolicyEvaluator(forged, SECRET)


def test_wrong_bundle_format_is_rejected():
    bundle = sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], SECRET)
    foreign = PolicyBundle(
        format="kcc-autobuild-policy/2",
        rules=bundle.rules,
        signature=bundle.signature,
    )
    with pytest.raises(InvalidPolicyBundle):
        PolicyEvaluator(foreign, SECRET)


# --- Decision rules (prescribed) --------------------------------------------


def test_same_operation_different_resource_is_ambiguous():
    evaluator = PolicyEvaluator(sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], SECRET), SECRET)
    assert evaluator.evaluate(Operation("deploy", "staging/app", "PUBLIC")) is (
        PolicyDecision.AMBIGUOUS
    )


def test_same_operation_different_data_class_is_ambiguous():
    evaluator = PolicyEvaluator(sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], SECRET), SECRET)
    assert evaluator.evaluate(Operation("deploy", "prod/app", "PERSONAL")) is (
        PolicyDecision.AMBIGUOUS
    )


def test_same_operation_different_resource_and_data_class_is_ambiguous():
    evaluator = PolicyEvaluator(sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], SECRET), SECRET)
    assert evaluator.evaluate(Operation("deploy", "staging/app", "PERSONAL")) is (
        PolicyDecision.AMBIGUOUS
    )


def test_same_operation_with_generic_resource_is_ambiguous():
    evaluator = PolicyEvaluator(sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], SECRET), SECRET)
    assert evaluator.evaluate(Operation("deploy", "*", "*")) is PolicyDecision.AMBIGUOUS


def test_unlisted_operation_is_denied():
    evaluator = PolicyEvaluator(
        sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], SECRET), SECRET
    )
    # Same resource/data_class, but the operation name is unlisted: DENIED.
    assert evaluator.evaluate(Operation("destroy", "prod/app", "PUBLIC")) is (
        PolicyDecision.DENIED
    )


def test_unlisted_operation_with_no_rules_at_all_is_denied():
    evaluator = PolicyEvaluator(sign_policy_bundle([], SECRET), SECRET)
    assert evaluator.evaluate(Operation("destroy", "prod/db", "PERSONAL")) is (
        PolicyDecision.DENIED
    )


def test_exact_deny_rule_wins_over_sibling_allow_rule():
    rules = [ALLOW_DEPLOY_PUBLIC, DENY_DEPLOY_PERSONAL]
    evaluator = PolicyEvaluator(sign_policy_bundle(rules, SECRET), SECRET)
    assert evaluator.evaluate(Operation("deploy", "prod/app", "PUBLIC")) is (
        PolicyDecision.ALLOWED
    )
    assert evaluator.evaluate(Operation("deploy", "prod/app", "PERSONAL")) is (
        PolicyDecision.DENIED
    )


def test_evaluation_is_deterministic():
    evaluator = PolicyEvaluator(
        sign_policy_bundle([ALLOW_DEPLOY_PUBLIC, DENY_DEPLOY_PERSONAL], SECRET), SECRET
    )
    queries = [
        Operation("deploy", "prod/app", "PUBLIC"),
        Operation("deploy", "staging/app", "PUBLIC"),
        Operation("destroy", "prod/app", "PUBLIC"),
    ]
    first = [evaluator.evaluate(query) for query in queries]
    # Repeated calls are byte-identical; a second evaluator over the verifiably
    # same bundle agrees -- no map-iteration nondeterminism.
    again = [evaluator.evaluate(query) for query in queries]
    twin = PolicyEvaluator(
        sign_policy_bundle([ALLOW_DEPLOY_PUBLIC, DENY_DEPLOY_PERSONAL], SECRET), SECRET
    )
    assert again == first
    assert [twin.evaluate(query) for query in queries] == first


# --- Bundle construction rejects ambiguity in the rule set -------------------


def test_conflicting_rules_for_identical_triple_are_rejected():
    with pytest.raises(InvalidPolicyBundle):
        sign_policy_bundle(
            [
                ALLOW_DEPLOY_PUBLIC,
                PolicyRule("deploy", "prod/app", "PUBLIC", PolicyDecision.DENIED),
            ],
            SECRET,
        )


def test_duplicate_rule_triple_is_rejected():
    with pytest.raises(InvalidPolicyBundle):
        sign_policy_bundle([ALLOW_DEPLOY_PUBLIC, ALLOW_DEPLOY_PUBLIC], SECRET)


def test_evaluator_rejects_duplicate_rule_triples_in_bundle():
    # A bundle that bypassed the signer (e.g. hand-assembled) still fails
    # closed at the evaluator: an ambiguous rule set is never evaluated.
    bundle = PolicyBundle(
        format=POLICY_BUNDLE_FORMAT,
        rules=(
            ALLOW_DEPLOY_PUBLIC,
            PolicyRule("deploy", "prod/app", "PUBLIC", PolicyDecision.DENIED),
        ),
        signature="0" * 64,
    )
    with pytest.raises(InvalidPolicyBundle):
        PolicyEvaluator(bundle, SECRET)


# --- Value-object validation -------------------------------------------------


def test_rule_decision_must_be_allowed_or_denied():
    with pytest.raises(ValueError):
        PolicyRule("deploy", "prod/app", "PUBLIC", PolicyDecision.AMBIGUOUS)
    with pytest.raises(ValueError):
        PolicyRule("deploy", "prod/app", "PUBLIC", "MAYBE")
    with pytest.raises(ValueError):
        PolicyRule("deploy", "prod/app", "PUBLIC", "")


def test_rule_accepts_canonical_decision_string():
    rule = PolicyRule("deploy", "prod/app", "PUBLIC", "ALLOWED")
    assert rule.decision is PolicyDecision.ALLOWED


def test_operation_fields_must_be_nonempty_strings():
    with pytest.raises(ValueError):
        Operation("", "prod/app", "PUBLIC")
    with pytest.raises(ValueError):
        Operation("deploy", "", "PUBLIC")
    with pytest.raises(ValueError):
        Operation("deploy", "prod/app", " ")
    with pytest.raises(TypeError):
        Operation("deploy", "prod/app", 42)  # type: ignore[arg-type]


def test_operation_is_a_value_object():
    op = Operation("deploy", "prod/app", "PUBLIC")
    assert op == Operation("deploy", "prod/app", "PUBLIC")
    assert op != Operation("deploy", "staging/app", "PUBLIC")
    with pytest.raises(Exception):
        op.resource = "staging/app"  # type: ignore[misc]


def test_evaluate_rejects_non_operation_arguments():
    evaluator = PolicyEvaluator(sign_policy_bundle([ALLOW_DEPLOY_PUBLIC], SECRET), SECRET)
    with pytest.raises(TypeError):
        evaluator.evaluate("deploy")  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        evaluator.evaluate(None)  # type: ignore[arg-type]


def test_evaluator_rejects_non_bundle_construction():
    with pytest.raises(TypeError):
        PolicyEvaluator(("not", "a", "bundle"), SECRET)  # type: ignore[arg-type]
