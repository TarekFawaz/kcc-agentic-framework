---
# Functional fields (none - this document defines a convention,
# materialized by .KCC/settings.json and consumed by solution-inspector)

# Obsidian metadata
title: Workspace Protocol
aliases:
  - workspace
  - workspace-layer
tags:
  - framework/protocol
  - workspace
  - kcc/v04
  - documentation
created: 2026-05-29
updated: 2026-06-02
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Workspace Protocol

The **workspace** is the layer above Cells in the KCC v0.4 operating model.
A cell is a team-owned composition of kernel contracts, selected
capabilities, and local additions. Generated harness folders (`.claude/`,
`.codex/`, and friends) are adapter surfaces for a cell, not cells
themselves. A workspace is the human-edited composition that contains one or
more cells, the source-control roots they apply to, and the workspace-level
decisions (tracker, model-class defaults, AutoPolicy defaults) that should
follow the work regardless of which harness is being used at the moment.

This protocol defines:

- what a workspace is and is not;
- how single-repo, multi-repo, and monorepo cases are recorded;
- how the multi-idea case is handled (folder convention, not config);
- the JSON schema for `.KCC/settings.json`;
- the future hook for tracker integration adapters;
- the Cell <-> Workspace relationship.

---

## 1. What a workspace is

A workspace is:

- A **composition** of one or more cells (one per team/domain, rendered to
  whichever harness adapter surfaces the team uses).
- A **set of source-control roots** the framework knows about - at minimum
  the current repo, and additionally any related repos for multi-repo
  compositions.
- A **set of workspace-level decisions** that apply across every cell and
  every spec in the workspace: tracker choice, model-class overrides,
  AutoPolicy defaults.

A workspace is **not**:

- A registry of ideas or specs - those live in `ideation/` and `specs/`
  and are discovered by convention.
- A package manifest - it does not declare dependencies between
  application modules, only between source-control roots.
- A replacement for the cell layer - cells still materialize per harness;
  the workspace sits above them.

---

## 2. Single vs multi-repo vs monorepo

| Topology | Definition | How recorded |
|--|--|--|
| **single-repo** | One git repo. One source-control root. The default for a fresh `framework-init`. | `solution.type = "single-repo"`; `workspace.repositories = []`. |
| **multi-repo** | Two or more git repos that together compose the solution. Common in IoT (firmware + gateway + cloud + mobile) and in microservice estates where each service has its own repo. | `solution.type = "multi-repo"`; `workspace.repositories` lists each repo with `name`, `path`, `url`, `role`, and `depends_on`/`deploys_with`. |
| **monorepo** | One git repo containing multiple package/service trees (lerna, nx, pnpm workspaces, Cargo workspace, go.work, rush, turbo). | `solution.type = "monorepo"`; the monorepo's package roots may be listed in `workspace.repositories` with `path` relative to the monorepo root. |
| **workspace-only** | No git repo - a working directory used as a sandbox or for prototyping. | `solution.type = "workspace-only"`. |

The [[solution-inspector]] agent detects the topology automatically (git
remotes, sibling-folder scan, monorepo markers) and then asks the human to
confirm or correct.

---

## 3. Multi-idea in one workspace

Multiple ideas in the same workspace are handled by **folder convention
only** - there is no `workspace.yml` or per-idea registry inside
`.KCC/settings.json`. The convention is enforced by
[[spec-layout]] (v5.0.0+):

```text
src/IDEA-{ID}-{slug}/
|-- README.md
|-- ...
```

Each idea gets its own per-idea source tree. The trace chain
`Idea -> Specs -> Story/Enabler` is then visible through the
`ideation/IDEA-{ID}-{slug}/` and
`specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/` folders.

This means: **the workspace layer does not need to know about ideas**.
Ideas appear and retire through ordinary folder operations, and the spec
layout protocol carries the contract.

See [[spec-layout]] for the canonical source-code layout.

---

## 4. Multi-repo composition

Multi-repo composition is recorded in the `workspace.repositories` array of
`.KCC/settings.json`. Each entry captures:

- `name` - short identifier the human picks (e.g. `firmware`, `gateway`,
  `cloud`, `mobile`, `web-admin`).
- `path` - relative path from the workspace root to the repo working
  directory, or an absolute path if the repo lives elsewhere on disk.
- `url` - the git remote URL (or `null` if not yet remoted).
- `role` - one of: `frontend`, `backend`, `firmware`, `gateway`, `mobile`,
  `infra`, `docs`, `other`.
- `depends_on` - list of other `name` values this repo depends on.
- `deploys_with` - list of other `name` values this repo ships with as a
  unit.

`workspace.relationships` is an optional richer table for relationships
that do not fit cleanly into `depends_on`/`deploys_with` (e.g.
`shares-schema`, custom integration patterns).

The framework does not enforce these declarations - it surfaces them to
planning/spec agents so cross-repo dependencies are explicit when an epic
spans more than one repo.

