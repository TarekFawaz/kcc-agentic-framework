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
