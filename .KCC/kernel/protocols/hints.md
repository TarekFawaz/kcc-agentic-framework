---
title: Hint Protocol
aliases:
  - hints
  - kcc-hint
tags:
  - framework/protocol
  - coordination
  - hitl
created: 2026-10-09
updated: 2026-10-09
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Hints

A **hint** is one short note from the human to a run that is already going:
"prefer small PRs", "do not add dependencies", "the API is internal, skip the
rate-limit story". It steers behaviour and expectations without stopping the
run and without editing a spec. Use a [[../../capabilities/skills/bug-report|bug report]]
for a defect and a spec change for a scope change; a hint is for guidance.

A hint **never waives** a gate, a confidence threshold, a token-budget approval,
a safety rule, or an earlier explicit instruction. An agent that finds a hint in
conflict with one of those follows the rule, says so in its return, and
leaves the hint standing for the human to resolve.

## Giving a hint

| Where | Command |
|--|--|
| Any terminal | `kcc hint "text"` or `kcc --hint "text"` |
| Inside a session | `/hint text` (the skill runs the tool and relays to running subagents) |
| No CLI installed | `bash .KCC/tools/kcc-hint.sh add "text"` / `.KCC\tools\kcc-hint.ps1 add "text"` |

Options: `--to all` (default: the main agent and every subagent), `--to main`,
`--to subagents`, or `--to <agent>` (for example `implementer`);
`--expires <minutes>` for a note that should lapse; `--by <name>`;
`--spec <ID>`. `kcc hint --list` shows what is active; `kcc hint --clear
<H-NNN|all>` withdraws one. Keep a hint to a few sentences (the limit is 1200
characters); for more, put the text in a file and hint its path.

## Where hints live

`coordination/hints/hints.tsv`, one line per active hint:

```
id <TAB> to <TAB> expires_epoch(0=never) <TAB> created_epoch <TAB> by <TAB> text(JSON-escaped)
```

`coordination/hints/seen/<reader>` lists the ids already delivered to each
reader. Withdrawn hints move to `coordination/hints/archive.tsv`. The format is
line-oriented on purpose: delivery runs on every tool call and must not parse
JSON. Hints are workspace state like the backchannel; commit them or ignore them
as the team prefers.

## How a hint reaches a running agent

Delivery is by hook, because nothing can be pushed into a model mid-thought. The
`kcc-hint inject` hook (`.claude/settings.json`) fires on:

| Event | Reaches | When |
|--|--|--|
| `PreToolUse` (every tool) | main agent **and each running subagent** (the hook input carries `agent_id` and `agent_type`) | before the next tool call: seconds while a session is busy |
| `UserPromptSubmit` | main agent | the next prompt, when the session was idle |
| `SubagentStart` | the new subagent | when it starts |
| `SessionStart` (`startup`, `resume`, `clear`, `compact`) | main agent | a rebuilt context gets every active hint again |

Each hint is delivered once per reader and then stays in that reader's context.
With no active hint the hook reads its input and exits, so it costs one process
start per tool call and no tokens.

**Subagents.** Hooks fire inside subagents too, with `agent_id` and `agent_type`
set, so a running subagent should see the hint on its next tool call. Claude
Code does not document that this context always reaches the subagent's model,
so the main agent is also told to relay the hint with `SendMessage` to any
subagent still running. Between the two, a subagent is covered even where hooks
do not run inside it.
Whatever the harness, the spawn protocol puts every active hint in the handover
packet of each subagent started afterwards (`coordination/orchestrator.md`,
*Spawn protocol*).

**Harnesses without hooks (Codex CLI, OpenCode, generic).** The agent reads the
hints itself: `kcc hint --pending --for <agent>` prints those it has not seen
(`--for main` for the orchestrating agent) and marks them seen. The generated
`AGENTS.md` asks for this at the start of each state and each wave.

**Unattended runs** (`kcc run`, `kcc-run`): each state starts a fresh session, so
`SessionStart` delivers all active hints to it. A hint given during one state is
therefore honoured from the next state at the latest.

## Backchannel events

`hint-issued` (hint id, `to`, `by`, `expires_at`), `hint-delivered` (hint ids,
reader kind, agent type, hook event), `hint-cleared` (hint id). They go through
`backchannel-append`, so the dashboard and traces show when guidance was given
and who received it. Butler may promote a hint that proved right into memory
(`/butler-remember`); a hint is not memory by itself and lapses when cleared.

## Limits

A hint reaches a model only at a hook point. A subagent that is generating a long
answer with no tool call sees it afterwards. A hint is guidance, not a guarantee:
the verifier still checks against the spec's acceptance criteria.
