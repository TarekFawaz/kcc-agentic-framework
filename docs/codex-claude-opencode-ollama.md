---
title: Codex, Claude Code, OpenCode, and Ollama Support
aliases:
  - codex-claude-opencode-ollama
  - harness-support
tags:
  - framework/documentation
  - codex
  - claude-code
  - opencode
  - ollama
created: 2026-06-07
updated: 2026-06-07
version: 1.0.0
status: active
---

# Codex, Claude Code, OpenCode, and Ollama Support

KCC keeps one neutral source of truth under `.KCC/` and generates harness
adapter surfaces from it.

| Harness | Generated output |
|---|---|
| Codex CLI | `.codex/agents/`, `.codex/skills/`, `.codex/tools/` |
| Claude Code | `.claude/agents/`, `.claude/skills/` |
| OpenCode | `.opencode/agents/`, `.opencode/commands/`, `.opencode/skills/` |
| Generic | `.agents/agents/`, `.agents/skills/`, `.agents/tools/` |
| Ollama | `ollama/agents.json`, `ollama/README.md` |

Edit `.KCC/kernel/` or `.KCC/capabilities/`, then regenerate:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
```

This keeps every harness aligned while preserving local team ownership.

## Related

- [KCC Quickstart](../QUICKSTART.md)
- [KCC vs agent frameworks](./kcc-vs-agent-frameworks.md)

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](../LICENSE).
