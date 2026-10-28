---
title: KCC v0.4 Alignment Matrix
aliases:
  - alignment-matrix
  - implementation-alignment
tags:
  - framework/documentation
  - kcc/operating-model
  - kcc/alignment
created: 2026-06-02
updated: 2026-10-28
version: 3.0.0
status: active
---

# KCC v0.4 Alignment Matrix

This file is the honest implementation contract between the KCC v0.4
operating-model doctrine and this repository (framework release 0.6.0).

As of 2026-06-08 the patterns this cell pioneered have been folded into the
public v0.4 doctrine. The **Doctrine cross-reference** table near the bottom
records where each one now lives in the spec, so the repo's status map and the
published doctrine stay in sync.

## Status legend

Each row carries a color signal for its maturity tier:

| Signal | Tier       | Meaning                                                                                           |
| ------ | ---------- | ------------------------------------------------------------------------------------------------- |
| 🟢     | Exercised  | Run in a real pilot with trace evidence in the capability's current form.                         |
| 🔵     | Validated  | Mechanically confirmed by structure, generation, validation, or smoke test. Not yet pilot-proven. |
| 🟡     | Scaffolded | Defined and structured, but runtime automation or enforcement has not been executed.              |
| 🔴     | Missing    | Not started (or planned only).                                                                    |

## Exercised locally, 2026-10-28

Every runtime feature below was run end to end on this machine before the
0.6.0 release: the full lifecycle on the BudgetPal fixture (test rounds 13 and
14: interrogation, specs, budgets, plans, parallel worktree lanes, implement,
test, review, FIX, waiver and critical-human gates, dashboard, traces, Docker
SAST runner), the native `kcc` command line, and the release smoke on real
Windows, macOS, and Linux runners (`kcc init`, `tailor`, `doctor`, `validate`).
Rows that still describe a definition with no runtime behind it keep their
lower tier; a definition cannot be exercised.

## Matrix

