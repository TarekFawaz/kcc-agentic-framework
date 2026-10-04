---
title: Local MCP Server Protocol
aliases:
  - mcp
  - kcc-mcp
  - local-mcp
tags:
  - framework/protocol
  - mcp
  - cli
created: 2026-10-04
updated: 2026-10-04
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Local MCP Server

`kcc mcp` serves the framework to any MCP-capable harness over stdio. It
runs on the developer's own machine, one process per harness session, and
opens no network port. It is not a shared service: sharing capabilities and
policy between teams is a separate, later layer.

What it gives a harness:

- **Section-level reads.** An agent pulls one heading of a protocol instead
  of the whole file. This is the lazy-read rule of
  [[agent-runtime]] made addressable.
- **The gate tools** with their contract JSON, callable the same way from
  every harness.
- **Every skill as a prompt**, for harnesses without file-based skills.

Hooks, the status line, subagent files, git, and run state stay local files.
An MCP server cannot register those.

## Content source

Inside a workspace the server reads that workspace's `.KCC/`, so tailoring
and local edits are honoured. Outside a workspace it serves the copy
embedded in the `kcc` binary, read-only; the tools then answer that no
workspace exists.

## Resources

| URI | Content |
|--|--|
| `kcc://protocol/{name}` | `.KCC/kernel/protocols/{name}.md` |
| `kcc://dialect/{name}` | `.KCC/kernel/protocols/dialects/{name}.md` |
| `kcc://contract/{name}` | `.KCC/kernel/contracts/{name}.md` |
| `kcc://template/{path}` | `.KCC/kernel/templates/{path}` |
| `kcc://agent/{agent}/ref/{topic}` | `.KCC/capabilities/agents/refs/{agent}-{topic}.md` |

Add `#heading` to read one section: the heading line through the line before
the next heading of the same or a higher level. The fragment is the heading
text or its slug (`#Hard%20stops` or `#hard-stops`). An unknown heading is an
error that lists the headings that exist.

## Tools

Each tool wraps the script of the same purpose under `.KCC/tools/` and
returns its output unchanged ([[tool-contract]] JSON). Exit 1 (violations)
and exit 3 (deferred) are results; only exit 2 (usage or environment) is
reported as a failed call.

| Tool | Script | Notes |
|--|--|--|
| `kcc_read` | none | Same as a resource read, for harnesses that prefer tools. `heading`, `outline` |
| `kcc_check` | `check-run-conformance` | `scope`, `spec` |
| `kcc_traceability` | `check-traceability` | `spec` |
| `kcc_wave_scope` | `check-wave-scope` | `spec`, `wave`, `base` |
| `kcc_impl_lock` | `check-impl-lock` | `path` or `staged` |
| `kcc_quality_gate` | `quality-gate` | `spec`, `fast`, `scope`. Never installs scanners |
| `kcc_checkpoint` | `kcc-checkpoint` | `reason`, `next_action`, `dry_run` |
| `kcc_handover` | `kcc-handover` | `to`, `dry_run`. Never launches the target harness |
| `kcc_run` | `kcc-run` | `status`, `plan` (dry run), `answer` (open gate). Starting and resuming a run stays a terminal action |
| `kcc_validate` | `validate-kcc` | text report |
| `kcc_tailor` | none | Shows the recorded tailoring; changing it stays a terminal action |

## Prompts

One prompt per file in `.KCC/capabilities/skills/`, named after the skill,
with one optional argument `args` that replaces the skill's argument
placeholder. In Claude Code they appear as `/mcp__kcc__<skill>`.

## Registration

`kcc init --mcp` or `kcc mcp --register` adds the server where a project
config exists:

| Harness | File | Entry |
|--|--|--|
| Claude Code | `.mcp.json` | `"mcpServers": { "kcc": { "command": "kcc", "args": ["mcp"] } }` |
| Codex CLI | `.codex/config.toml` | `[mcp_servers.kcc]` with `command = "kcc"`, `args = ["mcp"]` |
| OpenCode | `opencode.json` | `"mcp": { "kcc": { "type": "local", "command": ["kcc", "mcp"], "enabled": true } }` |

Existing entries are kept. A config that cannot be parsed is not touched;
the snippet is printed instead.

## Safety

- stdio only; no listener, no outbound calls of its own.
- The tools run local scripts in the workspace. Per [[lethal-trifecta]],
  treat the server as a sensitive capability: do not combine it with
  untrusted input and an outbound channel outside the sandbox.
- No tool pushes, deploys, installs software, or starts a harness.

## Related

- [[tool-contract]] - the JSON every tool returns
- [[agent-runtime]] - lazy reads
- [[tailoring]] - why the served content can differ per workspace
- [[kcc-run]] - the driver behind `kcc_run`
