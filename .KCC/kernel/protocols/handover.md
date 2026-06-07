---
# Functional fields (none - protocols are pure prose)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Handover Envelope Protocol
aliases:
  - handover-envelope
  - handover-protocol
tags:
  - framework/protocol
  - cross-harness
created: 2026-05-24
updated: 2026-05-24
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Handover Envelope Protocol

## Purpose

The Handover Envelope is the lingua franca that lets the **same role** running
under **different harnesses or models** exchange work. Examples:

- Architect on Claude Opus 4.7 hands off to architect on Codex GPT-5.x for a
  second opinion.
- Planner on Codex CLI hands its plan to implementer on Claude Opus.
- Coder on Qwen3-max swaps mid-spec with coder on Kimi K2.6 so the human can
  compare outputs.
- Architect-Claude and Architect-Codex both review the same design, then a
  third agent reconciles their dissent.

There is **no automated bridge** between harnesses. The human is the
transport layer: they copy the envelope from one session and paste it into
the next. The envelope is plain markdown so any harness - Claude Code,
Codex CLI, OpenCode, Ollama-backed runners - can both produce and consume it.

This protocol defines the envelope schema, the copy/paste handoff procedure,
the fan-out convention for parallel second opinions, and the failure-mode
return path.

---

## Envelope schema

Every envelope is a single markdown document. The required sections appear
as H2 (`##`) headers in the order below. Sub-fields inside a section may be
H3 (`###`) or a bulleted key/value list - the goal is predictable headers
so a future parser can lift each block without breaking on free-form prose.

| Section                  | Required | Purpose                                                              |
|--|--|--|
| `## Envelope ID`         | yes      | Unique identifier so envelopes can be referenced and threaded        |
| `## Spec reference`      | yes      | Which spec or idea this work belongs to                              |
| `## From`                | yes      | Sender's role + model + harness                                      |
| `## To`                  | yes      | Target role + model + harness (may be wildcard, e.g. "any architect")|
| `## Lifecycle stage`     | yes      | One of: interrogate / create / plan / implement / test / review      |
| `## Input context`       | yes      | Files + line ranges or pasted snippets the receiver needs            |
| `## Output / deliverable`| yes      | What the sender produced - decision, plan section, diff, verdict     |
| `## Ask`                 | yes      | Imperative statement of what the receiver should do                  |
| `## Constraints / non-goals` | yes  | What the receiver must NOT do                                        |
| `## Human notes`         | optional | Free-form commentary the human added before forwarding               |
| `## Token cost so far`   | optional | Running token total if Token Guard has tracked it                    |

### Section-by-section definitions

#### `## Envelope ID`

Free-form, but the suggested format is:

```text
HANDOVER-{YYYY-MM-DD}-{seq}
```

where `{seq}` is a zero-padded counter that resets each day. For fan-out
and reconciliation envelopes, append `-A`, `-B`, `-RECON`, or `-RETURN`
(see "Multi-receiver fan-out" and "Failure modes" below).

#### `## Spec reference`

The spec or idea this work pertains to, linked when possible.

```markdown
## Spec reference
SPEC-003 - `specs/SPEC-003-rate-limiter.md`
```

If the work is pre-spec (still in ideation) reference the idea folder:

```markdown
## Spec reference
IDEA-007 - `ideation/IDEA-007/`
```

#### `## From`

Sender identity as three slash-separated fields: `role / model / harness`.

```markdown
## From
architect / claude-opus-4-7 / Claude Code
```

The **role** must match one of the agents defined in `.KCC/capabilities/agents/`.
The **model** is the concrete model name (not the model-class). The
**harness** is one of: Claude Code, Codex CLI, OpenCode, Ollama, or any
other listed in `.KCC/kernel/adapters/`.

#### `## To`

Same format as `From`. May be a wildcard if the human hasn't picked a
specific target model yet:

```markdown
## To
architect / any / any           # any architect on any model/harness
architect / gpt-5.0 / Codex CLI # specific target
```

