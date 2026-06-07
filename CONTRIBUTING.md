---
title: Contributing to KCC
aliases:
  - contributing
  - contribution-guide
  - how-to-contribute
tags:
  - framework/documentation
  - entrypoint
  - kcc/v04
  - kcc/governance
created: 2026-05-25
updated: 2026-06-04
version: 1.4.0
status: active
related:
  - "[[MAINTAINERS]]"
  - "[[CODE_OF_CONDUCT]]"
  - "[[SECURITY]]"
  - "[[LICENSE]]"
  - "[[README]]"
---

# Contributing to KCC

Thanks for thinking about contributing. KCC is a structural operating
model with **three layers** (Kernel - Capabilities - Cells) and **three
contribution roles**. Match your change to the right layer first - that
determines who reviews it and how fast it moves.

If you're new here, read the alignment matrix in
[`docs/alignment-matrix.md`](./docs/alignment-matrix.md) first so you know
which v0.4 primitive your change touches and what state the framework is in
(currently **v1.4.0**, sitting at **Phase 1.8** on the KCC phase ladder).

---

## The three contribution roles

| Role | What you own | Authority | Cadence |
|--|--|--|--|
| **Kernel maintainer** (3-7 named) | Everything under `.KCC/kernel/` - contracts (cost-envelope, confidence, decision-trace, agent, skill), protocols (handover, backchannel, workspace, sandbox-runtime, deployment, accuracy-calibration, architecture-documentation, progress-tracking, lethal-trifecta, spec-layout, idea-layout, trace-layout, auto-mode, confidence-gate, obsidian-standard, adaptation-guide, token-budget, solution-onboarding, architecture-governance), dialects (23 stack-specific protocols), adapters (claude/codex/opencode/generic/ollama), templates (root entrypoints, ROI, C4, DFD, flowchart, pipelines, settings), cells doc, phase model, inspector spec | Veto on kernel changes; sponsors L2->L3 capability promotions; signs off on kernel ADRs; sets the framework version trajectory | Slow - quarterly minor, yearly major |
| **Capability maintainer** (one named owner per capability) | One or more files under `.KCC/capabilities/agents/` (17 agents) or `.KCC/capabilities/skills/` (22 skills) | Owns capability evolution within its frontmatter contract; promotes L1->L2 with evidence; coordinates breaking changes with kernel maintainers | Medium - weeks to months |
| **Cell team** (delivery team) | This cell's generated adapter surfaces (`.claude/`, `.codex/`, `.opencode/`, `.agents/`, `ollama/`) + team-local additions under `<surface>/local/` + their own `local/README.md` roster | Ships work; pins capability versions in `.KCC/settings.json` defaults; runs sandboxed sessions; manages cell-level secrets / deploy targets | Fast - weekly or faster |

Current roster: [`MAINTAINERS.md`](./MAINTAINERS.md). The default role
address `tarek.fawaz1983@gmail.com` holds open seats until individuals
claim them.

---

## Before you open a PR

1. **Read the alignment matrix** in
   [`docs/alignment-matrix.md`](./docs/alignment-matrix.md) so you know
   which v0.4 primitive your change touches and whether the change is a
   refinement of an existing primitive, a promotion (scaffold -> working),
   or closes a missing gap.

2. **Match your change to a layer**. If you're not sure, default to
   capability work. A maintainer will redirect to kernel or cell if
   needed. Cross-layer PRs are allowed but require a kernel maintainer.

3. **Run the validator** - PRs must keep it clean:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .KCC\tools\validate-kcc.ps1
   ```

   On Mac/Linux:

   ```bash
   .KCC/tools/validate-kcc.sh
   ```

   The validator enforces structural layout, every capability declares
   `maturity: L1|L2|L3` + `maintainer:`, the Lethal Trifecta detector
   doesn't flag any new agent without `confidence-gate: required`, and no
   stale-path references.

4. **Re-run sync** if you touched `.KCC/kernel/` or `.KCC/capabilities/`:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
   ```

   Generated cell outputs (`.claude/`, `.codex/`, `.opencode/`,
   `.agents/`, `ollama/`) are git-ignored. **Do not hand-edit them**;
   they are overwritten on every sync.

