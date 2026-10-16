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
   effort. Never inherit the caller's model, and never raise it on your own,
   except by the complexity rule (7) or an approved deep spawn (11).
2. **Fresh context per unit.** Spawn a new subagent for each
   idea/spec/story/wave unit. Never fork or resume the caller's transcript.
   One unit, one agent, one return. A hand-back is short: a 10-line summary
   (what was written, the check result, confidence, open points) plus the
   list of files; never the agent's whole report. Wait for every agent you
   spawn (parallel ones too) before you finish: in a non-interactive session (`claude -p`,
   kcc-run) the session ends with your reply, so never run a subagent in the
   background there.
3. **Handover packet, not file dumps.** Pass ≤ 300 words:
   `goal`, `ids` (IDEA/SPEC/STORY), `read` (paths + headings, never
   contents), `write` (expected artifact paths), `constraints`,
   `confidence_threshold`, `budget` (token-guard estimate id, if one exists),
   `depthlevel` (1-5 from the AutoPolicy, default 5; omit at 5),
   `hints` (the active human hints for this agent: `kcc hint --pending --for
   <agent> --all`; omit when none).
   Shape: `.KCC/kernel/protocols/handover.md`. Hints given while a subagent runs
   reach it by hook, and you relay them with `SendMessage`
   (`.KCC/kernel/protocols/hints.md`).
4. **Lazy reads.** Read a skill, this map and the state table once per
   session, then work from your notes: never re-read them per state, unit or
   retry. The agent reads only its packet's `read` list and its
   own profile inputs. For files over ~400 lines or any
   `.KCC/kernel/protocols/*`, Grep for the heading first and read that
   section only. Never load `.KCC/` wholesale.
5. **Lean return.** Reply with: the 10-line summary of rule 2 (≤ 150 words), artifact paths written,
   open questions, `Confidence: NN%`, and the `ActualTokenUsage` block
   (`.KCC/kernel/contracts/agent-contract.md`). No file echoes and no
   restated inputs.
6. **Parallel fan-out.** Spawn independent units from the same
   `plan.md -> ## Waves` wave in **one** message, then wait for all of them
   before starting the next wave (`.KCC/kernel/protocols/parallel-execution.md`).
7. **Model routing** (`.KCC/kernel/protocols/model-routing.md`). Start from the
   agent's profile tier and effort, then move at most one tier, from signals:
   `research`/`architecture`/`security` never below balanced; a `novel`
   domain (`Research.md -> ## Domain`) one tier up and effort high; a
   `common` domain one tier down for spec, plan, docs and scaffold work;
   CR-7 risk or `Complexity: high` never below balanced and effort high; a
   large unit (> 3 items or > 5 files) effort one step up; a retry one tier
   up and one effort up; under 20% budget left never above balanced unless
   risk. Name the tier, model id (`kernel/models.json`), effort and reasons
   in the packet and emit `model-selected`. Pin the id, never the alias
   (`haiku` can be an older generation; the Agent tool accepts the id).
   **The implementer runs on `balanced`.** It used to run on the executor class
   (Haiku on Claude); measured 2026-10-16, `claude-haiku-5-5` and `claude-sonnet-5-5`
   cost the same per token (`models.json -> tier_cost_observed`), so the cheaper
   class saved nothing and wrote weaker code (stale assertions, missing deliverables).
   For a backlog item whose `plan.md` Complexity is `high`/`extra-high`, whose SZ-3/SZ-4
   count is at its cap, or that is security-sensitive (auth, crypto, secrets, personal
   data, untrusted input), and on a retry after a FAIL, raise the effort to `high`.
   Any move to `strong-reasoning` still needs the gate.
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
11. **DeepThinking is a human-costed exception** (`.KCC/kernel/protocols/deep-thinking.md`).
   You may propose it in `auto` and under `--fasttrack`, only for the four tasks in
   `kernel/models.json -> deep_tasks` (not `human-directed`) and only when their trigger
   is clearly met; never from a silent run. Before each spawn emit `deep-proposed` with a
   cost range, ask the human once (approve at xhigh, approve at max, use strong, skip),
   emit `deep-approved` or `deep-declined`, then `deep-spawned` and, after the return,
   `deep-completed` with the actual cost. Tag every event `initiator: orchestrator`; at
   most `settings.json -> deep.max_per_run` per run. The human can also start one at any
   time with `/deep` (`initiator: human`, no run limit); never refuse or delay that.

### Harness binding

| Harness | How to spawn with the profile |
|---|---|
| Claude Code | `Agent(subagent_type: "<name>", prompt: <handover>)`. Model, effort, and tools come from `.claude/agents/<name>.md` frontmatter. Don't pass `model` except on an approved escalation (rule 7) or an approved deep spawn (rule 11). |
| Codex | Use `.codex/agents/<name>.md` (`model`, `model_reasoning_effort`) as the sub-session profile. |
| OpenCode | `@<name>` subagent from `.opencode/agents/<name>.md`. |
| Generic / Ollama | `.agents/manifest.json` or `ollama/agents.json`, keyed by agent name. |
| Switching harness | `.KCC/tools/kcc-handover.ps1\|.sh -To <harness> [-Launch] [-Unattended]`, then `auto resume` in the target. |

## Model classes

{{MODEL_CLASS_TABLE}}

## Agent profiles

Only the agents and skills listed here exist in this workspace. One that a
protocol or skill names but these tables omit was set aside by `kcc tailor`
(`.KCC/kernel/protocols/tailoring.md`): skip its step, record `skipped:
tailored out` in the trace, and do not improvise its work.

{{SPAWN_TABLE}}

## Skill routes

{{ROUTE_TABLE}}
