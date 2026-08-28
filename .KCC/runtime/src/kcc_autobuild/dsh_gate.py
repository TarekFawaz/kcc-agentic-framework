"""KCC policy gate for DeepSeek Harness workers (Plan 08, Task 5).

The hardened ``dsh`` profile's Cordis plugin registers the exact
wrappers ``kcc_policy_exec`` / ``kcc_policy_write`` (and the read-only
``kcc_harness_status`` probe) and a monotonic gate that fails closed on
every tool outside the post-lock allowlist.  The wrappers never decide
anything themselves: they derive the workspace from the calling session
and hand the *untrusted operation request* to the local Python policy
gate invoked over stdin -- the internal CLI commands
``kcc-autobuild gate-write`` / ``kcc-autobuild gate-exec``.

This module is that Python policy gate:

* **Fail-closed exact tool allowlist** (:func:`tool_allowed`): native
  ``read`` / ``read_image`` / ``glob`` / ``grep`` / ``todo_write`` plus
  the exact KCC wrappers ``kcc_policy_exec`` / ``kcc_policy_write`` /
  ``kcc_harness_status``.  Raw ``bash`` / ``pwsh`` / ``terminal`` /
  ``write`` / ``edit`` / ``str_replace`` / ``job_kill`` /
  ``web_search`` / ``web_fetch`` / ``create_goal`` / ``update_goal`` /
  ``subagent*`` / ``workflow`` / ``ralph`` / ``run_code`` /
  ``cordis_*`` / ``mcp__*`` and every unknown name DENY.  There is
  deliberately no controller or resume wrapper: KCC owns controller,
  status and resume.
* **Canonical path confinement** (:func:`confine_path`): the write
  target must be a relative path under the session cwd (the gate's
  process cwd -- the request carries no caller cwd); absolute paths,
  sibling/``..`` escapes, symlink escapes and escaping glob patterns
  are rejected before any policy decision or write.
* **Pipeline** (:class:`DshToolGate`): reload the durable run, reject a
  stale or wrongly-bound lease, verify the signed policy bundle, then
  let :class:`~kcc_autobuild.tool_gate.PolicyToolGate` mint/audit a
  unique decision token and only then run the executor (confined file
  write / exact-argv subprocess).  No raw secrets ever appear on a CLI
  argument -- the signing secret is read from an owner-only file
  referenced by environment (default ``KCC_AUTOBUILD_POLICY_SECRET_FILE``).

The behavioral contract is owned by
:file:`.KCC/runtime/tests/test_tool_gate.py` (Plan 08, Task 5 section).
"""

from __future__ import annotations

import json
import os
import re
import secrets
import subprocess
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Literal, Mapping, Sequence

from pydantic import Field, ValidationError, field_validator, model_validator

from kcc_autobuild.leases import LeaseStore
from kcc_autobuild.models import StrictModel
from kcc_autobuild.policy import (
    POLICY_BUNDLE_FORMAT,
    InvalidPolicyBundle,
    InvalidSignature,
    Operation,
    PolicyBundle,
    PolicyDecision,
    PolicyEvaluator,
    PolicyRule,
    UnsignedPolicy,
    sign_policy_bundle,
)
from kcc_autobuild.store import RunStore
from kcc_autobuild.tool_gate import (
    AmbiguousPolicy,
    PolicyAudit,
    PolicyDenied,
    PolicyToolGate,
)

GATE_REQUEST_VERSION = 1
"""Version of the stdin gate request contract (rejected when newer)."""

DEFAULT_SECRET_ENV = "KCC_AUTOBUILD_POLICY_SECRET_FILE"
"""Environment variable naming the owner-only file that holds the HMAC secret."""

DEFAULT_BUNDLE_NAME = "policy-bundle.json"
"""Name of the signed policy bundle under the gate directory."""

DEFAULT_SECRET_NAME = ".gate-secret"
"""Name of the owner-only signing-secret file under the gate directory."""

DSH_NATIVE_ALLOWED_TOOLS = frozenset(
    {"read", "read_image", "glob", "grep", "todo_write"}
)
"""The DSH native read-only allowlist a post-lock worker uses directly."""

DSH_KCC_WRAPPERS = frozenset(
    {"kcc_policy_exec", "kcc_policy_write", "kcc_harness_status"}
)
"""The exact KCC wrappers a post-lock worker may use -- and nothing more.

No controller, resume or status wrapper exists: KCC owns controller,
status and resume.
"""

