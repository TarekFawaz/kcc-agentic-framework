# KCC Tools Reference

KCC tools live under `.KCC/tools/`. Root `tools/` wrappers may exist in local
cells for compatibility, but new documentation and automation should prefer the
canonical `.KCC/tools/` paths.

Most tools have both PowerShell and native bash forms:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\<tool>.ps1
```

```bash
bash .KCC/tools/<tool>.sh
```

Run the Mac/Linux bootstrap once after clone if you want executable `.sh`
files:

```bash
bash .KCC/tools/bootstrap-mac-linux.sh
```

## Tool Overview

| Tool | PowerShell | Bash | Purpose |
|---|---|---|---|
| framework-init | yes | yes | First-run initializer for a clean cell. |
| sync-adapters | yes | yes | Regenerate harness adapter outputs from `.KCC`. |
| validate-kcc | yes | yes | Validate framework structure and source health. |
| backchannel-append | yes | yes | Append one meta-agent event to `coordination/backchannel.jsonl`. |
| show-backchannel | yes | yes | Read the backchannel in a human-friendly format. |
| build-dashboard | yes | yes | Generate the offline dashboard. |
| start-agent-session | yes | yes | Start a visible or sandboxed harness session for an agent. |
| toolchain-preflight | yes | yes | Detect required build/test tools without installing them; probe the Docker registry and build network (`PROBE` / `LIMIT` lines). |
| adapt-workflow | yes | yes | Scaffold migration folders for external agentic workflows. |
| bootstrap-mac-linux | no | yes | Prepare bash tools on macOS/Linux. |
| memory-append | yes | no | Butler-owned deterministic memory writer. |
| kcc-inspect | yes | no | Basic Inspector detect/propose pipeline over real signals. |
| check-run-conformance | yes | yes | Check idea, spec, plan, review, and bug artifacts against the layout. |
| check-traceability | yes | yes | Acceptance criterion -> Test ID -> test -> PASS. |
| check-wave-scope | yes | yes | A wave's changes stay inside its declared files. |
| check-impl-lock | yes | yes | Source changes only with an approved plan and budget. |
| quality-gate | yes | yes | Build, lint, tests, coverage, secrets, dependencies, SAST, SBOM, image scans, in the scope the plan declares (`QG-SCOPE`). |
| repo-bootstrap | yes | yes | Git init/remote gate; installs the KCC git hooks. |
| check-commit-msg | yes | yes | Commit message convention. |
| check-branch | yes | yes | Branch naming and protected-branch push guard. |
| kcc-checkpoint | yes | yes | Write a restore point. |
| kcc-run | yes | yes | Deterministic lifecycle driver; under `--silent --assume` it answers every gate by policy and never pauses. |
| kcc-limit-watch | yes | yes | Detached resume after a usage limit. |
| kcc-limit-guard, kcc-statusline | yes | yes | Claude Code usage-limit hook and status line. The status line does not run in the VS Code extension. |
| kcc-limit-hook | yes | no | Claude Code `StopFailure` hook: records a usage limit, writes a restore point, arms the watcher. Runs under bash (Git Bash on Windows). |
| kcc-hint | yes | yes | Human hints for a running session: `add`, `list`, `clear`, `pending`; `inject` (bash) is the Claude Code hook. |
| kcc-handover | yes | yes | Move a run to another harness. |
| record-token-actuals | yes | yes | Record actual token use at session end. |

The `kcc` command line ([cli.md](./cli.md)) runs any of these with the right
shell for the system: `kcc tool <name> [--flag value ...]`. Flags are written
the bash way (`--repo-root`, `--dry-run`) and translated for PowerShell on
Windows. `kcc init`, `kcc sync`, `kcc validate`, and `kcc run` are shortcuts
for `framework-init`, `sync-adapters`, `validate-kcc`, and `kcc-run`.

## Gate, continuity, and git tools

These tools were added in release 0.5.0 and share one contract
(`.KCC/kernel/contracts/tool-contract.md`).

| | |
|---|---|
| Common arguments | `-RepoRoot` / `--repo-root`, `-Json` / `--json`, `-Spec` / `--spec`, `-Scope` / `--scope`, `-DryRun` / `--dry-run` (mutating tools) |
| Exit codes | 0 pass, 1 violations, 2 usage or environment error, 3 deferred (a required external tool is missing or exited without a result, or the item needs a human; never a pass) |
| JSON | `{ tool, version, scope, errors, warnings, status, violations: [{ id, severity, fix_owner, file, message }] }` |

| Tool | Tool-specific arguments | Notes |
|---|---|---|
| `check-run-conformance` | `-Scope all\|idea\|specs\|plan\|review\|bugs` | Exit check of the `auto` states. Legacy v5 specs produce `SPEC-LEGACY` warnings. |
| `check-traceability` | `-Spec` | Run by the verifier before a review verdict. |
| `check-wave-scope` | `-Spec`, `-Wave N`, `-Base <ref or manifest>`, `-TestCommand` | Compares against the newest restore point by default. Extra paths can be allowed in `plan.md -> ## Wave file allowances`. |
| `check-impl-lock` | `-Path <file>`, `-Staged`, `-Hook` | `-Hook` is the Claude Code `PreToolUse` mode (exit 2 blocks the edit). |
| `quality-gate` | `-Spec`, `-Path`, `-Scope`, `-Fast`, `-Require`, `-Emit` | Commands are detected per stack; override them in `settings.json -> quality.commands`. The scope of `-Spec` comes from the plan's `## Gates coverage` table and is printed in the first row, `QG-SCOPE`: checks the plan does not cover are out of scope, not failed; `-Scope` overrides, and a plan without the table means `all`. Rows are `pass`, `fail`, `deferred` or `skipped`, each with a `fix_owner` (`implementer`, `infrastructure-implementer`, `human`, `architect`); a scanner that exits without a result, a gate tool error or a built image older than the workspace (`QG-IMAGE`, with a rebuild hint) is `deferred`, never an implementer failure. `QG-DEPS` calls osv-scanner per lockfile (`-L`), falls back to the per-stack audit, counts production groups and names dev-only advisories, which gate only when `quality.audit_dev_dependencies` is true. `quality.scanners.sast` is `semgrep` or `opengrep` (the other stands in when the named one is missing); `quality.sast_rules` (default `auto`) names the rules, and opengrep needs `architecture/sast-rules/`. `-Fast` scans staged files for secrets. `-Require` turns a deferred scanner into a failure (CI). A repo `.gitleaks.toml` is honoured. Set `quality.scanners.sast_runner` to `docker` where the scanner has no native build. |
| `repo-bootstrap` | `-Apply init-local\|connect-remote\|skip`, `-RemoteUrl`, `-InstallHook` | Never stores credentials and never pushes. Installs `pre-commit`, `commit-msg`, and `pre-push`. |
| `check-commit-msg` | `-File <path>` or `-Message <text>` | See [git-workflow.md](./git-workflow.md). |
| `check-branch` | `-Branch <name>`, `-Push` | `-Push` is the `pre-push` mode. |
| `kcc-checkpoint` | `-Reason`, `-NextAction`, `-Harness`, `-SessionId`, `-NoGit` | Writes `coordination/checkpoints/CP-NNN.md` and, in a git repo, a `kcc/cp-NNN` tag. |
| `kcc-run` | `-Input`, `-Silent`, `-Assume`, `-Accuracy`, `-Budget`, `-Currency`, `-Parallel`, `-Fasttrack`, `-DepthLevel`, `-Harness`, `-Resume`, `-Answer`, `-From`, `-Until`, `-Only`, `-MaxAttempts`, `-Note`, `-DryRun`, `-Json` | Exit 4 paused at a gate, 5 suspended on a usage limit, 6 stopped, 7 done with `[open]` items in `coordination/NeedsAttention.md` (unattended runs only). Gates and answers: `waiver` (`waive`, `recheck`, `abort`; opened by a `WAIVER_NEEDED` review or by `REVIEW-004 (human)`), `ruling` (`revise`, `waive`, `escalate`, `abort`), `quality-deferred-on-exit-3` (`install`, `accept-deferred`, `abort`), `loop` (`revise`, `escalate`, `abort`), `toolchain` (`install`, `human-install`, `defer`). Under `-Silent -Assume` every gate is answered by policy and exit 4 never happens. A scoped TEST with nothing to verify emits `test-skipped` instead of running the verifier; PREFLIGHT `LIMIT` lines reach the TEST prompt as `KNOWN ENVIRONMENT LIMITS`. Protocol: `.KCC/kernel/protocols/kcc-run.md`; guide: [unattended-runs.md](./unattended-runs.md). |
| `kcc-limit-watch` | `-Arm`, `-Run`, `-Wrap`, `-ResetAt`, `-Command` | Use when the `kcc` binary is not installed; `kcc run` replaces it. |
| `kcc-handover` | `-To claude\|codex\|opencode\|generic`, `-From`, `-Launch`, `-Unattended` | Writes the envelope and prints the start command. |

