"""Metadata and contract tests for the five Superpowers-derived bounded
engineering skills (Plan 03, Task 1).

Written first (strict TDD red phase) against the external behavior
contract of Plan 03 Task 1
(:doc:`bootstrap plan <../../../.superpowers/bootstrap/plans/2026-08-27-03-superpowers-execution-bridge.md>`,
KCC x Superpowers Hybrid Framework): five KCC-native engineering skills
adapted from ``obra/superpowers`` at the pinned commit carry exact
attribution (source, MIT, pinned commit), have unique KCC native names,
declare ``lifecycle-owner: false``, stay task-local (no lifecycle
ownership and no project-wave dispatch language), follow their exact
task-local contracts, and the root ``THIRD_PARTY_NOTICES.md`` carries the
verbatim pinned MIT notice with the adapted file inventory while the
existing KCC LICENSE is preserved.

Plan 03, Task 4 extends the contract with the
``autobuild-task-execute`` orchestration skill: it delegates to exactly
the bounded team (implementer, verifier and the five engineering
disciplines), never to a forbidden project controller, and spells the
bounded execution discipline in order -- Read handoff -> Verify lease ->
engineering-tdd -> engineering-debug (only after KCC classifies the
current failure as BUG) -> Request review -> engineering-verify ->
Execution Report (validated through
``kcc-autobuild validate-model execution-report``) -> Return control to
KCC.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml
from typer.testing import CliRunner

from kcc_autobuild.cli import app

REPO_ROOT = Path(__file__).resolve().parents[3]
SKILLS = REPO_ROOT / ".KCC" / "capabilities" / "skills"
CLI_RUNNER = CliRunner()

PINNED_COMMIT = "b36e0829c6d0140e93cfef2ca599b1b07d4a7797"
UPSTREAM_URL = "https://github.com/obra/superpowers"
UPSTREAM_ATTRIBUTION = "obra/superpowers"
UPSTREAM_LICENSE = "MIT"

# KCC skill name -> upstream source file at the pinned commit.
ENGINEERING_SKILLS = {
    "engineering-tdd": "skills/test-driven-development/SKILL.md",
    "engineering-debug": "skills/systematic-debugging/SKILL.md",
    "engineering-request-review": "skills/requesting-code-review/SKILL.md",
    "engineering-receive-review": "skills/receiving-code-review/SKILL.md",
    "engineering-verify": "skills/verification-before-completion/SKILL.md",
}

# Lifecycle controllers that must never be imported or referenced as
# lifecycle ownership by a bounded task skill (plan Global Constraints).
FORBIDDEN_CONTROLLERS = [
    "using-superpowers",
    "brainstorming",
    "writing-plans",
    "executing-plans",
    "dispatching-parallel-agents",
]

# Language that would make a task skill a second lifecycle controller or a
# project-level scheduler/planner ("no sibling scheduling, Build Contract
# rewriting, or project-level planning").
FORBIDDEN_DISPATCH_LANGUAGE = [
    "lifecycle controller",
    "second controller",
    "project-level",
    "sibling",
    "parallel",
    "wave",
    "build contract",
]


def _text(skill: str) -> str:
    path = SKILLS / f"{skill}.md"
    assert path.exists(), f"missing engineering skill: {path}"
    return path.read_text(encoding="utf-8")


def _frontmatter(skill: str) -> dict:
    text = _text(skill)
    parts = text.split("---", 2)
    assert len(parts) == 3 and parts[0].strip() == "", (
        f"{skill}.md must open with a YAML frontmatter block"
    )
    return yaml.safe_load(parts[1])


def _body(skill: str) -> str:
    return _text(skill).split("---", 2)[2]


def _norm(text: str) -> str:
    """Collapse whitespace so markdown line-wrapping cannot break a
    phrase-level assertion."""
    return " ".join(text.split())


def _assert_ordered(text: str, markers: list[str]) -> None:
    """Every marker must be present, in ascending order."""
    lowered = _norm(text).lower()
    markers = [_norm(m) for m in markers]
    positions = [lowered.find(marker.lower()) for marker in markers]
    missing = [m for m, p in zip(markers, positions) if p == -1]
    assert not missing, f"missing ordered marker(s): {missing}"
    assert positions == sorted(positions), (
        f"markers out of order: {[m for _, m in sorted(zip(positions, markers))]}"
    )


# ---------------------------------------------------------------------------
# Five bounded engineering skills exist with unique KCC-native names.
# ---------------------------------------------------------------------------


def test_five_bounded_engineering_skills_exist() -> None:
    """Every engineering-* skill file prescribed by Plan 03 Task 1 exists."""
    for skill in ENGINEERING_SKILLS:
        assert (SKILLS / f"{skill}.md").exists(), skill


def test_engineering_skill_names_are_unique_and_native() -> None:
    """Each frontmatter name is KCC-native, matches its file stem, and is
    globally unique (no collision with any other KCC skill)."""
    names = [str(fm["name"]) for fm in (_frontmatter(s) for s in ENGINEERING_SKILLS)]
    assert names == list(ENGINEERING_SKILLS)
    assert len(set(names)) == len(names) == 5

    other_files = [
        path.stem
        for path in SKILLS.glob("*.md")
        if path.stem not in ENGINEERING_SKILLS
    ]
    collisions = set(names) & set(other_files)
    assert not collisions, f"name collision with existing skills: {collisions}"


def test_engineering_skills_have_kcc_native_frontmatter() -> None:
    """The frontmatter is KCC-native (name/description/argument-placeholder/
    delegates-to/maturity/maintainer/copyright/homepage/license) and
    lifecycle-owner is exactly False."""
    for skill, fm in ((s, _frontmatter(s)) for s in ENGINEERING_SKILLS):
        assert fm["name"] == skill
        assert fm["description"]
        assert "usage" in fm["description"].lower()
        assert fm["argument-placeholder"] == "<ARGS>"
        assert fm["delegates-to"] == []
        assert fm["maturity"] in {"L1", "L2"}
        assert fm["maintainer"] == "tarek.fawaz1983@gmail.com"
        assert "KCC framework" in fm["copyright"]
        assert fm["homepage"] == "https://tikasway.dev/kcc"
        assert fm["license"] == "Licensed under the terms in LICENSE"
        assert fm["lifecycle-owner"] is False


# ---------------------------------------------------------------------------
# Exact source metadata: obra/superpowers, MIT, pinned commit.
# ---------------------------------------------------------------------------


def test_engineering_skills_carry_exact_upstream_attribution() -> None:
    """Every skill records the exact upstream source (obra/superpowers),
    the pinned commit and the MIT license, plus the upstream file it
    adapts."""
    for skill, fm in ((s, _frontmatter(s)) for s in ENGINEERING_SKILLS):
        assert fm["upstream"] == UPSTREAM_ATTRIBUTION
        assert fm["upstream-url"] == UPSTREAM_URL
        assert fm["upstream-commit"] == PINNED_COMMIT
        assert fm["upstream-license"] == UPSTREAM_LICENSE
        assert fm["adapted-from"] == ENGINEERING_SKILLS[skill]


def test_engineering_skills_attribution_also_in_body() -> None:
    """Attribution is visible in the skill body, not only frontmatter."""
    for skill in ENGINEERING_SKILLS:
        body = _norm(_body(skill).lower())
        assert UPSTREAM_ATTRIBUTION.lower() in body
        assert "mit" in body


# ---------------------------------------------------------------------------
# No lifecycle ownership or project-wave dispatch language.
# ---------------------------------------------------------------------------


def test_engineering_skills_do_not_import_lifecycle_controllers() -> None:
    """None of the forbidden lifecycle controllers appears in any
    engineering skill (plan Global Constraints)."""
    for skill in ENGINEERING_SKILLS:
        text = _text(skill).lower()
        for controller in FORBIDDEN_CONTROLLERS:
            assert controller not in text, f"{skill}: forbidden '{controller}'"


def test_engineering_skills_are_not_a_second_controller_or_planner() -> None:
    """No lifecycle-ownership or project-wave dispatch language appears in
    any engineering skill body or frontmatter."""
    for skill in ENGINEERING_SKILLS:
        text = _text(skill).lower()
        for phrase in FORBIDDEN_DISPATCH_LANGUAGE:
            assert phrase not in text, f"{skill}: forbidden '{phrase}'"


# ---------------------------------------------------------------------------
# Exact task-local contracts.
# ---------------------------------------------------------------------------


def test_engineering_tdd_contract_is_red_green_refactor() -> None:
    """TDD: smallest meaningful failing test -> verify red -> minimum
    implementation -> verify green -> refactor."""
    body = _body("engineering-tdd").lower()
    _assert_ordered(
        body,
        [
            "no production code without a failing test first",
            "red — smallest meaningful failing test",
            "verify red",
            "green — minimum implementation",
            "verify green",
            "refactor",
        ],
    )


def test_engineering_debug_contract_is_root_cause_first() -> None:
    """Debug: reproduce -> evidence -> one hypothesis -> smallest
    experiment -> root-cause fix -> regression test."""
    body = _body("engineering-debug").lower()
    _assert_ordered(
        body,
        [
            "reproduce",
            "evidence",
            "one hypothesis",
            "smallest experiment",
            "root-cause fix",
            "regression test",
        ],
    )


def test_engineering_request_review_contract_is_spec_then_quality() -> None:
    """Review request: specification first, then code quality."""
    body = _norm(_body("engineering-request-review").lower())
    assert "acceptance criteria" in body
    assert "specification first" in body
    assert "code quality" in body
    assert body.find("specification first") < body.find("code quality")


def test_engineering_receive_review_contract_verifies_before_applying() -> None:
    """Receive review: verify findings before applying; record rejected
    findings with evidence."""
    body = _body("engineering-receive-review")
    _assert_ordered(
        body,
        [
            "Verify each finding",
            "before applying it",
            "Record the rejected finding with its evidence",
        ],
    )


def test_engineering_verify_contract_requires_exact_commands_and_evidence() -> None:
    """Verify: no completion claim without fresh verification evidence;
    exact verification commands and evidence references are required."""
    body = _body("engineering-verify")
    _assert_ordered(
        body,
        [
            "No completion claim without fresh verification evidence",
            "exact verification command",
            "evidence reference",
        ],
    )


def test_engineering_skills_are_task_local() -> None:
    """Every engineering skill is explicitly bounded to the current task."""
    for skill in ENGINEERING_SKILLS:
        body = _norm(_body(skill).lower())
        assert "bounded" in body, skill
        assert "task-local" in body, skill
        assert "current task" in body, skill
        assert "does not change task scope" in body, skill


# ---------------------------------------------------------------------------
# Third-party notices: pinned MIT notice, adapted file inventory, KCC
# LICENSE preserved.
# ---------------------------------------------------------------------------


def test_third_party_notices_carries_pinned_mit_notice() -> None:
    """THIRD_PARTY_NOTICES.md records the upstream source, pinned commit,
    MIT, the exact notice (Copyright (c) 2025 Jesse Vincent) and the
    complete adapted file inventory."""
    notices = REPO_ROOT / "THIRD_PARTY_NOTICES.md"
    assert notices.exists()
    text = _norm(notices.read_text(encoding="utf-8"))

    assert UPSTREAM_URL in text
    assert PINNED_COMMIT in text
    assert UPSTREAM_LICENSE in text
    assert "Copyright (c) 2025 Jesse Vincent" in text
    assert "Permission is hereby granted, free of charge, to any person obtaining a copy" in text
    assert 'THE SOFTWARE IS PROVIDED "AS IS"' in text

    # Adapted file inventory: each KCC adaptation and its upstream source.
    for skill, upstream in ENGINEERING_SKILLS.items():
        assert f".KCC/capabilities/skills/{skill}.md" in text
        assert upstream in text


def test_kcc_license_is_preserved() -> None:
    """The existing KCC LICENSE is untouched and still carries KCC's own
    grant text."""
    license_path = REPO_ROOT / "LICENSE"
    assert license_path.exists()
    text = license_path.read_text(encoding="utf-8")
    assert "Copyright © 2026 Tarek Fawaz" in text
    assert "Permission is hereby granted, free of charge" in text


# ---------------------------------------------------------------------------
# autobuild-task-execute orchestration skill (Plan 03, Task 4).
# ---------------------------------------------------------------------------

ORCHESTRATION_SKILL = "autobuild-task-execute"

# The bounded delegate team: the implementer and the verifier plus the five
# Superpowers-derived engineering disciplines, each by its KCC-native name.
ORCHESTRATION_DELEGATES = [
    "implementer",
    "verifier",
    "engineering-tdd",
    "engineering-debug",
    "engineering-request-review",
    "engineering-receive-review",
    "engineering-verify",
]

# Ordered body phrases of the task-execution discipline (Task 4 bullet):
# Read handoff -> Verify lease -> engineering-tdd -> engineering-debug ->
# Request review -> engineering-verify -> Execution Report ->
# Return control to KCC.
EXECUTE_ORDER = [
    "read handoff",
    "verify lease",
    "engineering-tdd",
    "engineering-debug",
    "request review",
    "engineering-verify",
    "execution report",
    "return control to kcc",
]


def test_autobuild_task_execute_skill_exists() -> None:
    """The Task 4 orchestration skill exists under its KCC-native name."""
    assert (SKILLS / f"{ORCHESTRATION_SKILL}.md").exists(), ORCHESTRATION_SKILL


def test_autobuild_task_execute_has_kcc_native_frontmatter() -> None:
    """The skill carries KCC-native frontmatter and
    ``lifecycle-owner: false`` (it is an execution discipline, never a
    second lifecycle controller)."""
    fm = _frontmatter(ORCHESTRATION_SKILL)
    assert fm["name"] == ORCHESTRATION_SKILL
    assert fm["description"]
    assert "usage" in fm["description"].lower()
    assert fm["argument-placeholder"] == "<ARGS>"
    assert fm["maturity"] in {"L1", "L2"}
    assert fm["maintainer"] == "tarek.fawaz1983@gmail.com"
    assert "KCC framework" in fm["copyright"]
    assert fm["homepage"] == "https://tikasway.dev/kcc"
    assert fm["license"] == "Licensed under the terms in LICENSE"
    assert fm["lifecycle-owner"] is False


def test_autobuild_task_execute_delegates_exactly_the_bounded_team() -> None:
    """delegates-to is exactly the bounded delegate team: implementer,
    verifier and the five engineering disciplines."""
    fm = _frontmatter(ORCHESTRATION_SKILL)
    assert fm["delegates-to"] == ORCHESTRATION_DELEGATES


def test_autobuild_task_execute_never_delegates_to_a_project_controller() -> None:
    """None of the forbidden project lifecycle controllers appears as a
    delegate (or anywhere in the skill) -- plan Global Constraints."""
    fm = _frontmatter(ORCHESTRATION_SKILL)
    text = _text(ORCHESTRATION_SKILL).lower()
    for controller in FORBIDDEN_CONTROLLERS:
        assert controller not in fm["delegates-to"], (
            f"{ORCHESTRATION_SKILL}: forbidden delegate '{controller}'"
        )
        assert controller not in text, (
            f"{ORCHESTRATION_SKILL}: forbidden '{controller}'"
        )


def test_autobuild_task_execute_ordered_body_phrases() -> None:
    """The skill body spells the bounded execution discipline in the
    exact Task 4 order: Read handoff -> Verify lease -> engineering-tdd
    -> engineering-debug -> Request review -> engineering-verify ->
    Execution Report -> Return control to KCC."""
    _assert_ordered(_body(ORCHESTRATION_SKILL), EXECUTE_ORDER)


def test_autobuild_task_execute_receive_review_is_inside_the_loop() -> None:
    """engineering-receive-review is part of the loop: it is delegated
    between requesting review and final verification."""
    body = _norm(_body(ORCHESTRATION_SKILL).lower())
    assert "engineering-receive-review" in body
    assert body.find("request review") < body.find("engineering-receive-review")
    assert body.find("engineering-receive-review") < body.find("engineering-verify")


def test_autobuild_task_execute_debug_after_kcc_classifies_bug() -> None:
    """engineering-debug is entered only after KCC classifies the
    current failure as BUG (the worker never self-classifies)."""
    body = _norm(_body(ORCHESTRATION_SKILL).lower())
    gate = "only after kcc classifies the current failure as bug"
    assert gate in body, body
    # The gate precedes the engineering-debug discipline in the body.
    assert body.find(gate) < body.find("engineering-debug")


def test_autobuild_task_execute_report_validates_through_kcc_cli(tmp_path) -> None:
    """The final YAML report must validate through
    ``kcc-autobuild validate-model execution-report <path>`` before the
    worker returns -- the guard is not just a phrase: the command must
    actually accept a real ExecutionReport artifact (regression guard
    for the ``execution-report`` model kind)."""
    body = _norm(_body(ORCHESTRATION_SKILL))
    assert "kcc-autobuild validate-model execution-report <path>" in body

    report_path = tmp_path / "execution-report.yaml"
    report_path.write_text(
        "run_id: RUN-001\n"
        "task_id: TASK-021\n"
        "attempt: 1\n"
        "status: passed\n"
        "lease_id: LEASE-2026-0001\n"
        "workspace_id: WS-RUN-001\n"
        "acceptance_evidence:\n"
        "  - acceptance_id: AC-014-1\n"
        "    test_ids: [T-041, T-042]\n"
        "    evidence_refs: [artifacts/run-001/t-041.log]\n"
        "failure: null\n"
        "usage: {}\n"
        "outputs: []\n"
        "deviations: []\n"
        "trace_updates: []\n",
        encoding="utf-8",
    )
    result = CLI_RUNNER.invoke(
        app, ["validate-model", "execution-report", str(report_path)]
    )
    assert result.exit_code == 0, result.stderr
    assert json.loads(result.stdout) == {
        "valid": True,
        "kind": "execution-report",
        "path": str(report_path),
    }


def test_autobuild_task_execute_obey_skill_contract_steps_section() -> None:
    """The body carries the skill-contract ``## Steps`` section and the
    Task 4 phase headings are spelled inside it, in order."""
    body = _body(ORCHESTRATION_SKILL)
    assert "## Steps" in body, body
    steps_section = body.split("## Steps", 1)[1].split("\n## ", 1)[0]
    _assert_ordered(steps_section, EXECUTE_ORDER)


def test_autobuild_task_execute_has_no_dispatch_language() -> None:
    """The orchestration skill is not a second controller or planner:
    the same no-lifecycle-ownership / no-project-wave-dispatch language
    check applies to it as to the five engineering skills."""
    text = _text(ORCHESTRATION_SKILL).lower()
    for phrase in FORBIDDEN_DISPATCH_LANGUAGE:
        assert phrase not in text, (
            f"{ORCHESTRATION_SKILL}: forbidden '{phrase}'"
        )


def test_autobuild_task_execute_lease_checks_are_pack_scoped() -> None:
    """The worker verifies only what the handoff pack can prove -- the
    lease is present, bound to the same run id and task id, generation
    positive.  Lease *liveness* is not a pack fact: it is a
    chain-of-custody claim that KCC alone verifies before acceptance."""
    body = _norm(_body(ORCHESTRATION_SKILL).lower())
    for marker in (
        "lease is present",
        "bound to the same run id and task id",
        "generation is positive",
    ):
        assert marker in body, f"missing lease-check marker: {marker}"
    assert "lease liveness" in body
    assert "not a pack fact" in body
    assert "kcc alone verifies" in body