DSH_ALLOWED_TOOLS = DSH_NATIVE_ALLOWED_TOOLS | DSH_KCC_WRAPPERS
"""The exact post-lock tool allowlist (fail closed: everything else DENY)."""

DSH_DENIED_TOOLS = frozenset(
    {
        "bash",
        "pwsh",
        "terminal",
        "write",
        "edit",
        "str_replace",
        "str_replace_editor",
        "job_kill",
        "web_search",
        "web_fetch",
        "create_goal",
        "update_goal",
        "workflow",
        "ralph",
        "run_code",
    }
)
"""Raw mutation/orchestration tool names denied by the exact allowlist."""

DSH_DENIED_PREFIXES = ("subagent", "cordis_", "mcp__")
"""Name prefixes denied by the exact allowlist (``subagent*``, ``cordis_*``,
``mcp__*``)."""


def tool_allowed(name: str) -> bool:
    """Whether ``name`` is on the exact post-lock allowlist (fail closed).

    Any tool not named exactly -- raw mutation tools, subagent/cordis/mcp
    families and every unknown tool -- is denied; there is no implicit
    allowance.
    """
    return isinstance(name, str) and name in DSH_ALLOWED_TOOLS


class GatePathError(ValueError):
    """A governed write target escapes the canonical session-workspace path."""


_GLOB_METACHARS = re.compile(r"[*?\[\]{}]")
_WINDOWS_ABSOLUTE = re.compile(r"^[A-Za-z]:")


def confine_path(cwd: str | Path, target: str) -> Path:
    """Resolve ``target`` under the canonical ``cwd`` workspace, or raise.

    Fail-closed rules, in order:

    * ``target`` must be a non-blank string without NUL bytes;
    * absolute paths (POSIX, Windows drive or UNC) are rejected -- the
      caller never supplies the anchor, the process cwd is the anchor;
    * glob metacharacters are rejected (an escaping glob can never be
      smuggled through a governed write);
    * any ``..`` component is rejected (parent/sibling escape), even a
      non-escaping one;
    * the resolved target (symlinks followed) must stay inside the
      resolved cwd -- a symlink escape is rejected.

    The returned path is the canonical (fully resolved) absolute path.
    """
    if not isinstance(target, str) or not target.strip():
        raise GatePathError("write target must be a non-empty relative path")
    if "\x00" in target:
        raise GatePathError("write target must not contain NUL bytes")
    if target.startswith(("/", "\\")) or _WINDOWS_ABSOLUTE.match(target):
        raise GatePathError(
            f"absolute write target rejected (no caller-supplied cwd): {target!r}"
        )
    if _GLOB_METACHARS.search(target):
        raise GatePathError(
            f"escaped glob pattern rejected in a write target: {target!r}"
        )
    normalized = target.replace("\\", "/")
    parts = []
    for part in PurePosixPath(normalized).parts:
        if part == "..":
            raise GatePathError(
                f"parent/sibling escape rejected in write target: {target!r}"
            )
        if part in (".", ""):
            continue
        parts.append(part)
    if not parts:
        raise GatePathError(f"write target has no path components: {target!r}")
    anchor = Path(cwd).resolve()
    resolved = anchor.joinpath(*parts).resolve(strict=False)
    if resolved != anchor and not resolved.is_relative_to(anchor):
        raise GatePathError(
            f"write target escapes the session workspace via symlink: {target!r}"
        )
    return resolved


_COMMAND_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
_SHELL_METACHARS = re.compile(r"[\x00;|&`$<>(){}\[\]*?~#!]")