Usage-limit wording per harness lives in `.KCC/kernel/limit-patterns.json`
and is read by `kcc-run`, `kcc-limit-watch`, and the `kcc` binary.

## framework-init

Initializes a clean folder that contains `.KCC/` into a usable KCC cell.

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 codex
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 -Harness claude
```

Bash:

```bash
bash .KCC/tools/framework-init.sh
bash .KCC/tools/framework-init.sh codex
bash .KCC/tools/framework-init.sh claude
```

Arguments:

| Argument | Values | Notes |
|---|---|---|
| `Harness` / `-Harness` | `claude`, `codex`, `opencode`, `generic`, `ollama`, `all` | Defaults to `all`. |
| `RepoRoot` / `--repo-root` | path | Optional repository root override. |

Use when:

- setting up a new cell
- creating missing root entrypoints
- creating initial local state folders
- generating harness outputs for the first time

## sync-adapters

Regenerates adapter output from `.KCC/kernel/` and `.KCC/capabilities/`.

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 codex
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 -Harness opencode
```

Bash:

```bash
bash .KCC/tools/sync-adapters.sh
bash .KCC/tools/sync-adapters.sh codex
bash .KCC/tools/sync-adapters.sh opencode
```

Arguments:

| Argument | Values | Notes |
|---|---|---|
| `Harness` / `-Harness` | `claude`, `codex`, `opencode`, `generic`, `ollama`, `all` | Defaults to `all`. |
| `RepoRoot` / `--repo-root` | path | Optional repository root override. |
| `-InstallCodexSkills` | switch | Accepted as explicit project-local intent; does not install global skills. |

