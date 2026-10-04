---
# Functional fields (none - adapter docs are pure prose, no harness-consumed fields)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Claude Code Adapter
aliases:
  - claude-adapter
tags:
  - framework/adapter
  - harness/claude
created: 2026-05-24
updated: 2026-06-05
version: 1.2.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Claude Code adapter

How `.KCC/kernel/` neutral sources map onto Claude Code's on-disk conventions.

## Invocation

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 claude
# or, as part of an all-harness run:
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
```

## Generated files

`.KCC/tools/sync-adapters.ps1` regenerates these from `.KCC/kernel/`:

| Neutral source                       | Generated Claude file                          |
|--|--|
| `.KCC/capabilities/agents/{name}.md`         | `.claude/agents/{name}.md`                     |
| `.KCC/capabilities/skills/{name}.md`         | `.claude/skills/{name}/SKILL.md`               |

The root `CLAUDE.md` is created from `.KCC/kernel/templates/CLAUDE.md` when
missing, then preserved for local edits.

## Frontmatter mapping (agents)

Neutral -> Claude (`.claude/agents/{name}.md`):

| Neutral field        | Claude field      | Notes                                    |
|--|--|--|
| `name`               | `name:`           | Required by Claude Code; unregistered without it |
| `description`        | `description: >`  | Folded scalar (safe with `: ` inside)    |
| `model-class`        | `model:`          | Alias resolved via the table below       |
| `effort`             | `effort:`         | `low`..`max`; defaults per model-class   |
| `tools-required`     | `tools:`          | Comma-separated bare tool names only     |
| `role`               | (omitted)         | Published in `coordination/orchestrator.md` |
| `inputs` / `outputs` | (omitted)         | Published in `coordination/orchestrator.md` |

### Model class mapping

Aliases float to the newest model in each tier. The resolved IDs are
recorded in `coordination/orchestrator.json` -> `model_classes`.

| Neutral class         | Claude `model:` | Resolves to (2026-09) | Default `effort:` |
|--|--|--|--|
| `strong-reasoning`    | `opus`          | `claude-opus-5`       | `high`   |
| `balanced`            | `sonnet`        | `claude-sonnet-5`     | `medium` |
| `fast-implementation` | `haiku`         | `claude-haiku-4-5`    | `low`    |
| `local-strong`        | n/a - use Ollama adapter | | |
| `local-fast`          | n/a - use Ollama adapter | | |

### Tool name mapping

| Neutral tool | Claude tool(s)                            |
|--|--|
| `read`       | `Read`                                    |
| `search`     | `Glob`, `Grep`                            |
| `edit`       | `Write`, `Edit`                           |
| `exec`       | `Bash`                                    |
| `web`        | `WebSearch`, `WebFetch`                   |

Subagent `tools:` accepts bare tool names only, so a permission specifier
like `Bash(git log*)` there would not restrict anything. The sync script's
per-agent exec overrides are published as `exec_scope` in
`coordination/orchestrator.json` and in the Agent profiles table. To enforce
them, use `permissions` rules in `.claude/settings.json`.

## Frontmatter mapping (skills)

Neutral -> Claude:

| Neutral field           | Claude field      | Notes                                        |
|--|--|--|
| `name`                  | `name:`           | Also the folder: `.claude/skills/{name}/SKILL.md` |
| `description`           | `description: >`  | Folded scalar; include `Usage:` for routing   |
| `argument-placeholder`  | (substitution)    | `<ARGS>` is rewritten to `$ARGUMENTS`        |
| `delegates-to`          | `## Spawning` footer | One line pointing at the orchestrator spawn protocol |

## Spawning

Skills and agents spawn delegates by name, e.g.
`Agent(subagent_type: "planner", prompt: <handover packet>)`. Model, effort,
and tools come from the generated frontmatter, so callers never restate them.
Handover, return, parallelism, and escalation rules:
`coordination/orchestrator.md` -> *Spawn protocol*.

## Parallel execution realization