class GateOperation(StrictModel):
    """The untrusted operation request carried by a gate request.

    ``kind='write'`` requires ``path`` (confined under the session cwd)
    and ``content``; ``kind='exec'`` requires ``command`` (a plain
    program name -- never a path) and optional string ``args``.  ``args``
    entries with NUL or shell metacharacters are rejected: the executor
    always receives an exact argv list, never a shell string, so
    injection has no surface.
    """

    kind: Literal["write", "exec"]
    path: str | None = None
    content: str | None = None
    command: str | None = None
    args: list[str] = Field(default_factory=list)
    data_class: str = "PUBLIC"

    @field_validator("path", "content")
    @classmethod
    def _path_content_str(cls, value: str | None) -> str | None:
        if value is not None and not isinstance(value, str):
            raise TypeError("path/content must be strings")
        if value is not None and not value.strip():
            raise ValueError("path/content must be non-empty when set")
        return value

    @field_validator("command")
    @classmethod
    def _command_plain_name(cls, value: str | None) -> str | None:
        if value is None:
            return value
        if not isinstance(value, str):
            raise TypeError("command must be a string")
        if _COMMAND_NAME.fullmatch(value) is None:
            raise ValueError(
                "command must be a plain program name (no path, no shell "
                f"metacharacters): {value!r}"
            )
        return value

    @field_validator("data_class")
    @classmethod
    def _data_class_nonblank(cls, value: str) -> str:
        if not isinstance(value, str) or not value.strip():
            raise ValueError("data_class must be a non-empty string")
        return value

    @field_validator("args")
    @classmethod
    def _args_str_and_clean(cls, value: list[str]) -> list[str]:
        checked: list[str] = []
        for item in value:
            if not isinstance(item, str):
                raise TypeError("exec args must be strings")
            if _SHELL_METACHARS.search(item):
                raise ValueError(
                    "exec args must not carry shell metacharacters or NUL: "
                    f"{item!r}"
                )
            checked.append(item)
        return checked

    @model_validator(mode="after")
    def _kind_requires_its_fields(self) -> GateOperation:
        if self.kind == "write":
            if self.path is None or self.content is None:
                raise ValueError(
                    "write operations require path and content (exact argv "
                    "writes only; no glob)"
                )
        elif self.command is None:
            raise ValueError("exec operations require a plain command name")
        return self


class GateRequest(StrictModel):
    """One untrusted gate request: run/task/lease identity + operation.

    The request never carries the workspace (the wrapper derives it from
    the session and launches the gate there) nor any secret.  ``tool``
    names exactly the wrapper that produced the request; the internal CLI
    command pins it, so a ``kcc_policy_exec`` request can never ride the
    ``gate-write`` entry point.
    """

    version: int = GATE_REQUEST_VERSION
    run_id: str
    task_id: str
    lease_id: str
    generation: int = Field(ge=1)
    tool: Literal["kcc_policy_exec", "kcc_policy_write"]
    operation: GateOperation

    @field_validator("version")
    @classmethod
    def _version_supported(cls, value: int) -> int:
        if value != GATE_REQUEST_VERSION:
            raise ValueError(
                f"unsupported gate request version {value} "
                f"(expected {GATE_REQUEST_VERSION})"
            )
        return value

    @field_validator("run_id", "task_id", "lease_id")
    @classmethod
    def _identity_nonblank(cls, value: str) -> str:
        if not isinstance(value, str) or not value.strip():
            raise ValueError("run_id/task_id/lease_id must be non-empty strings")
        return value


class GateDecision(StrictModel):
    """Machine-readable outcome of one gate request.

    ``allowed`` is the single acceptance bit; ``token`` is the unique
    policy decision token when the signed policy was evaluated (present
    for DENIED/AMBIGUOUS too -- the gate audits every policy decision,
    never only the allowed ones), ``reason`` explains a denial and
    ``outcome`` carries the executor result on success.
    """

    allowed: bool
    tool: str
    token: str | None = None
    reason: str | None = None
    outcome: dict[str, Any] | None = None


class ShellResult:
    """Outcome of one governed subprocess invocation."""

    def __init__(
        self,
        *,
        returncode: int,
        stdout: str,
        stderr: str,
        error: str | None = None,
    ) -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        self.error = error


