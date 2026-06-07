---
# Functional fields (none - adapter docs are pure prose, no harness-consumed fields)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Ollama Adapter
aliases:
  - ollama-adapter
tags:
  - framework/adapter
  - harness/ollama
created: 2026-05-24
updated: 2026-06-05
version: 1.2.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Ollama adapter

Ollama is a **model runner**, not an agent harness. To use this framework with Ollama, you run it through a harness that supports an OpenAI-compatible endpoint pointed at Ollama (e.g. OpenCode, Aider, Continue.dev, or a custom wrapper using LiteLLM). This adapter document describes how the neutral model classes resolve to specific Ollama-hosted models.

## Invocation

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 ollama
# or, as part of an all-harness run:
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
```

## Convention

The sync script writes only two files (Ollama has no skill/prompt concept of its own):

| Output                     | Purpose                                                            |
|--|--|
| `ollama/agents.json`       | Per-agent model-class -> Ollama-model bindings, plus the class map. |
| `ollama/README.md`         | Documentation of the mapping and how to wire it through OpenCode.  |

The host harness (OpenCode is recommended) is responsible for delegating to the right model per agent - typically via `OPENAI_BASE_URL=http://localhost:11434/v1` and the model name from `agents.json`.

## Model class mapping

Defaults as of 2026; override per project by editing `ollama/agents.json` after sync.

| Neutral class         | Ollama model     | Approx VRAM |
|--|--|--|
| `strong-reasoning`    | `qwen2.5:72b`    | 48+ GB      |
| `balanced`            | `qwen2.5:32b`    | ~24 GB      |
| `fast-implementation` | `qwen2.5:14b`    | ~12 GB      |
| `local-strong`        | `qwen2.5:72b`    | 48+ GB      |
| `local-fast`          | `qwen2.5:7b`     | ~8 GB       |

Notes:

- Cloud-class `strong-reasoning` (Opus/GPT-5) has no faithful local equivalent. If a workflow requires it but only Ollama is available, escalate to the closest model - usually `local-strong` - and accept the quality drop. The Handover Envelope protocol (`.KCC/kernel/protocols/handover.md`) is the recommended way to bounce hard tasks back to a cloud session.
- Pick `qwen2.5:*` for code-heavy tasks (planner, implementer, verifier) and `llama3.1:*` when long-form reasoning is more important (architect, idea-interrogator).
- Quantization (`:q4_K_M`, `:q5_K_M`) trades quality for fit on smaller GPUs - set the suffix in `ollama/agents.json`.

## Argument placeholder

Whatever the host harness uses. OpenCode-via-Ollama uses `$ARGUMENTS`; a LiteLLM-based wrapper can substitute anything. The neutral `<ARGS>` token is rewritten by the sync script for the chosen host.

## Tool mapping

Ollama itself exposes no tools. Tool execution is the host harness's responsibility. The neutral `tools-required` list documents intent; the harness must grant equivalent permissions.

## Parallel execution realization

**Documented, not yet built.** Ollama has **no agent loop of its own**, so it
does **not** realize the spawner contract from
[[../protocols/parallel-execution|parallel-execution]] by process-level fan-out.

- **Mechanism:** parallelism = **concurrent model calls** issued by whichever
  harness is **driving** Ollama (e.g. OpenCode-via-Ollama). That driving harness
  realizes `run(independent_items)`; Ollama only serves the concurrent
  inference requests.
- **Bound:** concurrency is capped by `OLLAMA_NUM_PARALLEL` (set it in the Ollama
  server environment to match the wave width you expect, within VRAM limits).
- **Explicitly NOT:** Ollama itself does not spawn agent processes per wave item.
  Treat the driving harness's realization (Claude / Codex / OpenCode / generic)
  as the spawner; Ollama is the model backend with `num_parallel` configured.
- **Barrier / levels / merge-safety:** all owned by the driving harness; the
  file-disjoint wave rule and barrier semantics come from that harness, not from
  Ollama.

## Caveats

- Local models are markedly slower on long contexts. The `idea-interrogator` agent benefits most from a strong model - consider running interrogation against a cloud `strong-reasoning` model and only the implementation lifecycle against local models.
- Function/tool calling quality varies by model - Qwen2.5 family handles structured tool calls best among open models as of writing; Llama-3.1 family is weaker.
- No streaming-token cost meter - token-guard estimates may be less accurate; calibrate against a few real runs.