Use after any edit under:

- `.KCC/kernel/`
- `.KCC/capabilities/agents/`
- `.KCC/capabilities/skills/`

## validate-kcc

Validates the framework structure, metadata, generated/runtime boundaries,
PowerShell parser health, stale references, and text corruption markers.

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\validate-kcc.ps1
powershell -ExecutionPolicy Bypass -File .KCC\tools\validate-kcc.ps1 -Mode repo
powershell -ExecutionPolicy Bypass -File .KCC\tools\validate-kcc.ps1 -RepoRoot E:\Work\MyCell
```

Bash:

```bash
bash .KCC/tools/validate-kcc.sh
bash .KCC/tools/validate-kcc.sh --mode repo
bash .KCC/tools/validate-kcc.sh --repo-root /work/my-cell
```

Arguments:

| Argument | Values | Notes |
|---|---|---|
| `-Mode` / `--mode` | `cell`, `repo` | `cell` validates usable local cell source. `repo` validates full public package. |
| `-RepoRoot` / `--repo-root` | path | Optional root override. |

Expected success:

```text
Errors: 0
Warnings: 0
KCC validation passed.
```

## backchannel-append

Appends exactly one JSONL event to `coordination/backchannel.jsonl` and
best-effort refreshes the dashboard.

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\backchannel-append.ps1 -Kind brief-issued -From butler -Spec SPEC-003
powershell -ExecutionPolicy Bypass -File .KCC\tools\backchannel-append.ps1 -Kind approval -From human -To token-guard -Spec SPEC-003 -Payload '{"decision":"approved"}'
powershell -ExecutionPolicy Bypass -File .KCC\tools\backchannel-append.ps1 -Kind note -From architect -NoDashboard
```

Bash:

```bash
bash .KCC/tools/backchannel-append.sh --kind brief-issued --from butler --spec SPEC-003
bash .KCC/tools/backchannel-append.sh --kind approval --from human --to token-guard --spec SPEC-003 --payload '{"decision":"approved"}'
bash .KCC/tools/backchannel-append.sh --kind note --from architect --no-dashboard
```

Common arguments:

