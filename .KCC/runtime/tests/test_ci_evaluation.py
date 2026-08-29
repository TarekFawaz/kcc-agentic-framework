"""CI + final acceptance contract (Plan 07, Task 7) -- tests.

Written first (strict TDD red phase) against the external behavior
contract of Task 7 of :file:`.superpowers/bootstrap/plans/
2026-08-27-07-evaluation-rollout.task-contracts.md` (KCC x Superpowers
Hybrid Framework)::

    CI + final acceptance.  Create or update
    ``.github/workflows/autobuild-evaluation.yml`` with three jobs:
    Python3.11/3.12 runtime+harness tests; Canvas npm
    test/build/E2E-appropriate coverage; Windows adapters/conformance.
    Local acceptance ... Expected: all runtime green; exactly30
    evaluation scenarios, no skip/xfail; harness parity pass; Canvas
    pass; generated adapters preserve autobuild + legacy auto + native
    DSH skills.  Generic CI MUST NOT pretend live DSH exists; R3
    additionally consumes fresh Plan08 real DSH smoke evidence.

Binding semantics under test:

* The workflow exists with EXACTLY the three contract jobs
  (``runtime-tests``, ``canvas-tests``, ``windows-conformance``) and a
  parseable YAML document.
* The runtime job covers **Python 3.11 AND 3.12** (matrix) and runs
  BOTH suites the contract names -- ``.KCC/runtime/tests`` (the
  evaluation suite: exactly 30 scenarios, no skip/xfail) and
  ``.KCC/runtime/tests/harnesses`` (harness parity, adapter
  bootstrap/conformance, fake-DSH smoke gate).
* The canvas job runs ``npm test -- --run`` (vitest unit/component
  suite), ``npm run build`` (tsc + vite) and the fixture-backed
  Playwright E2E AFTER the build (the deterministic fixture server
  serves ``dist/`` -- E2E-appropriate coverage with no external
  service).
* The Windows job runs on ``windows-latest`` and exercises the
  PowerShell adapter mirrors -- ``sync-adapters.ps1`` across all
  surfaces and ``check-run-conformance.ps1`` for the ``autobuild`` and
  ``secrets`` scopes -- with ``pwsh``, plus the harness suite (whose
  ``skipif(PWSH is None)`` tests RUN on Windows).
* **Rollout honesty:** generic CI never pretends live DSH exists -- no
  executed step invokes a live DSH smoke (``--live``,
  ``harness smoke dsh``) and no CI step writes the Plan08 evidence
  file (``coordination/autobuild/evaluations/dsh-smoke.json``).  R3
  consumes FRESH Plan08 real DSH smoke evidence at gate time through
  the runtime metrics (Plan 07, Task 4), never through a CI claim.
* CI never softens the acceptance: no ``continue-on-error: true``, no
  deselection/skip of runtime cases (``--deselect``, ``--ignore``,
  ``-k``/``-x`` deselectors), so a red suite can only fail the job.
"""

from __future__ import annotations

from pathlib import Path

import yaml

from kcc_autobuild.cli import app  # noqa: F401  (runtime must stay importable)

REPO_ROOT = Path(__file__).resolve().parents[3]

WORKFLOW = REPO_ROOT / ".github" / "workflows" / "autobuild-evaluation.yml"

REQUIRED_JOBS = ("runtime-tests", "canvas-tests", "windows-conformance")

# Executed-command text only (run/uses/strategy) -- comments may document
# the Plan08 evidence boundary, but CI must never EXECUTE a live-DSH claim.
FORBIDDEN_EXEC_TOKENS = (
    "--live",            # live DSH smoke probes
    "harness smoke dsh",  # DSH smoke subcommand
    "dsh-smoke.json",     # Plan08 evidence file (written by real DSH runs)
    "--deselect",         # no skipping runtime cases
    "--ignore",           # no skipping test paths
)


def _workflow() -> dict:
    assert WORKFLOW.exists(), f"missing CI workflow: {WORKFLOW.relative_to(REPO_ROOT)}"
    text = WORKFLOW.read_text(encoding="utf-8")
    doc = yaml.safe_load(text)
    assert isinstance(doc, dict), "workflow YAML must be a mapping"
    return doc


def _jobs() -> dict:
    return _workflow()["jobs"]


def _runs(job: dict) -> list[str]:
    """Executed ``run`` command texts of a job (defaults excluded)."""
    return [str(s.get("run", "")) for s in job.get("steps", []) if isinstance(s.get("run"), str)]


def _uses(job: dict) -> list[str]:
    return [str(s.get("uses", "")) for s in job.get("steps", []) if isinstance(s.get("uses"), str)]


