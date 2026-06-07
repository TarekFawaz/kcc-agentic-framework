---
# Functional fields (none - this document defines a convention, it is not consumed by harness adapters)

# Obsidian metadata
title: Cells (KCC v0.4)
aliases:
  - cells
  - cell-layer
  - kcc-cells
tags:
  - kcc/kernel
  - framework/documentation
  - entrypoint
created: 2026-05-25
updated: 2026-06-02
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Cells (KCC v0.4)

> **This repository is one cell.** Its generated harness outputs -
> `.claude/`, `.codex/`, `.opencode/`, `.agents/`, and `ollama/` - are
> **runnable adapter surfaces of that one cell**, not five separate cells.
> They are materialized from `.KCC/kernel/` + `.KCC/capabilities/` by
> [[sync-adapters]]; the sync tool is the adapter-surface materializer.
> A genuinely separate cell would be a different team/domain that vendors
> the same kernel + capabilities into its own repo or workspace.

This document is the kernel-side definition of the **Cells** layer of the
KCC v0.4 operating model (Kernel + Capabilities + Cells) and the binding
between that abstract definition and the concrete artifacts in this repo.

---

## 1. What v0.4 says about Cells

In the KCC v0.4 operating model, the three layers have distinct ownership,
cadence, and blast radius:

| Layer | Owner | Change cadence | Blast radius |
|--|--|--|--|
| **Kernel** | Platform team | Months | Whole framework |
| **Capabilities** | Capability authors | Weeks | Every cell that selects the capability |
| **Cells** | Cell teams | Days / continuously | Just that cell |

The v0.4 definition of a cell, in short:

- A cell is a **team-owned composition** of (a) kernel contracts, (b) the
  subset of capabilities the team chose, and (c) any team-local additions.
- Cells are **where work ships**. Specs are executed inside a cell.
- Cells **change weekly or faster**. The kernel and capability layers do
  not - they move on a slower, more conservative cadence so that cells can
  stay stable.
- Cells operate **independently of the kernel**: a cell consumes the kernel
  and capability layers as a versioned input, but the cell team is not
  blocked on upstream changes for routine work.

The contract direction is one-way: cells consume kernel + capabilities;
kernel and capabilities never reach down into a cell.

---

## 2. How this implementation maps to v0.4

**This repo is one cell.** That single cell is materialized into one
**adapter surface per harness** - so the same cell can be driven from
Claude Code, Codex CLI, OpenCode, a generic runner, or Ollama bindings
without changing the source of truth:

| Path | Adapter surface (harness) | Materializer |
|--|--|--|
| `.claude/` | Claude Code | [[sync-adapters]] (`-Harness claude`) |
| `.codex/` | OpenAI Codex CLI | [[sync-adapters]] (`-Harness codex`) |
| `.opencode/` | OpenCode | [[sync-adapters]] (`-Harness opencode`) |
| `.agents/` | generic / portable | [[sync-adapters]] (`-Harness generic`) |
| `ollama/` | local Ollama bindings | [[sync-adapters]] (`-Harness ollama`) |

These five directories are **the same cell rendered for five harnesses**,
not five independent cells. They share one kernel, one capability set, one
workspace (`.KCC/settings.json`), one memory store, and one backchannel.
Pick whichever surface matches the harness you're running; the others stay
in sync on the next `sync-adapters.ps1` run.

`framework-init.ps1` performs first-time setup (root entrypoints + state
folders) and then calls `sync-adapters.ps1`. From that moment on, every
edit to `.KCC/kernel/` or `.KCC/capabilities/` is propagated into every
adapter surface on the next sync.

A **second cell** is a different team or domain that vendors this kernel +
capability set into its own repo or workspace, selects its own capability
subset, and adds its own team-local extensions under `<surface>/local/`.
That is the "many cells" in *one kernel, many capabilities, many cells* -
not the five harness folders in this one repo.

This mapping is the load-bearing piece: the v0.4 spec treats cells as
abstract compositions, but inside this repo the adapter surfaces are
concrete directories you can `ls`, vendor, or copy into a downstream
consumer.

---

## 3. Cell composition formula

A cell is built from three inputs, in this order:

```text
cell = kernel contracts  +  selected capabilities  +  (optional) team-local additions
```

Concretely, for a `.claude/` cell:

1. **Kernel contracts** (from `.KCC/kernel/contracts/`,
   `.KCC/kernel/protocols/`, `.KCC/kernel/templates/`): how agents
   handshake, what confidence/cost envelopes mean, what a spec folder must
   contain, how traces are written. See [[architecture-governance]] and
   [[spec-layout]].
2. **Selected capabilities** (from `.KCC/capabilities/agents/` and
   `.KCC/capabilities/skills/`): which agents and skills the cell actually
   exposes. In this repo every cell currently selects the full capability
   set; in a real multi-team deployment a cell may select a subset and pin
   versions.
3. **Team-local additions** (under `.claude/local/`, `.codex/local/`,
   etc.): agents, skills, snippets, or overrides that belong only to this
   cell and never propagate back upstream.

The sync tool owns step 1 and step 2. Step 3 is the cell team's territory
and is described in the next section.

---

## 4. The `local/` convention for team-local additions

> **Proposal.** Each cell may have a `local/` subdirectory that the sync
> script preserves across regenerations.

The structure mirrors the canonical layout but under a `local/` prefix:

