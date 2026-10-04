---
title: Orchestrator Map
tags:
  - coordination
  - generated
created: {{DATE}}
updated: {{DATE}}
version: 2.0.0
status: active
---

# Orchestrator Map

Single source for **who to spawn, on which model, at what effort, and how**.
Generated from `.KCC/capabilities/` + `.KCC/kernel/templates/orchestrator.md`
by `.KCC/tools/sync-adapters.ps1|.sh`. Do not hand-edit; change the agent's
`model-class` / `effort` frontmatter or this template, then resync.
Machine-readable twin: `coordination/orchestrator.json` (same data, plus the
butler-owned `active_session` pointer, which resync preserves).

## Spawn protocol

Every delegation from a skill, `auto`, or another agent follows these rules.

1. **Resolve, don't guess.** Look up the agent in the Agent Profiles table
   (or `orchestrator.json` → `agents[].spawn`). Use its harness model and
   effort. Never inherit the caller's model, and never raise it on your own.
2. **Fresh context per unit.** Spawn a new subagent for each
   idea/spec/story/wave unit. Never fork or resume the caller's transcript.
   One unit, one agent, one return.
3. **Handover packet, not file dumps.** Pass ≤ 300 words:
   `goal`, `ids` (IDEA/SPEC/STORY), `read` (paths + headings, never
   contents), `write` (expected artifact paths), `constraints`,
   `confidence_threshold`, `budget` (token-guard estimate id, if one exists).
   Shape: `.KCC/kernel/protocols/handover.md`.
4. **Lazy reads.** The agent reads only its packet's `read` list and its
   own profile inputs. For files over ~400 lines or any
   `.KCC/kernel/protocols/*`, Grep for the heading first and read that
   section only. Never load `.KCC/` wholesale.
5. **Lean return.** Reply with: ≤ 150-word summary, artifact paths written,
   open questions, `Confidence: NN%`, and the `ActualTokenUsage` block
   (`.KCC/kernel/contracts/agent-contract.md`). No file echoes and no
   restated inputs.
6. **Parallel fan-out.** Spawn independent units from the same
   `plan.md -> ## Waves` wave in **one** message, then wait for all of them
   before starting the next wave (`.KCC/kernel/protocols/parallel-execution.md`).
7. **Escalation ladder.** If a retry follows FAIL or low confidence, raise
   effort one step (`low→medium→high→xhigh`). Moving up a model class needs
   `/critical-human-gate` or a token-guard re-estimate. Below the confidence
   threshold, stop and run the gate. Don't loop.
8. **Gates are scripts.** A delegate's work is done only when the state's
   exit-check tool passes (`.KCC/kernel/contracts/tool-contract.md`). Route
   violations to their `fix_owner`. Exit 3 (deferred) is never a pass.
9. **Continuity.** At the soft usage threshold, spawn nothing new; the hard
   threshold writes a restore point and suspends the run
   (`.KCC/kernel/protocols/session-continuity.md`).
10. **Meta-agents stay cheap.** `butler` and `token-guard` run at their
   profile (fast class, low effort) and keep their output short (a context
   pack or a budget table). Skip `butler-brief` for single-file, read-only
   questions.

### Harness binding

| Harness | How to spawn with the profile |
|---|---|
| Claude Code | `Agent(subagent_type: "<name>", prompt: <handover>)`. Model, effort, and tools come from `.claude/agents/<name>.md` frontmatter. Don't pass `model` except on an approved escalation. |
| Codex | Use `.codex/agents/<name>.md` (`model`, `model_reasoning_effort`) as the sub-session profile. |
| OpenCode | `@<name>` subagent from `.opencode/agents/<name>.md`. |
| Generic / Ollama | `.agents/manifest.json` or `ollama/agents.json`, keyed by agent name. |
| Switching harness | `.KCC/tools/kcc-handover.ps1\|.sh -To <harness> [-Launch] [-Unattended]`, then `auto resume` in the target. |

## Model classes

{{MODEL_CLASS_TABLE}}

## Agent profiles

{{SPAWN_TABLE}}

## Skill routes

{{ROUTE_TABLE}}
