---
# Functional fields (none - examples doc, pure prose)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Handover Envelope - Worked Examples
aliases:
  - handover-examples
tags:
  - framework/protocol
  - cross-harness
  - examples
created: 2026-05-24
updated: 2026-05-24
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Handover Envelope - Worked Examples

Three complete envelopes a human could copy-paste today. Each demonstrates
a different cross-harness pattern from [[handover]].

- **Example 1** - Second-opinion architecture (fan-out with RETURN).
- **Example 2** - Cross-harness lifecycle handoff (planner -> implementer).
- **Example 3** - Mid-spec coder swap with partial progress.

---

## Example 1 - Second-opinion architecture (Claude Opus -> Codex GPT-5)

**Scenario:** Architect running on Claude Opus 4.7 has produced a
recommendation for SPEC-003 (rate limiter storage backend). The human
wants Codex GPT-5 to critique it before locking the decision.

### 1a. Outbound envelope (Claude Opus -> Codex GPT-5)

```markdown
## Envelope ID
HANDOVER-2026-05-24-001-A

## Spec reference
SPEC-003 - `specs/SPEC-003-rate-limiter.md`

## From
architect / claude-opus-4-7 / Claude Code

## To
architect / gpt-5.0 / Codex CLI

## Lifecycle stage
plan

## Input context
- `specs/SPEC-003-rate-limiter.md` (full file, ~120 lines) - acceptance
  criteria include sub-100ms p99 latency and Retry-After header on 429s.
- `src/api/middleware/throttle.ts` lines 1-80 - current naive in-memory
  counter implementation (gets reset on every pod restart, hence this spec).
- `CLAUDE.md` quality gate (pasted): "All rate limiters must surface 429
  responses with a Retry-After header indicating seconds until next window."
- Infra constraint from ops team: a Redis 7 cluster already exists in
  every environment; provisioning a new datastore requires a separate RFC.

## Output / deliverable

### Decision Required
Pick storage backend and algorithm for distributed rate limiter counters
serving ~8k req/s across 12 API pods.

### Options Analyzed

- **Option 1: Redis + sliding-window log**
  - How it works: per-key sorted set, score = unix-ms, ZADD on hit, ZREMRANGEBYSCORE on read.
  - Pros: exact accounting, atomic via Lua, sub-ms reads with existing cluster.
  - Cons: O(N) memory per key where N = window size; Lua adds CPU on Redis.
  - Impact on quality gates: meets latency gate; Retry-After computed from oldest entry.

- **Option 2: Redis + token bucket**
  - How it works: per-key hash of `tokens` and `last_refill_ms`, atomic Lua refill.
  - Pros: O(1) memory per key; cheap CPU; standard pattern.
  - Cons: bursty traffic can briefly exceed nominal rate within a refill tick.
  - Impact on quality gates: meets latency; Retry-After is an approximation, not exact.

- **Option 3: In-process counter + gossip**
  - How it works: each pod tracks local counter, gossips via existing service mesh.
  - Pros: zero Redis dependency; survives Redis partition.
  - Cons: eventual consistency means overage during gossip lag; complex to test.
  - Impact on quality gates: violates exact-accounting expectation in spec.

### Recommendation
**Option 1 (Redis + sliding-window log).** The Redis cluster is already
provisioned, exact accounting matches the spec's "no more than N per
window" criterion, and the Lua atomicity avoids the network-partition
race we'd hit with read-modify-write.

### Risks
- Memory growth on hot keys (mitigation: TTL = window size).
- Redis cluster failure halts rate limiting entirely (mitigation: fail-open
  with metrics alert; the spec accepts this trade-off).

### Impacted Services/Files
- `src/api/middleware/throttle.ts` - rewrite.
- `src/api/lua/sliding-window.lua` - new file.
- `infra/redis/keyspaces.md` - document new key prefix `rl:`.

## Ask
Critique the recommendation. Specifically: (a) challenge sliding-window
log vs token bucket on the exact-accounting trade-off, and (b) enumerate
failure modes I missed under a network partition between API pods and
the Redis cluster. Do not propose a different storage backend.

## Constraints / non-goals
- Do NOT propose a different storage backend (Redis is fixed by ops RFC).
- Do NOT write implementation code - this is still design phase.
- Do NOT expand scope beyond rate limiting (auth and quota are separate specs).

## Human notes
Codex tends to be sharper on distributed-systems edge cases than Claude.
Lean into that - I want a harsh failure-mode critique, not validation.

## Token cost so far
- Interrogation (IDEA-007): ~12k in / 8k out
- Architect (Claude Opus 4.7): ~24k in / 11k out
- **Cumulative: ~36k in / 19k out**
```

