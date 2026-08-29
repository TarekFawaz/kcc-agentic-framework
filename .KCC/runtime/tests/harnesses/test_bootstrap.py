"""Plan 07, Task 5 -- adapter compatibility + bootstrap optional runtime.

Contract (authoritative local source:
``.superpowers/bootstrap/plans/2026-08-27-07-evaluation-rollout.task-contracts.md``,
``### Task 5`` and its ``## Global Constraints``):

* ``framework-init`` never installs anything silently. Autobuild is an
  OPT-IN runtime: ``framework-init --enable-autobuild`` checks the
  interpreter is Python 3.11+ and PRINTS the runtime install command
  only (never executes it); a missing or old interpreter is reported
  and is never fatal.
* Existing KCC continues when Autobuild is not enabled: plain
  ``framework-init`` performs the ordinary harness sync, exits 0, does
  not run the interpreter check and never attempts an install.
* Conformance requires the autobuild runtime plus the generated adapter
  ``autobuild`` and ``autobuild-task-execute`` outputs and the legacy
  ``auto`` skill on every generated surface (``.codex``, ``.claude``,
  ``.agents``, ``.opencode``, ``.dsh``).
* Conformance secret-scans the durable state dirs ``coordination/``,
  ``Traces/`` and ``memory/`` for plaintext secret material.

The shell stack is the primary coverage (this runner is POSIX); the
PowerShell mirrors carry the identical rules and are exercised whenever
``pwsh`` is available.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[4]

SH_TOOLS = (
    "framework-init.sh",
    "sync-adapters.sh",
    "check-run-conformance.sh",
)
PS_TOOLS = (
    "framework-init.ps1",
    "sync-adapters.ps1",
    "check-run-conformance.ps1",
)

PWSH = shutil.which("pwsh")

# Content markers proving the outputs are the real autobuild capabilities,
# not stubs, and that the legacy auto skill kept its HOTL semantics.
AUTOBUILD_MARKER = "Run the approved autobuild discovery workflow"
TASK_EXECUTE_MARKER = "Execute one bounded autobuild task"
LEGACY_AUTO_MARKER = "Human-On-The-Loop"

SURFACES = ("codex", "claude", "agents", "opencode", "dsh")

REQUIRED_SKILLS = ("autobuild", "autobuild-task-execute", "auto")

SECRET_SAMPLE = "sk-ABCDEF0123456789abcdef"


def _chmod_x(path: Path) -> None:
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


@pytest.fixture()
def shims(tmp_path) -> dict[str, object]:
    """Fake ``python3``/``pip`` executables on a prepended PATH.

    ``python3`` answers ONLY a ``-c`` version probe (printing
    ``$FAKE_PYVERSION``) and fails any other invocation, so a test fails
    loudly if the bootstrap ever probes the interpreter differently.
    ``pip``/``pip3`` record every invocation into the marker file and
    exit 99, proving no silent install can happen: any install attempt
    fails the test.
    """
    fakebin = tmp_path / "fakebin"
    fakebin.mkdir()

    py = fakebin / "python3"
    py.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = "-c" ]; then\n'
        '  printf "%s\\n" "$FAKE_PYVERSION"\n'
        "  exit 0\n"
        "fi\n"
        'echo "unexpected python3 invocation: $*" >&2\n'
        "exit 99\n"
    )
    _chmod_x(py)

    for pip_name in ("pip", "pip3"):
        pip = fakebin / pip_name
        pip.write_text(
            "#!/bin/sh\n"
            'echo "$*" >> "$PIP_MARKER"\n'
            "exit 99\n"
        )
        _chmod_x(pip)

    marker = tmp_path / "pip-invoked.txt"
    env = {
        "PATH": f"{fakebin}:{os.environ.get('PATH', '')}",
        "FAKE_PYVERSION": "3.10.12",
        "PIP_MARKER": str(marker),
    }
    return {
        "fakebin": fakebin,
        "marker": marker,
        "env": env,
        "pip_called": lambda: marker.exists(),
    }


@pytest.fixture()
def cell(tmp_path) -> Path:
    """A minimal greenfield KCC cell: kernel, capabilities, tools, runtime.

    Enough of the real tree to run the real sync/conformance/init scripts
    deterministically without the canvas or the toolchain.
    """
    cell = tmp_path / "cell"
    tools = cell / ".KCC" / "tools"
    tools.mkdir(parents=True)

    for name in SH_TOOLS + PS_TOOLS:
        shutil.copy2(REPO_ROOT / ".KCC" / "tools" / name, tools / name)

    shutil.copytree(
        REPO_ROOT / ".KCC" / "kernel" / "templates",
        cell / ".KCC" / "kernel" / "templates",
    )
    shutil.copytree(
        REPO_ROOT / ".KCC" / "capabilities",
        cell / ".KCC" / "capabilities",
    )
    shutil.copytree(
        REPO_ROOT / ".KCC" / "runtime" / "src",
        cell / ".KCC" / "runtime" / "src",
    )
    shutil.copy2(
        REPO_ROOT / ".KCC" / "runtime" / "pyproject.toml",
        cell / ".KCC" / "runtime" / "pyproject.toml",
    )
    return cell


def run(cell: Path, tool: str, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    return subprocess.run(
        ["bash", str(cell / ".KCC" / "tools" / tool), *args],
        cwd=cell,
        env=full_env,
        capture_output=True,
        text=True,
        timeout=180,
    )


def run_ps(cell: Path, tool: str, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    return subprocess.run(
        [PWSH, "-NoProfile", "-File", str(cell / ".KCC" / "tools" / tool), *args],
        cwd=cell,
        env=full_env,
        capture_output=True,
        text=True,
        timeout=180,
    )


# ---------------------------------------------------------------------------
# framework-init: optional autobuild runtime, print install command only
# ---------------------------------------------------------------------------


def test_plain_init_continues_without_autobuild(cell: Path, shims) -> None:
    """Existing KCC init succeeds when Autobuild is not enabled.

    No interpreter check, no python/pip invocation, no silent install,
    and the ordinary adapter surface is still generated.
    """
    r = run(cell, "framework-init.sh", "claude", "--repo-root", str(cell), env=shims["env"])
    assert r.returncode == 0, r.stderr
    assert r.stdout, "init printed nothing"
    assert "Autobuild runtime not enabled" in r.stdout
    assert "[autobuild]" not in r.stdout, "runtime check ran although Autobuild is not enabled"
    assert "pip install -e" not in r.stdout
    assert not shims["pip_called"]()
    assert (cell / ".claude" / "skills" / "auto" / "SKILL.md").is_file()
    assert (cell / ".claude" / "skills" / "autobuild" / "SKILL.md").is_file()


def test_enable_autobuild_python_old_prints_requirement_and_command_only(cell: Path, shims) -> None:
    """Python below 3.11: requirement + install command are PRINTED, never run."""
    r = run(
        cell,
        "framework-init.sh",
        "claude",
        "--enable-autobuild",
        "--repo-root",
        str(cell),
        env=shims["env"],
    )
    assert r.returncode == 0, r.stderr
    assert "3.10.12" in r.stdout
    assert "Autobuild runtime requires Python 3.11+" in r.stdout
    assert "pip install -e" in r.stdout
    assert ".KCC/runtime" in r.stdout
    assert not shims["pip_called"](), "framework-init must never install silently"
    assert (cell / ".claude" / "skills" / "autobuild" / "SKILL.md").is_file()


def test_enable_autobuild_python_311_ready_prints_command_only(cell: Path, shims) -> None:
    """Python 3.11+: runtime ready, install command still only printed."""
    shims["env"] = {**shims["env"], "FAKE_PYVERSION": "3.11.9"}
    r = run(
        cell,
        "framework-init.sh",
        "claude",
        "--enable-autobuild",
        "--repo-root",
        str(cell),
        env=shims["env"],
    )
    assert r.returncode == 0, r.stderr
    assert "3.11.9" in r.stdout
    assert "Autobuild runtime ready" in r.stdout
    assert "pip install -e" in r.stdout
    assert not shims["pip_called"]()


def test_enable_autobuild_missing_python_continues(cell: Path) -> None:
    """No interpreter at all: reported, command printed, init still exits 0."""
    env = dict(os.environ)
    env["KCC_AUTOBUILD_PYTHON"] = "definitely-not-a-python-binary"
    r = run(cell, "framework-init.sh", "claude", "--enable-autobuild", "--repo-root", str(cell), env=env)
    assert r.returncode == 0, r.stderr
    assert "Autobuild runtime requires Python 3.11+" in r.stdout
    assert "pip install -e" in r.stdout
    assert (cell / ".claude" / "skills" / "auto" / "SKILL.md").is_file()


@pytest.mark.skipif(PWSH is None, reason="pwsh not available")
def test_plain_init_ps1_continues_without_autobuild(cell: Path, shims) -> None:
    r = run_ps(
        cell,
        "framework-init.ps1",
        "-Harness",
        "claude",
        "-RepoRoot",
        str(cell),
        env=shims["env"],
    )
    assert r.returncode == 0, r.stderr
    assert "Autobuild runtime not enabled" in r.stdout
    assert "pip install -e" not in r.stdout
    assert not shims["pip_called"]()
    assert (cell / ".claude" / "skills" / "auto" / "SKILL.md").is_file()


@pytest.mark.skipif(PWSH is None, reason="pwsh not available")
def test_enable_autobuild_ps1_prints_command_only(cell: Path, shims) -> None:
    r = run_ps(
        cell,
        "framework-init.ps1",
        "-Harness",
        "claude",
        "-RepoRoot",
        str(cell),
        "-EnableAutobuild",
        env=shims["env"],
    )
    assert r.returncode == 0, r.stderr
    assert "Autobuild runtime requires Python 3.11+" in r.stdout
    assert "pip install -e" in r.stdout
    assert not shims["pip_called"]()


@pytest.mark.skipif(PWSH is None, reason="pwsh not available")
def test_enable_autobuild_ps1_python_311_ready(cell: Path, shims) -> None:
    shims["env"] = {**shims["env"], "FAKE_PYVERSION": "3.11.9"}
    r = run_ps(
        cell,
        "framework-init.ps1",
        "-Harness",
        "claude",
        "-RepoRoot",
        str(cell),
        "-EnableAutobuild",
        env=shims["env"],
    )
    assert r.returncode == 0, r.stderr
    assert "Autobuild runtime ready" in r.stdout
    assert "pip install -e" in r.stdout
    assert not shims["pip_called"]()


# ---------------------------------------------------------------------------
# Conformance: runtime + autobuild/autobuild-task-execute/legacy auto outputs
# on every generated surface, after adapter sync
# ---------------------------------------------------------------------------


def test_sync_all_generates_autobuild_outputs_across_all_five_surfaces(cell: Path, shims) -> None:
    """After adapter sync every generated surface carries the autobuild outputs
    and legacy auto remains (the verified adapter-compatibility contract)."""
    r = run(cell, "sync-adapters.sh", "all", "--repo-root", str(cell), env=shims["env"])
    assert r.returncode == 0, r.stderr
    for surface in SURFACES:
        for skill in REQUIRED_SKILLS:
            assert (cell / f".{surface}" / "skills" / skill / "SKILL.md").is_file(), (
                f".{surface}/skills/{skill}/SKILL.md missing after sync"
            )
    for surface in SURFACES:
        auto_text = (cell / f".{surface}" / "skills" / "auto" / "SKILL.md").read_text(encoding="utf-8")
        assert LEGACY_AUTO_MARKER in auto_text, f"legacy auto semantics lost on .{surface}"
        assert AUTOBUILD_MARKER in (
            cell / f".{surface}" / "skills" / "autobuild" / "SKILL.md"
        ).read_text(encoding="utf-8")
        assert TASK_EXECUTE_MARKER in (
            cell / f".{surface}" / "skills" / "autobuild-task-execute" / "SKILL.md"
        ).read_text(encoding="utf-8")


def test_conformance_autobuild_scope_passes_after_sync_all(cell: Path, shims) -> None:
    run(cell, "sync-adapters.sh", "all", "--repo-root", str(cell), env=shims["env"])
    r = run(cell, "check-run-conformance.sh", "--repo-root", str(cell), "--scope", "autobuild", env=shims["env"])
    assert r.returncode == 0, f"stdout:\n{r.stdout}\nstderr:\n{r.stderr}"
    assert "Conformance check passed" in r.stdout


def test_conformance_autobuild_fails_when_output_deleted(cell: Path, shims) -> None:
    run(cell, "sync-adapters.sh", "all", "--repo-root", str(cell), env=shims["env"])
    shutil.rmtree(cell / ".dsh" / "skills" / "autobuild-task-execute")
    shutil.rmtree(cell / ".opencode" / "skills" / "auto")
    r = run(cell, "check-run-conformance.sh", "--repo-root", str(cell), "--scope", "autobuild", env=shims["env"])
    assert r.returncode == 1
    assert "AUTOBUILD-003" in r.stdout, r.stdout
    assert "AUTOBUILD-004" in r.stdout, r.stdout
    assert ".dsh" in r.stdout and ".opencode" in r.stdout


def test_conformance_autobuild_fails_when_runtime_missing(cell: Path, shims) -> None:
    run(cell, "sync-adapters.sh", "all", "--repo-root", str(cell), env=shims["env"])
    shutil.rmtree(cell / ".KCC" / "runtime" / "src" / "kcc_autobuild")
    r = run(cell, "check-run-conformance.sh", "--repo-root", str(cell), "--scope", "autobuild", env=shims["env"])
    assert r.returncode == 1
    assert "AUTOBUILD-001" in r.stdout, r.stdout


def test_conformance_autobuild_skips_without_surfaces(cell: Path, shims) -> None:
    """A cell that never generated a surface has nothing autobuild to judge."""
    r = run(cell, "check-run-conformance.sh", "--repo-root", str(cell), "--scope", "autobuild", env=shims["env"])
    assert r.returncode == 0, f"stdout:\n{r.stdout}\nstderr:\n{r.stderr}"
    assert "No violations" in r.stdout


@pytest.mark.skipif(PWSH is None, reason="pwsh not available")
def test_conformance_autobuild_scope_ps1_matches_shell(cell: Path, shims) -> None:
    run(cell, "sync-adapters.sh", "all", "--repo-root", str(cell), env=shims["env"])
    r = run_ps(cell, "check-run-conformance.ps1", "-RepoRoot", str(cell), "-Scope", "autobuild")
    assert r.returncode == 0, f"stdout:\n{r.stdout}\nstderr:\n{r.stderr}"
    shutil.rmtree(cell / ".codex" / "skills" / "autobuild")
    r = run_ps(cell, "check-run-conformance.ps1", "-RepoRoot", str(cell), "-Scope", "autobuild")
    assert r.returncode == 1
    assert "AUTOBUILD-002" in r.stdout, r.stdout


# ---------------------------------------------------------------------------
# Conformance: secret scan of durable coordination/, Traces/ and memory/
# ---------------------------------------------------------------------------

DURABLE_DIRS = ("coordination", "Traces", "memory")


def _seed_durable_dir(cell: Path, name: str, secret: bool) -> None:
    d = cell / name
    d.mkdir(exist_ok=True)
    (d / "notes.md").write_text(
        "Durable state is fine: env://TOKEN, vault://secret, "
        + (f"plus {SECRET_SAMPLE} leak" if secret else "no raw material."),
        encoding="utf-8",
    )


def test_conformance_secret_scan_clean_durable_dirs_passes(cell: Path, shims) -> None:
    for name in DURABLE_DIRS:
        _seed_durable_dir(cell, name, secret=False)
    r = run(cell, "check-run-conformance.sh", "--repo-root", str(cell), "--scope", "secrets", env=shims["env"])
    assert r.returncode == 0, f"stdout:\n{r.stdout}\nstderr:\n{r.stderr}"
    assert "No violations" in r.stdout


@pytest.mark.parametrize("name", DURABLE_DIRS)
def test_conformance_secret_scan_finds_plaintext_secret(cell: Path, shims, name: str) -> None:
    _seed_durable_dir(cell, name, secret=True)
    r = run(cell, "check-run-conformance.sh", "--repo-root", str(cell), "--scope", "secrets", env=shims["env"])
    assert r.returncode == 1
    assert "SECRET-001" in r.stdout, r.stdout
    assert name in r.stdout
    assert SECRET_SAMPLE in r.stdout


def test_conformance_secret_scan_ignores_secret_refs(cell: Path, shims) -> None:
    """Secret REFERENCES (vault://, env://) are not findings -- only raw material."""
    _seed_durable_dir(cell, "coordination", secret=False)
    (cell / "coordination" / "refs.md").write_text(
        "token: vault://secrets/provider/v1\napi key: env://PROVIDER_API_KEY\n",
        encoding="utf-8",
    )
    r = run(cell, "check-run-conformance.sh", "--repo-root", str(cell), "--scope", "secrets", env=shims["env"])
    assert r.returncode == 0, f"stdout:\n{r.stdout}\nstderr:\n{r.stderr}"


@pytest.mark.skipif(PWSH is None, reason="pwsh not available")
def test_conformance_secret_scan_ps1_matches_shell(cell: Path, shims) -> None:
    _seed_durable_dir(cell, "memory", secret=False)
    r = run_ps(cell, "check-run-conformance.ps1", "-RepoRoot", str(cell), "-Scope", "secrets")
    assert r.returncode == 0, f"stdout:\n{r.stdout}\nstderr:\n{r.stderr}"
    _seed_durable_dir(cell, "Traces", secret=True)
    r = run_ps(cell, "check-run-conformance.ps1", "-RepoRoot", str(cell), "-Scope", "secrets")
    assert r.returncode == 1
    assert "SECRET-001" in r.stdout
