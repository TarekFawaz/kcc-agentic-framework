# The `kcc` Command Line

`kcc` is one self-contained program for Windows, macOS, and Linux. It carries
the whole framework inside it, so a project no longer starts with downloading
or cloning `.KCC/` by hand. Nothing else has to be installed: no Node, no
PowerShell 7. It uses the shell each system already has (Windows PowerShell
on Windows, bash on macOS and Linux) to run the framework's own scripts.

## Install

With a package manager (once the release is published in each):

```text
winget install Tikasway.KCC          # Windows
brew install tarekfawaz/kcc/kcc      # macOS and Linux
```

Or with the script installers. Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/TarekFawaz/kcc-agentic-framework/main/install.ps1 | iex
```

macOS and Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/TarekFawaz/kcc-agentic-framework/main/install.sh | sh
```

The installer downloads the binary for your system from the GitHub release,
checks its SHA-256 against the release's `checksums.txt`, and puts it in a
user folder (`%LOCALAPPDATA%\kcc\bin` or `~/.local/bin`). No administrator
rights are needed.

| Option | Windows | macOS / Linux |
|--|--|--|
| A specific version | `-Version 0.5.0` | `--version 0.5.0` or `KCC_VERSION` |
| Another folder | `-InstallDir <path>` | `--dir <path>` or `KCC_INSTALL_DIR` |
| A local build | `-From cli\dist\kcc.exe` | `--from cli/dist/kcc` |
| Leave PATH alone | `-NoPath` | (never changed; a hint is printed) |

Update by running the installer again, then `kcc upgrade` in each project.

## First project

```text
cd my-project
kcc init claude            # or codex | opencode | generic | ollama | all
kcc tailor                 # answer a few questions about the solution
kcc doctor
```

Then start the lifecycle inside your harness (`auto <idea>`) or from the
terminal (`kcc run --input "<idea>"`).

## Commands

| Command | What it does |
|--|--|
| `kcc init [harness]` | Writes `.KCC/` into the folder from the copy inside the binary, records `.KCC/kcc.lock`, and generates the harness adapters. Safe to re-run. On a folder that already has a hand-copied `.KCC/`, it adopts it and keeps every file you changed |
| `kcc tailor` | Fits agents, skills, and dialects to the solution. See [tailoring](./tailoring.md) |
| `kcc upgrade` | Brings `.KCC/` to the version this binary ships. Files you edited are listed and left alone |
| `kcc sync [harness]` | Regenerates harness adapters after you edit `.KCC/kernel/` or `.KCC/capabilities/` |
| `kcc validate [--mode cell\|repo]` | Runs the framework validator |
| `kcc doctor [--json]` | Checks the installation and names the fix for each problem |
| `kcc run ...` | Drives the lifecycle and survives usage limits. See below |
| `kcc models [--check\|--refresh] [--deep]` | Lists the model of each tier per harness. `--check` probes the pinned Claude ids; `--deep` adds the DeepThinking tier (about $0.80 per probe) |
| `kcc route [SPEC-ID] [--dry-run]` | Decides the model and reasoning effort per backlog item from the plan and writes `## Routing` into `plan.md`; the drivers and the orchestrator ask the same router (`.KCC/tools/kcc-route`) before every spawn |
| `kcc report [--skeleton-min N] [--app-min N] [--out file]` | Measures the run in this folder (time per stage, human waits, agents, cost) and judges it against a time budget; exit 1 on a miss |
| `kcc limits [--json]` | Shows usage, the last limit hit, and the next resume |
| `kcc hint "text" [--to all\|main\|subagents\|<agent>] [--expires <min>]` | Gives the running session and its subagents a hint, delivered by hook on the next tool call. Also `kcc --hint "text"`. `--list`, `--clear <id\|all>`, `--pending [--for <agent>]` manage and read hints. See `.KCC/kernel/protocols/hints.md` |
| `kcc doctor --fix-hooks` | Adds the missing KCC hooks (hint delivery, StopFailure limit resume, limit guard) to `.claude/settings.json` without touching your own entries |
| `kcc mcp` | Serves KCC over MCP. See [MCP](./mcp.md) |
| `kcc tool <name> [args]` | Runs any script from `.KCC/tools/` with the right shell for this system |
| `kcc version`, `kcc help` | Version and usage |

