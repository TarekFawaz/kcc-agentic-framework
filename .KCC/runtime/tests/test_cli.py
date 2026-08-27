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
