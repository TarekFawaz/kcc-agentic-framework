# The `kcc` Command Line

`kcc` is one self-contained program for Windows, macOS, and Linux. It carries
the whole framework inside it, so a project no longer starts with downloading
or cloning `.KCC/` by hand. Nothing else has to be installed: no Node, no
PowerShell 7. It uses the shell each system already has (Windows PowerShell
on Windows, bash on macOS and Linux) to run the framework's own scripts.

## Install

Windows (PowerShell):

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
| `kcc limits [--json]` | Shows usage, the last limit hit, and the next resume |
| `kcc mcp` | Serves KCC over MCP. See [MCP](./mcp.md) |
| `kcc tool <name> [args]` | Runs any script from `.KCC/tools/` with the right shell for this system |
| `kcc version`, `kcc help` | Version and usage |

Every command accepts `--dir <path>`; the default is the current folder or
the nearest parent that holds `.KCC/`.

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
        [--harness claude|codex|opencode|generic] [--parallel] [--dry-run] [--json]
kcc run --resume
kcc run --answer <choice>
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
`kcc run --answer <choice>`), 5 suspended on a usage limit, 6 stopped or
aborted. Resume commands never use a permission-bypass flag; a template that
contains one is refused.

Usage percentages exist only for Claude Code (its status line writes
`coordination/usage.json`). Other harnesses do not publish usage, so for
them a limit is known only when it is hit.

### `kcc tool`

Flags are written the bash way on every system and translated for
PowerShell on Windows:

```text
kcc tool quality-gate --spec SPEC-003 --json
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

## Relation to the scripts

The scripts under `.KCC/tools/` remain the source of truth for generation
and gates; the CLI calls them and adds what a script cannot do well:
install, upgrade with conflict detection, tailoring, supervision, and MCP.
A project can still be used with the scripts alone.
