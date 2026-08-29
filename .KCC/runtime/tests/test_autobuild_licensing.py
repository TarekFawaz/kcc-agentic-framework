"""Licensing/attribution baselines and autobuild operator-document contract
tests (Plan 07, Task 6).

Written first (strict TDD red phase) against the external behavior
contract of Plan 07 Task 6
(:doc:`../../../.superpowers/bootstrap/plans/2026-08-27-07-evaluation-rollout.task-contracts.md`):
``docs/autobuild/licensing.md`` records the immutable KCC + Superpowers
baselines (exact pinned commits, LICENSE Git blob, GitHub
``NOASSERTION``, custom/non-SPDX, MIT, Copyright (c) 2025 Jesse
Vincent, release v6.3.0); the operator docs record the exact commands
``autobuild <idea-or-path>``, resume RUN, ``--status``, ``--pause``,
``--resume`` and the state semantics (BLOCKED auto-recheck,
EXTERNAL_WAIT tracking, HALTED consolidated decision only outside
authority); README/QUICKSTART describe Autobuild as opt-in without
changing the upstream ``auto`` semantics.
"""

from __future__ import annotations

from pathlib import Path

from kcc_autobuild.cli import app  # noqa: F401  (runtime must stay importable)

REPO_ROOT = Path(__file__).resolve().parents[3]

LICENSING_DOC = REPO_ROOT / "docs" / "autobuild" / "licensing.md"
OPERATIONS_DOC = REPO_ROOT / "docs" / "autobuild" / "operations.md"
README = REPO_ROOT / "README.md"
QUICKSTART = REPO_ROOT / "QUICKSTART.md"

# Immutable baselines from the Plan 07 Task 6 contract.
KCC_PINNED_COMMIT = "708bd761a4ca39abcb2161de9b1109b913cafda8"
KCC_LICENSE_BLOB = "ae6d7670ed9310494163033a2146d07de2ef4e81"
GITHUB_LICENSE = "NOASSERTION"
SUPERPOWERS_PINNED_COMMIT = "b36e0829c6d0140e93cfef2ca599b1b07d4a7797"
SUPERPOWERS_RELEASE = "v6.3.0"
SUPERPOWERS_LICENSE = "MIT"
SUPERPOWERS_COPYRIGHT = "Copyright (c) 2025 Jesse Vincent"

# Operator-facing exact commands and semantics from the same contract.
OPERATOR_COMMANDS = (
    "autobuild <idea-or-path>",
    "--status",
    "--pause",
    "--resume",
)


def _body(path: Path) -> str:
    assert path.exists(), f"missing doc: {path.relative_to(REPO_ROOT)}"
    return path.read_text(encoding="utf-8")


def test_licensing_doc_records_kcc_baseline() -> None:
    """docs/autobuild/licensing.md pins the KCC license baseline: pinned
    commit, custom/non-SPDX, GitHub NOASSERTION, LICENSE Git blob."""
    text = _body(LICENSING_DOC)

    assert KCC_PINNED_COMMIT in text
    assert KCC_LICENSE_BLOB in text
    assert GITHUB_LICENSE in text
    assert "non-SPDX" in text
    assert "custom" in text


def test_licensing_doc_records_superpowers_baseline() -> None:
    """docs/autobuild/licensing.md pins the Superpowers baseline: pinned
    commit, release v6.3.0, MIT, Copyright (c) 2025 Jesse Vincent."""
    text = _body(LICENSING_DOC)

    assert SUPERPOWERS_PINNED_COMMIT in text
    assert SUPERPOWERS_RELEASE in text
    assert SUPERPOWERS_LICENSE in text
    assert SUPERPOWERS_COPYRIGHT in text


def test_operator_doc_records_exact_commands() -> None:
    """The operator doc spells the exact commands: autobuild
    <idea-or-path>, resume RUN, --status, --pause, --resume."""
    text = _body(OPERATIONS_DOC)

    for command in OPERATOR_COMMANDS:
        assert command in text, f"operator doc missing exact command: {command}"
    # "resume RUN" semantics (resume an existing RUN from durable state).
    assert "resume run" in text.lower()


def test_operator_doc_records_state_semantics() -> None:
    """The operator doc states BLOCKED auto-recheck, EXTERNAL_WAIT
    tracking, and HALTED consolidated decision outside authority."""
    text = _body(OPERATIONS_DOC)

    assert "BLOCKED" in text
    assert "auto-recheck" in text
    assert "EXTERNAL_WAIT" in text
    assert "HALTED" in text
    assert "consolidated" in text


def test_readme_and_quickstart_describe_autobuild_opt_in() -> None:
    """README and QUICKSTART describe Autobuild as an opt-in workflow
    with its exact entrypoint command."""
    for path in (README, QUICKSTART):
        text = _body(path)
        assert "opt-in" in text, f"{path.name} must describe Autobuild as opt-in"
        assert "autobuild <idea-or-path>" in text, (
            f"{path.name} must show the autobuild entrypoint command"
        )


def test_upstream_auto_semantics_unchanged() -> None:
    """The autobuild opt-in description must not redefine the upstream
    ``auto`` entrypoint semantics documented in README/QUICKSTART."""
    readme = _body(README)
    quickstart = _body(QUICKSTART)

    # `auto <idea>` remains the documented HOTL entrypoint.
    assert "auto <idea>" in readme
    assert "auto <idea text>" in quickstart
    assert "HOTL" in readme
    assert "`auto` is the Human-On-The-Loop entrypoint" in quickstart
