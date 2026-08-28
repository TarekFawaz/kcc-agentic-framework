import json

import pytest
from typer.testing import CliRunner
from kcc_autobuild.cli import app

runner = CliRunner()


def test_init_run_creates_database(tmp_path):
    result = runner.invoke(app, ["init-run", "RUN-001", "demo", "--repo-root", str(tmp_path)])
    assert result.exit_code == 0
    assert '"state": "INTAKE"' in result.stdout
    assert (tmp_path / "coordination/autobuild/RUN-001/run.db").exists()


def test_transition_refuses_invalid_skip(tmp_path):
    runner.invoke(app, ["init-run", "RUN-001", "demo", "--repo-root", str(tmp_path)])
    result = runner.invoke(app, ["transition", "RUN-001", "DONE", "--expected", "INTAKE", "--repo-root", str(tmp_path)])
    assert result.exit_code != 0


@pytest.mark.parametrize("bad_id", ["bad-id", "RUN-1/../../.git"])
def test_init_run_rejects_invalid_run_id_without_artifacts(tmp_path, bad_id):
    """Invalid run_id must be rejected before any coordination artifact is created."""
    result = runner.invoke(app, ["init-run", bad_id, "demo", "--repo-root", str(tmp_path)])
    assert result.exit_code != 0
    assert not (tmp_path / "coordination").exists()


def test_show_run_missing_does_not_create_database(tmp_path):
    """show-run for a nonexistent run must fail without creating a DB."""
    result = runner.invoke(app, ["show-run", "RUN-999", "--repo-root", str(tmp_path)])
    assert result.exit_code != 0
    assert not (tmp_path / "coordination/autobuild/RUN-999/run.db").exists()


def test_transition_missing_does_not_create_database(tmp_path):
    """transition for a nonexistent run must fail without creating a DB."""
    result = runner.invoke(
        app,
        ["transition", "RUN-999", "DONE", "--expected", "INTAKE", "--repo-root", str(tmp_path)],
    )
    assert result.exit_code != 0
    assert not (tmp_path / "coordination/autobuild/RUN-999/run.db").exists()


# ---------------------------------------------------------------------------
# R5: validate-model is real YAML/schema validation, not an existence probe.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("kind", "yaml_text"),
    [
        ("trace", "nodes: []\nedges: []\n"),
        ("readiness", "items: []\nred_team_findings: []\n"),
        ("decision-log", "run_id: RUN-001\nentries: []\n"),
        (
            "contract",
            "contract_version: '1.0'\n"
            "tier1:\n"
            "  product_scope: demo\n"
            "  authority: {}\n"
            "  money: {}\n"
            "  definition_of_done: demo done\n",
        ),
        (
            "prototype",
            "title: demo\n"
            "artifact_ref: https://demo.invalid\n"
            "interactive: true\n"
            "screens: []\n"
            "interactions: []\n",
        ),
    ],
)
def test_validate_model_valid_kind(tmp_path, kind, yaml_text):
    path = tmp_path / "artifact.yaml"
    path.write_text(yaml_text, encoding="utf-8")
    result = runner.invoke(app, ["validate-model", kind, str(path)])
    assert result.exit_code == 0, result.stderr
    assert json.loads(result.stdout) == {
        "valid": True,
        "kind": kind,
        "path": str(path),
    }


def test_validate_model_rejects_invalid_model_yaml(tmp_path):
    """Schema violations fail nonzero instead of reporting valid=true."""
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
    result = runner.invoke(app, ["validate-model", "trace", str(path)])
    assert result.exit_code != 0
    assert '"valid": false' in result.stderr


def test_validate_model_rejects_unknown_kind(tmp_path):
    path = tmp_path / "artifact.yaml"
    path.write_text("nodes: []\n", encoding="utf-8")
    result = runner.invoke(app, ["validate-model", "bogus", str(path)])
    assert result.exit_code != 0
    assert "bogus" in result.stderr


def test_validate_model_rejects_malformed_yaml(tmp_path):
    path = tmp_path / "broken.yaml"
    path.write_text("{ this is not: [ valid\n", encoding="utf-8")
    result = runner.invoke(app, ["validate-model", "trace", str(path)])
    assert result.exit_code != 0


def test_validate_model_rejects_missing_file(tmp_path):
    result = runner.invoke(
        app, ["validate-model", "trace", str(tmp_path / "missing.yaml")]
    )
    assert result.exit_code != 0
