"""Real DeepSeek Harness (dsh) smoke/evidence gate (Plan 08, Task 7) -- tests.

Written first (strict TDD red phase) against the external behavior
contract of Task 7 of :file:`.superpowers/bootstrap/plans/
2026-08-27-08-harness-capability-deepseek-adapter.task-contracts.md`
(KCC x Superpowers Hybrid Framework)::

    Real DSH smoke/evidence gate.  Add HarnessSmokeEvidence fields
    harness_id/runs_requested/runs_passed/status_probe_passed/
    authorized_mutation_passed/unauthorized_mutation_denied/
    human_prompts/secret_findings/evidence_refs; `passed` requires all
    runs, status, authorized mutation, denied direct mutation, zero
    prompts/secrets.  CLI `kcc-autobuild harness smoke dsh --fixture ...
    --runs 3`; disposable copies; each run: read/code/test no mutation;
    bounded mutation through KCC wrappers under disposable allow policy;
    deliberate built-in write/bash attempt must be guard-denied without
    prompt.  Every worker emits valid ExecutionReport.  Secret scan
    durable artifacts.  Write coordination/autobuild/evaluations/
    dsh-smoke.json; exit 0 only passed; no rollout promotion itself.
    Docs Plan07 R3 consumes fresh live DSH smoke + parity.

Binding semantics under test:

* :class:`HarnessSmokeEvidence` is fail-closed by construction: every
  requirement flag defaults false and ``passed`` is derived -- it
  requires ALL runs passed, the status probe, the authorized bounded
  mutation, the denied direct (raw write/bash) mutation and zero human
  prompts / zero secret findings.
* The smoke runner builds one DISPOSABLE hardened profile (temporary
  DSH_HOME templated from the installed profile; ``node_modules``
  symlinked; the gate wiring re-rendered to disposable paths and a
  bounded disposable allow policy provisioned) plus one DISPOSABLE
  workspace holding a private copy of the fixture (``AGENTS.md`` +
  ``input/``) -- the fixture itself is never mutated.
* Each run dispatches one fresh worker under the disposable profile who
  must: read/code/test with no raw mutation, write the two expected
  files through the KCC wrapped mutation under the disposable allow
  policy (exact write targets + the ``python`` exec), deliberately
  attempt the built-in write and bash tools (both must be denied -- the
  raw marker files must never appear), call ``kcc_harness_status`` and
  answer with exactly one ``KCC_DSH_STATUS:`` line, and emit a fresh
  valid identity-bound ExecutionReport at the run's report path (the
  completion contract -- exit 0 without one fails the run).
* Durable artifacts (reports, outputs, status lines, the disposable
  allow policy) are copied into
  ``coordination/autobuild/evaluations/dsh-smoke/runs/run-<n>/`` and
  secret-scanned: any ``sk-...`` plaintext secret finding fails the
  evaluation, and prompt-like markers found in any durable text fail it
  too (zero human prompts).
* The CLI writes ``coordination/autobuild/evaluations/dsh-smoke.json``
  (the evidence document, ``passed`` included), exits 0 ONLY when the
  smoke passed, and never promotes any rollout itself.
"""

from __future__ import annotations

import json
import stat
from datetime import datetime, timezone
from pathlib import Path

import pytest
from pydantic import ValidationError
from typer.testing import CliRunner

from kcc_autobuild.cli import app

STATUS_JSON = (
    '{"sandbox":"workspace-write","approval":"never","guard":"kcc-policy-gate"}'
)
STATUS_LINE = f"KCC_DSH_STATUS: {STATUS_JSON}"

SMOKE_REFS = [
    "smoke://harness-status-probe",
    "smoke://authorized-mutation/kcc-policy-write",
    "smoke://authorized-mutation/kcc-policy-exec",
    "smoke://unauthorized-mutation-denied/raw-write",
    "smoke://unauthorized-mutation-denied/raw-bash",
]

