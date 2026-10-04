---
title: KCC CLI Guide
aliases:
  - cli-guide
  - kcc-cli-guide
tags:
  - framework/documentation
  - cli
  - how-to
created: 2026-10-04
updated: 2026-10-04
version: 0.5.1
status: active
---

# KCC CLI Guide

How to install the `kcc` command line and use it day to day. For every
option of every command, see [docs/cli.md](./docs/cli.md).

`kcc` is one self-contained program. The KCC framework is inside it, so you
do not clone or copy anything into your project by hand.

## 1. What you need

| | Windows | macOS / Linux |
|--|--|--|
| Shell | Windows PowerShell (already installed) | bash (already installed) |
| Git | Git for Windows (also provides the `bash` the hooks use) | git |
| An agent harness | Claude Code, Codex CLI, or OpenCode | same |

You do not need Node, Bun, or PowerShell 7.

## 2. Install

### Windows: winget (recommended)

```powershell
winget install Tikasway.KCC
```

winget downloads the program, verifies it, and makes `kcc` available in new
terminals. Update later with `winget upgrade Tikasway.KCC`; remove with
`winget uninstall Tikasway.KCC`.

### macOS and Linux: Homebrew (recommended)

```bash
brew install tarekfawaz/kcc/kcc
```

Update later with `brew upgrade kcc`; remove with `brew uninstall kcc`.

### Without a package manager

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/TarekFawaz/kcc-agentic-framework/main/install.ps1 | iex
```

The program goes to `%LOCALAPPDATA%\kcc\bin\kcc.exe` and that folder is added
to your user PATH. Open a new terminal afterwards.

macOS and Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/TarekFawaz/kcc-agentic-framework/main/install.sh | sh
```

The program goes to `~/.local/bin/kcc`. If that folder is not on your PATH,
the installer prints the line to add to your shell profile.

### Check

```text
kcc version
```

```text
kcc 0.5.1 (framework 0.5.1)
```

### Script installer options

| Need | Windows | macOS / Linux |
|--|--|--|
| A specific version | `install.ps1 -Version 0.5.1` | `sh install.sh --version 0.5.1` |
| Another folder | `-InstallDir C:\tools\kcc` | `--dir /opt/kcc` |
| Do not change PATH | `-NoPath` | (PATH is never changed) |
| Install a binary you built | `-From cli\dist\kcc.exe` | `--from cli/dist/kcc` |

The installers download from the GitHub release and check the file against
the release's `checksums.txt`. No administrator rights are needed.

### Before the first release is published, or offline

