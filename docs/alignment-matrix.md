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
updated: 2026-06-08
version: 2.1.0
status: active
---

# KCC v0.4 Alignment Matrix

This file is the honest implementation contract between the KCC v0.4
operating-model doctrine and this repository's current local-cell example.

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

The three pilots mentioned in the README - csvtojson CLI plus two games -
predate the current v1.x framework refactor. The lifecycle concept is
pilot-proven, but the current implementation is **not yet re-exercised**, which
is why no row is 🟢 Exercised today.

## Matrix

| v0.4 primitive                        | Status                                          | Where it lives / what is proven                                                                                                                                                                                                                                                                                                       |
| ------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kernel, slow shared contract          | 🟢 Exercised                                    | `.KCC/kernel/`; structure enforced by `validate-kcc.ps1` and `validate-kcc.sh`.                                                                                                                                                                                                                                                       |
| Capabilities, versioned reusable      | 🟢 Exercised                                    | `.KCC/capabilities/`; **17 agents and 22 skills**; presence, maturity, and maintainer metadata are validator-enforced.                                                                                                                                                                                                                |
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
| Accuracy calibration loop             | 🟡 Scaffolded                                   | Accuracy-calibration protocol, Butler Mode D, and backchannel events are defined; no drift data yet.                                                                                                                                                                                                                                  |
| Lethal Trifecta detector              | 🔵 Validated                                    | Detector runs in `validate-kcc.ps1`; automatic sandbox engagement is scaffolded.                                                                                                                                                                                                                                                      |
| Docker sandbox runtime                | 🟡 Scaffolded                                   | `.KCC/sandbox/`, sandbox-runtime protocol, and `start-agent-session` support exist; images not yet built or run in CI.                                                                                                                                                                                                                |
| Inspector Pipeline, five stages       | 🟡 Scaffolded                                   | `.KCC/kernel/inspector/` stage docs exist; basic detect/propose in `kcc-inspect.ps1`; full automation deferred.                                                                                                                                                                                                                       |
| Maturity ladder, L1/L2/L3             | 🔵/🟡 Validated (presence) / Scaffolded (gates) | Every capability declares maturity; promotion gates are not built.                                                                                                                                                                                                                                                                    |
| Capability maintainer                 | 🔵 Validated                                    | Every capability declares `maintainer:` and validation enforces it.                                                                                                                                                                                                                                                                   |
| Phase model                           | 🟡 Scaffolded                                   | `.KCC/kernel/phase-model.md`; self-assessed at Phase 1.8. Defined, not enforced.                                                                                                                                                                                                                                                      |
| Architecture docs always-on           | 🟡 Scaffolded                                   | Architecture-documentation protocol plus architect requirements; not re-piloted.                                                                                                                                                                                                                                                      |
| Progress tracking                     | 🔵 Validated                                    | `progress.md`, `specs/specs.md`, `ideation/ideas.md`, and progress-tracking protocol exist.                                                                                                                                                                                                                                           |
| Deploy lifecycle stage                | 🟡 Scaffolded                                   | `spec-deploy`, `infrastructure-implementer`, and deployment protocol exist; pipeline templates deferred.                                                                                                                                                                                                                              |
| Mac/Linux native bash path            | 🟡 Scaffolded                                   | Native bash scripts present; `validate-kcc.sh` now runs clean (cell + repo, 0/0); full tool parity still needs a real macOS/Linux host.                                                                                                                                                                                               |
| Native CLI                            | 🔴 Planned                                      |                                                                                                                                                                                                                                                                                                                                       |
| Butler behavior-based trust scoring   | 🟡 Scaffolded                                   | Calibration loop defined; trust-ladder automation not built.                                                                                                                                                                                                                                                                          |
| Workslop detection                    | 🔴 Missing                                      | Needs trace data.                                                                                                                                                                                                                                                                                                                     |
| Inspector Pipeline automation         | 🔴 Missing                                      | Needs real trace data for honest rules.                                                                                                                                                                                                                                                                                               |


### Capabilities beyond the original v0.4 list (now folded into the doctrine)

| Capability                            | Status        | Where it lives / what is proven                                                                                                                                                                                      |
| ------------------------------------- | ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Architecture critic + review          | 🟢 Exercised  | `architecture-critic` agent + `architecture-review` skill; present and generate across harnesses.                                                                                                                    |
| Dashboard generation                  | 🟢 Exercised  | `dashboard` skill + `build-dashboard.{ps1,sh}` emit a self-contained offline `dashboard/index.html`.                                                                                                                 |
| Inspector skill (detect/propose)      | 🔵 Validated  | `inspect` skill + `kcc-inspect.ps1` mine real backchannel/trace/test signals into proposal stubs; never fabricate patterns.                                                                                          |
| Dual-mode validator + corruption scan | 🟢 Exercised  | `validate-kcc.{ps1,sh}` support `cell` (default) and `repo` modes plus control-char / mojibake / mid-file-BOM scanning. Both validators pass 0/0 in cell and repo modes.                                             |
| Dashboard auto-refresh                | 🟡 Scaffolded | `backchannel-append.ps1` best-effort rebuilds the dashboard after each event (`-NoDashboard` / `KCC_SKIP_DASHBOARD=1` to opt out); not pilot-exercised.                                                              |
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

As of 2026-06-07:

| Check | Result |
|---|---|
| `.KCC/tools/validate-kcc.ps1` (cell) | 0 errors, 0 warnings |
| `.KCC/tools/validate-kcc.ps1 -Mode repo` | 0 errors, 0 warnings |
| `.KCC/tools/validate-kcc.sh` (cell) | 0 errors, 0 warnings |
| `.KCC/tools/validate-kcc.sh --mode repo` | 0 errors, 0 warnings |
| Source agents | 17 |
| Source skills | 22 |
| Codex generated surface | 17 agents, 22 skills |
| Generic generated surface | 17 agents, 22 skills |

Re-run validation after any kernel or capability edit.

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](../LICENSE).