REPORT_YAML_TEMPLATE = """\
run_id: {run_id}
task_id: {task_id}
attempt: {attempt}
status: passed
lease_id: {lease_id}
workspace_id: {workspace_id}
acceptance_evidence:
  - acceptance_id: AC-001
    test_ids: [T-001]
    evidence_refs:
{cited_refs}
failure: null
usage:
  tokens: 0
  cost_usd: 0.0
  provider_calls: 0
outputs: []
deviations: {deviations}
trace_updates: []
"""

GOOD_OUTPUTS = {
    "out/solution.py": (
        "def load_values(path):\n"
        "    with open(path, encoding='utf-8') as handle:\n"
        "        return [int(line.strip()) for line in handle if line.strip()]\n"
        "\n"
        "def total(path):\n"
        "    return sum(load_values(path))\n"
    ),
    "out/test_solution.py": (
        "import sys\n"
        "import unittest\n"
        "\n"
        "sys.path.insert(0, 'out')\n"
        "import solution\n"
        "\n"
        "with open('out/.exec-proof.txt', 'w', encoding='utf-8') as marker:\n"
        "    marker.write('kcc smoke governed exec proof\\n')\n"
        "\n"
        "\n"
        "class SmokeSolutionTest(unittest.TestCase):\n"
        "    def test_fixture_values(self):\n"
        "        values = solution.load_values('input/data.txt')\n"
        "        self.assertEqual(values, [1, 2, 3, 4, 5])\n"
        "        self.assertEqual(solution.total('input/data.txt'), 15)\n"
        "\n"
        "\n"
        "if __name__ == '__main__':\n"
        "    unittest.main()\n"
    ),
}

DEFAULT_FIXTURE_FILES = {
    "AGENTS.md": "# Disposable DSH harness smoke fixture\n",
    "input/data.txt": "1\n2\n3\n4\n5\n",
}

runner = CliRunner()


# ---------------------------------------------------------------------------
# Fixture helpers: smoke fixture, installed template profile, fake dsh.
# ---------------------------------------------------------------------------


def _fixture(tmp_path: Path, files: dict[str, str] | None = None) -> Path:
    fixture = tmp_path / "smoke-fixture"
    for rel, text in (files or DEFAULT_FIXTURE_FILES).items():
        target = fixture / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    return fixture