The target is the current folder, or the nearest parent that holds `.KCC/`.
To work on another folder, give its path after the command (`kcc init claude
../app`, `kcc tailor ../app`, `kcc doctor ../app`, `kcc upgrade ../app`,
`kcc sync claude ../app`, `kcc validate ../app`) or use `--dir <path>`.
`run`, `limits`, `mcp`, and `tool` take only `--dir`, because their other
arguments are passed on (`kcc tool --dir ../app quality-gate --json`).
`kcc init` creates the target folder when it does not exist.

### `kcc init`

```text
kcc init [harness] [--context <file> | --from-baseline] [--yes] [--mcp] [--force] [--no-sync]
```

- `--context` / `--from-baseline` tailor during init, so only the fitted
  adapters are generated.
- `--mcp` registers the local MCP server with the harnesses.
- `--force` replaces files you edited with the shipped version.
- `.KCC/settings.json` is yours: it is created once and never overwritten.

### `kcc upgrade`

```text
kcc upgrade [--dry-run] [--force] [--no-sync]
```

`.KCC/kcc.lock` stores a checksum of every framework file as installed. On
upgrade, a file that still matches its checksum is replaced; a file you
changed is reported as a conflict and kept (exit code 1 tells scripts that
conflicts exist). Files a new version no longer ships are removed only if
you never edited them. Tailoring is re-applied afterwards. Line-ending
changes made by git are not treated as edits.

### `kcc doctor`

Exit 0 when nothing must be fixed, 1 otherwise. `--json` prints the
tool-contract shape used by the other KCC tools.

| ID | Meaning | Fix |
|--|--|--|
| `DOCTOR-ENV-001..003` | PowerShell, bash, or git missing | Install it |
| `DOCTOR-INSTALL-001` | No `.KCC/` here | `kcc init` |
| `DOCTOR-INSTALL-002` | `.KCC/` was copied by hand (no lock) | `kcc init` to adopt it |
| `DOCTOR-VERSION-001` | `.KCC/` is older than the CLI | `kcc upgrade` |
| `DOCTOR-DRIFT-001` | A framework file is missing | `kcc upgrade` |
| `DOCTOR-DRIFT-002` | Framework files edited locally (warning) | none needed |
| `DOCTOR-SYNC-001` | Generated agents do not match the sources | `kcc sync` |
| `DOCTOR-HOOK-001..002` | Claude Code limit guard or implementation lock not configured (warning) | Merge from `.KCC/kernel/templates/claude-settings.json` |
| `DOCTOR-HOOK-003` | A KCC git hook is not installed | `kcc tool repo-bootstrap --install-hook` |

### `kcc run`: auto-continue on every harness

```text
kcc run --input <idea | path | IDEA-ID | SPEC-ID | all> [--silent --assume] [--budget NN --currency CCY]
        [--harness claude|codex|opencode|generic] [--parallel] [--fasttrack] [--depthlevel 1-5]
        [--open-dashboard | --no-open-dashboard]
        [--dry-run] [--json]
kcc run --resume
kcc run --answer <choice>
kcc run --lane SPEC-NNN --answer <choice>
kcc run --lane SPEC-NNN --from <state id>
kcc run --wrap [--harness <name>] -- <any harness command>
```

`kcc run` passes its options to the `kcc-run` driver
(`.KCC/kernel/protocols/kcc-run.md`), which executes the lifecycle state by
state through your harness's own command line and checks each state with a
script. On top of that, `kcc run` supervises:

1. When the harness stops on a usage or rate limit, a restore point is
   written.
2. The reset time is read from the harness output. If none is stated,
   `continuity.default_wait_minutes` is used.
3. `kcc run` waits, then resumes the same run, up to
   `continuity.max_resumes` times.

This works the same for Claude Code, Codex, OpenCode, and any command you
configure as `generic`, because detection reads what the harness prints:
structured JSON events first, then the wording in
`.KCC/kernel/limit-patterns.json`. To teach it a new harness's message, add
the wording to that file.

`--wrap` gives the same protection to a harness command you run yourself:

```text
kcc run --wrap --harness codex -- codex exec "implement SPEC-003 wave 2"
```

| Option | Meaning |
|--|--|
| `--no-wait` | Exit with code 5 at the first limit instead of waiting |
| `--max-resumes N` | Override `continuity.max_resumes` |