### 1b. Return envelope (Codex GPT-5 -> Claude Opus)

```markdown
## Envelope ID
HANDOVER-2026-05-24-001-A-RETURN

## Spec reference
SPEC-003 - `specs/SPEC-003-rate-limiter.md`

## From
architect / gpt-5.0 / Codex CLI

## To
architect / claude-opus-4-7 / Claude Code

## Lifecycle stage
plan

## Input context
- Original envelope HANDOVER-2026-05-24-001-A (received in full, ingestion
  confirmed at start of session).
- No additional files needed - original envelope was self-contained.

## Output / deliverable

### Critique of sliding-window log recommendation

**Where I agree:** Exact accounting matches the spec language and Lua
atomicity is the right primitive given the existing Redis. Fail-open on
Redis loss is the correct posture for an API edge.

**Where I dissent:**

1. **Sliding-window log is memory-hostile under abuse.** A malicious or
   buggy client hammering a single key at, say, 1000 req/s with a 60-s
   window stores 60k sorted-set entries per key. At 8k req/s aggregate
   across hot keys this becomes the dominant memory pressure on the
   Redis cluster - not the rate-limited app traffic itself. Token bucket
   stays O(1) regardless of attack volume. The recommendation should
   either (a) switch to token bucket and accept burst approximation, or
   (b) keep sliding-window log but cap entries per key with ZREMRANGEBYRANK
   and document the resulting accuracy loss under abuse.

2. **Missed failure mode - partial partition.** The risks section only
   considers total Redis loss. The harder case is *partial* partition:
   half the API pods can reach Redis, half can't. Fail-open on the
   unreachable half means real overage at exactly the moment you most
   want enforcement (likely correlated with the network event causing
   the partition). Mitigation: circuit-breaker per pod with a short
   open window, plus a metric on fail-open rate that triggers paging.

3. **Missed failure mode - Lua script eviction.** Redis evicts cached
   scripts under memory pressure (`MAXMEMORY` with `allkeys-lru`). First
   request after eviction does a full SCRIPT LOAD + EVAL, adding ~10ms
   of latency cliff. Mitigation: SCRIPT LOAD at pod startup and on
   NOSCRIPT errors, not just lazily.

4. **Clock skew across API pods.** Sliding-window log scores are unix-ms
   from the pod's clock. NTP drift of even 100ms across pods means
   inconsistent eviction. Mitigation: use Redis `TIME` command as the
   score source (one extra round-trip per request - measure if acceptable).

### Net verdict
Recommendation is defensible but under-specified. I would add the four
mitigations above to the Risks section before locking the decision. If
abuse-resistance is a stated requirement, switch to token bucket.

## Ask
Decide whether to incorporate the four mitigations into the architect
recommendation, switch algorithms, or escalate to the human for a
priority call between exact-accounting and abuse-resistance.

## Constraints / non-goals
- Did NOT propose alternative storage backends (Redis constraint respected).
- Did NOT write implementation code.

## Human notes
(none added on return path)

## Token cost so far
- Inherited from outbound: ~36k in / 19k out
- This Codex turn: ~14k in / 6k out
- **Cumulative: ~50k in / 25k out**
```

### 1c. Reconciliation pattern (optional third step)

If the human had also sent the outbound envelope to a Qwen3-max architect
as `HANDOVER-2026-05-24-001-B`, both `-A-RETURN` and `-B-RETURN` would
feed into a `HANDOVER-2026-05-24-001-RECON` envelope routed to a third
architect (or back to the Claude Opus original) whose `## Ask` is:
"Reconcile the two critiques. Identify points of agreement, points of
dissent, and recommend the path forward."

---

## Example 2 - Cross-harness lifecycle handoff (planner Codex -> implementer Claude Opus)

**Scenario:** Planner running on Codex CLI has produced a plan for SPEC-004
(add OpenAPI spec generation). Human wants the implementer to run on
Claude Opus because Claude Code has the filesystem `edit` tool wired up.