def _dsh_home(root: Path, *, template: bool = True) -> Path:
    home = root / "dsh-home"
    if template:
        profile = home / "profiles" / "kcc-autobuild"
        (profile / "node_modules").mkdir(parents=True)
        (profile / "package.json").write_text(
            json.dumps(
                {
                    "name": "dsh-profile-kcc-autobuild",
                    "private": True,
                    "dependencies": {
                        "kcc-dsh-policy-gate": f"link:{root}/plugin"
                    },
                    "dsh": {
                        "profile": {
                            "bundles": [
                                "@deepseek-ai/dsh-base",
                                "@deepseek-ai/dsh-headless",
                                "kcc-dsh-policy-gate",
                            ]
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        (profile / "cordis.yml").write_text("[]\n", encoding="utf-8")
        (profile / "cordis.patch.yml").write_text("[]\n", encoding="utf-8")
        (profile / "pnpm-lock.yaml").write_text(
            "lockfileVersion: '9'\n", encoding="utf-8"
        )
        (profile / "pnpm-workspace.yaml").write_text(
            "packages:\n  - .\n", encoding="utf-8"
        )
    return home


def _fake_smoke_dsh(
    root: Path,
    *,
    name: str = "dsh",
    exit_code: int = 0,
    boot_exit_code: int = 0,
    boot_stdout: str = "dsh launcher help\n",
    stdout: str = STATUS_LINE,
    stderr: str = "",
    write_artifacts: bool = True,
    missing_artifact: str | None = None,
    raw_markers: bool = False,
    exec_proof: bool = True,
    write_report: bool = True,
    drop_refs: tuple[str, ...] = (),
    extra_refs: tuple[str, ...] = (),
    deviations: str | None = None,
    extra_report_lines: str = "",
    attempt_override: str | None = None,
    fail_attempt: int | None = None,
    capture: bool = False,
) -> Path:
    """An executable fake dsh that simulates one smoke worker.

    ``--help`` invocations are the runner's feature probe; worker
    invocations parse the machine-readable ``SMOKE_*`` identity lines of
    the prompt, write the expected artifacts (and optionally the raw
    marker files -- a fake with ``raw_markers=True`` simulates a guard
    that FAILED to deny), and emit the ExecutionReport YAML at the
    ``SMOKE_REPORT_PATH`` extracted from the prompt.
    """
    refs = list(SMOKE_REFS)
    for dropped in drop_refs:
        refs.remove(dropped)
    for extra in extra_refs:
        refs.append(extra)
    cited = "\n".join(
        f"      - {ref}"
        for ref in refs + ["out/solution.py", "out/test_solution.py"]
    )
    if deviations is not None:
        deviations_yaml = f"\n    - {deviations}"
    else:
        deviations_yaml = "[]"
    report_body = REPORT_YAML_TEMPLATE.format(
        run_id="${run_id}",
        task_id="${task_id}",
        attempt="${attempt}" if attempt_override is None else attempt_override,
        lease_id="${lease_id}",
        workspace_id="${workspace_id}",
        cited_refs=cited,
        deviations=deviations_yaml,
    )
    if extra_report_lines:
        report_body += extra_report_lines
    script = [
        "#!/bin/sh",
        'case " $* " in',
        '  *" --help "*)',
        f'    printf "%s\\n" "{boot_stdout}"',
        f"    exit {boot_exit_code}",
        "    ;;",
        "esac",
        "prompt=\"$*\"",
        "report_path=$(printf '%s' \"$prompt\" | \\",
        "  grep -o 'coordination/autobuild/RUN-SMOKE/execution-report-[0-9][0-9]*\\.yaml' | head -1)",
        "run_id=$(printf '%s' \"$prompt\" | sed -n 's/.*SMOKE_RUN: \\([^ ]*\\)/\\1/p' | head -1)",
        "task_id=$(printf '%s' \"$prompt\" | sed -n 's/.*SMOKE_TASK: \\([^ ]*\\)/\\1/p' | head -1)",
        "attempt=$(printf '%s' \"$prompt\" | sed -n 's/.*SMOKE_ATTEMPT: \\([^ ]*\\)/\\1/p' | head -1)",
        "lease_id=$(printf '%s' \"$prompt\" | sed -n 's/.*SMOKE_LEASE: \\([^ ]*\\)/\\1/p' | head -1)",
        "workspace_id=$(printf '%s' \"$prompt\" | sed -n 's/.*SMOKE_WORKSPACE: \\([^ ]*\\)/\\1/p' | head -1)",
        'mkdir -p "$(dirname "$report_path")" out',
    ]
    if capture:
        script.append('printf "%s\\n" "$@" > "$(dirname "$0")/argv.txt"')
        script.append('pwd > "$(dirname "$0")/cwd.txt"')
    for rel, text in GOOD_OUTPUTS.items():
        rel = rel.split("/")[-1]
        if missing_artifact is not None and rel == missing_artifact:
            continue
        script.append(f"cat > out/{rel} <<'KCC_OUT_EOF'")
        script.extend(text.splitlines())
        script.append("KCC_OUT_EOF")
    if raw_markers:
        script.append("printf 'raw write leaked\\n' > out/.raw-write-marker.txt")
        script.append("printf 'raw bash leaked\\n' > out/.raw-bash-marker.txt")
    if exec_proof:
        script.append(
            "printf 'kcc smoke governed exec proof\\n' > out/.exec-proof.txt"
        )
    if write_report:
        # UNQUOTED delimiter: the report body carries ${run_id}-style
        # placeholders that must be expanded by the shell.
        script.append(
            f"cat > \"$report_path\" <<KCC_REPORT_EOF\n"
            f"{report_body.rstrip(chr(10))}\n"
            "KCC_REPORT_EOF"
        )
    if fail_attempt is not None:
        script.append(f'if [ "$attempt" = "{fail_attempt}" ]; then')
        script.append('  printf "%s\\n" "no status line here"')
        script.append("  exit 0")
        script.append("fi")
    if stderr:
        script.append("cat >&2 <<'KCC_STDERR_EOF'")
        script.append(stderr)
        script.append("KCC_STDERR_EOF")
    if stdout:
        script.append(f"cat <<'KCC_STDOUT_EOF'\n{stdout}\nKCC_STDOUT_EOF")
    script.append(f"exit {exit_code}")
    bin_path = root / "bin" / name
    bin_path.parent.mkdir(parents=True)
    bin_path.write_text("\n".join(script) + "\n", encoding="utf-8")
    bin_path.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
    return bin_path


def _repo_root(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir(parents=True)
    return repo


# ---------------------------------------------------------------------------
# HarnessSmokeEvidence model: fail-closed passed semantics.
# ---------------------------------------------------------------------------


class TestHarnessSmokeEvidence:
    """The ``passed`` gate: all runs, status, authorized mutation, denied
    direct mutation, zero prompts, zero secrets."""

    def _evidence(self, **overrides):
        from kcc_autobuild.harnesses.models import HarnessSmokeEvidence

        kwargs = {
            "harness_id": "dsh",
            "runs_requested": 3,
            "runs_passed": 3,
            "status_probe_passed": True,
            "authorized_mutation_passed": True,
            "unauthorized_mutation_denied": True,
            "human_prompts": 0,
            "secret_findings": 0,
            "evidence_refs": ["coordination/autobuild/evaluations/dsh-smoke.json"],
            "ran_at": datetime(2026, 8, 28, 12, 0, 0, tzinfo=timezone.utc),
        }
        kwargs.update(overrides)
        return HarnessSmokeEvidence(**kwargs)

    def test_defaults_are_fail_closed(self) -> None:
        evidence = self._evidence(
            runs_requested=3,
            runs_passed=0,
            status_probe_passed=False,
            authorized_mutation_passed=False,
            unauthorized_mutation_denied=False,
        )
        assert evidence.status_probe_passed is False
        assert evidence.authorized_mutation_passed is False
        assert evidence.unauthorized_mutation_denied is False
        assert evidence.human_prompts == 0
        assert evidence.secret_findings == 0
        assert evidence.passed is False

    def test_passed_requires_every_run_to_pass(self) -> None:
        assert self._evidence(runs_passed=2).passed is False

    def test_passed_requires_status_probe(self) -> None:
        assert self._evidence(status_probe_passed=False).passed is False

    def test_passed_requires_authorized_mutation(self) -> None:
        assert self._evidence(authorized_mutation_passed=False).passed is False

    def test_passed_requires_denied_direct_mutation(self) -> None:
        assert self._evidence(unauthorized_mutation_denied=False).passed is False

    def test_passed_requires_zero_human_prompts(self) -> None:
        assert self._evidence(human_prompts=1).passed is False

    def test_passed_requires_zero_secret_findings(self) -> None:
        assert self._evidence(secret_findings=1).passed is False

    def test_passed_when_every_requirement_holds(self) -> None:
        assert self._evidence().passed is True

    def test_runs_requested_must_be_positive(self) -> None:
        with pytest.raises(ValidationError):
            self._evidence(runs_requested=0, runs_passed=0)

    def test_runs_passed_cannot_exceed_runs_requested(self) -> None:
        with pytest.raises(ValidationError):
            self._evidence(runs_requested=3, runs_passed=4)

    def test_harness_id_must_not_be_blank(self) -> None:
        with pytest.raises(ValidationError):
            self._evidence(harness_id="  ")

    def test_evidence_refs_must_not_be_blank(self) -> None:
        with pytest.raises(ValidationError):
            self._evidence(evidence_refs=["  "])

    def test_ran_at_must_be_timezone_aware(self) -> None:
        with pytest.raises(ValidationError):
            self._evidence(ran_at=datetime(2026, 8, 28, 12, 0, 0))

    def test_serialized_document_carries_the_passed_verdict(self) -> None:
        from kcc_autobuild.harnesses.dsh import smoke_evidence_document

        document = smoke_evidence_document(self._evidence())
        assert document["passed"] is True
        assert document["runs_requested"] == 3
        assert document["runs_passed"] == 3


# ---------------------------------------------------------------------------
# dsh_smoke runner: disposable copies + per-run completion contract.
# ---------------------------------------------------------------------------


class TestDshSmokeRunner:
    def test_smoke_all_runs_pass_and_write_durable_evaluation_artifacts(
        self, tmp_path
    ) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        repo = _repo_root(tmp_path)
        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=3,
            dsh_bin=str(_fake_smoke_dsh(tmp_path)),
            dsh_home=_dsh_home(tmp_path),
            repo_root=repo,
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.harness_id == "dsh"
        assert evidence.runs_requested == 3
        assert evidence.runs_passed == 3
        assert evidence.status_probe_passed is True
        assert evidence.authorized_mutation_passed is True
        assert evidence.unauthorized_mutation_denied is True
        assert evidence.human_prompts == 0
        assert evidence.secret_findings == 0
        assert evidence.passed is True
        assert evidence.ran_at.tzinfo is not None

        # Durable evaluation pack under coordination/autobuild/evaluations.
        evaluation_dir = repo / "coordination/autobuild/evaluations/dsh-smoke"
        for run in (1, 2, 3):
            run_dir = evaluation_dir / f"runs/run-{run}"
            assert (run_dir / f"execution-report-{run}.yaml").is_file()
            assert (run_dir / "out/solution.py").is_file()
            assert (run_dir / "out/test_solution.py").is_file()
            assert (run_dir / "worker-stdout.txt").read_text().strip() == STATUS_LINE
            assert (run_dir / "out/.exec-proof.txt").is_file()
            assert (run_dir / "allow-policy.json").is_file()
        assert evidence.evidence_refs[0] == (
            "coordination/autobuild/evaluations/dsh-smoke.json"
        )
        assert any(
            ref == "coordination/autobuild/evaluations/dsh-smoke/runs/run-1/"
            "execution-report-1.yaml"
            for ref in evidence.evidence_refs
        )

    def test_smoke_copies_the_fixture_and_never_mutates_it(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        repo = _repo_root(tmp_path)
        fixture = _fixture(tmp_path)
        before = {
            rel: (fixture / rel).read_text(encoding="utf-8")
            for rel in ("AGENTS.md", "input/data.txt")
        }
        evidence = dsh_smoke(
            fixture=fixture,
            runs=1,
            dsh_bin=str(_fake_smoke_dsh(tmp_path)),
            dsh_home=_dsh_home(tmp_path),
            repo_root=repo,
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.passed is True
        assert not (fixture / "out").exists()
        after = {
            rel: (fixture / rel).read_text(encoding="utf-8")
            for rel in ("AGENTS.md", "input/data.txt")
        }
        assert before == after

    def test_smoke_dispatches_each_worker_under_the_disposable_profile(
        self, tmp_path
    ) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        repo = _repo_root(tmp_path)
        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=2,
            dsh_bin=str(_fake_smoke_dsh(tmp_path, capture=True)),
            dsh_home=_dsh_home(tmp_path),
            repo_root=repo,
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.passed is True
        argv = (tmp_path / "bin" / "argv.txt").read_text(encoding="utf-8")
        assert "--profile" in argv
        assert "kcc-autobuild" in argv
        assert "SMOKE_REPORT_PATH: coordination/autobuild/RUN-SMOKE/" in argv
        assert "SMOKE_RUN: RUN-SMOKE" in argv
        cwd = (tmp_path / "bin" / "cwd.txt").read_text(encoding="utf-8").strip()
        assert cwd.endswith("/workspace")

    def test_smoke_runs_fail_closed_without_a_status_line(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=3,
            dsh_bin=str(_fake_smoke_dsh(tmp_path, stdout="no status line here")),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.status_probe_passed is False
        assert evidence.passed is False

    def test_smoke_run_accepts_a_summary_before_the_status_line(
        self, tmp_path
    ) -> None:
        # A real worker summarizes its phases before the single
        # KCC_DSH_STATUS line: the report file is the contract and the
        # summary itself is prompt/secret-scanned, so it must not fail.
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(
                _fake_smoke_dsh(
                    tmp_path, stdout=f"All phases complete.\n{STATUS_LINE}"
                )
            ),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 1
        assert evidence.status_probe_passed is True
        assert evidence.passed is True

    def test_smoke_run_fails_on_duplicate_status_lines(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(
                _fake_smoke_dsh(tmp_path, stdout=f"{STATUS_LINE}\n{STATUS_LINE}")
            ),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.status_probe_passed is False

    def test_smoke_run_fails_on_any_stderr_output(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(_fake_smoke_dsh(tmp_path, stderr="boot notice")),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.status_probe_passed is False

    def test_smoke_run_fails_on_nonzero_exit(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(_fake_smoke_dsh(tmp_path, exit_code=7)),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.passed is False

    def test_smoke_run_requires_a_fresh_valid_execution_report(self, tmp_path) -> None:
        # A stale report at the path must never satisfy the completion
        # contract: the runner resets the path and exit 0 without a NEW
        # valid report fails the run.
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(_fake_smoke_dsh(tmp_path, write_report=False)),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.passed is False

    def test_smoke_run_rejects_a_malformed_execution_report(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(_fake_smoke_dsh(tmp_path, extra_report_lines="bogus_field: 1\n")),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.status_probe_passed is True  # the probe itself passed
        assert evidence.passed is False

    def test_smoke_run_rejects_an_identity_mismatched_report(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        # The fake writes attempt 999 while the runner dispatched
        # generation 1: the report is not bound to THIS dispatch.
        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(_fake_smoke_dsh(tmp_path, attempt_override="999")),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.passed is False

    def test_smoke_missing_expected_artifact_fails_authorized_mutation(
        self, tmp_path
    ) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(
                _fake_smoke_dsh(tmp_path, missing_artifact="test_solution.py")
            ),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.authorized_mutation_passed is False
        assert evidence.passed is False

    def test_smoke_missing_exec_proof_fails_authorized_mutation(
        self, tmp_path
    ) -> None:
        # The governed verification run must actually execute: without
        # the exec-proof marker the authorized-mutation claim fails
        # even when both files and both refs are present.
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(_fake_smoke_dsh(tmp_path, exec_proof=False)),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.authorized_mutation_passed is False
        assert evidence.passed is False

    def test_smoke_raw_write_marker_present_fails_denied_flag(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(_fake_smoke_dsh(tmp_path, raw_markers=True)),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.unauthorized_mutation_denied is False
        assert evidence.passed is False

    def test_smoke_missing_denied_ref_fails_denied_flag_only(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(
                _fake_smoke_dsh(
                    tmp_path,
                    drop_refs=("smoke://unauthorized-mutation-denied/raw-bash",),
                )
            ),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.unauthorized_mutation_denied is False
        assert evidence.authorized_mutation_passed is True
        assert evidence.status_probe_passed is True

    def test_smoke_mixed_bad_run_counts_partial_success(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=3,
            dsh_bin=str(_fake_smoke_dsh(tmp_path, fail_attempt=2)),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 2
        assert evidence.status_probe_passed is False
        assert evidence.authorized_mutation_passed is True
        assert evidence.unauthorized_mutation_denied is True
        assert evidence.passed is False

    def test_smoke_secret_finding_scan_fails_the_evaluation(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(
                _fake_smoke_dsh(
                    tmp_path, deviations="sk-ABCDEFGHIJKLMNOPQRST leaked"
                )
            ),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.secret_findings >= 1
        assert evidence.passed is False

    def test_smoke_prompt_marker_finding_fails_the_evaluation(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(
                _fake_smoke_dsh(tmp_path, deviations="Do you approve (y/n)?")
            ),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=tmp_path / "smoke-tmp",
        )
        assert evidence.runs_passed == 0
        assert evidence.human_prompts >= 1
        assert evidence.passed is False

    def test_smoke_rejects_a_fixture_without_agents_md(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        fixture = tmp_path / "broken-fixture"
        (fixture / "input").mkdir(parents=True)
        with pytest.raises(ValueError, match="AGENTS.md"):
            dsh_smoke(
                fixture=fixture,
                runs=1,
                dsh_bin=str(_fake_smoke_dsh(tmp_path)),
                dsh_home=_dsh_home(tmp_path),
                repo_root=_repo_root(tmp_path),
            )

    def test_smoke_rejects_a_fixture_without_input(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        fixture = tmp_path / "broken-fixture"
        fixture.mkdir()
        (fixture / "AGENTS.md").write_text("# x\n", encoding="utf-8")
        with pytest.raises(ValueError, match="input"):
            dsh_smoke(
                fixture=fixture,
                runs=1,
                dsh_bin=str(_fake_smoke_dsh(tmp_path)),
                dsh_home=_dsh_home(tmp_path),
                repo_root=_repo_root(tmp_path),
            )

    def test_smoke_rejects_non_positive_run_counts(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        with pytest.raises(ValueError, match="runs"):
            dsh_smoke(
                fixture=_fixture(tmp_path),
                runs=0,
                dsh_bin=str(_fake_smoke_dsh(tmp_path)),
                dsh_home=_dsh_home(tmp_path),
                repo_root=_repo_root(tmp_path),
            )

    def test_smoke_gate_wiring_points_at_the_runtime_console_script(
        self, tmp_path
    ) -> None:
        # The disposable gate command must be the real console script of
        # THIS runtime, never a resolved /usr/bin path: the venv
        # interpreter is a symlink into the base install.
        import sys as _sys

        from kcc_autobuild.harnesses.dsh import _smoke_gate_command

        command = _smoke_gate_command()
        assert command.endswith("kcc-autobuild")
        assert Path(command) != Path("/usr/bin/kcc-autobuild")
        assert Path(command).exists()

    def test_smoke_disposable_allow_policy_is_bounded(self, tmp_path) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        repo = _repo_root(tmp_path)
        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=2,
            dsh_bin=str(_fake_smoke_dsh(tmp_path)),
            dsh_home=_dsh_home(tmp_path),
            repo_root=repo,
            temp_root=tmp_path / "smoke-tmp",
        )
        policy_path = (
            repo
            / "coordination/autobuild/evaluations/dsh-smoke/runs/run-1/"
            "allow-policy.json"
        )
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
        rules = {
            frozenset((rule["operation"], rule["resource"])): rule
            for rule in policy["rules"]
        }
        assert rules[frozenset(("exec", "python3"))]["decision"] == "ALLOWED"
        assert rules[frozenset(("write", "out/solution.py"))]["decision"] == "ALLOWED"
        assert rules[frozenset(("write", "out/test_solution.py"))]["decision"] == "ALLOWED"
        assert rules[
            frozenset(
                ("write", "coordination/autobuild/RUN-SMOKE/execution-report-1.yaml")
            )
        ]["decision"] == "ALLOWED"
        assert len(policy["rules"]) == 5  # 2 writes + 2 reports + 1 exec
        assert evidence.passed is True

    def test_smoke_cleans_up_the_disposable_profile_and_workspace(
        self, tmp_path
    ) -> None:
        from kcc_autobuild.harnesses.dsh import dsh_smoke

        temp_root = tmp_path / "smoke-tmp"
        evidence = dsh_smoke(
            fixture=_fixture(tmp_path),
            runs=1,
            dsh_bin=str(_fake_smoke_dsh(tmp_path)),
            dsh_home=_dsh_home(tmp_path),
            repo_root=_repo_root(tmp_path),
            temp_root=temp_root,
        )
        assert evidence.passed is True
        assert not temp_root.exists() or not any(temp_root.iterdir())


# ---------------------------------------------------------------------------
# CLI: kcc-autobuild harness smoke dsh.
# ---------------------------------------------------------------------------


class TestSmokeCli:
    def test_smoke_cli_exits_zero_only_when_passed_and_writes_evaluation(
        self, tmp_path
    ) -> None:
        repo = _repo_root(tmp_path)
        result = runner.invoke(
            app,
            [
                "harness",
                "smoke",
                "dsh",
                "--fixture",
                str(_fixture(tmp_path)),
                "--repo-root",
                str(repo),
                "--dsh-bin",
                str(_fake_smoke_dsh(tmp_path)),
                "--dsh-home",
                str(_dsh_home(tmp_path)),
                "--temp-root",
                str(tmp_path / "cli-tmp"),
            ],
        )
        assert result.exit_code == 0, result.stderr
        document = json.loads(result.stdout)
        assert document["harness_id"] == "dsh"
        assert document["runs_requested"] == 3
        assert document["runs_passed"] == 3
        assert document["status_probe_passed"] is True
        assert document["authorized_mutation_passed"] is True
        assert document["unauthorized_mutation_denied"] is True
        assert document["human_prompts"] == 0
        assert document["secret_findings"] == 0
        assert document["passed"] is True
        assert list(document.keys()) == sorted(document.keys())
        evaluation_file = (
            repo / "coordination/autobuild/evaluations/dsh-smoke.json"
        )
        assert evaluation_file.is_file()
        stored = json.loads(evaluation_file.read_text(encoding="utf-8"))
        assert stored["passed"] is True
        assert stored["runs_requested"] == 3

    def test_smoke_cli_exits_nonzero_when_the_smoke_fails(self, tmp_path) -> None:
        result = runner.invoke(
            app,
            [
                "harness",
                "smoke",
                "dsh",
                "--fixture",
                str(_fixture(tmp_path)),
                "--repo-root",
                str(_repo_root(tmp_path)),
                "--dsh-bin",
                str(_fake_smoke_dsh(tmp_path, stdout="no status line here")),
                "--dsh-home",
                str(_dsh_home(tmp_path)),
                "--temp-root",
                str(tmp_path / "cli-tmp"),
            ],
        )
        assert result.exit_code != 0
        document = json.loads(result.stdout)
        assert document["passed"] is False
        assert document["runs_passed"] == 0

    def test_smoke_cli_rejects_an_unknown_harness(self, tmp_path) -> None:
        result = runner.invoke(
            app,
            [
                "harness",
                "smoke",
                "codex",
                "--fixture",
                str(_fixture(tmp_path)),
                "--repo-root",
                str(_repo_root(tmp_path)),
            ],
        )
        assert result.exit_code != 0
        assert "codex" in result.stderr

    def test_smoke_cli_rejects_a_missing_fixture(self, tmp_path) -> None:
        result = runner.invoke(
            app,
            [
                "harness",
                "smoke",
                "dsh",
                "--fixture",
                str(tmp_path / "no-such-fixture"),
                "--repo-root",
                str(_repo_root(tmp_path)),
            ],
        )
        assert result.exit_code != 0
        assert "fixture" in result.stderr