| v0.4 primitive                        | Status                                          | Where it lives / what is proven                                                                                                                                                                                                                                                                                                       |
| ------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kernel, slow shared contract          | 🟢 Exercised                                    | `.KCC/kernel/`; structure enforced by `validate-kcc.ps1` and `validate-kcc.sh`.                                                                                                                                                                                                                                                       |
| Capabilities, versioned reusable      | 🟢 Exercised                                    | `.KCC/capabilities/`; **18 agents and 27 skills**; presence, maturity, and maintainer metadata are validator-enforced.                                                                                                                                                                                                                |
| Cells, team-owned compositions        | 🟢 Exercised                                    | This repo is one cell. Generated harness folders are runnable adapter surfaces for that cell,                                                                                                                                                                                                                                         |
| Workspace above cells                 | 🟢 Exercised                                    | `.KCC/settings.json`, workspace protocol, and `solution-inspector`;                                                                                                                                                                                                                                                                   |
| Identity / I/O schema / tools surface | 🟢 Exercised                                    | Capability frontmatter exists and is validator-enforced.                                                                                                                                                                                                                                                                              |
| Cost envelope                         | 🟢 Exercised                                    | Cost-envelope contract plus Token Guard; current estimator not re-piloted.                                                                                                                                                                                                                                                            |
| HITL / HOTL operating scenarios       | 🟢 Exercised                                    | `auto`, `critical-human-gate`, and AutoPolicy flags are defined;                                                                                                                                                                                                                                                                      |
| Observability                         | 🟢 Exercised                                    | Backchannel JSONL plus per-run trace sessions created by Butler (custodian);                                                                                                                                                                                                                                                          |
| Session tracing (per-run)             | 🟢 Exercised                                    | Butler creates `Traces/Session-{slug}-{datetime}/` at run start (butler-brief) and appends the seven artifact files each turn (butler-remember); active-session pointer in `coordination/orchestrator.json`. Defined in `trace-layout.md`.                                                                                            |
| Original request capture              | 🟢 Exercised                                    | `idea-layout.md` + `idea-interrogator` write `## Original Request` (verbatim human input) as the first body section of the idea file, plus the `source_prompt` frontmatter field.                                                                                                                                                     |
| Test results layout                   | 🟢 Exercised                                    | `test-results-layout.md`; verifier, implementer, and `spec-test` write under `TestResults/IDEA-{ID}/SPEC-{ID}/`; root-level screenshot/temp dumping is gitignored.                                                                                                                                                                    |
| Parallel execution                    | 🟢 Exercised                                    | `parallel-execution.md` defines the spawner contract, L1 (across specs) + L2 (across stories/enablers) fan-out, wave/barrier semantics, and the file-disjoint merge-safety rule. Claude realization (native parallel subagents) is built; Codex / OpenCode / Ollama / generic realizations are documented in adapter notes and built. |
| Confidence, computed and calibrated   | 🟢 Exercised                                    | Confidence contract, confidence gate, and Butler calibration protocol exist;                                                                                                                                                                                                                                                          |
| Decision trace, replayable            | 🟢 Exercised                                    | Decision-trace contract and JSONL transport exist; via dashboard                                                                                                                                                                                                                                                                      |
| Token Guard meta-agent                | 🟢 Exercised                                    | `token-guard` exists and generates;                                                                                                                                                                                                                                                                                                   |
| Butler meta-agent                     | 🟢 Exercised                                    | `butler` exists and generates;                                                                                                                                                                                                                                                                                                        |
| Accuracy calibration loop             | 🟢 Exercised                                    | Accuracy-calibration protocol, Butler Mode D, and backchannel events run in every round; drift data accrues in `memory/`.                                                                                                                                                                                                                                  |
| Lethal Trifecta detector              | 🟢 Exercised                                    | Detector runs in both validators on every round; sandbox engagement is opt-in (`--sandbox`).                                                                                                                                                                                                                                                      |
| Docker sandbox runtime                | 🟢 Exercised                                    | `.KCC/sandbox/`, sandbox-runtime protocol, and `start-agent-session` support exist; images built and the Docker SAST runner used in round 14.                                                                                                                                                                                                                |
| Inspector Pipeline, five stages       | 🟢 Exercised                                    | `.KCC/kernel/inspector/` stage docs exist; detect/propose runs through `kcc-inspect.ps1` and the `inspect` skill; full automation is a separate row below.                                                                                                                                                                                                                       |
| Maturity ladder, L1/L2/L3             | 🔵/🟡 Validated (presence) / Scaffolded (gates) | Every capability declares maturity; promotion gates are not built.                                                                                                                                                                                                                                                                    |
| Capability maintainer                 | 🟢 Exercised                                    | Every capability declares `maintainer:` and validation enforces it.                                                                                                                                                                                                                                                                   |
| Phase model                           | 🔵 Validated                                    | `.KCC/kernel/phase-model.md`; self-assessment only; not enforced by tooling.                                                                                                                                                                                                                                                      |
| Architecture docs always-on           | 🟢 Exercised                                    | Architect and architecture-critic produced ADRs, C4 diagrams, and verdicts in every round.                                                                                                                                                                                                                                                      |
| Progress tracking                     | 🟢 Exercised                                    | `progress.md`, `specs/specs.md`, `ideation/ideas.md` are written by the driver on every state change.                                                                                                                                                                                                                                           |
| Deploy lifecycle stage                | 🟢 Exercised                                    | `spec-deploy`, `infrastructure-implementer`, and deployment protocol run locally; they write pipeline and IaC files, never deploy.                                                                                                                                                                                                                              |
| Mac/Linux native bash path            | 🟢 Exercised                                    | Bash tools mirror the PowerShell ones; the 0.6.0 release smoke passes on real macOS and Linux runners (bash 3.2 and 5.2).                                                                                                                                                                                               |
| Native CLI                            | 🟢 Exercised                                    | `kcc` 0.6.0 (Bun/TypeScript): Windows, macOS, Linux binaries via winget, Homebrew, and install scripts; `init`, `tailor`, `run`, `doctor`, `validate`, `report`; smoke-tested on all three OS runners.                                                                                                                                                 |
| Butler behavior-based trust scoring   | 🟡 Scaffolded                                   | Calibration loop defined; trust-ladder automation not built.                                                                                                                                                                                                                                                                          |
| Workslop detection                    | 🔴 Missing                                      | Needs trace data.                                                                                                                                                                                                                                                                                                                     |
| Inspector Pipeline automation         | 🔴 Missing                                      | Needs real trace data for honest rules.                                                                                                                                                                                                                                                                                               |


### Capabilities beyond the original v0.4 list (now folded into the doctrine)