5. **For Docker-sensitive changes**, test the sandbox build:

   ```powershell
   docker build -t kcc-sandbox-test -f .KCC\sandbox\Dockerfile.claude .
   ```

6. **Open the PR** with a description that names: the v0.4 primitive
   touched (from the alignment matrix), the layer (kernel / capability /
   cell), the contribution pattern (from the catalog below), and any new
   KCC-FB-NNN upstream entry you're proposing.

---

## Contribution patterns

### 1. Add a new capability (agent or skill)

1. Create `.KCC/capabilities/agents/{name}.md` or
   `.KCC/capabilities/skills/{name}.md`.
2. Use the format spec in [`.KCC/kernel/README.md`](./.KCC/kernel/README.md)
   for required frontmatter.
3. Set `maturity: L1` (Experimental) by default.
4. Set `maintainer:` to your own role address (or to
   `tarek.fawaz1983@gmail.com` if you do not yet own a maintainer slot in
   [`MAINTAINERS.md`](./MAINTAINERS.md)).
5. For agents that touch untrusted input + private data + external
   comms, add `confidence-gate: required` to frontmatter to acknowledge
   the Lethal Trifecta.
6. Run sync + validate. Open the PR.

### 2. Promote a capability up the maturity ladder

- **L1 -> L2** (Proven): demonstrate stable use across two or more cells
  for at least a sprint. Include evidence (handover envelopes, trace
  excerpts, or pilot reports). Reviewed by the capability maintainer.
- **L2 -> L3** (Golden Path): requires kernel-maintainer sponsorship.
  Include an evaluation bundle (test fixtures, golden inputs/outputs)
  and a proposed deprecation path for the prior recommended capability.

### 3. Change something in `.KCC/kernel/`

Kernel changes require an **ADR** (Architectural Decision Record). Add
it under `architecture/adrs/` and link it from the PR description.
Approval needs at least one named kernel maintainer per
[`MAINTAINERS.md`](./MAINTAINERS.md). For deeper protocol changes
(spec-layout, auto-mode, token-budget, accuracy-calibration), propose a
draft on a topic branch and call for review before sinking time.

### 4. Workspace + multi-repo contributions

The Workspace layer (above Cells) is one of the youngest primitives.
Useful contributions:

- Extend `solution-inspector` to detect more monorepo flavors
  (currently: `lerna`, `nx`, `pnpm-workspace`, `rush`, `Cargo workspace`,
  `go.work`).
- Add tracker adapter scaffolds in
  [`.KCC/settings.json`](./.KCC/settings.json) `tracker.config` for Jira
  / Azure DevOps / Asana / Linear / GitHub Issues - schema is reserved;
  real adapter implementations are v1.2 work.
- Refine the workspace protocol in
  [`workspace`](./.KCC/kernel/protocols/workspace.md) when you find
  edge cases (e.g. git submodules vs vendored sources for IoT
  multi-repo).

### 5. Docker sandbox contributions

Sandbox runtime is enterprise-critical. Useful contributions:

- Add Dockerfile variants for other harnesses (e.g. Aider, Cursor) under
  `.KCC/sandbox/Dockerfile.<harness>`.
- Tighten the base image (`debian:stable-slim` today) - Alpine or
  distroless variants welcome with measurable size reduction.
- Add a Windows-container variant (today Linux-only) - flag as v1.x
  follow-up.
- Improve the auto-sandbox-on-trifecta heuristic in
  `start-agent-session.ps1` - false positives / false negatives are
  worth flagging on backchannel for tuning.
- Document network-policy patterns (egress-allowlist via internal
  registry, etc.) in
  [`sandbox-runtime`](./.KCC/kernel/protocols/sandbox-runtime.md).

### 6. Deploy stage + infrastructure-implementer

`/spec-deploy` is scaffolded. Useful contributions:

- Add **real pipeline templates** under
  `.KCC/kernel/templates/pipelines/{target}/{ci}/` - TBD per cell x CI
  matrix. Start with whichever combo you actually use (GitHub Actions +
  AWS / Azure DevOps + Azure are highest-traffic).
- Extend `infrastructure-implementer` to handle additional IaC dialects
  (Pulumi, AWS CDK in Python/TypeScript, Crossplane).
- Add the `deploy.md` audit trail format with examples.
- Wire `/spec-deploy` to honor `.KCC/settings.json` `tracker.type` for
  release-note creation in Jira / DevOps / Asana once those adapters
  land.

### 7. Architecture documentation

Always-on architecture docs (C4 + flowcharts + DFDs per depth) are at
PASS but every new agent gets reviewed for depth honesty. Useful:

- Add new templates under `.KCC/kernel/templates/` for diagram types
  not yet covered (sequence, deployment, threat-model).
- Improve the `architect` agent's depth-driven artifact selection logic.
- Add fitness-function examples per dialect family (backend x language,
  frontend x framework).

### 8. Calibration + Butler improvements

Butler's accuracy calibration loop (Mode D) is at PASS scaffolded with the
+/-10pp drift threshold over 10-turn rolling window. Useful:

- Add visualization to `show-backchannel.ps1` for the calibration drift
  per agent over time.
- Improve the calibration table format in
  [`accuracy-calibration`](./.KCC/kernel/protocols/accuracy-calibration.md)
  for Dataview-friendly Obsidian queries.
- Add per-step calibration (not just per-agent) - surface which
  lifecycle steps systematically over/under-claim confidence.

### 9. Mac / Linux + bootstrap

`.sh` wrappers + the bootstrap script are at PASS but plenty of room:

- Add `chmod +x` automation alternatives (git attributes, post-checkout
  hook) so first-time Mac/Linux users don't need to run the bootstrap.
- Improve the bootstrap script's diagnostic output (which `.sh` files
  failed `chmod`, why, etc.).
- Add a Linux distro detection sub-section to the install hint (Ubuntu /
  Debian / RHEL / Alpine).

### 10. CLI contributions (when v1.1+ lands)

A native Node + TypeScript CLI named **`kcc`** (package `@tikasway/kcc`)
is planned per [`CLI-PLAN.md`](./CLI-PLAN.md). Once v1.1 work begins:

- Port one PowerShell tool at a time to TypeScript with feature parity.
- Maintain PowerShell as canonical for v1.x - CLI is a parallel path,
  not a replacement, until v2.0.
- Use the same `.KCC/settings.json` schema.

### 11. Propose an upstream contribution to KCC v0.4

If your discovery is more than a local pattern - i.e. it should refine
the v0.4 spec itself - open a GitHub issue or discussion proposing a
**KCC-FB-NNN** entry. Maintainers curate the upstream-contribution catalog
internally. Each proposal needs:

- Where it lives in `.KCC/`
- v0.4 problem it addresses
- Proposed v0.4 section
- Recommendation verdict (Adopt / Adopt-with-modifications / Reject /
  Defer)
- 3-4 paragraph rationale

The catalog is shipped upstream periodically when the v0.4 spec
publishes a contribution channel.

### 12. Adapt an external workflow into KCC

