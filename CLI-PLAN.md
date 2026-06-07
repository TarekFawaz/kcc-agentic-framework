---
title: KCC CLI - Planning Document
aliases:
  - cli-plan
  - kcc-cli
  - cli-roadmap
tags:
  - framework/documentation
  - cli
  - roadmap
  - kcc/v04
created: 2026-05-29
updated: 2026-05-29
version: 1.0.0
status: active
---

# KCC CLI - Planning Document

This is a **planning document**, not a build. No CLI code lives in this
repo yet. This file captures the intent, language choice, package name,
command shape, and milestones so the work can begin in v1.1 with the
trade-offs already settled.

## Why a CLI

Today every tool in this framework is a PowerShell script
(`.KCC/tools/*.ps1`). That has bitten us repeatedly:

- **Mac / Linux friction** - users must install PowerShell 7
  (`brew install --cask powershell` on macOS, the MS docs path on Linux)
  before they can run `framework-init`, `sync-adapters`, `validate-kcc`,
  `adapt-workflow`, `show-backchannel`, or `start-agent-session`. Sibling
  A's `.sh` wrappers help, but they wrap PowerShell - they do not
  eliminate the dependency.
- **Distribution friction** - there is no way to `npm install -g
  @something/kcc` and have the tools on a clean machine. Every adoption
  starts with a git clone and a `cd` into `.KCC/tools/`.
- **Cross-script consistency** - the six PowerShell scripts share no
  common helpers beyond convention. A native CLI can share a single
  argument parser, config loader, settings.json reader, and logger.
- **Future-proofing** - a CLI binary opens the door to non-developer
  consumers (PMs running `kcc auto "<idea>" --silent --assume`,
  for example) who would not install PowerShell for a single command.

The PowerShell scripts are **not going away**: they remain canonical
through v1.x. The CLI is a parallel path. v2.0 is the earliest the CLI
could become primary and PowerShell wrappers deprecated, and only after
parity is proven through actual cross-platform use.

## Why Node + TypeScript

The candidates were Node, Go, Rust, and Python. Node wins on three axes:

1. **Easiest install path.** `npm install -g @tikasway/kcc` is one command
   anyone has already run a thousand times. Go and Rust ship single
   binaries but require either a per-platform release matrix or
   `go install` / `cargo install` from source. Python suffers from the
   `pip install` global-vs-venv mess and shebang portability.
2. **Ecosystem familiarity.** Most KCC adopters are JavaScript /
   TypeScript shops by default; the package conventions, lockfile
   semantics, and CI hooks are already in their muscle memory.
3. **Single-binary fallback.** When `npm install` is undesirable (corporate
   policy, air-gapped environments), `pkg` or `bun build --compile` ships
   a single platform binary from the same source. That gives us the
   Go / Rust advantage without committing to those toolchains.

TypeScript (not plain JS) is required: the CLI has to read structured
files (`settings.json`, `backchannel.jsonl`, agent + skill frontmatter,
calibration tables). Type safety on those parsers is the difference
between "works on my machine" and "works on every adopter's machine."

Acceptable runtime: Node 20 LTS or newer. Bun 1.0+ is an explicitly
supported alternative for users who already use it.

## Package name reserved

**`@tikasway/kcc`** on npm. Scope owner: the
`tarek.fawaz1983@gmail.com` group (per the contribution roles in the root
`README.md`). The scope will be reserved before v1.1 work begins so the
name cannot be squatted.

CLI invocation name: `kcc`. (Short, unambiguous, no conflict with common
package names we screened against.)

## Command shape (v1.1+ target surface)

```text
kcc init [--harness=<name>]              # equivalent to framework-init.ps1
kcc sync [--harness=<name>]              # equivalent to sync-adapters.ps1
kcc validate                             # equivalent to validate-kcc.ps1
kcc adapt <path> [--format=<hint>]       # equivalent to adapt-workflow.ps1
kcc backchannel [--last=N] [--kind=K] [--spec=ID]
                                         # equivalent to show-backchannel.ps1
kcc session [--sandbox] [--harness=<n>]  # equivalent to start-agent-session.ps1
                                         # --sandbox launches inside the Docker
                                         # sandbox runtime (KCC-FB-012)

# Pass-throughs to the harness - same UX as `auto` today:
kcc auto "<idea>"                        # forwards to the active harness
kcc auto "<idea>" --silent --assume --accuracy 95% --budget 200 USD
```

