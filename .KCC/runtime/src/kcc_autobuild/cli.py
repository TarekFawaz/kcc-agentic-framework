"""Typer CLI over the autobuild runtime.

Behavioral contract owned by :file:`.KCC/runtime/tests/test_cli.py`
(see the KCC x Superpowers Hybrid Framework Plan 01, Task 4, and
Plan 02, Task 5 for the real ``validate-model`` schema validation).

Output is deterministic: commands that print a model use
``json.dumps(model.model_dump(mode='json'), sort_keys=True)`` so the
machine-readable contract of the CLI output is stable. ``validate-model``
is real YAML/schema validation (Plan-02 ruling R5): model kinds map to
the actual Pydantic models and invalid input exits non-zero — failures
are never swallowed into exit 0.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path

import typer
import yaml
from pydantic import ValidationError

from kcc_autobuild.contract import BuildContract
from kcc_autobuild.decision_log import DecisionLog
from kcc_autobuild.models import RUN_ID_PATTERN, LifecycleState, RunRecord
from kcc_autobuild.prototype import Prototype
from kcc_autobuild.readiness import ReadinessPack
from kcc_autobuild.store import RunStore
from kcc_autobuild.trace import TraceGraph

app = typer.Typer(no_args_is_help=True)

MODEL_KINDS: dict[str, type] = {
    "trace": TraceGraph,
    "readiness": ReadinessPack,
    "contract": BuildContract,
    "decision-log": DecisionLog,
    "prototype": Prototype,
}
"""Map the ``validate-model`` kind strings to the real Pydantic models.

The five kinds are the approved autobuild artifact kinds (Plan-02 ruling
R5): trace matrix, readiness evidence pack, build contract, decision log
and clickable prototype manifest.
"""


def db_for(repo_root: Path, run_id: str) -> Path:
    """Return the ``run.db`` path for a run under a repository root."""
    return repo_root / "coordination" / "autobuild" / run_id / "run.db"


def validate_run_id(run_id: str) -> None:
    """Reject run ids that do not match the canonical identity pattern.

    Runs before any RunStore/db_for use so an invalid identity can never
    create a coordination directory or database.
    """
    if re.fullmatch(RUN_ID_PATTERN, run_id) is None:
        raise typer.BadParameter(
            f"invalid run_id {run_id!r}; must match {RUN_ID_PATTERN}"
        )


def require_existing_run_db(db_path: Path, run_id: str) -> None:
    """Fail if the run database does not exist (never create-on-read)."""
    if not db_path.exists():
        typer.echo(
            f"error: run {run_id!r} not found (no database at {db_path})",
            err=True,
        )
        raise typer.Exit(code=1)


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
    validate_run_id(run_id)
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
    validate_run_id(run_id)
    run_db = db_for(repo_root, run_id)
    require_existing_run_db(run_db, run_id)
    store = RunStore(run_db)
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
    validate_run_id(run_id)
    run_db = db_for(repo_root, run_id)
    require_existing_run_db(run_db, run_id)
    store = RunStore(run_db)
    try:
        store.transition(run_id, expected=expected, target=target, reason=reason)
        typer.echo(deterministic_json(store.load_run(run_id)))
    finally:
        store.close()


@app.command("validate-model")
def validate_model(kind: str, path: Path) -> None:
    """Validate a YAML artifact against the real autobuild model schema.

    Kinds: trace, readiness, contract, decision-log, prototype.  Exits 0
    with deterministic JSON when the artifact is valid; exits non-zero
    with a deterministic JSON error document on stderr for an unknown
    kind, a missing file, malformed YAML or a model schema violation
    (Plan-02 ruling R5 — this is real validation, not an existence
    probe, so LOCK validation is meaningful).
    """
    model_cls = MODEL_KINDS.get(kind)
    if model_cls is None:
        _validate_model_error(
            kind, path, [f"unknown model kind '{kind}'"]
        )
    if not path.exists():
        _validate_model_error(kind, path, ["file not found"])
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
    except (yaml.YAMLError, OSError) as exc:
        _validate_model_error(kind, path, [str(exc)])
    try:
        model_cls.model_validate(data)
    except ValidationError as exc:
        errors = sorted(str(error["msg"]) for error in exc.errors())
        _validate_model_error(kind, path, errors)
    typer.echo(
        json.dumps(
            {"kind": kind, "path": str(path), "valid": True},
            sort_keys=True,
        )
    )


def _validate_model_error(kind: str, path: Path, errors: list[str]) -> None:
    """Report an invalid artifact deterministically and exit non-zero."""
    typer.echo(
        json.dumps(
            {
                "kind": kind,
                "path": str(path),
                "valid": False,
                "errors": list(errors),
            },
            sort_keys=True,
        ),
        err=True,
    )
    raise typer.Exit(code=1)