Exit codes: 0 done, 2 usage error, 4 paused at a human gate (answer with
`kcc run --answer <choice>`, or `kcc run --lane SPEC-NNN --answer <choice>`
for one spec's lane), 5 suspended on a usage limit, 6 stopped or aborted,
7 done with `[open]` items in `coordination/NeedsAttention.md` (only under
`--silent --assume`, which never exits 4). Resume commands never use a
permission-bypass flag; a template that contains one is refused.

`kcc run --resume` on a run that closed with lanes not merged (a parked spec,
a lane merged by hand after a conflict) reopens the run for those lanes and
closes it again at the end.

The gates a run can pause at, and their answers:

| Gate | Answers | Opened when |
|--|--|--|
| `waiver` | `waive`, `recheck`, `abort` | The review is `WAIVER_NEEDED`, or `CHANGES_NEEDED` with no open Bug, no implementer-owned gate failure and no traceability error (`REVIEW-004 (human)`). `waive` closes the spec as a recorded waiver, never a pass; `recheck` re-runs TEST, scoped, after you fixed the environment |
| `ruling` | `revise`, `waive`, `escalate`, `abort` | Only blocked Bugs are left; `revise` applies the Bug file's recommended option (or your `--note`) |
| `quality-deferred-on-exit-3` | `install`, `accept-deferred`, `abort` | `quality-gate` exited 3 because a scanner could not run |
| `loop` | `revise`, `escalate`, `abort` | Three failed exit checks, or a third full verifier pass |
| `toolchain` | `install`, `human-install`, `defer` | PREFLIGHT found a required tool missing |
| `budget`, `budget-cap`, `confirm`, `roi-gate`, `repo-bootstrap` | see `.KCC/kernel/protocols/kcc-run.md` -> *Gates* | Full lifecycle and first-run gates |

Under `--silent --assume` each gate is answered by policy (`waiver` ->
`waive`, `ruling` -> `revise`, scanner missing -> `accept-deferred`,
toolchain -> `defer`, confidence -> `proceed`); `loop`, `budget-cap` and a
check error park the spec as an `[open]` item and the run ends with exit 7.
A scoped TEST with nothing to verify is not dispatched (`test-skipped`
event). The outcomes and what to do for each are in
[unattended-runs.md](./unattended-runs.md).

Usage percentages exist only for Claude Code (its status line writes
`coordination/usage.json`). Other harnesses do not publish usage, so for
them a limit is known only when it is hit.

### `kcc tool`

Flags are written the bash way on every system and translated for
PowerShell on Windows:

```text
kcc tool quality-gate --spec SPEC-003 --json
kcc tool quality-gate --spec SPEC-003 --scope deps
kcc tool toolchain-preflight --tools node,docker
kcc tool check-traceability --spec SPEC-003
kcc tool kcc-checkpoint --reason manual --next-action "review wave 2"
kcc tool repo-bootstrap --install-hook
```

## What lands in a project

```text
.KCC/                 framework source (kernel, capabilities, tools)
.KCC/kcc.lock         installed version and file checksums
.KCC/settings.json    your settings; never overwritten
.claude/ .codex/ .opencode/ .agents/ ollama/   generated adapters
CLAUDE.md, AGENTS.md  entrypoints (created once, then yours)
coordination/, memory/, Traces/               run state
```

## Building from source

```bash
cd cli
bun install
bun test                 # packs the payload, then runs the tests
bun run build            # dist/kcc for this machine
bun run build:all        # every release target
bun run test/mcp-smoke.ts dist/kcc <workspace>   # end-to-end MCP check
```

`scripts/pack.ts` embeds the repository's `.KCC/` tree into the binary, so
rebuild after changing anything under `.KCC/`. A release is cut by pushing a
tag `vX.Y.Z` that matches `cli/package.json`; `.github/workflows/release.yml`
builds, checksums, publishes, and smoke-tests the installers on all three
systems.

### Publishing to winget and Homebrew

The release workflow also runs `scripts/packaging.ts`, which writes the
winget manifest and the Homebrew formula with the release's checksums and
attaches them to the release. Two optional jobs publish them; each runs only
when its secret exists in the repository settings.

| Channel | One-time setup | Secret |
|--|--|--|
| Homebrew | Create the public repository `TarekFawaz/homebrew-kcc` (it may be empty) | `HOMEBREW_TAP_TOKEN`: a token with write access to that repository |
| winget | None. Each version opens a pull request against `microsoft/winget-pkgs`, which Microsoft reviews before it becomes installable | `WINGET_TOKEN`: a classic token with the `public_repo` scope |

Without the secrets, publish by hand: copy `kcc.rb` from the release into
`Formula/kcc.rb` of the tap, and run
`wingetcreate submit <folder with the three .yaml files>`.

## Relation to the scripts

The scripts under `.KCC/tools/` remain the source of truth for generation
and gates; the CLI calls them and adds what a script cannot do well:
install, upgrade with conflict detection, tailoring, supervision, and MCP.
A project can still be used with the scripts alone.
