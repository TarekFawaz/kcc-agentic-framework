---
title: Maintainers
aliases:
  - maintainers
  - kcc-maintainers
  - roster
tags:
  - framework/documentation
  - kcc/governance
  - kcc/v04
created: 2026-05-25
updated: 2026-05-30
version: 1.2.0
status: active
related:
  - "[[CONTRIBUTING]]"
  - "[[CODE_OF_CONDUCT]]"
  - "[[SECURITY]]"
  - "[[README]]"
---

# Maintainers

This file maps the role addresses used in capability frontmatter to the
real humans who own them. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for
how to claim a maintainer slot.

The framework is currently at **v1.2.0**, sitting at **Phase 1.8** on the
KCC phase ladder. Most capabilities and protocols are still owned by the
default project address; community sponsorship of individual capabilities
is actively encouraged.

---

## Kernel maintainers

3-7 named individuals with veto authority over `.KCC/kernel/` changes.

**Scope** - kernel maintainers own:

- **Contracts** (`.KCC/kernel/contracts/`): cost-envelope, confidence,
  decision-trace, agent, skill
- **Protocols** (`.KCC/kernel/protocols/`): handover + handover-examples,
  backchannel, workspace, sandbox-runtime, deployment,
  accuracy-calibration, architecture-documentation, progress-tracking,
  lethal-trifecta, spec-layout, idea-layout, trace-layout, auto-mode,
  confidence-gate, obsidian-standard, adaptation-guide, token-budget,
  solution-onboarding, architecture-governance
- **Dialects** (`.KCC/kernel/protocols/dialects/`): 23 stack-specific
  protocols (backend x 8 languages, frontend x 4 frameworks, fullstack
  x 5, embedded x 3, devops x 2, plus testing-unit / testing-integration
  / testing-performance / testing-security)
- **Adapters** (`.KCC/kernel/adapters/`): claude, codex, opencode,
  generic, ollama
- **Templates** (`.KCC/kernel/templates/`): root entrypoints (AGENTS.md,
  CLAUDE.md), ROI, settings.json template, C4-context, C4-container,
  flowchart-business, DFD, pipelines/README
- **Cells doc** (`.KCC/kernel/cells.md`)
- **Phase model** (`.KCC/kernel/phase-model.md`)
- **Inspector spec** (`.KCC/kernel/inspector/`)

**Responsibilities**: veto on kernel changes; sponsor L2->L3 capability
promotions; sign off on kernel ADRs (`architecture/adrs/`); set framework
version trajectory.

**Cadence**: quarterly minor, yearly major.

| Role address | Name | GitHub handle | Notes |
|---|---|---|---|
| `tarek.fawaz1983@gmail.com` | Tarek Fawaz | (GitHub: TBD) | Founder; primary kernel maintainer; sole approver until community seats fill |
| _open slot_ | _unassigned_ | - | Open for community sponsorship - apply via PR adding your row |
| _open slot_ | _unassigned_ | - | Open for community sponsorship |
| _open slot_ | _unassigned_ | - | Open for community sponsorship |

---

## Capability maintainers

Every file in `.KCC/capabilities/agents/` (17 agents) and
`.KCC/capabilities/skills/` (22 skills) declares a `maintainer:` field
in its frontmatter. **Validator enforces presence** - see
`.KCC/tools/validate-kcc.ps1`.

Currently all capabilities default to `tarek.fawaz1983@gmail.com` until
individual maintainers claim them via PR.

### Lifecycle agents (6) - `model-class: strong-reasoning`

| Capability | Current maintainer | Status |
|---|---|---|
| `idea-interrogator` | `tarek.fawaz1983@gmail.com` | L2 Proven |
| `spec-writer` | `tarek.fawaz1983@gmail.com` | L2 Proven |
| `planner` | `tarek.fawaz1983@gmail.com` | L2 Proven |
| `implementer` | `tarek.fawaz1983@gmail.com` | L2 Proven |
| `verifier` | `tarek.fawaz1983@gmail.com` | L2 Proven |
| `architect` | `tarek.fawaz1983@gmail.com` | L1 Experimental |

### Specialist agents (3) - `model-class: strong-reasoning`

| Capability | Current maintainer | Status |
|---|---|---|
| `technical-interrogator` | `tarek.fawaz1983@gmail.com` | L1 |
| `ux-ui-designer` | `tarek.fawaz1983@gmail.com` | L1 |
| `security-analyst` | `tarek.fawaz1983@gmail.com` | L1 |
| `infrastructure-planner` | `tarek.fawaz1983@gmail.com` | L1 |

### Meta-agents (2) - `model-class: fast-implementation`, always-on

| Capability | Current maintainer | Status |
|---|---|---|
| `butler` (memory + calibration) | `tarek.fawaz1983@gmail.com` | L2 Proven |
| `token-guard` (budget + loop detection) | `tarek.fawaz1983@gmail.com` | L2 Proven |

### Utility agents (4) - `model-class: balanced` or `strong-reasoning`

| Capability | Current maintainer | Status |
|---|---|---|
| `solution-cartographer` | `tarek.fawaz1983@gmail.com` | L1 |
| `solution-inspector` (NEW v1.1) | `tarek.fawaz1983@gmail.com` | L1 |
| `infrastructure-implementer` (NEW v1.2) | `tarek.fawaz1983@gmail.com` | L1 |
| `migrator` | `tarek.fawaz1983@gmail.com` | L1 |