def _subprocess_runner(
    argv: Sequence[str],
    cwd: Path,
    env: Mapping[str, str],
    timeout_seconds: float,
) -> ShellResult:
    try:
        process = subprocess.run(
            list(argv),
            cwd=cwd,
            env=dict(env),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        return ShellResult(
            returncode=-1, stdout="", stderr="", error=f"timed out after {timeout_seconds}s"
        )
    except OSError as exc:
        return ShellResult(
            returncode=-1,
            stdout="",
            stderr="",
            error=f"cannot launch command: {type(exc).__name__}: {exc}",
        )
    return ShellResult(
        returncode=process.returncode,
        stdout=process.stdout,
        stderr=process.stderr,
    )


_SECRET_KEY_TOKENS = frozenset(
    {"SECRET", "TOKEN", "PASSWORD", "CREDENTIAL", "CREDENTIALS", "AUTH"}
)
_SECRET_KEY_BIGRAMS = frozenset(
    {"API_KEY", "ACCESS_KEY", "AUTH_TOKEN", "PRIVATE_KEY", "SESSION_KEY"}
)


def _looks_like_secret_key(key: str) -> bool:
    """Whether an environment variable name looks like a secret container.

    Token-aware (underscore/dash separated), so ``AWS_SECRET_ACCESS_KEY``
    and ``OPENROUTER_API_KEY`` are dropped while ``PATH``/``DSH_HOME``
    survive.
    """
    parts = [part for part in re.split(r"[_\-]+", key.upper()) if part]
    if any(part in _SECRET_KEY_TOKENS for part in parts):
        return True
    return any(
        "_".join(parts[index : index + 2]) in _SECRET_KEY_BIGRAMS
        for index in range(len(parts) - 1)
    )


def sanitized_env(env: Mapping[str, str] | None = None) -> dict[str, str]:
    """A child environment with every secret-looking variable dropped.

    Governed subprocesses never inherit API keys, tokens, passwords or
    credentials: they get PATH/HOME-style execution facts only (fail
    closed -- a variable whose name looks like a secret is removed, not
    masked).
    """
    source = os.environ if env is None else env
    return {
        key: value
        for key, value in source.items()
        if not _looks_like_secret_key(key)
    }


def gate_audit_path(repo_root: str | Path, run_id: str) -> Path:
    """The durable decision-audit jsonl of one run (under its run dir)."""
    return Path(repo_root) / "coordination" / "autobuild" / run_id / "gate-audit.jsonl"


def load_policy_bundle(path: str | Path) -> PolicyBundle:
    """Deserialize and reconstruct a signed :class:`PolicyBundle`."""
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise InvalidPolicyBundle("policy bundle document must be a JSON object")
    if data.get("format") != POLICY_BUNDLE_FORMAT:
        raise InvalidPolicyBundle(
            f"unsupported policy bundle format {data.get('format')!r}"
        )
    rules = tuple(
        PolicyRule(
            operation=rule["operation"],
            resource=rule["resource"],
            data_class=rule["data_class"],
            decision=PolicyDecision(rule["decision"]),
        )
        for rule in data.get("rules", [])
    )
    return PolicyBundle(
        format=data["format"],
        rules=rules,
        signature=data.get("signature"),
    )


def _bundle_document(bundle: PolicyBundle) -> dict[str, Any]:
    return {
        "format": bundle.format,
        "rules": [
            {
                "operation": rule.operation,
                "resource": rule.resource,
                "data_class": rule.data_class,
                "decision": rule.decision.value,
            }
            for rule in bundle.rules
        ],
        "signature": bundle.signature,
    }


def provision_gate_policy(
    out_dir: str | Path,
    rules: Sequence[PolicyRule] = (),
    *,
    secret: str | None = None,
    bundle_name: str = DEFAULT_BUNDLE_NAME,
    secret_name: str = DEFAULT_SECRET_NAME,
) -> tuple[Path, Path]:
    """Provision a signed policy bundle + owner-only secret for one gate.

    ``rules`` is the exact-match policy of the gate (default: an empty
    policy -- every operation DENIED until KCC signs the real policy, so
    a fresh install fails closed).  The secret is generated randomly when
    not provided and written mode 0600; the bundle is written alongside.
    Returns ``(bundle_path, secret_path)``.
    """
    directory = Path(out_dir)
    directory.mkdir(parents=True, exist_ok=True)
    actual_secret = secret if secret is not None else secrets.token_hex(32)
    bundle = sign_policy_bundle(rules, actual_secret)
    bundle_path = directory / bundle_name
    secret_path = directory / secret_name
    bundle_path.write_text(
        json.dumps(_bundle_document(bundle), sort_keys=True, indent=2)
        + "\n",
        encoding="utf-8",
    )
    secret_path.write_text(f"{actual_secret}\n", encoding="utf-8")
    secret_path.chmod(0o600)
    return bundle_path, secret_path


class DshToolGate:
    """The full KCC policy gate: run -> lease -> bundle -> gate -> executor.

    Every governed request crosses exactly this pipeline, in order:

    1. reload the durable run (``coordination/autobuild/<run>/run.db``);
    2. reject a stale/unknown/fenced lease and a lease not bound to the
       request's run/task/generation;
    3. verify the signed policy bundle (fail closed on missing secret,
       unsigned or tampered bundle);
    4. confine the write target (or validate the exec command);
    5. :class:`~kcc_autobuild.tool_gate.PolicyToolGate` evaluates the
       exact policy, mints a unique decision token, audits it (memory +
       ``gate-audit.jsonl``) and only then invokes the executor.

    The runner is injectable for deterministic tests; by default it runs
    the exact argv through ``subprocess.run`` with no shell and a
    secret-sanitized environment.  No raw secret ever appears on a CLI
    argument: the signing secret comes from ``secret`` (tests) or the
    owner-only file at ``secret_file`` (default:
    ``$KCC_AUTOBUILD_POLICY_SECRET_FILE``).
    """

    def __init__(
        self,
        *,
        repo_root: str | Path,
        bundle: PolicyBundle | None = None,
        bundle_path: str | Path | None = None,
        secret_file: str | Path | None = None,
        secret: str | bytes | None = None,
        runner: Callable[[Sequence[str], Path, Mapping[str, str]], ShellResult]
        | None = None,
        timeout_seconds: float = 600.0,
        now: datetime | None = None,
        token_factory: Callable[[], str] | None = None,
    ) -> None:
        self.repo_root = Path(repo_root)
        self._bundle = bundle
        self.bundle_path = (
            Path(bundle_path)
            if bundle_path is not None
            else self.repo_root
            / ".KCC"
            / "adapters"
            / "dsh"
            / "gate"
            / DEFAULT_BUNDLE_NAME
        )
        self.secret_file = self._resolve_secret_file(secret_file)
        self._secret = secret
        self._runner = runner
        self.timeout_seconds = timeout_seconds
        self._now = now
        self._token_factory = token_factory
        self.audits: list[PolicyAudit] = []

    @staticmethod
    def _resolve_secret_file(secret_file: str | Path | None) -> Path | None:
        if secret_file is not None:
            return Path(secret_file)
        configured = os.environ.get(DEFAULT_SECRET_ENV)
        return Path(configured) if configured else None

    @property
    def _now_utc(self) -> datetime:
        return self._now if self._now is not None else datetime.now(timezone.utc)

    def _denied(self, tool: str, reason: str, token: str | None = None) -> GateDecision:
        return GateDecision(allowed=False, tool=tool, token=token, reason=reason)

    def _load_evaluator(self) -> PolicyEvaluator:
        """Verify the signed bundle; fail closed on any trust failure."""
        bundle = self._bundle
        if bundle is None:
            if not self.bundle_path.is_file():
                raise UnsignedPolicy(
                    f"no signed policy bundle at {self.bundle_path}"
                )
            bundle = load_policy_bundle(self.bundle_path)
        secret = self._secret
        if secret is None:
            if self.secret_file is None or not self.secret_file.is_file():
                raise UnsignedPolicy(
                    "policy gate secret unavailable: no owner-only secret file "
                    "configured (KCC_AUTOBUILD_POLICY_SECRET_FILE)"
                )
            secret = self.secret_file.read_text(encoding="utf-8").strip()
        return PolicyEvaluator(bundle, secret)

    def _write_parts(
        self, request: GateRequest
    ) -> tuple[Operation, Callable[[Operation, str], dict[str, Any]]]:
        operation = request.operation
        if operation.kind != "write":
            raise GatePathError(
                "kcc_policy_write requires a write operation"
            )
        confined = confine_path(self.repo_root, operation.path or "")
        anchor = self.repo_root.resolve()
        resource = str(confined.relative_to(anchor))
        content = operation.content or ""

        def executor(operation_token: Operation, token: str) -> dict[str, Any]:
            before = confined.read_text(encoding="utf-8") if confined.is_file() else None
            confined.parent.mkdir(parents=True, exist_ok=True)
            confined.write_text(content, encoding="utf-8")
            return {
                "operation": "update" if before is not None else "create",
                "before": before,
                "after": content,
            }

        return (
            Operation("write", resource, operation.data_class),
            executor,
        )

    def _exec_parts(
        self, request: GateRequest
    ) -> tuple[Operation, Callable[[Operation, str], dict[str, Any]]]:
        operation = request.operation
        if operation.kind != "exec":
            raise GatePathError("kcc_policy_exec requires an exec operation")
        command = operation.command or ""
        argv = [command, *operation.args]
        env = sanitized_env()

        def executor(operation_token: Operation, token: str) -> dict[str, Any]:
            if self._runner is not None:
                result = self._runner(argv, self.repo_root, env)
            else:
                result = _subprocess_runner(
                    argv, self.repo_root, env, self.timeout_seconds
                )
            if result.error is not None:
                raise RuntimeError(
                    f"governed exec failed: {result.error}"
                )
            return {
                "command": command,
                "returncode": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            }

        return Operation("exec", command, operation.data_class), executor

    def _audit_sink(self, request: GateRequest):
        """The durable jsonl sink plus the in-memory trail."""
        path = gate_audit_path(self.repo_root, request.run_id)

        def record(audit: PolicyAudit) -> None:
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a", encoding="utf-8") as handle:
                    handle.write(
                        json.dumps(
                            {
                                "ts": self._now_utc.isoformat(),
                                "run_id": request.run_id,
                                "task_id": request.task_id,
                                "lease_id": request.lease_id,
                                "generation": request.generation,
                                "token": audit.token,
                                "decision": audit.decision.value,
                                "operation": audit.operation.operation,
                                "resource": audit.operation.resource,
                                "data_class": audit.operation.data_class,
                            },
                            sort_keys=True,
                        )
                        + "\n"
                    )
            except OSError:
                # The audit source of truth is the in-memory trail; a failure
                # to persist the line must not change the decision.
                pass

        class _Sink:
            def record(self, audit: PolicyAudit) -> None:  # noqa: N802
                record(audit)

        return _Sink()

    def handle(self, request: GateRequest) -> GateDecision:
        """Run one governed request through the full gate pipeline."""
        if not isinstance(request, GateRequest):
            raise TypeError(
                f"request must be a GateRequest, got {type(request).__name__}"
            )
        if (request.tool == "kcc_policy_write") != (
            request.operation.kind == "write"
        ):
            return self._denied(
                request.tool,
                "tool/operation mismatch: the request tool does not match "
                "the operation kind",
            )
        db_path = (
            self.repo_root
            / "coordination"
            / "autobuild"
            / request.run_id
            / "run.db"
        )
        if not db_path.is_file():
            return self._denied(
                request.tool,
                f"run not found: no durable run database at {db_path}",
            )
        store = RunStore(db_path)
        try:
            try:
                store.load_run(request.run_id)
            except KeyError:
                return self._denied(
                    request.tool, f"run not found: {request.run_id}"
                )
            leases = LeaseStore(store)
            if not leases.lease_is_live(
                request.lease_id, request.run_id, now=self._now_utc
            ):
                return self._denied(
                    request.tool,
                    "stale lease: the lease is unknown, fenced, expired or "
                    f"belongs to another run ({request.lease_id})",
                )
            current = leases.current_lease(request.task_id)
            if (
                current is None
                or current.lease_id != request.lease_id
                or current.generation != request.generation
            ):
                return self._denied(
                    request.tool,
                    "lease is not bound to this run/task/generation "
                    f"(current: {getattr(current, 'lease_id', None)})",
                )
            evaluator = self._load_evaluator()
            if request.tool == "kcc_policy_write":
                policy_operation, executor = self._write_parts(request)
            else:
                policy_operation, executor = self._exec_parts(request)
            gate = PolicyToolGate(
                evaluator,
                executor=executor,
                audit_sink=self._audit_sink(request),
                token_factory=self._token_factory,
            )
            try:
                outcome = gate.execute(policy_operation)
            except PolicyDenied as exc:
                self.audits.extend(gate.audits)
                return self._denied(request.tool, str(exc), token=exc.token)
            except AmbiguousPolicy as exc:
                self.audits.extend(gate.audits)
                return self._denied(request.tool, str(exc), token=exc.token)
            self.audits.extend(gate.audits)
            return GateDecision(
                allowed=True,
                tool=request.tool,
                token=gate.audits[-1].token,
                outcome=outcome,
            )
        except (UnsignedPolicy, InvalidSignature, InvalidPolicyBundle) as exc:
            return self._denied(
                request.tool, f"unverified signed policy bundle: {exc}"
            )
        except GatePathError as exc:
            return self._denied(
                request.tool, f"path confinement rejected the operation: {exc}"
            )
        except ValidationError as exc:
            return self._denied(
                request.tool,
                "invalid gate request: "
                + "; ".join(sorted(str(error["msg"]) for error in exc.errors())),
            )
        finally:
            store.close()