| Argument | Required | Notes |
|---|---|---|
| `-Kind` / `--kind` | yes | Event kind, such as `brief-issued`, `approval`, `toolchain-preflight-result`. |
| `-From` / `--from` | yes | Event source. |
| `-To` / `--to` | no | Intended recipient. |
| `-Spec` / `--spec` | no | Related `SPEC-{ID}`. |
| `-Session` / `--session` | no | Related trace session. |
| `-Payload` / `--payload` | no | JSON payload object. |
| `-NoDashboard` / `--no-dashboard` | no | Skip dashboard refresh. |

## show-backchannel

Displays recent backchannel events.

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\show-backchannel.ps1
powershell -ExecutionPolicy Bypass -File .KCC\tools\show-backchannel.ps1 -Last 50
powershell -ExecutionPolicy Bypass -File .KCC\tools\show-backchannel.ps1 -Kind approval -Spec SPEC-003
powershell -ExecutionPolicy Bypass -File .KCC\tools\show-backchannel.ps1 -Json
```

Bash:

```bash
bash .KCC/tools/show-backchannel.sh
bash .KCC/tools/show-backchannel.sh --last 50
bash .KCC/tools/show-backchannel.sh --kind approval --spec SPEC-003
bash .KCC/tools/show-backchannel.sh --json
```

Arguments:

| Argument | Notes |
|---|---|
| `-Last` / `--last` | Number of events to show. Default is 20. |
| `-Kind` / `--kind` | Filter by event kind. |
| `-From` / `--from` | Filter by source. |
| `-Spec` / `--spec` | Filter by spec. |
| `-Json` / `--json` | Emit JSON instead of human-readable text. |

## build-dashboard

Builds a self-contained local dashboard at `dashboard/index.html`.

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\build-dashboard.ps1
powershell -ExecutionPolicy Bypass -File .KCC\tools\build-dashboard.ps1 -Open
```

Bash:

```bash
bash .KCC/tools/build-dashboard.sh
bash .KCC/tools/build-dashboard.sh --open
```

Arguments:

| Argument | Notes |
|---|---|
| `-Open` / `--open` | Open the generated dashboard in a browser. |

Use when you want a local view of ideas, specs, traces, backchannel events,
reviews, and memory.

## start-agent-session

Starts an agent-focused harness session, optionally in Docker sandbox mode.

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\start-agent-session.ps1 -Agent idea-interrogator -Harness claude
powershell -ExecutionPolicy Bypass -File .KCC\tools\start-agent-session.ps1 -Agent implementer -Harness codex -Sandbox
powershell -ExecutionPolicy Bypass -File .KCC\tools\start-agent-session.ps1 -Agent verifier -Harness opencode -DryRun
```

Bash:

```bash
bash .KCC/tools/start-agent-session.sh --agent idea-interrogator --harness claude
bash .KCC/tools/start-agent-session.sh --agent implementer --harness codex --sandbox
bash .KCC/tools/start-agent-session.sh --agent verifier --harness opencode --dry-run
```

Common arguments:

| Argument | Required | Notes |
|---|---|---|
| `-Agent` / `--agent` | yes | Agent role to launch. |
| `-Harness` / `--harness` | no | `claude`, `codex`, `opencode`, or `generic`. |
| `-Sandbox` / `--sandbox` | no | Launch inside Docker sandbox. |
| `-DryRun` / `--dry-run` | no | Print what would run without launching. |
| `-Prompt` / `--prompt` | no | Inline prompt. |
| `-PromptFile` / `--prompt-file` | no | Prompt file path. |

## toolchain-preflight

Checks whether build/test tools exist and suggests install commands. It never
installs tools by itself.

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\toolchain-preflight.ps1 -Tools git,node,pnpm
powershell -ExecutionPolicy Bypass -File .KCC\tools\toolchain-preflight.ps1 -Tools dotnet,docker
```

Bash:

```bash
bash .KCC/tools/toolchain-preflight.sh --tools git,node,pnpm
bash .KCC/tools/toolchain-preflight.sh --tools dotnet,docker
```

Arguments:

| Argument | Required | Notes |
|---|---|---|
| `-Tools` / `--tools` | yes | Comma-separated tool names. |

Install decisions must be human-gated and traceable.