---

## 5. Tracker integration (future hook)

`.KCC/settings.json` carries the tracker choice today even though no
tracker adapter ships yet:

```json
"tracker": {
  "type": "jira",
  "config": { }
}
```

Supported values for `tracker.type`:

- `none` - no tracker integration (default).
- `jira` - Atlassian Jira (Cloud or Server).
- `azure-devops` - Azure DevOps Boards.
- `asana` - Asana.
- `linear` - Linear.
- `github-issues` - GitHub Issues.
- `custom` - escape hatch; `tracker.config` carries adapter-specific
  config.

When tracker adapters land, they will read this section to know which
backend to call. Until then, the field documents the human's intent so
later automation does not need to re-ask.

The [[solution-inspector]] agent **always asks** the tracker question,
even under `auto --silent --assume`, because tracker choice has
production-impacting implications.

---

## 6. Settings file location

The workspace settings file lives at:

```
.KCC/settings.json
```

This is **kernel-adjacent**, not harness-specific. It is distinct from
`.claude/settings.json`, which is the Claude Code harness configuration
(permissions, hooks, generated adapter-surface config). The split is deliberate:

- `.KCC/settings.json` - workspace-level decisions, edited by humans
  (with [[solution-inspector]] doing the heavy lifting). One file per
  workspace, shared across every cell in the workspace.
- `.claude/settings.json` / `.codex/...` - per-surface harness config,
  generated and owned by [[sync-adapters]].

Cells consume `.KCC/settings.json` indirectly: when a spec lifecycle skill
runs inside a cell, it reads `.KCC/settings.json` to discover the
workspace defaults. The cell itself never owns these decisions.

---

## 7. Cell <-> Workspace relationship

| Concept | Owner | Cadence | Number per workspace |
|--|--|--|--|
| Workspace | The team (human-edited via inspector) | Rarely (topology changes) | 1 |
| Cell | A team/domain (this repo = 1 cell) | Days / continuously | 1 here, rendered as one adapter surface per harness |

One workspace contains one cell here, rendered as one adapter surface per
harness in use (claude, codex, opencode, generic, ollama). The
`.KCC/settings.json` file applies to the **workspace**. The adapter
surfaces may still carry surface-local overrides under their `local/`
subdirectories (see [[cells]] section 4), but workspace-level decisions
are not duplicated per cell.

---

## 8. JSON schema for `.KCC/settings.json`

Canonical reference. Solution-inspector writes this shape; framework
adapters read it.

```json
{
  "$schema": "./settings.schema.json",
  "version": "1.0",
  "solution": {
    "name": "<solution name>",
    "type": "single-repo | multi-repo | monorepo | workspace-only",
    "primary_repo_path": ".",
    "primary_repo_url": null
  },
  "workspace": {
    "repositories": [
      {
        "name": "<short id>",
        "path": "<relative path or absolute>",
        "url": "<git remote URL or null>",
        "role": "frontend | backend | firmware | gateway | mobile | infra | docs | other",
        "depends_on": ["<other-repo-name>"],
        "deploys_with": ["<other-repo-name>"]
      }
    ],
    "relationships": [
      {"from": "<repo>", "to": "<repo>", "kind": "depends-on | deploys-with | shares-schema | other", "notes": "..."}
    ]
  },
  "tracker": {
    "type": "none | jira | azure-devops | asana | linear | github-issues | custom",
    "config": {}
  },
  "defaults": {
    "model_class_overrides": {},
    "auto_policy": {
      "silent": false,
      "assume": false,
      "accuracy_threshold_pct": 95,
      "budget_cap_amount": null,
      "budget_cap_currency": "USD"
    }
  }
}
```

### Field notes

- `version` - schema version. Bump only on breaking schema changes.
- `solution.name` - human-friendly name. Defaults to the repo directory
  name if not set.
- `solution.primary_repo_path` - the workspace anchor. Almost always `"."`.
- `workspace.repositories` - empty array for single-repo solutions;
  populated for multi-repo and (optionally) monorepo cases.
- `workspace.relationships` - optional richer relationship table.
- `tracker.config` - adapter-specific. Inspector leaves it empty until a
  real tracker adapter lands.
- `defaults.model_class_overrides` - map of model-class name to overridden
  concrete model identifier. Empty by default.
- `defaults.auto_policy` - solution-level AutoPolicy defaults. Individual
  `auto` invocations may override on the command line.

---

## 9. Related

- Cells layer: [[cells]]
- Solution onboarding flow: [[solution-onboarding]]
- Spec folder layout (multi-idea source convention): [[spec-layout]]
- Solution inspector agent: [[.KCC/capabilities/agents/solution-inspector]]
- Solution cartographer agent: [[.KCC/capabilities/agents/solution-cartographer]]
- Auto-mode AutoPolicy: [[auto-mode]]
- Obsidian standard: [[obsidian-standard]]
