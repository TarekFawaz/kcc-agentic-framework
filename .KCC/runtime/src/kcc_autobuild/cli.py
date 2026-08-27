"""Typer CLI over the autobuild runtime.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_cli.py`
(see the KCC x Superpowers Hybrid Framework Plan 01, Task 4).

Output is deterministic: commands that print a model use
``json.dumps(model.model_dump(mode='json'), sort_keys=True)`` so the
machine-readable contract of the CLI output is stable. Invalid lifecycle
transitions raise, which Typer/Click reports as a non-zero exit code;
failures are never swallowed into exit 0.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import typer

from kcc_autobuild.models import LifecycleState, RunRecord
from kcc_autobuild.store import RunStore

app = typer.Typer(no_args_is_help=True)


def db_for(repo_root: Path, run_id: str) -> Path:
    """Return the ``run.db`` path for a run under a repository root."""
    return repo_root / "coordination" / "autobuild" / run_id / "run.db"


def deterministic_json(model: RunRecord) -> str:
    """Serialize a model deterministically (sorted keys, JSON-safe values)."""
    return json.dumps(model.model_dump(mode='json'), sort_keys=True)


@app.command("init-run")
def init_run(
    run_id: str,
    title: str,
    repo_root: Path = typer.Option(
        Path.cwd(), help="Repository root that holds coordination/"
    ),
) -> None:
    """Create an autobuild run in INTAKE and print its record as JSON."""
    store = RunStore(db_for(repo_root, run_id))
    try:
        record = RunRecord(
            run_id=run_id,
            title=title,
            created_at=datetime.now(timezone.utc),
        )
        store.create_run(record)
        typer.echo(deterministic_json(record))
    finally:
        store.close()


@app.command("show-run")
def show_run(
    run_id: str,
    repo_root: Path = typer.Option(
        Path.cwd(), help="Repository root that holds coordination/"
    ),
) -> None:
    """Load an existing run and print its record as deterministic JSON."""
    store = RunStore(db_for(repo_root, run_id))
    try:
        typer.echo(deterministic_json(store.load_run(run_id)))
    finally:
        store.close()


@app.command("transition")
def transition(
    run_id: str,
    target: LifecycleState,
    expected: LifecycleState = typer.Option(
        ..., help="Expected current state of the run"
    ),
    reason: str = typer.Option(
        "manual-controller-transition",
        help="Reason recorded with the transition",
    ),
    repo_root: Path = typer.Option(
        Path.cwd(), help="Repository root that holds coordination/"
    ),
) -> None:
    """Transition a run to target; non-zero exit if the transition is invalid."""
    store = RunStore(db_for(repo_root, run_id))
    try:
        store.transition(run_id, expected=expected, target=target, reason=reason)
        typer.echo(deterministic_json(store.load_run(run_id)))
    finally:
        store.close()


@app.command("validate-model")
def validate_model(kind: str, path: Path) -> None:
    """Report whether a model artifact exists, as deterministic JSON."""
    typer.echo(
        json.dumps(
            {"kind": kind, "path": str(path), "valid": path.exists()},
            sort_keys=True,
        )
    )
