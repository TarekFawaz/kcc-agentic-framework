---
title: Plan - KCC distribution, CLI, MCP server, and tailored frameworks
tags:
  - kcc/plan
  - distribution
  - mcp
created: 2026-09-21
updated: 2026-09-21
version: 0.2.0
status: ready-to-run
---

# Plan: from "copy `.KCC/`" to CLI + MCP + tailored frameworks

## 1. Problem

Today every project vendors the full `.KCC/` (~1.5 MB, ~190 files) and runs the
scripts. The costs:

- **Drift and painful upgrades.** A single improvement round touched 86 files,
  and each project is effectively a fork.
- **Token waste.** Agents and protocols are generic. Every project carries
  every dialect and every protocol, even though a React + Node project never
  needs the embedded-C dialect.
- **Friction.** Installing means clone, copy, script, and each harness is
  configured separately.

## 2. Options evaluated

| Option | Pros | Cons | Verdict |
|--|--|--|--|
| A. Vendored `.KCC/` (today) | Offline, auditable, hooks just work | Drift, manual upgrades, repo bloat, forks | Keep as the **offline mode** only |
| B. Versioned package + `kcc` CLI (npm `npx kcc`, or `uvx kcc`) | Pinned versions, `kcc upgrade` with merge, one command installs | Still writes generated files into the repo (that's fine and needed) | **Yes: the foundation** |
| C. Local MCP server (stdio), shipped in the same package | No kernel copy; section-addressable resources (cheaper lazy reads); one server for Claude Code, Codex, and OpenCode; tools callable by any harness | Can't register subagents, hooks, or the status line (those stay as local files); MCP tool output also costs context | **Yes: the delivery layer** |
| D. Hosted remote MCP (HTTP) | Zero install, org-wide policy, telemetry | Can't see the local workspace, so the gates must run locally anyway; trust and security (code + repos); latency; infra cost | **Later, read-only content and policy only** |
| E. GitHub template repo | Easy first start | No upgrade path | Nice extra, not a strategy |
| F. LangGraph / Agent SDK orchestrator | Durable server-side runs | API-key billing, loses the harness-native tools | **Optional adapter** that reuses `kcc-run` semantics |

**Recommendation: a layered hybrid.** Ship KCC as a versioned package with a
`kcc` CLI and a **local** MCP server, write a thin generated footprint into
each project, and add tailoring. Keep the vendored mode for air-gapped teams.
Hosted MCP comes later and is limited to read-only content and policy. It
never executes anything against user repos.

## 3. Target architecture

```text
kcc package (npm / uvx, versioned, signed)
|-- kernel/ + capabilities/ + tools/        <- the same source of truth as .KCC today
|-- cli: kcc init | sync | tailor | upgrade | doctor | vendor | run | hook
`-- mcp server (stdio): resources + tools + prompts (thin wrappers over tools/)

project (thin footprint)
|-- .kcc/kcc.lock          <- version, harnesses, tailoring manifest, file checksums
|-- .kcc/settings.json     <- repo, quality, continuity, run, spec_sizing
|-- .claude/ .codex/ .opencode/ .agents/  <- generated, tailored adapters
|-- CLAUDE.md / AGENTS.md  <- lean entrypoints + project block
|-- .mcp.json (and harness equivalents)   <- registers `kcc mcp`
`-- ideation/ specs/ architecture/ coordination/ Traces/ memory/ src/  <- runtime, as today
```

**What must stay local** regardless of the delivery model: hooks and the
status line (they run `kcc hook <name>`), subagent files, git, run state,
gate execution, and scanners. None of these can live on a remote server.

## 4. MCP surface (local stdio)

| Kind | Items | Why |
|--|--|--|
| Resources | `kcc://protocol/{name}#{heading}`, `kcc://dialect/{name}`, `kcc://template/{name}`, `kcc://agent/{name}/ref/{topic}` | Section-level reads: an agent pulls one heading, never a whole protocol. Formalises the lazy-read rule. |
| Tools | `kcc_check(scope, spec)`, `kcc_traceability`, `kcc_wave_scope`, `kcc_impl_lock`, `kcc_quality_gate`, `kcc_checkpoint`, `kcc_handover`, `kcc_run(start\|resume\|answer\|status)`, `kcc_validate`, `kcc_tailor`, `kcc_upgrade_plan` | Wrap the existing `.ps1`/`.sh` tools and return their contract JSON. No logic is duplicated. |
| Prompts | Each skill (`auto`, `bug-report`, `spec-plan`, ...) | A fallback for harnesses without file-based skills. In Claude Code they appear as `/mcp__kcc__<skill>`. |

Security: stdio only, no network by default, `kcc_quality_gate` scanner
installs remain human-gated, and tools that run shell commands are marked
for the lethal-trifecta review.

## 5. Context-tailored framework (`kcc tailor`)

Inputs: the `/solution-onboard` baseline (stack, repos, deployables), the
chosen harnesses, team policy (coverage floor, scanners, gates), and project
size.

Outputs:

- **Pruned capabilities:** only the relevant dialects and specialist agents
  (no infra planner for a library, no UX designer for a CLI).
- **Tailored agent bodies:** stack-specific commands and conventions baked
  in, with irrelevant protocol pointers removed. This makes system prompts
  smaller per spawn.
- **Tailored gates:** quality-gate commands per detected stack, coverage
  floor, QG-PROD applicability.
- **Project block** in `CLAUDE.md` / `AGENTS.md` (goal, constraints,
  context-loading table), drafted from onboarding.
- **`kcc.lock`** records the tailoring manifest, so `kcc upgrade` can
  re-tailor after a framework update without losing local edits (three-way
  merge: base checksum, new version, local).

## 6. Phases

| Phase | Scope | Exit criteria |
|--|--|--|
| P0 Hardening | Port the 2026-09-21 upgrade; turn the dev fixtures into a test suite; CI matrix Windows/macOS/Linux x PS 5.1/pwsh/bash; tag v0.5 | All tool tests green on 3 OSes |
| P1 Package + CLI | `kcc init/sync/upgrade/doctor/vendor/run/hook`, `kcc.lock`, three-way merge upgrade, offline `vendor` | Install < 2 min; upgrade without a manual merge; `doctor` detects drift |
| P2 Local MCP | Resources, tools, and prompts above; `kcc init --mcp` registers the server for each harness | The same run works in Claude Code, Codex, and OpenCode through MCP |
| P3 Tailoring | `kcc tailor` from the onboarding baseline; tailored agents, gates, and entrypoints | Measurable cut in tokens per spawn against the generic build |
| P4 (optional) Hosted registry | Versioned capability packs, org policy overlays, signed releases; read-only remote MCP | Org can enforce policy across repos |
| P5 (optional) Server adapter | LangGraph or Claude Agent SDK runner using `auto-states.json` + `kcc-run` semantics | Durable server-side runs for teams that want them |

## 7. Decisions needed

1. **Runtime for CLI + MCP:** TypeScript/npm (mature MCP SDK; Claude Code and
   Codex users already have Node) is recommended. Python/uvx is the
   alternative.
2. **Keep the scripts as the source of truth,** with the CLI and MCP wrapping
   them (recommended), or port the logic into the CLI language.
3. **Vendored mode:** keep `kcc vendor` for offline and air-gapped teams
   (recommended).
4. **Hosted services (P4):** open source vs commercial; telemetry strictly
   opt-in.
5. **Package names and registry ownership** (`kcc` may be taken; check npm
   and PyPI).

## 8. Epics and acceptance criteria (input for `auto` / `kcc-run`)

Each epic is sized to spec-layout v6. The spec-writer may split them further
(SZ-1..5); it never merges them.

| Epic | Phase | Delivery (smallest user value) | Acceptance criteria |
|--|--|--|--|
| E1 Test harness | P0 | Maintainers can prove every tool works on 3 OSes | AC-1 the fixture suites (valid + broken) for every `.KCC/tools` check run in CI on Windows/macOS/Linux under PS 5.1, pwsh, and bash. AC-2 the PS and bash results match (same exit codes and violation IDs). AC-3 the release is tagged v0.5 with the upgrade notes. |
| E2 `kcc` CLI core | P1 | A user installs KCC in one command | AC-1 `npx kcc init [harness]` produces the same outputs as `framework-init`. AC-2 `.kcc/kcc.lock` records the version, harnesses, and checksums. AC-3 install completes in under 2 minutes on a clean machine. |
| E3 Upgrade + doctor | P1 | A user upgrades without a manual merge | AC-1 `kcc upgrade` three-way merges base / new / local and reports conflicts without overwriting. AC-2 `kcc doctor` exits 1 on drift or a missing hook and names the fix. AC-3 `kcc vendor` writes a full offline `.KCC/`. |
| E4 Local MCP server | P2 | Any harness uses KCC through MCP | AC-1 section-addressable `kcc://` resources return only the requested heading. AC-2 each tool in section 4 returns the tool-contract JSON by wrapping the existing scripts. AC-3 skills are exposed as prompts. AC-4 `kcc init --mcp` registers the server for Claude Code, Codex, and OpenCode. AC-5 no network by default. |
| E5 Tailoring | P3 | A project gets a framework fitted to its stack | AC-1 `kcc tailor` reads the onboarding baseline and prunes dialects and agents. AC-2 tailored gates and quality commands match the detected stack. AC-3 tokens per spawn are measurably lower than the generic build (reported). AC-4 `kcc upgrade` re-tailors while keeping local edits. |
| E6 Hosted registry (optional) | P4 | An org enforces policy across repos | AC-1 read-only remote MCP serves signed capability packs and policy overlays. AC-2 it never executes code against a user repo. AC-3 telemetry is opt-in. |
| E7 Server adapter (optional) | P5 | A team runs KCC server-side | AC-1 a LangGraph or Agent SDK runner executes `.KCC/kernel/auto-states.json` with the `kcc-run` semantics (the same gates, exit codes, and restore points). |

## 9. How to run this plan in the KCC repo

1. Port the 2026-09-21 upgrade first (`.KCC/UPGRADE-2026-09-21.md`). The
   plan relies on spec layout v6, the scripted gates, and `kcc-run`.
2. Copy this file to `docs/plans/PLAN-distribution-mcp.md` in the KCC repo.
3. Answer the section 7 decisions (edit the file). Unanswered decisions
   become human gates in the run.
4. Start the run in one of two ways:
   - **Interactive (recommended for the first pass):** in Claude Code, run
     `auto docs/plans/PLAN-distribution-mcp.md`. The folder/file input makes
     the idea-interrogator treat it as the idea source and the epic table as
     the phases. Answer the gates as they come.
   - **Deterministic driver:** `powershell -File .KCC\tools\kcc-run.ps1
     -Input docs/plans/PLAN-distribution-mcp.md` (or `bash
     .KCC/tools/kcc-run.sh --input ...`). Add `-Silent -Assume -Budget NN` for
     a hands-off run within a budget.
5. Scope control: to run only P0 + P1 first, add a line `Scope for this run:
   E1, E2, E3` at the top of section 8. The spec-writer then creates only
   those specs, and CR-13 stops the rest being dropped silently: they stay
   in `ROADMAP.md` as later waves.
