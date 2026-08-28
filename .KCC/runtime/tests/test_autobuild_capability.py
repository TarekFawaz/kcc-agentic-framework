"""Capability tests for the Plan-02 autobuild governance artifacts.

Written first (strict TDD red phase) against the external behavior
contract of :doc:`Plan 02 Task 5 <../../../.superpowers/sdd/plan-02/progress.md>`
(KCC x Superpowers Hybrid Framework): Plan-02 kernel protocols /
contracts / templates, the ``autobuild`` skill, the ``readiness-auditor``
agent and the real YAML/schema ``validate-model`` CLI (ruling R5).

Binding semantics under test:

* Every approved kernel YAML template validates against the actual
  Pydantic model it represents — both directly and through the
  ``validate-model`` CLI for the ``trace`` / ``readiness`` /
  ``contract`` / ``decision-log`` / ``prototype`` kinds (R5).
* The readiness template carries typed red-team findings (R2) and all
  templates stay model-compatible with the optional ``run_id`` (R1).
* The ``autobuild`` skill exists as a separate capability from the
  existing ``auto`` skill, documents the approved discovery-to-lock
  sequence (risk classify -> H1 -> journey/flow/prototype/H2 ->
  research/architecture -> Trace+Decision -> dependency/readiness ->
  red team -> contract -> runtime validation -> LOCK -> controller) and
  keeps H1 Scope, H2 Prototype and final LOCK as the only formal
  pre-build gates (R10); post-lock routine questions are prohibited.
* The ``readiness-auditor`` agent exists as the independent red-team
  readiness reviewer of Design Spec v1.2 section 12.6 and records typed
  findings with dispositions into the readiness pack.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import yaml
from typer.testing import CliRunner

from kcc_autobuild.cli import app
from kcc_autobuild.contract import BuildContract
from kcc_autobuild.decision_log import DecisionLog
from kcc_autobuild.prototype import Prototype
from kcc_autobuild.readiness import ReadinessPack, RedTeamDisposition, RedTeamFinding
from kcc_autobuild.trace import TraceGraph

REPO_ROOT = Path(__file__).resolve().parents[3]
KERNEL = REPO_ROOT / ".KCC" / "kernel"
TEMPLATES = KERNEL / "templates"
SKILLS = REPO_ROOT / ".KCC" / "capabilities" / "skills"
AGENTS = REPO_ROOT / ".KCC" / "capabilities" / "agents"

runner = CliRunner()

APPROVED_SEQUENCE = [
    "risk classify",
    "h1",
    "prototype",
    "h2",
    "architecture",
    "decision log",
    "readiness",
    "red team",
    "contract",
    "lock",
    "controller",
]


def _read_template(name: str) -> dict:
    path = TEMPLATES / name
    assert path.exists(), f"template missing: {path}"
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def _invoke_validate_model(kind: str, path: Path):
    return runner.invoke(app, ["validate-model", kind, str(path)])


# ---------------------------------------------------------------------------
# Kernel YAML templates validate against the actual Pydantic models (R5).
# ---------------------------------------------------------------------------


def test_trace_graph_template_matches_model() -> None:
    """The trace-graph template is a valid TraceGraph (R1 run_id included)."""
    graph = TraceGraph.model_validate(_read_template("trace-graph.yaml"))
    assert graph.run_id == "RUN-001"
    assert graph.nodes
    assert graph.edges


def test_readiness_pack_template_matches_model_and_has_red_team_findings() -> None:
    """The readiness template is a valid ReadinessPack carrying red-team
    findings (R2) with typed dispositions."""
    pack = ReadinessPack.model_validate(_read_template("readiness-pack.yaml"))
    assert pack.items
    assert pack.red_team_findings
    assert all(
        isinstance(finding, RedTeamFinding) for finding in pack.red_team_findings
    )
    assert any(
        finding.disposition is RedTeamDisposition.OPEN
        or finding.disposition is RedTeamDisposition.RESOLVED
        or finding.disposition is RedTeamDisposition.MITIGATED
        or finding.disposition is RedTeamDisposition.ACCEPTED
        for finding in pack.red_team_findings
    )
    for item in pack.items:
        for record in item.evidence:
            assert record.checked_at.tzinfo is not None


def test_decision_log_template_matches_model() -> None:
    """The decision-log template is a valid DecisionLog (R1 run_id)."""
    log = DecisionLog.model_validate(_read_template("decision-log.yaml"))
    assert log.run_id == "RUN-001"
    assert log.entries
    assert all(entry.id.startswith("DEC-") for entry in log.entries)


def test_build_contract_template_matches_model() -> None:
    """The build-contract template is a valid (unlocked) BuildContract."""
    contract = BuildContract.model_validate(_read_template("build-contract.yaml"))
    assert contract.tier1.product_scope
    assert contract.tier1.definition_of_done
    assert contract.locked_at is None
    assert contract.contract_hash is None
    assert contract.tier2_hash is None


def test_prototype_manifest_template_matches_model() -> None:
    """The prototype-manifest template is a valid clickable Prototype.

    The prototype is declared interactive and is never the production
    implementation (Design Spec v1.2 section 9.6).
    """
    prototype = Prototype.model_validate(
        _read_template("prototype-manifest.yaml")
    )
    assert prototype.interactive is True
    assert prototype.production_implementation is False
    assert prototype.primary_journey
    assert prototype.screens
    assert prototype.interactions


# ---------------------------------------------------------------------------
# The real validate-model CLI accepts every template kind (R5).
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("kind", "filename"),
    [
        ("trace", "trace-graph.yaml"),
        ("readiness", "readiness-pack.yaml"),
        ("contract", "build-contract.yaml"),
        ("decision-log", "decision-log.yaml"),
        ("prototype", "prototype-manifest.yaml"),
    ],
)
def test_cli_validate_model_accepts_every_template_kind(kind, filename) -> None:
    """validate-model exits 0 with valid:true for each approved template."""
    result = _invoke_validate_model(kind, TEMPLATES / filename)
    assert result.exit_code == 0, result.stderr
    assert json.loads(result.stdout) == {
        "valid": True,
        "kind": kind,
        "path": str(TEMPLATES / filename),
    }


def test_cli_validate_model_rejects_unknown_kind() -> None:
    """An unknown kind is an error, not a success (R5: real validation)."""
    result = _invoke_validate_model("bogus", TEMPLATES / "trace-graph.yaml")
    assert result.exit_code != 0
    assert "bogus" in result.stderr


def test_cli_validate_model_rejects_schema_violation(tmp_path) -> None:
    """A model-level schema violation fails nonzero (R5)."""
    path = tmp_path / "bad-trace.yaml"
    path.write_text(
        "nodes:\n"
        "  - id: REQ-001\n"
        "    kind: requirement\n"
        "edges:\n"
        "  - source: REQ-001\n"
        "    target: MISSING\n",
        encoding="utf-8",
    )
    result = _invoke_validate_model("trace", path)
    assert result.exit_code != 0
    assert '"valid": false' in result.stderr


def test_cli_validate_model_rejects_malformed_yaml(tmp_path) -> None:
    """A YAML syntax error fails nonzero (R5)."""
    path = tmp_path / "broken.yaml"
    path.write_text("{ this is not: [ valid\n", encoding="utf-8")
    result = _invoke_validate_model("trace", path)
    assert result.exit_code != 0
    assert '"valid": false' in result.stderr


def test_cli_validate_model_rejects_missing_file(tmp_path) -> None:
    """A missing artifact fails nonzero instead of an existence probe."""
    result = _invoke_validate_model("trace", tmp_path / "missing.yaml")
    assert result.exit_code != 0
    assert '"valid": false' in result.stderr


# ---------------------------------------------------------------------------
# autobuild capability: separate from auto, approved sequence, only
# H1 / H2 / LOCK formal gates (R10).
# ---------------------------------------------------------------------------


def test_autobuild_skill_exists_and_is_separate_from_auto() -> None:
    """autobuild.md exists with skill frontmatter; auto.md stays separate."""
    skill_path = SKILLS / "autobuild.md"
    assert skill_path.exists()
    frontmatter = yaml.safe_load(
        skill_path.read_text(encoding="utf-8").split("---", 2)[1]
    )
    assert frontmatter["name"] == "autobuild"
    assert frontmatter["description"]
    assert frontmatter["argument-placeholder"] == "<ARGS>"
    # The pre-existing auto capability remains its own skill.
    auto_frontmatter = yaml.safe_load(
        (SKILLS / "auto.md").read_text(encoding="utf-8").split("---", 2)[1]
    )
    assert auto_frontmatter["name"] == "auto"


def test_autobuild_skill_documents_approved_sequence_in_order() -> None:
    """The skill body spells the approved discovery-to-lock sequence in
    order and keeps only H1/H2/LOCK as formal pre-build gates (R10)."""
    body = (SKILLS / "autobuild.md").read_text(encoding="utf-8").lower()
    positions = [body.find(marker) for marker in APPROVED_SEQUENCE]
    assert all(position != -1 for position in positions), (
        [marker for marker, pos in zip(APPROVED_SEQUENCE, positions) if pos == -1]
    )
    assert positions == sorted(positions)
    # Only the three formal gates; no extra pre-build approval gate.
    assert "only formal pre-build gates" in body
    assert "no post-lock approval" in body or "post-lock approvals are prohibited" in body


# ---------------------------------------------------------------------------
# readiness-auditor agent (Design Spec v1.2 section 12.6).
# ---------------------------------------------------------------------------


def test_readiness_auditor_agent_exists() -> None:
    """readiness-auditor.md exists with agent frontmatter and re-execution
    semantics: it re-executes a sample of readiness claims instead of
    re-reading them (spec 12.6), and records typed dispositions."""
    agent_path = AGENTS / "readiness-auditor.md"
    assert agent_path.exists()
    frontmatter = yaml.safe_load(
        agent_path.read_text(encoding="utf-8").split("---", 2)[1]
    )
    assert frontmatter["name"] == "readiness-auditor"
    assert frontmatter["role"]
    assert frontmatter["model-class"] == "strong-reasoning"
    assert frontmatter["description"]
    assert frontmatter["tools-required"]
    body = agent_path.read_text(encoding="utf-8").lower()
    assert "re-execute" in body or "re-executes" in body
    assert "red_team_findings" in body


# ---------------------------------------------------------------------------
# Kernel protocols and contract document (Plan-02 governance surface).
# ---------------------------------------------------------------------------


def test_kernel_protocols_cover_discovery_and_readiness() -> None:
    """autobuild-discovery.md covers H1/H2 + Trace/Decision; 
    autobuild-readiness.md covers evidence + red team + pack taxonomy."""
    discovery = (KERNEL / "protocols" / "autobuild-discovery.md").read_text(
        encoding="utf-8"
    ).lower()
    assert "h1" in discovery
    assert "h2" in discovery
    assert "trace" in discovery
    assert "decision log" in discovery or "decision-log" in discovery

    readiness = (KERNEL / "protocols" / "autobuild-readiness.md").read_text(
        encoding="utf-8"
    ).lower()
    assert "red team" in readiness or "red-team" in readiness
    assert "readiness evidence pack" in readiness
    assert "blocker" in readiness
    assert "ready" in readiness


def test_kernel_contract_document_exists() -> None:
    """autobuild-contract.md documents the two-tier contract and the LOCK."""
    contract_doc = (KERNEL / "contracts" / "autobuild-contract.md").read_text(
        encoding="utf-8"
    ).lower()
    assert "tier 1" in contract_doc or "tier1" in contract_doc
    assert "tier 2" in contract_doc or "tier2" in contract_doc
    assert "lock" in contract_doc