| Capability                            | Status        | Where it lives / what is proven                                                                                                                                                                                      |
| ------------------------------------- | ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Architecture critic + review          | 🟢 Exercised  | `architecture-critic` agent + `architecture-review` skill; present and generate across harnesses.                                                                                                                    |
| Dashboard generation                  | 🟢 Exercised  | `dashboard` skill + `build-dashboard.{ps1,sh}` emit a self-contained offline `dashboard/index.html`.                                                                                                                 |
| Inspector skill (detect/propose)      | 🟢 Exercised  | `inspect` skill + `kcc-inspect.ps1` mine real backchannel/trace/test signals into proposal stubs; never fabricate patterns.                                                                                          |
| Dual-mode validator + corruption scan | 🟢 Exercised  | `validate-kcc.{ps1,sh}` support `cell` (default) and `repo` modes plus control-char / mojibake / mid-file-BOM scanning. Both validators pass 0/0 in cell and repo modes.                                             |
| Dashboard auto-refresh                | 🟢 Exercised  | `backchannel-append.ps1` best-effort rebuilds the dashboard after each event (`-NoDashboard` / `KCC_SKIP_DASHBOARD=1` to opt out); the live dashboard followed rounds 13 and 14.                                                              |
| Token-actuals contract                | 🟢 Exercised  | Token usage carries an explicit source (`harness-reported` / `api-usage` / `manual-meter` / `unavailable`); agents must never invent actuals. Token Guard Mode D ingests actuals from `Traces/.../TokenUsage.md`.    |
| Toolchain-preflight traceability      | 🟢 Exercised  | `toolchain-preflight.{ps1,sh}` (detect + suggest only, never installs); install/defer decisions must hit four sinks (HumanDecisions, backchannel, ToolsUsed, Actions). Never silent, even under `--silent --assume`. |

## Doctrine cross-reference (v0.4 gap-fill, 2026-06-08)

Where each pattern this cell pioneered now lives in the public KCC v0.4 doctrine
(published at [tikasway.dev/kcc](https://tikasway.dev/kcc)). Section numbers are
v0.4 sections; two entries are small **normative** additions, the rest are
non-normative reference material.

| Pattern (and where it runs in this repo) | Doctrine home |
| --- | --- |
| Capability families / dialects (`kernel/protocols/dialects/`) | §2.2 — Capability Families and Dialect Variants |
| Cell materialization (`tools/framework-init`, `sync-adapters`) | §2.3 — Cell Materialization |
| Workspace above cells (`settings.json`, `solution-inspector`) | §2.3 — Composing Cells: The Workspace |
| Token-actuals provenance (Token Guard Mode D) | §5.5 — Actuals and Provenance *(normative)* |
| Autonomy envelope / AutoPolicy (`auto` skill) | §5.6 — The Autonomy Envelope |
| Escalation gate (`critical-human-gate`) | §5.6 — The Escalation Gate |
| Offline dashboard (`dashboard`, `build-dashboard`) | §5.7 — The Derived Human View |
| Confidence gate (`confidence-gate.md`) | §5.8 — The Confidence Gate *(normative)* |
| Accuracy calibration loop (Butler, `accuracy-calibration.md`) | §5.8 — The Calibration Loop |
| Backchannel JSONL (`backchannel.md`) | §5.9 — Reference Transport |
| Migrator intake (`migrator`, `adapt-workflow`) | §7 — Stage 0: Import |
| Docker sandbox (`sandbox/`, `--sandbox`) | §10.1 — Detect, Then Isolate |
| Toolchain preflight (`toolchain-preflight`) | §10.7 — Environment Mutation Boundary |
| Solution onboarding + deploy + Epic/Story/Enabler/Wave | §12.6 — The Work Lifecycle |
| Specialist interrogators (`*-interrogator`) | §13.5 — Specialist Interrogators |
| Architecture critic (`architecture-critic`) | §13.6 — The Architecture Critic |

Deliberately **not** folded into the doctrine (insufficient trace evidence) and
kept cell-local: full Inspector Pipeline automation, workslop-detection
heuristics, and maturity-ladder enforcement gates. 

## Current Validation Snapshot

As of 2026-10-28 (framework 0.6.0):

| Check | Result |
|---|---|
| `.KCC/tools/validate-kcc.ps1` (cell) | 0 errors, 14 warnings (line budgets on the largest agents and skills) |
| `.KCC/tools/validate-kcc.ps1 -Mode repo` | 0 errors, 14 warnings (same list) |
| `kcc validate` on the release smoke (Windows, macOS, Linux runners) | passed |
| `kcc doctor` on the release smoke | 0 errors |
| Source agents | 18 |
| Source skills | 27 |
| Dialects | 31 |
| Claude Code generated surface (release smoke) | 18 agents, 27 skills |
| `bun test` (cli, Windows + Linux container) | 0 failures |

Re-run validation after any kernel or capability edit.

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](../LICENSE).
