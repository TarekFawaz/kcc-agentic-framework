# KCC: Agentic AI Operating Model and Spec-Driven Workflow Framework

KCC helps software teams use AI coding agents without losing governance,
traceability, cost awareness, quality gates, or reusable learning.

[![Status: public alpha](https://img.shields.io/badge/status-public%20alpha-blue)](./docs/alignment-matrix.md)
[![License](https://img.shields.io/badge/license-see%20LICENSE-green)](./LICENSE)
[![Harnesses](https://img.shields.io/badge/harnesses-Codex%20%7C%20Claude%20Code%20%7C%20OpenCode%20%7C%20Ollama-informational)](#initialize-or-sync)


**Official KCC page:** [tikasway.dev/kcc](https://tikasway.dev/kcc)

![KCC animation: set up once with the kcc command line, then run the governed lifecycle from idea to deploy](./docs/diagrams/kcc-lifecycle.gif)

```text
kcc init -> kcc tailor -> idea -> interrogate -> spec -> budget -> plan -> budget -> implement -> test -> review -> merge -> deploy
```

KCC is local-first. The source of truth lives in `.KCC/`, and the framework
generates adapter surfaces for Codex CLI, Claude Code, OpenCode, generic
`.agents` bundles, and Ollama-backed runners.

> KCC exists to structurally compound intelligence without collapsing
> governance.

## Contents

- [What You Get](#what-you-get)
- [Quick Start](#quick-start)
- [How To Use KCC](./docs/how-to-use-kcc.md)
- [CLI Guide: install and use kcc](./CLI-Guide.md)
- [Release Notes 0.5.0](./releasenotes-2026-10-04.md)
- [kcc Command Reference](./docs/cli.md)
- [KCC Tools Reference](./docs/kcc-tools-reference.md)
- [Why KCC](#why-kcc)
- [How KCC Works](#how-kcc-works)
- [The KCC Model](#the-kcc-model)
- [Supported Harnesses](#supported-harnesses)
- [Repository Map](#repository-map)
- [Current Status](#current-status)
- [Learn More](#learn-more)
- [Contributing](#contributing)

## What You Get

| KCC gives you | Why it matters |
|---|---|
| Spec-driven lifecycle | Raw ideas become specs, plans, tests, reviews, and traceable implementation work. |
| Governance gates | Humans approve budget, confidence, toolchain, security, privacy, and scope decisions when needed. |
| Token Guard | Cost and token estimates appear before expensive planning or implementation. |
| Butler memory | Reusable decisions and patterns survive beyond a single agent context window. |
| Multi-harness adapters | One `.KCC` source generates Codex, Claude Code, OpenCode, generic, and Ollama surfaces. |
| `kcc` command line | One self-contained program for Windows, macOS, and Linux installs, upgrades, tailors, and runs the framework. |
| Context tailoring | `kcc tailor` keeps only the agents, skills, and dialects that fit your solution. |
| Scripted quality gates | Traceability, wave scope, implementation lock, and a production quality gate are tool results, not prose. |
| Auto-continue | `kcc run` detects a usage limit on any harness, waits for the reset, and resumes the run. |
| Git workflow | Branch, commit-message, pre-commit, and pre-push checks, plus CI and deploy pipeline templates. |
| Local MCP server | `kcc mcp` serves protocols by section, the gate tools, and every skill to any MCP-capable harness. |

## Quick Start

Install the `kcc` command line once per machine.

Windows:

```powershell
winget install Tikasway.KCC
```

macOS and Linux:

```bash
brew install tarekfawaz/kcc/kcc
```

No package manager? Use the script installers instead:

```powershell
irm https://raw.githubusercontent.com/TarekFawaz/kcc-agentic-framework/main/install.ps1 | iex
```

```bash
curl -fsSL https://raw.githubusercontent.com/TarekFawaz/kcc-agentic-framework/main/install.sh | sh
```

All of these need a published release (winget also needs the package to be
accepted in Microsoft's repository). Until then, build from `cli/` as
described in [CLI-Guide.md](./CLI-Guide.md).

Then, in any project folder:

```text
kcc init claude        # or codex | opencode | generic | ollama | all
kcc tailor             # fit the framework to this solution
kcc doctor
```

Open your harness and start with an idea:

```text
auto build a CLI that converts CSV to JSON
```

or drive the same lifecycle from the terminal, with automatic resume after a
usage limit:

```text
kcc run --input "build a CLI that converts CSV to JSON"
```

The binary carries the framework, so there is nothing to clone. Cloning this
repository and running `.KCC/tools/framework-init` still works and is the
offline path.

Step-by-step guide: [CLI-Guide.md](./CLI-Guide.md). Command reference:
[docs/cli.md](./docs/cli.md). What changed in this release:
[releasenotes-2026-10-04.md](./releasenotes-2026-10-04.md).

See [QUICKSTART.md](./QUICKSTART.md) for Claude Code, Codex CLI, OpenCode,
generic/Ollama, and Mac/Linux paths.

## Why KCC

Agentic AI is fast, but unmanaged speed creates new failure modes. KCC is
designed around preventing the most common ones:

| Failure | What it looks like | KCC's structural answer |
|---|---|---|
| **Fragmentation** | Every team builds its own incompatible agents, prompts, and conventions; nothing composes. | A shared **kernel** of contracts every cell honors, with capabilities promoted across teams. |
| **Invisible cost** | Token and time spend is unmeasured until the bill or the deadline arrives. | A **cost envelope** surface and the **Token Guard** meta-agent that estimates and gates spend before work runs. |
| **Untraceable decisions** | You cannot reconstruct why an agent did what it did. | A first-class **decision trace** surface and append-only backchannel + per-run trace sessions. |
| **Trapped knowledge** | What one agent learns dies in its context window. | The **Butler** meta-agent curates reusable memory; good local patterns are promoted into shared capabilities. |

The load-bearing claim: *the kernel does not run the cells - it defines the
contract they all honor.*

## How KCC Works

KCC wraps the agent workflow with evidence-producing roles:

| Role | What it contributes |
|---|---|
| Interrogators | Clarify problem, technical direction, UX, security, and infrastructure assumptions. |
| Architect | Produces ADRs, guardrails, quality gates, diagrams, and architecture depth. |
| Spec writer | Creates epic specs, story/enabler backlog files, and parallelization maps. |
| Planner | Converts specs into implementation plans and atomic test cases. |
| Implementer | Writes scoped code under the approved idea folder. |
| Verifier | Checks tests and acceptance criteria, then writes review evidence. |
| Butler + Token Guard | Preserve memory, traces, calibration signals, token estimates, and budget gates. |

## Who This Is For

This repo is for:

| Audience | What you get |
|---|---|
| Engineering leaders | A concrete model for governing agentic work across teams. |
| Platform teams | A reusable kernel/capability/cell structure for agent workflows. |
| Delivery teams | A local framework for moving from idea to implementation with human gates. |
| Contributors | A starting point for improving agents, skills, protocols, tools, and docs. |

If you only want to run the framework, start with [QUICKSTART.md](./QUICKSTART.md).
If you want to understand the operating-model claim, start here.

## Why Not Just Use Coding Agents Directly?

Individual agents can be fast. The hard organizational problem is making that
speed accountable, repeatable, and learnable. KCC adds the missing operating
surfaces around agentic work: specs, decision traces, confidence gates, token
budgets, specialist interrogators, test/review handoffs, and reusable memory.

## How KCC Differs

| Compared with | KCC's emphasis |
|---|---|
| Prompt libraries | Kernel contracts, traceability, and lifecycle gates instead of loose prompt reuse. |
| Single-agent coding assistants | Multi-agent role separation across idea, architecture, planning, implementation, verification, and memory. |
| Generic agent frameworks | Software-delivery governance: specs, backlogs, token budgets, confidence, and review artifacts. |
| Project templates | A reproducible local cell that generates harness-specific surfaces from one `.KCC` source of truth. |

## The KCC Model

Most AI adoption starts as individual productivity: better prompting, faster
coding, local automations, and personal workflows. That helps, but it does
not automatically create organizational learning.

KCC proposes a federated structure:

> One kernel. Many capabilities. Many cells.

| Layer | Purpose | Owner | Change pace |
|---|---|---|---|
| Kernel | Shared contracts, governance rules, schemas, confidence gates, cost envelopes, decision traces, maturity rules. | Kernel maintainers | Slow |
| Capabilities | Reusable agents, skills, hooks, evaluations, and patterns that conform to the kernel. | Capability maintainers | Medium |
| Cells | Team-owned compositions of kernel + selected capabilities + local additions. This is where work ships. | Delivery teams | Fast |

The kernel does not run the teams. It defines the rules of the road. Cells
stay local and autonomous, but they emit evidence: traces, decisions, costs,
confidence signals, failures, and patterns. Over time, good local patterns
can be promoted into reusable capabilities.

## The Agent Contract: Nine Surfaces

Every KCC capability honors a kernel-defined agent contract. Seven surfaces are
operational; the last two are the distinctive KCC contribution - **cognitive**
surfaces that few agent frameworks treat as first-class, kernel-enforced fields.

| # | Surface | Kind | What it declares |
|---|---|---|---|
| 1 | Identity | Operational | Who the agent is and what role it fills. |
| 2 | Input schema | Operational | What it accepts. |
| 3 | Output schema | Operational | What it returns. |
| 4 | Declared tools | Operational | Which tools it may use. |
| 5 | Cost envelope | Operational | Its token/blast-radius budget. |
| 6 | HITL / HOTL | Operational | When a human must be in or on the loop. |
| 7 | Observability | Operational | What evidence it must emit. |
| 8 | **Confidence** | Cognitive | A computed confidence score per turn, gated against a threshold. |
| 9 | **Decision trace** | Cognitive | A replayable record of why it decided what it did. |

Two **meta-agents** enforce the contract across every turn: **Token Guard**
(cost envelope, surface 5) and **Butler** (memory, calibration, and trace
custody). Both run at the cheapest model class to keep overhead low.

## What This Repo Is

This repository is one example cell with the kernel and capabilities included
locally:

| Area | Role |
|---|---|
| `.KCC/kernel/` | Source of truth for contracts, protocols, adapters, templates, dialects, and governance docs. |
| `.KCC/capabilities/` | Source of truth for local reusable agents and skills. |
| `.KCC/tools/` | Init, sync, validation, gate, continuity, git, migration, backchannel, and session tools. |
| `cli/` | Source of the `kcc` command line; it embeds `.KCC/` when built. |
| Root docs | Public explanation, quick start, contribution docs, and project policy. |

Generated harness folders such as `.claude/`, `.codex/`, `.opencode/`,
`.agents/`, and `ollama/` are **local output**, not source. They are adapter
surfaces generated from `.KCC/` when the user initializes or syncs the
framework.

## Current Status

| Surface | Current state |
|---|---|
| Framework release | 0.5.1 (implements the KCC v0.4 operating-model specification) |
| Source agents | 18 |
| Source skills | 25 |
| Dialects | 26 |
| Command line | `kcc` 0.5.1: Windows x64, macOS arm64/x64, Linux x64/arm64 |
| Harness adapter targets | Claude Code, Codex CLI, OpenCode, generic `.agents`, Ollama |
| Structural validation | Passing with 0 errors and 0 warnings (PowerShell + bash, cell + repo modes) |
| Current maturity | Public alpha / field-pilot reference implementation |

The detailed implementation status lives in
[docs/alignment-matrix.md](./docs/alignment-matrix.md).

## Lifecycle

The cell moves work through a fixed lifecycle:

```text
interrogate -> create -> estimate -> plan -> estimate -> implement -> test -> review -> merge -> deploy
```

`merge` (`/spec-merge`) and `deploy` (`/spec-deploy`) are optional steps a
human starts after an approved review. A human can report a defect at any
point with `/bug-report`; it becomes a Bug backlog item that goes through a
regression test, the fix, and the same gates.

The animated lifecycle view is shown near the top of this README. Editable
diagram sources live in [docs/diagrams/](./docs/diagrams/).

## Operating Scenarios

The framework supports human-led and Human On The Loop modes:

| Operating scenario | Trigger | Behavior |
|---|---|---|
| Default HOTL | `auto <idea>` | Starts with human interrogation, then runs until a required gate is hit. |
| Full hand-off HOTL | `auto <idea> --silent --assume` | Agents make allowed decisions and document assumptions. Stops only on safety, confidence, loop, or prohibited-assumption gates. |
| Controlled hand-off HOTL | `auto <idea> --silent --assume --accuracy 99% --budget 200` | Full hand-off with explicit confidence and budget controls. |
| Direct HITL | `/idea-interrogator <idea>` | Human-led idea interrogation. |
| Individual skills | `/spec-create`, `/spec-plan`, etc. | Human starts at a specific lifecycle step. |

`auto` is the main HOTL entrypoint. It is not permission to skip governance.
Fresh ideas still start with interrogation unless the user explicitly chooses
full hand-off mode.

Add `--parallel` to any of these to force parallel agent sessions - spec
creation fans out one subagent per epic, and parallel windows open without the
per-spec prompt (e.g. `auto <idea> --parallel`). See
[QUICKSTART.md](./QUICKSTART.md#the-auto-skill-in-depth).

## Source Package vs Generated Output

The public source package should contain the framework source and docs:

```text
.KCC/
|-- kernel/
|-- capabilities/
|-- tools/
|-- sandbox/
`-- settings.json

cli/
install.ps1
install.sh
CLI-Guide.md
releasenotes-2026-10-04.md
README.md
QUICKSTART.md
example-solutions.md
CONTRIBUTING.md
CODE_OF_CONDUCT.md
SECURITY.md
MAINTAINERS.md
LICENSE
docs/
```

Expected local output after init/sync:

```text
AGENTS.md
CLAUDE.md
.claude/
.codex/
.opencode/
.agents/
ollama/
memory/
coordination/
architecture/
solution/
ideation/
specs/
Traces/
migrations/
src/
```

Generated output is ignored by default. If this public repo needs to show a
captured example of generated output later, publish it as a curated document
under `docs/` instead of committing live harness folders at the root.

## Repository Map

| Path                                   | Description                                                                                         |
| -------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `.KCC/kernel/`                         | KCC governance: contracts, protocols, adapters, templates, dialects, cells, inspector, phase model. |
| `.KCC/capabilities/agents/`            | Neutral source files for lifecycle, specialist, meta, and utility agents.                           |
| `.KCC/capabilities/skills/`            | Neutral source files for slash-command style skills.                                                |
| `.KCC/tools/`                          | Canonical tool entrypoints for Windows PowerShell and Mac/Linux bash.                               |
| `.KCC/sandbox/`                        | Docker sandbox files and sandbox runtime docs.                                                      |
| `cli/`                                 | The `kcc` command line (TypeScript, built into self-contained binaries with Bun).                   |
| `install.ps1`, `install.sh`            | Script installers for Windows and for macOS/Linux (winget and Homebrew are the package-manager routes). |
| `CLI-Guide.md`                         | Installing and using `kcc`, step by step, with troubleshooting.                                     |
| `releasenotes-2026-10-04.md`           | Release 0.5.0: what is new, breaking changes, known limits.                                         |
| `docs/cli.md`                          | `kcc` command reference: init, tailor, upgrade, doctor, run, limits, mcp, tool.                     |
| `docs/tailoring.md`                    | How to fit the framework to a solution.                                                             |
| `docs/mcp.md`                          | The local MCP server.                                                                               |
| `docs/git-workflow.md`                 | Branching, commit, hook, and pipeline conventions.                                                  |
| `docs/upgrade-v0.5.md`                 | What changed in release 0.5.0 and how to upgrade an existing cell.                                  |
| `docs/how-to-use-kcc.md`               | Scenario guide for fresh ideas, existing solutions, and adapting workflows.                         |
| `docs/kcc-tools-reference.md`          | PowerShell and bash tool reference with arguments and examples.                                     |
| `docs/agentic-ai-operating-model.md`   | Search-friendly overview of the KCC operating-model claim.                                          |
| `docs/spec-driven-ai-development.md`   | How KCC structures AI-assisted delivery around specs and evidence.                                  |
| `docs/ai-agent-governance.md`          | Governance surfaces: cost, confidence, traces, toolchain gates, and memory.                         |
| `docs/kcc-vs-agent-frameworks.md`      | How KCC differs from prompt libraries, coding assistants, and agent frameworks.                     |
| `docs/codex-claude-opencode-ollama.md` | Harness adapter overview for Codex, Claude Code, OpenCode, generic, and Ollama.                     |
| `docs/alignment-matrix.md`             | Honest status matrix against the KCC v0.4 operating-model primitives.                               |
| `docs/diagrams/`                       | Animated GIF, Mermaid, and draw.io sources.                                                         |
| `QUICKSTART.md`                        | Guided first run.                                                                                   |

## Supported Harnesses

| Harness | Generated local output |
|---|---|
| Codex CLI | `.codex/agents/`, `.codex/skills/`, `.codex/tools/` |
| Claude Code | `.claude/agents/`, `.claude/skills/` |
| OpenCode | `.opencode/agents/`, `.opencode/commands/`, `.opencode/skills/` |
| Generic | `.agents/agents/`, `.agents/skills/`, `.agents/tools/` |
| Ollama | `ollama/agents.json`, `ollama/README.md` |

## Initialize or Sync

With the command line:

```text
kcc init codex
kcc sync
kcc validate
kcc upgrade
```

With the scripts (offline, or from a clone of this repository), Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 -Harness codex
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
powershell -ExecutionPolicy Bypass -File .KCC\tools\validate-kcc.ps1
```

Mac/Linux:

```bash
bash .KCC/tools/bootstrap-mac-linux.sh
bash .KCC/tools/framework-init.sh codex
bash .KCC/tools/sync-adapters.sh
bash .KCC/tools/validate-kcc.sh
```

Supported harness values:

```text
claude | codex | opencode | generic | ollama | all
```

## Important Concepts

| Concept | Meaning |
|---|---|
| Cell | A team-owned composition of kernel, selected capabilities, and local additions. This repo is one cell. |
| Adapter surface | Generated harness-specific output for a cell, such as `.codex/` or `.claude/`. |
| Capability | A reusable agent or skill that follows kernel contracts. |
| Gate | A required stop for human approval, budget, confidence, safety, or scope. |
| Trace | A session-level record of actions, tools, decisions, handovers, and token usage. |
| Butler | Meta-agent responsible for memory and calibration signals. |
| Token Guard | Meta-agent responsible for cost estimates and budget gates. |

## What Is Not Implemented Yet

This repo is intentionally honest about its gaps. The main deferred areas are:

- trace-driven Inspector automation
- tracker adapters for Jira, Azure DevOps, Asana, Linear, and GitHub Issues
- real Mac/Linux host validation for the native bash path and for the
  macOS/Linux `kcc` binaries (the release workflow builds and smoke-tests
  them; they have not been exercised on real projects)
- multi-cell rollout examples across separate team repos
- an organisation-shared registry of capabilities and policy (the MCP server
  is local to each developer)
- live winget and Homebrew channels: the release workflow prepares the
  winget manifest and the Homebrew formula, but the tap repository, the
  publishing secrets, and Microsoft's acceptance of the package are still
  outstanding; there is no npm package
- turnkey deployments: the CI and deploy pipeline templates are starting
  points with placeholders

## Learn More

| Topic | Start here |
|---|---|
| How to use KCC | [docs/how-to-use-kcc.md](./docs/how-to-use-kcc.md) |
| Installing and using `kcc` | [CLI-Guide.md](./CLI-Guide.md) |
| Release notes 0.5.0 | [releasenotes-2026-10-04.md](./releasenotes-2026-10-04.md) |
| `kcc` command reference | [docs/cli.md](./docs/cli.md) |
| Tailoring to a solution | [docs/tailoring.md](./docs/tailoring.md) |
| Local MCP server | [docs/mcp.md](./docs/mcp.md) |
| Git workflow and pipelines | [docs/git-workflow.md](./docs/git-workflow.md) |
| Upgrading to 0.5.0 | [docs/upgrade-v0.5.md](./docs/upgrade-v0.5.md) |
| Script tools | [docs/kcc-tools-reference.md](./docs/kcc-tools-reference.md) |
| Agentic AI operating model | [docs/agentic-ai-operating-model.md](./docs/agentic-ai-operating-model.md) |
| Spec-driven AI development | [docs/spec-driven-ai-development.md](./docs/spec-driven-ai-development.md) |
| AI agent governance | [docs/ai-agent-governance.md](./docs/ai-agent-governance.md) |
| KCC vs agent frameworks | [docs/kcc-vs-agent-frameworks.md](./docs/kcc-vs-agent-frameworks.md) |
| Codex, Claude Code, OpenCode, and Ollama | [docs/codex-claude-opencode-ollama.md](./docs/codex-claude-opencode-ollama.md) |

## Contributing

Contributions should improve either:

1. the KCC operating-model implementation,
2. the local-cell developer experience,
3. the quality of agents, skills, protocols, and dialects,
4. the validation and evidence story, or
5. the clarity of public docs.

Start with [CONTRIBUTING.md](./CONTRIBUTING.md) and
[MAINTAINERS.md](./MAINTAINERS.md).

## Project Links

- GitHub repository: https://github.com/TarekFawaz/kcc-agentic-framework
- Website: https://tikasway.dev
- KCC v0.4 public specification: https://tikasway.dev/kcc

## License

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](./LICENSE).