After the per-tool lines (present, `MISSING`, or `WRONG` for a version outside
the range the plan's `## Toolchain` table asks for), two environment probes run
when `docker` is required and present, one line each:

```text
LIMIT docker-daemon unreachable: docker is installed but its daemon is not running (...)
PROBE    docker-registry reachable (docker pull hello-world)
PROBE    docker-build-network reachable (a RUN step reached registry.npmjs.org over TLS)
LIMIT docker-build-network unreachable: a RUN step inside a build cannot reach registries over TLS (...); see KCC_CA_BUNDLE
```

A `LIMIT` line never fails the preflight and never opens the install gate.
`kcc-run` copies the lines into the TEST prompt as `KNOWN ENVIRONMENT LIMITS`,
so the verifier defers the checks they rule out at once. What to do about the
limit: [unattended-runs.md](./unattended-runs.md) -> *Machines behind a
TLS-intercepting proxy or antivirus*.

## adapt-workflow

Scaffolds a migration workspace for an external agentic workflow.

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\adapt-workflow.ps1 -SourcePath ../OtherProject
powershell -ExecutionPolicy Bypass -File .KCC\tools\adapt-workflow.ps1 -SourcePath ../OtherProject -Format cursor
powershell -ExecutionPolicy Bypass -File .KCC\tools\adapt-workflow.ps1 -SourcePath ../OtherProject -DryRun
```

Bash:

```bash
bash .KCC/tools/adapt-workflow.sh --source-path ../OtherProject
bash .KCC/tools/adapt-workflow.sh --source-path ../OtherProject --format cursor
bash .KCC/tools/adapt-workflow.sh --source-path ../OtherProject --dry-run
```

Arguments:

| Argument | Required | Notes |
|---|---|---|
| `-SourcePath` / `--source-path` | yes | External workflow path. |
| `-Format` / `--format` | no | `auto`, `cursor`, `claude`, `codex`, `opencode`, `aider`, or `generic`. |
| `-DryRun` / `--dry-run` | no | Preview without writing migration files. |

## bootstrap-mac-linux

Prepares native bash tools on macOS/Linux.

Bash:

```bash
bash .KCC/tools/bootstrap-mac-linux.sh
```

What it does:

- sets executable bits on `.sh` tools
- smoke-tests native bash validation
- reports obvious missing shell prerequisites

## memory-append

PowerShell-only deterministic memory writer used by Butler.

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\memory-append.ps1 -Type decision -Title "Use SQLite" -Summary "Local DB is sufficient" -Body "Decision details..."
powershell -ExecutionPolicy Bypass -File .KCC\tools\memory-append.ps1 -Type pattern -Title "Spec-first CLI work" -Summary "Useful pattern" -Body "..." -Tags cli,spec
```

Arguments:

| Argument | Required | Notes |
|---|---|---|
| `-Type` | yes | `decision`, `pattern`, `incident`, `preference`, or `glossary`. |
| `-Title` | yes | Entry title. |
| `-Summary` | yes | Short summary. |
| `-Body` | yes | Full body. |
| `-Tags` | no | Comma-separated tags. |
| `-RelatedSpecs` | no | Related spec IDs. |

Only Butler should write long-term memory in normal KCC operation.

## kcc-inspect

PowerShell-only basic Inspector pipeline over real run signals.

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\kcc-inspect.ps1
powershell -ExecutionPolicy Bypass -File .KCC\tools\kcc-inspect.ps1 -MinEvents 12 -MinOccurrences 3
```

Arguments:

| Argument | Default | Notes |
|---|---|---|
| `-MinEvents` | `8` | Minimum events before proposals are considered. |
| `-MinOccurrences` | `2` | Minimum repeated pattern occurrences. |

It writes proposal stubs under `.KCC/kernel/inspector/proposals/` and does not
fabricate patterns when signals are insufficient.

## Recommended Tool Flows

### First run with the command line (any system)

```text
kcc init codex
kcc tailor
kcc doctor
```

### First run on Windows

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 codex
powershell -ExecutionPolicy Bypass -File .KCC\tools\validate-kcc.ps1
```

### First run on macOS/Linux

```bash
bash .KCC/tools/bootstrap-mac-linux.sh
bash .KCC/tools/framework-init.sh codex
bash .KCC/tools/validate-kcc.sh
```

### After editing an agent or skill

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
powershell -ExecutionPolicy Bypass -File .KCC\tools\validate-kcc.ps1 -Mode repo
```

### Inspect coordination events

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\show-backchannel.ps1 -Last 20
powershell -ExecutionPolicy Bypass -File .KCC\tools\build-dashboard.ps1 -Open
```

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](../LICENSE).