```markdown
## Envelope ID
HANDOVER-2026-05-24-002

## Spec reference
SPEC-004 - `specs/SPEC-004-openapi-generation.md`

## From
planner / gpt-5.0 / Codex CLI

## To
implementer / claude-opus-4-7 / Claude Code

## Lifecycle stage
implement

## Input context
- `specs/SPEC-004-openapi-generation.md` (full file, ~95 lines).
- `specs/SPEC-004-zod-validation/plan.md` (the plan being handed off - full content
  pasted below since the receiving harness should read it from disk but
  also has it inline as a fallback).
- `src/api/routes/` (12 route files, listed in plan step 1).
- `package.json` - note `zod` and `zod-to-openapi` are already declared.
- Dependency check from `specs/specs.md`: SPEC-002 (Zod schemas) is **Done**;
  no other blockers.

### Inline copy of `specs/SPEC-004-zod-validation/plan.md`

> ### Dependency Check
> SPEC-002 (Zod schemas on every route) is Done. No blockers.
>
> ### Ordered Changes
>
> 1. **File:** `src/api/openapi/generator.ts` (new)
>    **Change:** Implement `buildOpenApiDocument()` that walks the route
>    registry and emits an OpenAPI 3.1 document via `zod-to-openapi`.
>    **Why:** AC-1 (single source of truth for API contract).
>    **Depends on:** nothing.
>
> 2. **File:** `src/api/openapi/registry.ts` (new)
>    **Change:** Export `registerRoute(method, path, schemas)` that
>    collects route metadata for the generator to consume.
>    **Why:** AC-1; decouples route declaration from generator.
>    **Depends on:** step 1.
>
> 3. **Files:** `src/api/routes/*.ts` (12 files)
>    **Change:** In each route module, call `registerRoute(...)` once at
>    module load with the route's Zod schemas.
>    **Why:** AC-2 (every route present in generated spec).
>    **Depends on:** step 2.
>
> 4. **File:** `src/api/routes/index.ts`
>    **Change:** Add `GET /openapi.json` returning `buildOpenApiDocument()`.
>    **Why:** AC-3 (spec is fetchable at runtime).
>    **Depends on:** step 3.
>
> 5. **File:** `tests/api/openapi.test.ts` (new)
>    **Change:** Snapshot test of `/openapi.json` and contract test that
>    every route file is represented.
>    **Why:** AC-4 (regression protection).
>    **Depends on:** step 4.
>
> ### Risk Flags
> - Module-load side effects (the `registerRoute` calls) require the route
>   files be imported before the generator runs. Confirm import order in
>   `src/api/bootstrap.ts`.
> - Snapshot test will churn on every legitimate API change - document the
>   `--update-snapshot` workflow.
>
> ### Verification Steps
> - `npm run typecheck`
> - `npm test -- openapi`
> - `curl localhost:3000/openapi.json | jq '.paths | keys | length'` should
>   equal the number of route files.
>
> ### Scope
> Medium (5 logical changes touching 15 files).

## Output / deliverable
The plan above is the deliverable. Codex has not written any code - that
is the implementer's job. Codex also confirms the dependency check
(SPEC-002 status verified against `specs/specs.md`) and flagged two
risks the implementer should keep in mind.

## Ask
Execute the plan above in the exact order shown. Commit per logical
change with message `SPEC-004: step {N} - {summary}`. After step 4,
run the verification commands and paste their output before continuing
to step 5. Return an envelope when complete (or earlier if blocked).

## Constraints / non-goals
- Do NOT alter any acceptance criteria - they are locked.
- Do NOT add routes that are not already in `src/api/routes/`.
- Do NOT skip the bootstrap import-order check (risk flag 1).
- Do NOT update snapshots without showing the diff to the human first.

## Human notes
The 12 route files are mostly mechanical changes. If you find yourself
varying the `registerRoute(...)` call shape between files, stop and flag
it - that means the routes themselves are inconsistent and need a
separate cleanup spec.

## Token cost so far
- Spec creation: ~9k in / 4k out
- Planning (Codex): ~22k in / 7k out
- **Cumulative: ~31k in / 11k out**
- Token Guard estimate for implement phase: 60-90k additional.
```

---

## Example 3 - Mid-spec coder swap (Qwen3-max -> Kimi K2.6)

**Scenario:** Coder on Qwen3-max has implemented steps 1-3 of an 8-step
plan for SPEC-005 (background job queue). Human wants to compare Kimi
K2.6's output for the remaining 5 steps. Partial progress and a clear
restart point must be conveyed.

```markdown
## Envelope ID
HANDOVER-2026-05-24-003

## Spec reference
SPEC-005 - `specs/SPEC-005-job-queue.md`

## From
implementer / qwen3-max / Ollama

## To
implementer / kimi-k2-6 / Ollama

## Lifecycle stage
implement

## Input context

### Spec and plan (read from disk)
- `specs/SPEC-005-job-queue.md` (full file, ~140 lines).
- `specs/SPEC-005-cli-output/plan.md` - 8 ordered steps. Steps 1-3 are DONE
  (commits below). Steps 4-8 are the work to take over.

### Commits already landed on branch `spec/SPEC-005`
- `a1b2c3d` - "SPEC-005: step 1 - add `JobQueue` interface in `src/jobs/types.ts`"
- `d4e5f6a` - "SPEC-005: step 2 - implement `InMemoryQueue` in `src/jobs/in-memory.ts`"
- `b7c8d9e` - "SPEC-005: step 3 - add `JobRunner` worker loop in `src/jobs/runner.ts`"

### Current state of changed files (read from working tree at commit b7c8d9e)
- `src/jobs/types.ts` - defines `Job`, `JobQueue`, `JobHandler`, `JobResult`.
- `src/jobs/in-memory.ts` - FIFO queue with retry counter; passes the in-memory
  branch of `tests/jobs/queue.test.ts`.
- `src/jobs/runner.ts` - worker loop with backoff. Has a TODO at line 47
  about graceful shutdown that step 6 of the plan is supposed to resolve.

### Remaining plan steps (4-8) - verbatim from `specs/SPEC-005-cli-output/plan.md`

> 4. **File:** `src/jobs/redis-queue.ts` (new)
>    **Change:** Implement `RedisQueue` satisfying `JobQueue`, backed by
>    `BLPOP` for blocking dequeue and a `LREM`-based dead-letter list.
>    **Why:** AC-2 (queue survives restart).
>    **Depends on:** step 1.
>
> 5. **File:** `src/jobs/factory.ts` (new)
>    **Change:** Export `createQueue(config)` returning `InMemoryQueue`
>    when `config.driver === 'memory'` and `RedisQueue` otherwise.
>    **Why:** AC-3 (driver swappable via config).
>    **Depends on:** steps 2 and 4.
>
> 6. **File:** `src/jobs/runner.ts`
>    **Change:** Replace the TODO at line 47 with a SIGTERM handler that
>    finishes the in-flight job, persists the queue cursor, then exits.
>    **Why:** AC-4 (no job loss on deploy).
>    **Depends on:** step 3.
>
> 7. **File:** `tests/jobs/redis-queue.test.ts` (new)
>    **Change:** Integration test against a `redis-memory-server` fixture.
>    **Why:** AC-2 verification.
>    **Depends on:** step 4.
>
> 8. **File:** `docs/jobs.md` (new)
>    **Change:** Operator-facing doc: config keys, metrics, SIGTERM behavior.
>    **Why:** AC-5 (operability).
>    **Depends on:** steps 4-6.

### Qwen handoff notes on the in-flight work
- The `JobHandler` signature in `types.ts` is `(job: Job) => Promise<JobResult>`.
  Step 4 (`RedisQueue`) must NOT change this signature - the in-memory
  tests depend on it.
- I tried step 4 partially and reverted (no commit). The aborted attempt
  used `BRPOPLPUSH` for at-least-once semantics, but I am not confident
  that the dead-letter `LREM` cleanup is race-free under multiple workers.
  Recommend Kimi reconsider from scratch - do not anchor on my abandoned
  approach. The reverted code is not in git history.
- Tests for steps 1-3 pass: `npm test -- jobs/queue` is green at b7c8d9e.

## Output / deliverable
Steps 1-3 implemented and committed on branch `spec/SPEC-005`. Working
tree is clean at `b7c8d9e`. The unfinished step 4 work has been
discarded - there is no half-committed state.

## Ask
Pick up at step 4 of the plan and execute steps 4 through 8 in order.
Commit per step with the convention `SPEC-005: step {N} - {summary}`.
Run `npm test -- jobs` after step 7 and paste output. Return an envelope
when step 8 is committed (or earlier if blocked).

## Constraints / non-goals
- Do NOT modify `src/jobs/types.ts` - the interface is locked at step 1.
- Do NOT modify `src/jobs/in-memory.ts` or `src/jobs/runner.ts` except
  for the explicit step-6 SIGTERM change in `runner.ts`.
- Do NOT rewrite steps 1-3 even if you would have done them differently.
- Do NOT introduce a third queue driver - the plan is `memory` and `redis` only.
- Do NOT skip the integration test in step 7 (AC-2 requires it).

## Human notes
I am running Qwen and Kimi back-to-back on the same plan tail so I can
diff the two implementations. Please keep your style readable and your
commits atomic - the comparison is the point. If you disagree with a
plan step, raise it in a return envelope rather than silently deviating.

## Token cost so far
- Spec + plan: ~28k in / 9k out
- Implementer (Qwen, steps 1-3): ~41k in / 18k out
- Aborted step 4 attempt (not committed): ~9k in / 4k out
- **Cumulative: ~78k in / 31k out**
- Token Guard estimate for steps 4-8: 45-65k additional.
```
