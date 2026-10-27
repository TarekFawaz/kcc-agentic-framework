---
# Functional fields (consumed by harness adapters)
name: deep
description: >
 Run one bounded analysis on the DeepThinking tier (the most capable model at xhigh or max effort) after you have seen the cost range. Use it for a named task (architecture-tradeoff, threat-model, failure-root-cause, cross-spec-consistency) or any question you name. Usage: /deep <task-id | question> [--agent <name>] [--effort xhigh|max] [--spec SPEC-ID]
argument-placeholder: <ARGS>
delegates-to:
  - architect
  - security-analyst
  - verifier
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Deep Skill
aliases:
  - deep-skill
tags:
  - framework/skill
  - models
  - cost
  - hitl
created: 2026-10-16
updated: 2026-10-16
version: 1.0.0
status: active
---

# Deep

Deep analysis: <ARGS>

The human's own entry to DeepThinking. The orchestrator can propose the same tier during `auto`; this skill
is for when you decide. Protocol, tasks, costs and events: `.KCC/kernel/protocols/deep-thinking.md`. It
produces one analysis file and never edits source, specs or plans.

## Steps

1. If <ARGS> is empty, list the four task ids and `human-directed` in one line each and stop.
2. Read `.KCC/settings.json -> deep.enabled` and `.KCC/kernel/models.json` (the `deep` entry of this harness,
   `deep_tasks`, `deep_cost_observed`). If disabled or the harness has no `deep` entry, say so in one line and
   offer `strong` at `high` instead; stop unless the human accepts it.
3. Resolve the task. If the first word of <ARGS> is a catalogue task id, use it and its agent
   (`--agent` may override only for `human-directed`). Otherwise the whole text is the question: task
   `human-directed`, agent `--agent` or `architect`.
4. Name the inputs. List the files the agent must read (paths and headings, never contents) from <ARGS> and
   `--spec`; ask for them only if the question cannot be answered without them.
5. **Show the cost, then ask once** (`AskUserQuestion`). Estimate: `0.8 + output_tokens x 0.000048 +
   extra_input_tokens x 0.00002` USD, as a low-high range from the output cap (an 80-line file is roughly
   20k-60k output tokens including thinking). Say it is an estimate and that `max` can cost several times
   `xhigh`. Options: **xhigh** (recommended), **max**, **strong instead** (Opus at `high`), **cancel**.
   `--effort` in <ARGS> pre-selects the answer but the range is still shown.
6. Record and spawn. Through `.KCC/tools/backchannel-append.ps1|.sh` emit `deep-proposed`, then on an
   answer `deep-approved` (`initiator: human`, `approved_by: human`) or `deep-declined`. Spawn the agent
   fresh (`Agent` with `model` = the registry `deep` id and `effort` = the chosen one), packet <= 300 words:
   the question, the read list, the output path `docs/deep/DEEP-{YYYYMMDD}-{slug}.md` (or the task's normal
   artifact when the task has one and `--spec` is given), the line cap from the protocol, and "analysis only:
   do not edit `src/`, specs or plans". Emit `deep-spawned` (`initiator: human`) first, `deep-completed` after
   with the actual cost and tokens from the `ActualTokenUsage` block.
7. Reply in <= 10 lines: the file written, the conclusion in 3 bullets, the actual cost against the
   estimate, and what to do next (who consumes the file). Do not paste the analysis.

## Notes

- Works in or out of an `auto` run. Not counted against `deep.max_per_run`; every call is approved by you.
- On `strong` or `cancel`, nothing deep runs. Say what ran instead, or that nothing did.
- A conflict with a gate or safety rule is not overridden by a deep answer: report it.