#### `## Lifecycle stage`

Exactly one of the seven stage tokens from CLAUDE.md's lifecycle:
`interrogate`, `create`, `plan`, `implement`, `test`, `review`.

#### `## Input context`

Everything the receiver needs to rebuild the sender's context **without
access to the sender's session**. List files with line ranges, paste
short snippets inline, and link to spec / plan / ideation artifacts.

```markdown
## Input context
- `specs/SPEC-003-rate-limiter/SPEC-003-rate-limiter.md` (full file, ~120 lines)
- `specs/SPEC-003-rate-limiter/backlog.md` (stories/enablers relevant to the handoff)
- `src/api/middleware/throttle.ts` lines 1-80 (current implementation)
- `specs/SPEC-003-rate-limiter/plan.md` section "Ordered Changes" steps 1-4
- Inline excerpt of `CLAUDE.md` quality gate on backpressure (pasted below)

> Quality gate: all rate limiters must surface 429 with Retry-After header.
```

If the receiver's harness can read the repo directly, file paths suffice.
If not (e.g. a hosted model with no filesystem), paste the relevant
content inline so the envelope is self-contained.

#### `## Output / deliverable`

What the sender actually produced. This is the *substance* of the handover.

```markdown
## Output / deliverable
### Decision Required
Pick storage backend for rate limiter counters.

### Recommendation
Redis with sliding-window log. Reasons: existing Redis cluster, sub-ms
read latency, atomic Lua scripts available for window eviction.

### Options analyzed
... (full architect output)
```

#### `## Ask`

A single imperative sentence (or short paragraph) telling the receiver
exactly what to do. No ambiguity.

```markdown
## Ask
Critique the recommendation above. Specifically, challenge the choice of
sliding-window log vs token bucket, and identify any failure modes I missed
under network partition between API and Redis.
```

#### `## Constraints / non-goals`

What the receiver must NOT do. Prevents scope creep and keeps the loop tight.

```markdown
## Constraints / non-goals
- Do NOT propose a different storage backend (Redis is fixed by infra team).
- Do NOT write implementation code - this is still design phase.
- Do NOT expand scope beyond rate limiting (auth and quota are separate specs).
```

#### `## Human notes` (optional)

Anything the human wants to add before forwarding - context the agent
might not have, priority signals, preferences between dissenting options,
etc.

```markdown
## Human notes
Codex tends to be more conservative about distributed-systems edge cases.
Lean into that - I want the failure-mode critique to be harsh.
```

#### `## Token cost so far` (optional)

Running total if Token Guard has been tracking. Lets the receiver decide
whether to continue or compact. See `.KCC/kernel/protocols/token-budget.md`.

```markdown
## Token cost so far
- Interrogation: ~12k in / 8k out
- Architect (Claude Opus 4.7): ~24k in / 11k out
- **Cumulative: ~36k in / 19k out**
```

---

## Copy/paste protocol

The human is the transport. The flow is:

1. **Sender finishes work**, emits an envelope as the final block of its
   response (clearly delimited so the human can grab it).
2. **Human copies** the envelope verbatim - from the `## Envelope ID`
   line through the last section.
3. **Human opens the target session** (a fresh Claude Code, Codex CLI,
   OpenCode, or Ollama chat) and **pastes the envelope as the first user
   message**. No preamble, no wrapping commentary - the envelope itself
   is the prompt.
4. **Receiver recognizes the envelope shape** (the `## Envelope ID` /
   `## From` / `## To` / `## Ask` headers are the signature) and
   **confirms ingestion** before acting. The confirmation echoes:
   - The envelope ID it received
   - The role + model + harness it is running as
   - A one-line restatement of the Ask
   - Any missing context it would need pulled from disk
5. **Human approves** (one-word: "go" / "proceed") or **supplies missing
   context**, then the receiver executes the Ask.
6. **Receiver emits a return envelope** with its output and (usually)
   a new `## To` pointing back to the original sender's role.