Claude Code is the **built and validated** realization of the spawner contract
`run(independent_items)` in [[../protocols/parallel-execution|parallel-execution]].

- **Mechanism:** native parallel subagents. To execute a wave, the orchestrator
  issues **one subagent (Task/Agent) call per wave item in a single turn**.
  Claude Code runs those subagent calls **concurrently**.
- **Scope per call:** each subagent is scoped to one wave item (a story/enabler
  at L2, or a whole spec flow at L1) and that item's declared impacted files
  under `src/IDEA-{ID}-{slug}/...`. Because the planner guarantees waves are
  file-disjoint, the concurrent subagents write non-overlapping files.
- **Barrier:** "await all subagent results." The turn completes only when every
  subagent in the wave has returned; the orchestrator then collects results and
  starts the next wave.
- **Levels:** L1 (across independent specs) and L2 (across independent
  stories/enablers within a wave) both use this same one-call-per-item pattern.
- **Governance:** butler-brief/remember wrap each subagent (shared trace
  session, agent-named appends); token-guard accounts each; confidence-gate and
  loop detection apply per subagent. One upfront token-budget gate covers the
  whole wave set.
- **Visible / sandboxed option:** `.KCC/tools/start-agent-session.ps1` can
  additionally surface these flows in visible windows or sandbox a risky unit;
  it complements native subagents and is not a fallback. HOTL window-permission
  rules in [[../protocols/auto-mode|auto-mode]] still apply.

## Token-actuals capture (SessionEnd hook)

Claude Code does not expose per-turn token usage to the agent mid-session, so
**actual** token counts can only be captured from the transcript after the fact.
A `SessionEnd` hook in `.claude/settings.json` runs the token-actuals producer:

```json
"SessionEnd": [
  { "hooks": [ { "type": "command",
    "command": "powershell -ExecutionPolicy Bypass -File \"%CLAUDE_PROJECT_DIR%\\.KCC\\tools\\record-token-actuals.ps1\" -FromHookStdin" } ] }
]
```

The hook fires once at session end (it cannot block), passes its JSON - including
`transcript_path` - on stdin, and the tool parses the transcript's per-message
`message.usage`, writing one **session-total `harness-reported`** row to the
active `Traces/Session-*/TokenUsage.md` and emitting an `actual-recorded`
backchannel event. Token Guard's Mode D then reconciles estimate-vs-actual.

Token math: `actual_input_tokens = input_tokens + cache_creation_input_tokens`
(fresh input); `actual_output_tokens = output_tokens`; `cache_read_input_tokens`
is recorded separately as `actual_cache_read_tokens` (reused context billed at a
reduced rate - folding it into the total would massively inflate it).

**Mac/Linux variant** (swap the command in `settings.json`):

```json
"command": "bash \"$CLAUDE_PROJECT_DIR\"/.KCC/tools/record-token-actuals.sh --from-hook-stdin"
```

The `.sh` parser needs `python3` or `jq`; without either it honestly records
`source: unavailable`. For non-Claude harnesses, use
`record-token-actuals.{ps1,sh} -ManualTotal N` (manual-meter) or `-Unavailable`.

Known limitation: the session total comes from the main transcript and may
undercount tokens spent inside parallel subagents.

## Caveats

- The lifecycle hooks in `.claude/settings.json` (`SubagentStart` matcher for `implementer`, and the `SessionEnd` token-actuals hook above) are harness-specific and **not** modelled as capabilities. They live in `settings.json` directly.
- `sync-adapters` **seeds** `.claude/settings.json` from `.KCC/kernel/templates/claude-settings.json` only when it is **absent**; it never overwrites an existing (hand-edited) one.
- Claude's permissions (`permissions.allow`) are also harness-specific.
- Round-trip is faithful: regenerated `.claude/agents/*.md` and `.claude/skills/*/SKILL.md` are content-equivalent to the originals (modulo minor whitespace normalization). The only deliberate drift is the `model:` line, which now reads from the neutral class table rather than being hand-set per file.
