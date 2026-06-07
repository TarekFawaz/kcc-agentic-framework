---
# Functional fields
description: Security pattern - any agent whose tool surface combines untrusted input, private data, and external communication must declare a confidence gate and route through critical-human-gate before execution.
inputs: An agent capability file under `.KCC/capabilities/agents/`.
outputs: A pass/warn verdict from `validate-kcc.ps1` plus a runtime gate requirement.

# Obsidian metadata
title: Lethal Trifecta Protocol
aliases:
  - lethal-trifecta
  - trifecta
  - kcc-security-trifecta
tags:
  - kcc/kernel
  - framework/protocol
  - security
created: 2026-05-25
updated: 2026-05-29
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Lethal Trifecta

KCC v0.4's distinctive security move. An agent that combines all three
of the following in the same tool surface is a **lethal trifecta** and
must be handled with extra care:

1. **Untrusted input** - text or content from outside the repository
   that the agent treats as instructions or data (raw human prompts,
   external file contents, web fetch results, scraped pages).
2. **Private data** - read access to the framework's sensitive
   stores: `memory/`, `coordination/`, secret-bearing config, or any
   path the human has marked sensitive.
3. **External communication** - the ability to send data outside the
   sandbox: `web` (fetch / search / post), or shell commands with
   network capability (`exec` without explicit network denial).

Individually, each is normal. **All three in the same agent** creates
an exfiltration path: untrusted input crafts an instruction that
causes the agent to read private data and forward it through the
external channel. This is the classic "prompt injection
exfiltration" failure mode.

## Map to this framework's semantics

The detector in `.KCC/tools/validate-kcc.ps1` uses these heuristics
against each `.KCC/capabilities/agents/*.md` frontmatter:

| Trifecta leg | Heuristic |
|--|--|
| Untrusted input | `inputs:` field text mentions `human`, `user`, `external`, or `prompt`. |
| Private data | `tools-required` contains `read` AND the agent body or `role:` mentions `memory/` or `coordination/`. |
| External comms | `tools-required` contains `web` OR `exec` is present without a narrow scope comment that explicitly disclaims network use. |

These are deliberately broad. False positives are fine - the
required mitigation is light. False negatives are the failure mode
to avoid.

## Required mitigation

Any agent triggering all three legs MUST:

1. Declare `confidence-gate: required` in its functional frontmatter.
2. Have its delegating skill explicitly route through
   [[critical-human-gate]] before invocation - meaning the skill's
   `delegates-to:` chain includes `critical-human-gate` or the
   skill body documents an explicit pre-call check.
3. Document in its `## Constraints` section which trifecta leg is
   intentional (often `web` for research; sometimes raw human
   prompt is unavoidable for an interrogator).

## Exact gate handshake

When a trifecta-flagged agent is about to execute its first
external-comms action in a turn, the orchestrator MUST first invoke
[[critical-human-gate]] with this payload:

```text
Lethal Trifecta gate triggered:
- Agent: {agent}
- Untrusted input source: {what is being treated as input}
- Private data scope: {paths the agent has read since turn start}
- External comms target: {URL / domain / command}
- Proposed next action: {one-sentence description}

Choose: approve | revise | abort
```

`escalate` is intentionally omitted from the choice menu - a
trifecta firing is already at the highest escalation, so the
remaining decisions are go / change / stop.

Recording follows the standard [[confidence-gate]] convention:
`coordination/backchannel.jsonl` gets `trifecta-gate-triggered` and
`trifecta-gate-resolved` events; if a trace session is open,
`Traces/Session-*/HumanDecisions.md` gets the verdict appended.

## Validator behavior

`validate-kcc.ps1` runs the heuristic on every agent file. For each
match where `confidence-gate: required` is **not** present in
frontmatter, it emits a **WARNING** (not a hard error) of the form:

```text
Lethal Trifecta WARNING: {agent} matches all three legs
  - untrusted-input: {evidence}
  - private-data: {evidence}
  - external-comms: {evidence}
  Fix: add `confidence-gate: required` to its frontmatter and route
       the delegating skill through `critical-human-gate`.
```

It is a WARNING rather than an ERROR because:

- The heuristic is broad and can over-fire.
- Some agents legitimately combine all three with the mitigation
  already declared.
- Hard-failing the validator would block honest work while a real
  fix is being authored.

When automation matures (Phase 3, see [[phase-model]]), this should
graduate to a hard runtime block at skill invocation - not just a
lint warning.

## Auto-sandbox mitigation

Once `validate-kcc.ps1` flags an agent as matching all three trifecta
legs, the recommended runtime mitigation is **two-part**:

1. **Declare the gate.** Add `confidence-gate: required` to the
   agent's frontmatter so the orchestrator routes the delegating skill
   through [[critical-human-gate]] before the first external-comms
   action of every turn.
2. **Enable auto-sandbox.** Add `lethal-trifecta-match: true` to the
   agent's frontmatter. `.KCC/tools/start-agent-session.ps1` reads this
   marker and **automatically launches the session inside the per-harness
   Docker sandbox** (see [[sandbox-runtime]]) - even when the human
   does not pass `--sandbox` explicitly. The host filesystem and
   non-LLM network egress are then off-limits to the agent regardless
   of how the gate is answered.

These two mitigations are complementary, not alternatives. The gate
catches what a human would catch (prompt injection visible in the
proposed next action). The sandbox catches what a human would miss
(an approved action that quietly tries to read `~/.ssh/id_rsa` or
POST to an attacker-controlled domain). Use both.

A trifecta-marked agent that is *also* invoked via
`start-agent-session.ps1 --sandbox` runs in the sandbox once - the
flag and the marker are idempotent.

## Related

- [[confidence-gate]] - the general human-gate protocol this
  layers on.
- [[critical-human-gate]] - the skill the trifecta gate routes
  through.
- [[sandbox-runtime]] - the per-harness Docker isolation that
  trifecta-marked agents launch into automatically.
- [[backchannel]] - event log for gate triggers and resolutions.
- [[phase-model]] - Phase 3 promotes this from lint to runtime.
- [[inspector/README|Inspector Pipeline]] - Detect stage flags
  `trifecta-violation` candidates immediately without an evidence
  threshold.