winget, Homebrew, and the one-line installers all need a published release
(winget also needs Microsoft to accept the package). Until then, or on a
machine without internet access, build the program from this repository
(this needs [Bun](https://bun.sh) on the build machine only):

```bash
cd cli
bun install
bun run build
```

Then install the result:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -From cli\dist\kcc.exe
```

```bash
sh install.sh --from cli/dist/kcc
```

## 3. Set up a project

Go to your project folder (empty or existing) and run:

```text
kcc init claude
```

Use the harness you work with: `claude`, `codex`, `opencode`, `generic`,
`ollama`, or `all`.

### Target folder

Every command works on the current folder unless you name another one. Give
the path after the command; `kcc init` creates the folder if it is missing.

```text
kcc init claude C:\work\billing-api
kcc tailor C:\work\billing-api
kcc doctor ../billing-api
kcc upgrade ../billing-api
kcc sync claude ../billing-api
```

`--dir <path>` does the same and is the form to use with `run`, `limits`,
`mcp`, and `tool`, whose other arguments are passed on:

```text
kcc run --dir ../billing-api --input "add invoice export"
kcc tool --dir ../billing-api quality-gate --spec SPEC-003
```

Run from inside a subfolder and `kcc` finds the project by walking up to the
nearest folder that holds `.KCC/`.

This creates:

```text
.KCC/                  the framework (kernel, capabilities, tools)
.KCC/settings.json     your settings; never overwritten later
.claude/ (or .codex/, .opencode/, ...)   generated agents and skills
CLAUDE.md, AGENTS.md   entrypoints your harness reads
coordination/, memory/, Traces/          run state
```

Then check the installation:

```text
kcc doctor
```

`Errors: 0  Warnings: 0` means you are ready. Otherwise each line names the
fix.

## 4. Fit KCC to your solution

Out of the box KCC carries every agent, skill, and dialect. Tell it what you
are building so it keeps only what applies.

**Answer questions:**

```text
kcc tailor
```

**Or give a file** (good for teams; commit it):

```yaml
# solution-context.yaml
name: billing-api
project_type: api-service     # web-app | api-service | cli-tool | library | mobile | embedded | data-pipeline | other
stacks: [dotnet]              # python nodejs nestjs mern react angular vanilla-js dotnet go rust java cpp c php
has_ui: false
deployment: kubernetes        # none | cloud | kubernetes | onprem | hybrid
existing_codebase: true
data_sensitivity: high        # low | medium | high
performance_tests: true
coverage_min_pct: 85
```

```text
kcc tailor --context solution-context.yaml
```

**Or use an existing codebase's baseline:** run `/solution-onboard .` in your
harness, then `kcc tailor --from-baseline`.

Useful switches:

| Command | Effect |
|--|--|
| `kcc tailor --context <file> --dry-run` | Show what would be kept and dropped; change nothing |
| `kcc tailor --show` | Show what is applied now |
| `kcc tailor --reset` | Restore the full framework |

Nothing is deleted: dropped files move to `.KCC/.tailored-out/`. You can do
both steps at once on a new project: `kcc init claude --context solution-context.yaml`.

Optional second step, inside your harness: `/tailor-workflow` drafts
solution-specific additions (your real build commands, conventions, custom
skills) under `migrations/TAILOR-001/` for you to review. More:
[docs/tailoring.md](./docs/tailoring.md).

## 5. Set up git

```text
kcc tool repo-bootstrap --apply init-local
```

This runs `git init` (on `main`), adds a `.gitignore` if missing, makes the
first commit, and installs three hooks: a secret scan and implementation
lock before each commit, a commit-message check, and a guard against pushing
straight to `main`.

Already have a repository? Install only the hooks:

```text
kcc tool repo-bootstrap --install-hook
```

Commit messages then follow one of these forms:

```text
SPEC-003 Story-001: add CSV parser
chore: bump dependencies
```

KCC never pushes for you. More: [docs/git-workflow.md](./docs/git-workflow.md).

## 6. Run the lifecycle

**Inside your harness** (the usual way):

```text
auto build a CLI that converts CSV to JSON
```

**From the terminal**, with automatic resume after a usage limit:

```text
kcc run --input "build a CLI that converts CSV to JSON"
```

| Command | Use |
|--|--|
| `kcc run --input "<idea>" --dry-run` | List the states the run would execute; write nothing |
| `kcc run --input "<idea>" --silent --assume --budget 200 --currency USD` | Hands-off run inside a budget |
| `kcc run --input SPEC-003` | Continue one spec |
| `kcc run --answer proceed` | Answer the human gate the run is paused at |
| `kcc run --resume` | Continue a paused or suspended run |
| `kcc run --harness codex --input "<idea>"` | Use another harness |

A run stops at human gates (budget, confidence, ROI). The gate text is in
`coordination/gates/`, and the run prints the allowed answers.

Exit codes: 0 done, 4 paused at a gate, 5 suspended on a usage limit,
6 stopped or aborted.

### When the harness hits a usage limit

`kcc run` handles it for you:

1. It writes a restore point.
2. It reads the reset time from the harness output.
3. It waits and resumes the same run.

You can leave the terminal open and walk away. To see the state:

```text
kcc limits
```

To protect a harness command you run yourself:

```text
kcc run --wrap --harness codex -- codex exec "implement SPEC-003 wave 2"
```

`--no-wait` exits at the first limit instead of waiting; continue later with
`kcc run --resume`.

## 7. Give your harness the MCP server (optional)

```text
kcc mcp --register
```

Restart the harness session and approve the `kcc` server. Agents can then
read one section of a protocol instead of the whole file, and call the gate
tools directly. The server runs on your machine only. More:
[docs/mcp.md](./docs/mcp.md).

## 8. Everyday commands

| I want to | Command |
|--|--|
| Check the installation | `kcc doctor` |
| Regenerate adapters after editing `.KCC/kernel/` or `.KCC/capabilities/` | `kcc sync` |
| Validate the framework files | `kcc validate` |
| Run the quality gate for a spec | `kcc tool quality-gate --spec SPEC-003` |
| Check that every acceptance criterion has a passing test | `kcc tool check-traceability --spec SPEC-003` |
| Write a restore point by hand | `kcc tool kcc-checkpoint --reason manual` |
| Move the run to another harness | `kcc tool kcc-handover --to codex --dry-run` |
| Check a commit message | `kcc tool check-commit-msg --message "SPEC-003 Story-001: add parser"` |
| Work on a project in another folder | add the path (`kcc doctor ../app`) or `--dir <path>` |

`kcc tool <name>` runs any script from `.KCC/tools/`. Write flags the same
way on every system (`--spec`, `--dry-run`, `--json`).

## 9. Update

1. Get the new `kcc`: `winget upgrade Tikasway.KCC`, `brew upgrade kcc`, or
   run the script installer again.
2. In each project:

   ```text
   kcc upgrade --dry-run     # see what would change
   kcc upgrade
   ```

Framework files you never edited are replaced. Files you edited are kept and
listed; use `kcc upgrade --force` to take the shipped versions instead. Your
`settings.json` and your tailoring are kept.

## 10. Troubleshooting

| Symptom | Cause | Fix |
|--|--|--|
| `kcc` is not recognized | The install folder is not on PATH in this terminal | Open a new terminal; on macOS/Linux add `~/.local/bin` to PATH |
| The installer reports 404 | No release is published yet, or the version does not exist | Build from source (section 2) or pick an existing version |
| `winget` finds no package `Tikasway.KCC` | The package is not accepted in the winget repository yet | Use the PowerShell installer |
| `brew` cannot find the tap | The tap repository is not published yet | Use the `curl` installer |
| `no .KCC/ found` | You are not inside a KCC project | `cd` to the project, or run `kcc init` |
| `kcc doctor` reports `DOCTOR-SYNC-001` | Adapters are out of date | `kcc sync` |
| `kcc doctor` reports `DOCTOR-HOOK-003` | Git hooks are not installed | `kcc tool repo-bootstrap --install-hook` |
| An agent or skill is missing | The workspace is tailored | `kcc tailor --show`, then re-run `kcc tailor` or `kcc tailor --reset` |
| `kcc upgrade` says files were kept | You edited framework files | Keep them, or `kcc upgrade --force` |
| A commit is blocked by `kcc commit-msg` | The message does not follow the convention | Reword it (section 5) |
| A push to `main` is blocked | `main` is protected | Push your `spec/...` branch and open a pull request |
| A run exits with code 5 | Usage limit, and the resume attempts are used up | `kcc limits`, then `kcc run --resume` |
| A run exits with code 4 | Waiting for your decision | Read the gate file it names, then `kcc run --answer <choice>` |
| macOS blocks the program as unidentified | The binary is not signed | Allow it under System Settings -> Privacy & Security, or run `xattr -d com.apple.quarantine ~/.local/bin/kcc` |

## 11. Uninstall

`winget uninstall Tikasway.KCC` or `brew uninstall kcc`. After a script
install, delete the program (`%LOCALAPPDATA%\kcc\bin\kcc.exe` or
`~/.local/bin/kcc`) and remove the folder from PATH. Projects keep working with the scripts in
their `.KCC/tools/` folder.

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](./LICENSE).