Use the migrator:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\adapt-workflow.ps1 -SourcePath ../OtherProject
```

Supported source formats: Cursor (`.cursor/rules/`), Claude Code
(`.claude/`), Codex / OpenCode (`AGENTS.md`), Aider, OpenHands, generic
`prompts/` / `agents/`. Output: drafts under
`migrations/IMPORT-{NNN}/plan.md` + `drafts/agents/*.md` +
`drafts/skills/*.md` + `mapping.md`. **Drafts are never auto-promoted**
- review, edit, then explicitly move into `.KCC/capabilities/`.

---

## Coding and writing conventions

### PowerShell scripts (`.KCC/tools/*.ps1`)

- PowerShell 5.1 compatible (Windows ships it).
- No `&&` operator (use `; if ($?) { ... }`).
- UTF-8 with BOM if the file contains any non-ASCII character
  (em-dashes, smart quotes, etc. - PS 5.1 misreads UTF-8 no-BOM
  otherwise).
- CRLF line endings for PowerShell files.
- Use the established pattern in
  [`.KCC/tools/sync-adapters.ps1`](./.KCC/tools/sync-adapters.ps1) as
  the reference.

### Bash wrappers (`.KCC/tools/*.sh` + `tools/*.sh`)

- `#!/usr/bin/env bash` shebang.
- `set -euo pipefail` at the top.
- LF line endings, no BOM.
- Thin delegators only - check for `pwsh`, print install hint if
  missing, invoke the `.ps1` original via `pwsh -ExecutionPolicy
  Bypass -File`.
- ~15 lines per wrapper.
- Use the established pattern in
  [`.KCC/tools/sync-adapters.sh`](./.KCC/tools/sync-adapters.sh).

### Markdown (everywhere in the framework)

- Follow the Obsidian standard at
  [`.KCC/kernel/protocols/obsidian-standard.md`](./.KCC/kernel/protocols/obsidian-standard.md).
- Frontmatter required: `title`, `aliases`, `tags`, `created`,
  `updated`, `version`, `status`.
- Capability frontmatter additionally requires: `name`, `role` (agents
  only), `model-class`, `description`, `tools-required`, `inputs`,
  `outputs`, `maturity`, `maintainer`.
- Use `[[wikilinks]]` for in-vault cross-references, markdown links for
  external URLs.
- One sentence per line is encouraged for cleaner diffs.
- No BPMN - use Mermaid flowcharts for business workflows.

### Dockerfiles (`.KCC/sandbox/Dockerfile.*`)

- `debian:stable-slim` base for consistency across harnesses.
- Non-root `kcc` user, workdir `/workspace`.
- `VOLUME ["/workspace"]` for cell mount.
- Install: git + nodejs 20 + pwsh + the harness CLI (comment its
  install instruction; don't bake credentials).
- Add a comment block explaining default mount and network policy.

### Naming

- Kebab-case for file names: `idea-interrogator.md`, `spec-create.md`.
- Verb-noun pairs for capabilities: `spec-create`, `idea-interrogator`,
  `butler-brief`, `solution-onboard`.
- `IDEA-{ID}-{slug}` and `SPEC-{ID}-{slug}` are zero-padded to 3 digits.
- Story / Enabler files use capitalized form: `Story-001-{slug}.md`,
  `Enabler-001-{slug}.md` (keys inside files match filename case).

### Versioning

- Bump version minor on additive changes (new sections, new fields,
  new examples).
- Bump version major on breaking changes (renamed paths, removed
  fields, restructured frontmatter).
- Always set `updated:` to the change date in YYYY-MM-DD format.

---

## Code of conduct

By participating, you agree to abide by the
[Code of Conduct](./CODE_OF_CONDUCT.md). Reports go to
`tarek.fawaz1983@gmail.com`.

---

## Security

If you discover a security issue - especially anything triggering the
Lethal Trifecta in a packaged capability, escaping the sandbox runtime,
or exposing backchannel events with sensitive payloads - follow the
disclosure process in [`SECURITY.md`](./SECURITY.md). Do **not** open a
public GitHub issue for security reports.

---

## Attribution and licensing

Contributions are accepted under the terms of the project
[`LICENSE`](./LICENSE), which preserves IP attribution to
**Tarek Fawaz - tikasway.dev**. By opening a PR you agree your
contribution falls under those terms (including the upstream-contribution
clause that grants Tarek Fawaz - tikasway.dev a non-exclusive perpetual
license to incorporate your changes into the combined Work).

If you contribute substantially to a capability you also want to
maintain, add your row to [`MAINTAINERS.md`](./MAINTAINERS.md) in the
same PR - that's how you claim a maintainer slot.

Welcome aboard.

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](./LICENSE).