### Skills (18)

| Skill | Current maintainer | Status |
|---|---|---|
| `/idea-interrogator` | `tarek.fawaz1983@gmail.com` | L2 |
| `/spec-create` | `tarek.fawaz1983@gmail.com` | L2 |
| `/spec-plan` | `tarek.fawaz1983@gmail.com` | L2 |
| `/spec-implement` | `tarek.fawaz1983@gmail.com` | L2 |
| `/spec-test` | `tarek.fawaz1983@gmail.com` | L2 |
| `/spec-review` | `tarek.fawaz1983@gmail.com` | L2 |
| `/spec-status` | `tarek.fawaz1983@gmail.com` | L2 |
| `/spec-deploy` (NEW v1.2) | `tarek.fawaz1983@gmail.com` | L1 |
| `/butler-brief` | `tarek.fawaz1983@gmail.com` | L2 |
| `/butler-remember` | `tarek.fawaz1983@gmail.com` | L2 |
| `/token-estimate` | `tarek.fawaz1983@gmail.com` | L2 |
| `/auto` | `tarek.fawaz1983@gmail.com` | L1 |
| `/critical-human-gate` | `tarek.fawaz1983@gmail.com` | L1 |
| `/solution-onboard` | `tarek.fawaz1983@gmail.com` | L1 |
| `/adapt-workflow` | `tarek.fawaz1983@gmail.com` | L1 |
| `/technical-interrogator` | `tarek.fawaz1983@gmail.com` | L1 |
| `/security-interrogator` | `tarek.fawaz1983@gmail.com` | L1 |
| `/infrastructure-interrogator` | `tarek.fawaz1983@gmail.com` | L1 |
| `/ux-ui-interrogator` | `tarek.fawaz1983@gmail.com` | L1 |

### High-leverage claim candidates

If you're looking for impact, these are the capabilities most worth
claiming as a maintainer (they touch the most lifecycle paths):

1. **`butler`** - Mode D calibration loop is fresh; per-agent drift
   tuning is high-value
2. **`token-guard`** - three estimation modes + loop detection;
   calibration of the +/-50% -> +/-20% tightening rule needs pilot data
3. **`spec-writer`** - emits the entire idea->spec->backlog tree; folder
   layout is load-bearing
4. **`infrastructure-implementer`** - pipeline templates are TBD per
   cell x CI; first real implementations unlock the deploy stage
5. **`solution-inspector`** - workspace topology auto-detection has
   room for many more monorepo flavors

### How to claim a capability

1. Open a PR changing the `maintainer:` field on the capability files
   you want to own.
2. Add your row to the matching table above with: GitHub handle,
   scope, time commitment.
3. Existing kernel maintainer approves.
4. (Optional) Move your contact preference into a dedicated
   role-address (e.g. `your-handle@your-domain`) and update the file
   accordingly.

---

## Cell-team owners

Each generated cell directory (`.claude/`, `.codex/`, `.opencode/`,
`.agents/`, `ollama/`) may be owned by a delivery team. Cell-team
rosters live inside the cell's own `<cell>/local/README.md` once
initialized - they are **NOT** tracked in this repository (cell teams
are autonomous per the v0.4 cells convention; see
[`.KCC/kernel/cells.md`](./.KCC/kernel/cells.md)).

Cell-team responsibilities:

- Maintain `<cell>/local/` contents (team-local agents, skills, config)
- Pin capability versions in `.KCC/settings.json` `defaults` for the
  cell
- Run sandboxed sessions where Lethal Trifecta or enterprise policy
  requires
- Manage cell-level secrets / deploy targets
- Coordinate with capability maintainers when local additions should be
  promoted to canonical capabilities

---

## Release coordinator

(Open slot - to be filled when release cadence formalizes.)

A release coordinator triages the cumulative changes between version
bumps, runs the final `sync-adapters.ps1` + `validate-kcc.ps1` pass,
writes the release-notes entry, and tags the version in git.

Current state: founder handles releases informally as version increments
land (1.0.0 -> 1.1.0 -> 1.2.0 within ~weeks).

---

## CLI maintainer

(Open slot - activates when [`CLI-PLAN.md`](./CLI-PLAN.md) v1.1 work
begins.)

The CLI maintainer owns the native Node + TypeScript CLI (`kcc` /
`@tikasway/kcc`) as it is built in parallel to the PowerShell tools.
Scope: `kcc init` / `sync` / `validate` / `adapt` parity with the
PowerShell originals through v1.1, then `session` / `backchannel` /
`auto` for v1.2.

---

## How to reach the maintainers

- **General questions**: `tarek.fawaz1983@gmail.com`
- **Security issues**: see [`SECURITY.md`](./SECURITY.md)
  (`tarek.fawaz1983@gmail.com`, do NOT open public issues for security)
- **Public discussion**: GitHub Discussions (link TBD post-publish)
- **Upstream KCC v0.4 contributions**: the KCC-FB-NNN catalog is curated
  internally by maintainers (kept under `output/`, not shipped in the public
  repo); proposals arrive via GitHub issues/discussions

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](./LICENSE).
