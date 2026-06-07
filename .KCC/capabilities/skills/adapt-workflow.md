---
# Functional fields
name: adapt-workflow
description: >
  Adapt an existing agentic workflow into this framework. Scans a source
  path (Cursor / Claude Code / Codex / OpenCode / Aider / generic), produces
  a draft migration under `migrations/IMPORT-{NNN}/`, and never auto-promotes.
  Usage: /adapt-workflow <path-or-repo> [--format=<hint>]
argument-placeholder: <ARGS>
delegates-to:
  - migrator
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata
title: Adapt Workflow Skill
aliases:
  - migrate-workflow
  - import-workflow
tags:
  - framework/skill
  - lifecycle/meta
  - migration
created: 2026-05-24
updated: 2026-06-06
version: 1.3.0
status: active
---

# Adapt Workflow

Adapt an existing agentic workflow defined in another format (Cursor rules,
Claude Code, Codex `AGENTS.md`, OpenCode, Aider, generic `prompts/` or
`agents/`) into reviewable draft local capabilities using the neutral
[[.KCC/kernel/README]] format.

Invoked with: `/adapt-workflow <ARGS>` where `<ARGS>` is the source path,
optionally followed by `--format=<cursor|claude|codex|opencode|aider|generic>`.

## Steps

1. **Parse `<ARGS>`.** Split into:
   - source path (the first positional token), and
   - optional `--format=<hint>` flag (anywhere else in `<ARGS>`).
   If `<ARGS>` is empty, print the usage line and stop.

2. **Verify the source path exists and is non-empty.** If the path is
   missing, unreadable, or contains no files, report the problem and stop -
   do not invoke the migrator on nothing.

3. **Create `migrations/` if missing.** This folder is created lazily by this
   skill on invocation - it never pre-exists from init. Then **delegate to the
   [[migrator]] agent** with two parameters: the verified source path and the
   format hint (or `auto` if none was supplied). Let migrator detect,
   inventory, draft, and write the `migrations/IMPORT-{NNN}/` folder per its
   own process.

4. **Print the migrator's one-paragraph summary** verbatim, then the
   absolute path to `migrations/IMPORT-{NNN}/plan.md` so the human can open
   it directly.

5. **Remind the human, in a final line:** "Drafts are NOT promoted
   automatically. Review `plan.md`, edit `drafts/` as needed, then
   explicitly move accepted drafts into `.KCC/capabilities/agents/` or
   `.KCC/capabilities/skills/` and rerun `.KCC/tools/sync-adapters.ps1`."