Flag conventions follow standard POSIX: `--long-form` with `=` for values,
short flags only where unambiguous. Help is `--help` and `-h` everywhere.

## Milestones

### v1.1 - Parity with PowerShell tools (target slice)

- `kcc init` - full parity with `framework-init.ps1`
- `kcc sync` - full parity with `sync-adapters.ps1`
- `kcc validate` - full parity with `validate-kcc.ps1`
- `kcc adapt` - full parity with `adapt-workflow.ps1`
- Mac / Linux / Windows binary built via Node 20 LTS
- `npm install -g @tikasway/kcc` and `bun add -g @tikasway/kcc` both
  documented
- Unit tests for every parser (settings.json, capability frontmatter,
  adapter notes)
- Lint, type-check, test in CI for every push

### v1.2 - Runtime tooling

- `kcc session [--sandbox]` - wires the Docker sandbox runtime
  (KCC-FB-012, sibling A's work) so `kcc session --sandbox` is the
  one-line entry to a hardened run
- `kcc backchannel` - full parity with `show-backchannel.ps1`, plus
  `--replay <SPEC-ID>` for the long-promised replay viewer
- `kcc auto "<idea>"` - forwards to the configured harness with the
  right slash-command dialect (e.g. `claude /auto`, `codex /auto`,
  `opencode auto`)
- Single-binary releases via `bun build --compile` for users who cannot
  `npm install -g`

### v1.3 - Config helpers + tracker integrations

- `kcc config get|set` - read/write `.KCC/settings.json` safely with
  schema validation (replaces the current hand-edit + `solution-inspector`
  workflow for trivial changes)
- `kcc tracker <jira|azure-devops|asana|linear|github-issues> ...` -
  configure and exercise the tracker adapters (deferred to v1.3 per the
  README's "What this repo does not implement yet" list)
- `kcc calibration show [--agent <name>]` - read-only view of
  `memory/calibration/agent-calibration.md` for quick drift inspection
  (Butler still owns the writes per
  [[.KCC/kernel/protocols/accuracy-calibration|accuracy-calibration]])

### v2.0 - PowerShell deprecation (only after parity is proven)

Earliest the PowerShell wrappers under `.KCC/tools/*.ps1` could be marked
deprecated. Requires:

- Six months of v1.x CLI use across multiple platforms with zero parity
  regressions
- A documented migration guide for every PowerShell-only command line
  pattern in this repo
- Agreement from kernel maintainers per the contribution roles

## Out of scope (for any milestone)

- **Rewriting agent or skill content.** Agents and skills stay as
  Markdown under `.KCC/capabilities/agents/` and
  `.KCC/capabilities/skills/`. The CLI reads them; it does not replace
  them.
- **Rewriting the kernel.** Contracts, protocols, dialects, adapters,
  templates all stay as Markdown. The CLI is a runtime; it is not the
  governance source.
- **Replacing the harness.** The CLI passes through to whichever harness
  the user has configured (Claude Code, Codex, OpenCode, Ollama). It is
  not itself an LLM client.
- **Becoming a CI plugin.** The CLI runs from a terminal; the CI
  integration story belongs to the deploy stage (see
  [[.KCC/kernel/protocols/deployment]]) and to the pipeline templates
  under `.KCC/kernel/templates/pipelines/`.

## Relationship to the PowerShell tools

| Concern | PowerShell today | CLI tomorrow |
|--|--|--|
| Canonical until v2.0 | YES | NO (parallel path) |
| Reads same `.KCC/kernel/` source | YES | YES |
| Reads same `.KCC/capabilities/` source | YES | YES |
| Writes generated harness adapters | YES | YES (same output) |
| Cross-platform | requires PowerShell 7 install | native via Node/Bun |
| Installable via package manager | NO | YES (`npm`, `bun`) |
| Distributed as single binary | NO | YES (v1.2+) |

The CLI and the PowerShell tools MUST produce byte-identical output for
the same inputs in v1.1. Drift between the two paths is a parity bug.

## Related

- Sibling A's bash wrappers (interim Mac/Linux story): `.KCC/tools/*.sh`
- Sibling A's Docker sandbox runtime (KCC-FB-012): `.KCC/sandbox/`
- Deploy stage (KCC-FB-013): [[.KCC/kernel/protocols/deployment]]
- Butler calibration (KCC-FB-014): [[.KCC/kernel/protocols/accuracy-calibration]]
- Cells convention: [[.KCC/kernel/cells]]
- Workspace protocol: [[.KCC/kernel/protocols/workspace]]

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](./LICENSE).