**Why the confirmation step matters:** harnesses differ in tool access. A
Claude Code session can `Read` files directly; a hosted Codex session may
need the file contents pasted inline. The confirmation surfaces these
gaps before tokens are spent on the wrong context.

---

## Multi-receiver fan-out

For parallel second opinions (e.g. send the same architecture decision to
**both** Codex GPT-5 and Ollama-hosted Qwen3-max for independent critique),
the envelope is duplicated with suffixed IDs:

- `HANDOVER-2026-05-24-007-A` - sent to architect / gpt-5.0 / Codex CLI
- `HANDOVER-2026-05-24-007-B` - sent to architect / qwen3-max / Ollama

The two return envelopes come back as:

- `HANDOVER-2026-05-24-007-A-RETURN`
- `HANDOVER-2026-05-24-007-B-RETURN`

A third agent (typically an architect on a strong-reasoning model the human
trusts as tiebreaker) receives a **reconciliation envelope**:

- `HANDOVER-2026-05-24-007-RECON`

The RECON envelope's `## Input context` includes both `-A-RETURN` and
`-B-RETURN` verbatim, and its `## Ask` is: "Reconcile the two critiques.
Identify points of agreement, points of dissent, and recommend the path
forward."

Fan-out beyond two receivers is allowed - extend the suffix alphabetically
(`-A`, `-B`, `-C`, ...). The RECON envelope still uses a single `-RECON`
suffix regardless of the number of inputs.

---

## Failure modes

If the receiver's harness **cannot fulfill the ask**, it returns a
`RETURN` envelope with a `## Blocker` section instead of (or in addition
to) the normal `## Output / deliverable` section.

Common blockers and their handling:

| Blocker                                       | Handling                                                                                          |
|--|--|
| Required tool not available (e.g. `exec`, `web`) | Receiver lists the missing tool by its neutral name from `.KCC/kernel/README.md` and returns.       |
| Model context window too small for input      | Receiver returns immediately; human routes to a larger-context model or asks sender to compact.   |
| Cannot read referenced files (no filesystem)  | Receiver lists the file paths it cannot access; human re-sends envelope with files pasted inline. |
| Ask is ambiguous or contradicts constraints   | Receiver requests clarification in `## Blocker`; does not guess.                                  |
| Spec or plan referenced does not exist        | Receiver returns with the missing reference noted; human verifies the spec ID.                    |

### RETURN envelope shape

A RETURN envelope is structurally identical to a normal envelope, with:

- ID suffix `-RETURN` appended to the original envelope ID
- `## From` and `## To` swapped from the original
- A `## Blocker` H2 section inserted **before** `## Output / deliverable`
  (which may then be empty or partial)

```markdown
## Envelope ID
HANDOVER-2026-05-24-007-A-RETURN

## From
architect / gpt-5.0 / Codex CLI

## To
architect / claude-opus-4-7 / Claude Code

## Blocker
Cannot read `src/api/middleware/throttle.ts` - this Codex session has no
filesystem access. Please re-send with the file contents pasted inline
under `## Input context`.

## Output / deliverable
(none - blocked)
```

The human reads the blocker, fixes the gap (pastes the file, switches
model, clarifies the ask), and re-sends a fresh envelope with a new ID.
RETURN envelopes are not retried in place - every new attempt gets a new
top-level envelope ID so the audit trail stays linear.

---

## Recognition heuristics for receivers

A receiving agent should recognize an envelope by the presence of all of:

- An H2 header literally named `## Envelope ID` as the first or near-first heading
- An H2 header `## From` with a `role / model / harness` triple
- An H2 header `## Ask` with imperative content

If those three are present, treat the entire pasted block as an envelope
and follow the confirmation protocol above. If only some are present,
ask the human whether this was meant as an envelope or as ad-hoc input.

---

## See also

- [[handover-examples]] - three fully worked envelopes.
- [[token-budget]] - how `## Token cost so far` is populated.
- [[obsidian-standard]] - vault frontmatter and linking convention.
- `.KCC/kernel/README.md` - neutral agent and skill file formats.