def _exec_text(job: dict) -> str:
    parts = _runs(job) + _uses(job)
    parts.append(yaml.safe_dump(job.get("strategy", {})))
    return "\n".join(parts)


def test_workflow_exists_with_exactly_the_three_contract_jobs() -> None:
    """The three jobs named by the contract are present and no others."""
    jobs = _jobs()
    assert set(jobs) == set(REQUIRED_JOBS), f"unexpected job set: {sorted(jobs)}"
    for job_id in REQUIRED_JOBS:
        assert isinstance(jobs[job_id], dict), f"job {job_id} must be a mapping"
        assert "steps" in jobs[job_id], f"job {job_id} has no steps"


def test_runtime_job_matrix_covers_python_311_and_312() -> None:
    runtime = _jobs()["runtime-tests"]
    matrix = runtime["strategy"]["matrix"]
    assert matrix["python-version"] == ["3.11", "3.12"], "runtime matrix must cover 3.11 and 3.12"


def test_runtime_job_runs_runtime_and_harness_suites() -> None:
    """The runtime job executes both pytest suites plus a runtime install."""
    runs = "\n".join(_runs(_jobs()["runtime-tests"]))
    assert "pip install" in runs and ".KCC/runtime" in runs, "editable install of the runtime required"
    assert "pytest .KCC/runtime/tests -q" in runs, "runtime suite (.KCC/runtime/tests) must run"
    assert "pytest .KCC/runtime/tests/harnesses -q" in runs, "harness suite must run"
    assert "python -m pytest" in runs


def test_canvas_job_runs_unit_tests_build_then_e2e() -> None:
    """Canvas: vitest, build, and the fixture-backed E2E AFTER the build
    (the deterministic fixture server serves ``dist/``)."""
    canvas = _jobs()["canvas-tests"]
    runs = _runs(canvas)
    assert any("npm test" in r and "--run" in r for r in runs), "vitest unit suite required"
    build = next(i for i, r in enumerate(runs) if "npm run build" in r)
    assert "npm ci" in "\n".join(runs), "locked dependency install required"
    e2e = next(i for i, r in enumerate(runs) if "test:e2e" in r)
    assert build < e2e, "E2E must run after the production build (fixture server serves dist/)"
    assert any("playwright install" in r for r in runs), "Playwright browser install required for E2E"


def test_windows_job_runs_powershell_adapters_and_conformance() -> None:
    """Windows: pwsh executes the PowerShell adapter sync and both
    conformance scopes, plus the harness suite (PS1 mirrors included)."""
    win = _jobs()["windows-conformance"]
    assert win["runs-on"] == "windows-latest", "Windows job must run on windows-latest"
    runs = "\n".join(_runs(win))
    assert "pytest .KCC/runtime/tests/harnesses" in runs, "harness suite must run on Windows"
    assert "sync-adapters.ps1" in runs, "PowerShell adapter sync required"
    assert "check-run-conformance.ps1" in runs, "PowerShell conformance required"
    assert "-Scope autobuild" in runs, "adapter-compatibility conformance scope required"
    assert "-Scope secrets" in runs, "durable-state secret scan scope required"
    assert "pwsh" in runs or "powershell" in runs.lower(), "PowerShell shell required on Windows"


def test_ci_never_pretends_live_dsh_exists() -> None:
    """Rollout honesty (global constraint): no executed CI step invokes a
    live DSH smoke or fabricates Plan08 smoke evidence; R3 consumes the
    FRESH Plan08 real records at gate time (runtime metrics), never a CI
    claim."""
    for job in _jobs().values():
        text = _exec_text(job)
        for token in FORBIDDEN_EXEC_TOKENS:
            assert token not in text, f"job step executes forbidden token: {token!r}"
    text = WORKFLOW.read_text(encoding="utf-8")
    assert "R3" in text and "Plan 08" in text, "workflow must document the Plan08 R3 evidence boundary"
    assert "live DSH" in text, "workflow must state CI never pretends live DSH exists"


def test_ci_never_softens_the_acceptance() -> None:
    """No continue-on-error, no deselection, no xfail wiring: a red suite
    can only fail the job, so 'exactly30 evaluation scenarios, no
    skip/xfail' stays enforced by the pipeline itself."""
    for job in _jobs().values():
        for step in job.get("steps", []):
            assert not step.get("continue-on-error", False), "CI must not tolerate failing steps"
    runs = "\n".join(" ".join(_runs(j)) for j in _jobs().values())
    for token in ("--deselect", "--ignore", " -k ", "-x "):
        assert token not in runs, f"CI must not deselect/skip cases: {token!r}"