```text
.claude/
|-- agents/                 # GENERATED - owned by sync; do not edit
|-- skills/                 # GENERATED - owned by sync; do not edit
|-- commands/               # GENERATED - owned by sync; do not edit
`-- local/                  # CELL-TEAM TERRITORY - preserved across syncs
    |-- agents/             # team-only agents
    |-- skills/             # team-only skills
    |-- commands/           # team-only commands / aliases
    `-- README.md           # what's here, why, owner contact
```

The same shape applies to `.codex/local/`, `.opencode/local/`, and
`.agents/local/`.

This convention resolves the apparent tension between two rules:

- **"Do not edit generated files."** - preserved: the canonical directories
  are still owned by the sync tool and may be wiped and re-emitted on
  every run.
- **"Cells are where teams add custom agents."** (v0.4) - preserved: the
  cell team has a dedicated, well-known location (`local/`) that the sync
  tool never touches.

Sync semantics that need updating to honor this convention are noted in
section 8 (a known TBD - not implemented in this slice).

---

## 5. Cell ownership

Every cell has a **named cell-team owner**. In this single-team reference
implementation there is one cell (rendered as five adapter surfaces), and
its default owner is:

```yaml
cell-owner: tarek.fawaz1983@gmail.com
```

Cell-team owners may:

- **Pin specific capability versions.** If `.KCC/capabilities/agents/spec-writer.md`
  is at version `4.4.0` but the cell needs `4.3.0` for stability, the cell
  team can vendor that older version under `local/`.
- **Override model-class resolution.** A cell may map
  `model-class: strong-reasoning` to a different concrete model than the
  framework default (e.g. a locally hosted alternative).
- **Add their own agents and skills under `local/`.** These never appear
  in the upstream `.KCC/capabilities/` tree and do not need to satisfy the
  full kernel review process; they only need to satisfy the contracts
  listed in [[architecture-governance]].

Maturity tags (`L1` / `L2` / `L3`) on upstream capabilities give cell
teams the signal they need to decide what to consume directly versus what
to vendor and pin.

---

## 6. What stays out of cells

A cell is the **downstream** of the framework. Things that stay out:

- **Kernel contracts in their canonical form.** Cells reference them, they
  do not embed copies. The single source of truth lives at
  `.KCC/kernel/`.
- **Untransformed capability sources.** Cells receive transformed
  per-harness artifacts (e.g. `.claude/agents/spec-writer.md`), not raw
  `.KCC/capabilities/agents/spec-writer.md` files.
- **Ideas, specs, traces, memory.** These are produced *by* work that
  happens *inside* a cell; they live at the repo root
  (`ideation/`, `specs/`, `Traces/`, `memory/`) and are shared across
  cells in this single-repo setup. In a multi-repo deployment they may
  be local to each cell repo.

The kernel and the capability layer are upstream; cells are strictly
downstream consumers.

---

## 7. Multiple cells vs one cell, many surfaces

This repo is **one cell**, materialized as one adapter surface per harness
in the **same repo root**. That works because there is one team (one
cell-team owner) and one capability selection. The five harness folders
are not five cells - they are five renderings of the same cell.

A real multi-team deployment would look different:

- Each team has its **own repo or workspace**, which is the cell.
- The cell consumes this repo's `.KCC/kernel/` + `.KCC/capabilities/` as
  a **vendored or referenced source** (git submodule, package, mirror,
  or pinned ref).
- The cell runs the equivalent of `sync-adapters.ps1` against the
  vendored source to produce its own `.claude/`, `.codex/`, etc.
- Each cell ships independently. A patch to the kernel must be tested
  per-cell before adoption.

The composition formula in section 3 is identical in that world; only the
filesystem topology changes.

---

## 8. Sync semantics - known TBD

The current `.KCC/tools/sync-adapters.ps1` regenerates per-harness output
files but does not yet enforce the `local/` convention from section 4.

To honor `local/`, a future patch should pick one of:

- **(a) Name-scoped rewrite.** The sync tool only deletes/rewrites files
  whose names match canonical capability or skill names produced from
  `.KCC/capabilities/`. Anything unrelated is left alone.
- **(b) Path-scoped skip.** The sync tool explicitly skips any path
  containing a `/local/` segment, regardless of file name.

Option (b) is the simpler invariant and is recommended as the default.
Option (a) is stricter but requires the sync tool to track a manifest of
what it owns.

This is documented here as a **known TBD**, not implemented in this
slice. Until the patch lands, cell teams should:

- Place team-local additions under `local/` so the convention is already
  in place once the sync tool is updated.
- Treat anything outside `local/` as ephemeral - assume it will be wiped
  on the next sync.

See also [[obsidian-standard]] for the frontmatter conventions every
agent/skill/local addition must follow.

---

## 9. Cheat sheet

- **Cell = team-owned composition.** This repo is one cell; `.claude/`,
  `.codex/`, `.opencode/`, `.agents/`, and `ollama/` are adapter surfaces
  for that one cell.
- **Adapter-surface materializer = [[sync-adapters]].** Edit `.KCC/kernel/` or
  `.KCC/capabilities/`, then rerun the sync tool.
- **Cell composition = kernel + selected capabilities + (optional) local.**
- **Cell team owns `local/`.** Sync owns everything else inside the cell.
- **Cell owner defaults to `tarek.fawaz1983@gmail.com`** in this
  reference implementation.
- **Multi-cell deployments** put each cell in its own repo and vendor
  this kernel + capabilities source.
