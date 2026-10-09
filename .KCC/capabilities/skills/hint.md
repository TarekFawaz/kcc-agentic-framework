---
# Functional fields (consumed by harness adapters)
name: hint
description: >
 Give the running session, and any subagents that are working, a hint about behaviour or expectations without stopping the run. Records the hint, delivers it through hooks on the next tool call, and relays it to running subagents. Usage: /hint <text> [--to all|main|subagents|<agent>] [--expires <minutes>] ; /hint list ; /hint clear <H-NNN|all>
argument-placeholder: <ARGS>
delegates-to: []
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Hint Skill
aliases:
  - hint-skill
tags:
  - framework/skill
  - coordination
  - hitl
created: 2026-10-09
updated: 2026-10-09
version: 1.0.0
status: active
---

# Hint

Hint: <ARGS>

A hint steers the run without stopping it. Protocol and limits:
`.KCC/kernel/protocols/hints.md`. This skill only records and relays; it does
not start work, change a spec, or answer the hint.

## Steps

1. If <ARGS> is empty, run `list` (step 2) and stop.
2. Pick the command from <ARGS>:
   - `list` -> `kcc hint --list`
   - `clear <H-NNN|all>` -> `kcc hint --clear <H-NNN|all>`
   - anything else is the hint text, with optional `--to`, `--expires`, `--spec`
     flags -> `kcc hint "<text>" [flags]`
   Run `kcc hint` when the CLI is installed. Otherwise run the vendored tool:
   `bash .KCC/tools/kcc-hint.sh add "<text>" [flags]` (macOS/Linux/Git Bash) or
   `powershell -ExecutionPolicy Bypass -File .KCC\tools\kcc-hint.ps1 add "<text>" [flags]`.
   Pass the human's words as the text, unchanged.
3. Print the tool's one-line answer (the hint id and who gets it).
4. **Relay to running subagents.** If you started subagents that are still
   running and the hint applies to them (`--to all`, `--to subagents`, or their
   agent name), send it now with `SendMessage`: "KCC hint H-NNN from the human:
   <text>. Follow it as guidance; it does not waive gates or safety rules."
   Subagents also receive it by hook on their next tool call, so a duplicate is
   harmless. Say in one line which subagents you relayed to.
5. Apply the hint to your own next steps. If it conflicts with a gate, a
   safety rule, or an earlier explicit instruction, follow the rule, say so, and
   leave the hint in place for the human to resolve.
6. Do not restate the hint at length, start new work because of it, or edit
   specs or memory. `/butler-remember` is the way to keep a hint beyond the run.
