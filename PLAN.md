---
title: KCC v0.4 Local Cell Plan
aliases:
  - plan
  - roadmap
  - future-activities
tags:
  - framework/documentation
  - roadmap
  - kcc/operating-model
created: 2026-06-02
updated: 2026-06-02
version: 1.0.0
status: active
---

# KCC v0.4 Local Cell Plan

This file records the future activities for this repository. It is not the
full KCC operating-model roadmap. It is the roadmap for this local-cell
reference implementation.

## Near Term

| Area | Activity | Why it matters |
|---|---|---|
| Public packaging | Ship source only: `.KCC/`, root Markdown, docs, and tool entrypoints. Keep generated harness folders out of the package. | Keeps the repo clean and reinforces `.KCC` as source of truth. |
| Generated-output examples | Use `output/` only for captured examples or release artifacts. Do not commit live `.claude/`, `.codex/`, `.opencode/`, `.agents/`, or `ollama/` roots. | Lets contributors inspect expected output without confusing it with source. |
| Operating scenarios | Re-pilot the default HOTL, full hand-off HOTL, and controlled hand-off HOTL scenarios against the current v1.x capabilities. | Moves alignment rows from Validated/Scaffolded toward Exercised. |
| Bash parity | Test native bash tools on real macOS and Linux hosts. | Confirms the framework is not Windows-only. |
| README assets | Replace any remaining text-heavy diagrams with maintained visual assets. | Makes the doctrine easier to understand publicly. |

## Framework Quality

| Area | Activity | Why it matters |
|---|---|---|
| Decision trace replay | Build a replay tool that reads traces, backchannel events, human decisions, handovers, and token usage together. | Makes agent work auditable, not just logged. |
| Backchannel viewer | Keep `show-backchannel` as the quick human-readable viewer; do not treat it as full replay. | Avoids overclaiming. |
| Maturity ladder gates | Implement L1 to L2 and L2 to L3 promotion gates with evidence requirements. | Turns maturity tags into governance. |
| Butler trust ladder | Automate behavior-based trust scoring from calibration and trace data. | Lets the system adapt confidence thresholds with evidence. |
| Workslop detection | Design detection only after enough trace data exists. | Avoids performative rules with no signal. |
| Inspector Pipeline automation | Automate Observe, Detect, Propose, Review, Promote after real runs exist. | Converts local learning into reusable capabilities. |

## Delivery Features

| Area | Activity | Why it matters |
|---|---|---|
| Pipeline templates | Add real CI/IaC templates by cloud and CI provider. | Makes `/spec-deploy` useful beyond stubs. |
| Tracker adapters | Implement Jira, Azure DevOps, Asana, Linear, and GitHub Issues adapters behind `.KCC/settings.json`. | Connects markdown-first progress to enterprise delivery tools. |
| Multi-cell rollout | Document and test separate team/domain repos that vendor `.KCC/kernel/` and `.KCC/capabilities/`. | Proves the "many cells" doctrine beyond one repo. |
| Existing-solution onboarding | Re-pilot `/solution-onboard` on a real multi-repo codebase. | Validates workspace topology and solution-inspector behavior. |
| Architecture artifacts | Re-pilot always-on architecture docs with minimal, standard, and deep depth settings. | Confirms diagrams are useful without becoming ceremony. |

## Tooling Roadmap

| Area | Activity | Target |
|---|---|---|
| Native bash | Maintain bash scripts for Mac/Linux without delegating to PowerShell. | Current slice plus host testing. |
| Native CLI | Build `kcc` under the planned `@tikasway/kcc` npm package. | v1.1+ |
| CLI parity | Init, sync, validate, and adapt parity first. | v1.1 |
| CLI expansion | Session, backchannel, and auto helpers. | v1.2 |
| CLI governance | Config, tracker, and calibration helpers. | v1.3 |
| PowerShell deprecation decision | Decide only after CLI and bash paths are mature. | v2.0 earliest |

## Evidence Needed

Before marking a capability as Exercised in
[`docs/alignment-matrix.md`](./docs/alignment-matrix.md), capture:

1. A real trace folder under `Traces/Session-{slug}-{datetime}/`.
2. Backchannel events for estimates, approvals, and confidence gates.
3. The generated idea/spec artifacts.
4. Budget forecast versus actual usage where available.
5. Human decisions that explain assumptions, overrides, or escalations.
6. A short retrospective describing what should be promoted, fixed, or
   rejected.

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](./LICENSE).
