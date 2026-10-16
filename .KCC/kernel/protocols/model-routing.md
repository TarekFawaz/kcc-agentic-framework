---
# Functional fields
description: How a model tier and an effort level are chosen for each agent run from the task, the domain, the risk, the size, the attempt and the budget, instead of one fixed model per agent.
inputs: The agent's default class (frontmatter), the state, `Research.md -> ## Domain`, the plan's Complexity and item sizes, the attempt number, the remaining budget, and `kernel/models.json`.
outputs: A tier (`strong` | `balanced` | `fast`), an effort (`low` .. `xhigh`), the reasons, recorded in the handover packet and a `model-selected` event.

# Obsidian metadata
title: "Model Routing Protocol"
aliases:
  - model-routing
  - model-router
tags:
  - framework/protocol
  - orchestration
  - models
created: 2026-10-16
updated: 2026-10-16
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
---

# Model routing

The router stops at `strong`. The `deep` tier (xhigh/max on the most capable model) is never a router
output: it is a human-costed exception for four named tasks, see [[deep-thinking]].

Each agent has a default class in its frontmatter (`model-class`) and a default effort. The router
moves that default by at most one tier up or down, and sets the effort, from signals it can read.
No signal, no move. The registry of what each tier is on each harness is `kernel/models.json`.

## Signals

| Signal | Read from | Values |
|--|--|--|
| Task | the state | `research` (IDEA), `architecture` (ARCH), `security` (security brief, CR-7 items), `spec`, `plan`, `review` (TEST, REVIEW), `implement`, `scaffold` (wave 1 enablers), `docs`, `close` |
| Domain | `ideation/IDEA-*/Research.md -> ## Domain` | `common` (well-known problem space), `specialised`, `novel` |
| Risk | CR-7 domains in the item, or `Complexity: high` / `extra-high` in `plan.md` | yes / no |
| Size | the wave's items and the item's Impacted Files | items > 3 or files > 5 is "large" |
| Attempt | the driver's attempt counter | 1, 2, 3 |
| Budget | `--budget` remaining | % left |

## Rules (applied in this order; tier is clamped to default +/- 1)

1. Start at the agent's default tier and effort.
2. **Task floor.** `research`, `architecture`, `security` never run below `balanced`.
3. **Domain.** `novel`: one tier up and effort `high`. `common`: one tier down for `spec`,
   `plan`, `docs`, `scaffold` (writing well-known things), effort unchanged.
4. **Risk.** Never below `balanced`; effort `high`.
5. **Size.** Large: effort one step up.
6. **Retry.** Attempt 2 or later: one tier up and effort one step up, for the agent that is fixing something
   (implementer, spec-writer ...). A verifier or critic (task `review`) is **never** escalated for a retry: its second run
   is a re-check of the fixes, not harder work (round 10: a retried verifier ran on Opus at xhigh for 25 minutes).
7. **Budget.** Under 20% left: never above `balanced` unless risk.
8. Effort is clamped to `low` .. `xhigh`; `max` is a human choice only.
9. **Caller ceilings.** `kcc-route -MaxTier / -MaxEffort` (`--max-tier / --max-effort`) cap the result. `kcc-run` caps REVIEW
   (`/spec-review` is a quick diff review) and a scoped TEST re-verification at `balanced` tier and `high` effort. The first,
   full TEST pass keeps what rules 1-7 give (a security-sensitive large spec still gets `high` or `xhigh`).

Examples: an implementer (`fast`, `medium`) on a common CRUD wave stays `fast / medium`; the same
implementer on an auth module (risk) runs `balanced / high`; a spec-writer (`balanced`, `high`) on a
common domain writes on `fast / high`; an architect (`balanced`, `high`) on a novel domain runs
`strong / high`.

## Plan time, per backlog item (`## Routing`)

The architect and the planner are the ones who know how hard each item is, so the decision is taken once, after the plan,
per item (story, enabler), not per agent for the whole run. `kcc route [SPEC-ID]` reads each item's `Complexity`, the
files in its Backlog item, `Research.md -> ## Domain` and the CR-7 words in its notes and ACs (auth, password, session,
csrf, token, crypto, payment, personal data), runs the rules above for the `implement` task, and writes
`## Routing` into `plan.md`:

| Item | Wave | Tier | Model | Effort | Why |

- `kcc run` does this itself right after SPECS; in a chat run the orchestrator runs `kcc route SPEC-ID` after the plan.
- Implementation is capped at `routing.implement_max_tier` (settings, default `balanced`): a novel domain raises its
  effort, not its price class. `extra-high` Complexity gives `xhigh` effort. Set the cap to `strong` to let the
  router go higher.
- `kcc-run` reads the table and passes each wave (and the FIX pass) the strongest model and effort among that wave's
  items, emitting `model-selected`. A retry raises the effort one step. The drivers hold no routing rules of their own
  when the table exists; without it they keep their older subset.
- The planner does not write this table by hand; it fills the `Complexity` column.

## Where it runs: one router, three identical copies, every cycle

The reference is `cli/src/run/router.ts`; `.KCC/tools/kcc-route.ps1` and `kcc-route.sh` are line-for-line ports and a parity
test feeds all three the same cases. Every flow asks it before it spawns an agent:

| Flow | Who asks | How |
|--|--|--|
| `kcc run` / `kcc-run`, every state, every cycle (full `auto` and `--fasttrack`) | the driver | `kcc-route -Agent <state agent> -Spec -Wave -Attempt`; a direct worker (fast track) gets the model and effort as flags, an orchestrator session is told in its prompt which tier, model and effort to spawn the agent on; `model-selected` records it |
| chat `auto`, and any skill a developer runs by hand | the orchestrator | spawn rule 7: run `kcc-route` before each spawn and pass its model and effort to the Agent call |
| `kcc route [SPEC-ID]` | anyone | writes the per-item `## Routing` table into `plan.md` for reading and review |

The answer is already in the active harness's terms: the model id from `kernel/models.json` (its registry column, `run.registry`)
and the effort folded onto what the harness accepts (`kernel/harnesses.json`), so Codex, OpenCode, Ollama-behind-OpenCode and
Claude all route the same way with their own models.


- **Chat (`auto`)**: the orchestrator applies the rules when it writes the handover packet
  (`orchestrator.md` -> Spawn protocol rule 7) and names the tier, effort and reasons in the packet;
  it emits `model-selected` (`agent`, `tier`, `model`, `effort`, `reasons`).
- **Driver (`kcc-run`)**: for a direct agent run (`claude --agent`) it applies the same rules from
  the signals it has (domain, complexity, attempt) and passes `--model` and `--effort`.
- **CLI**: `kcc models` lists the registry; `kcc models --check` probes every pinned id against the
  installed harness and fails on an unknown id or a disagreement with the generated agent files;
  `kcc models --refresh` also reports what each alias resolves to today, so a newer generation is
  noticed. `kcc doctor` warns when the registry's `verified` date is older than 30 days.

## Related

- DeepThinking: [[deep-thinking]]
- Orchestrator spawn protocol: `kernel/templates/orchestrator.md`
- Registry: `kernel/models.json`
- Harness adapters: [[../adapters/claude|claude]], [[../adapters/codex|codex]]
