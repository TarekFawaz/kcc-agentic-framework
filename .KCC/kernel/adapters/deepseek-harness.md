---
# Functional fields (none - adapter docs are pure prose, no harness-consumed fields)

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: DeepSeek Harness (dsh) Adapter
aliases:
  - deepseek-harness-adapter
  - dsh-adapter
tags:
  - framework/adapter
  - harness/dsh
created: 2026-08-28
updated: 2026-08-28
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# DeepSeek Harness (dsh) adapter

How `.KCC/kernel/` neutral sources are surfaced to the DeepSeek harness
(`dsh` CLI) as native project-local skill packages, and what boundary those
generated workers actually enforce.

## Invocation

```powershell
# First-time or refresh (PowerShell stack):
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 dsh

# Or as part of an all-harness run:
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
```

```bash
# Bash stack (macOS/Linux):
bash .KCC/tools/sync-adapters.sh dsh

# Or as part of an all-harness run:
bash .KCC/tools/sync-adapters.sh
```

## Convention

The dsh adapter is a local-first, project-scoped materializer. It generates a
`.dsh/` tree of native skill packages only - it never writes to the user-level
DSH_HOME. The root `AGENTS.md` stays the directive catalogue `dsh` reads as the
project entrypoint: it is created once from `.KCC/kernel/templates/AGENTS.md`
when missing, then **preserved** for local edits and never overwritten by
normal sync.

The neutral capabilities source of truth is `.KCC/capabilities/`. Edit there,
then rerun the sync script, exactly like every other adapter.

## Generated files

| Neutral source                       | Generated dsh file                          |
|--|--|
| `.KCC/capabilities/skills/{name}.md` | `.dsh/skills/{name}/SKILL.md`               |
| (one-time scaffold)                  | root `AGENTS.md` (only created if absent)   |

Every generated SKILL.md carries neutral frontmatter (`name`, `description`,
`compatibility: dsh`) plus Obsidian provenance metadata, with the neutral body
preserved after the frontmatter. `.dsh/` is local generated output; it should
not be committed.

## Argument placeholder

dsh skill bodies keep slash-command style arguments by rewriting the neutral
`<ARGS>` placeholder to `$ARGUMENTS` inside `.dsh/skills/{name}/SKILL.md`.

## Generated worker boundary (post-lock)

Every generated `.dsh/skills/{name}/SKILL.md` ends with a generated
`## KCC worker boundary` section that states, verbatim:

- Post-lock workers use the DSH native read-only allowlist directly (read,
  read_image, glob, grep, todo_write) and never escalate it.
- process, write, network, subagent, workflow, code-runtime, MCP, Cordis, and
  unknown operations **fail closed** (denied without prompt).
- Governed actions use exactly `` `kcc_policy_exec` `` / `` `kcc_policy_write` ``.
- KCC owns controller, status, and resume.

This text is generated for every skill and is checked by
`.KCC/tools/check-run-conformance.{sh,ps1} -Scope harness` (DSH-001..DSH-005).

Read-only accesses stay native and direct so workers never need a wrapper for
reading; anything that could mutate, orchestrate, or escape - process, write,
network, subagent, workflow, code-runtime, MCP, Cordis, and unknown tools -
is denied by the generated boundary and may only be reached when governed
through the exact KCC policy wrappers. KCC owns controller, status, and resume:
workers never start, pause, resume, or report lifecycle state themselves.

## Capability level (adapter-specific, never claimed)

The core is harness-neutral; each adapter reports only proven capabilities.
**Skill generation alone is insufficient for Full Autopilot.** Generating
`.dsh/skills/*/SKILL.md` documents the workflow and the worker boundary, but
it does not enforce either. Full Autopilot requires the policy-guard
profile/plugin: a fresh-session hardened `dsh` profile with sandbox
`workspace-write`, `approval_mode=NEVER`, and
`mutation_enforcement=KCC_POLICY_GATE`, plus the Cordis mutation guard that
mints/audits decision tokens for the exact `kcc_policy_exec` /
`kcc_policy_write` wrappers. That capability is proven only by live evidence
(`doctor dsh --live`, disposable DSH smoke) against the installed profile and
guard - never by the presence of generated skill files.

Until that proof exists, the dsh adapter reports only proven capabilities:

- **Native read-only allowlist:** proven by the sandbox profile, not by prose.
- **Write that mutates:** fail-closed unless governed through
  `kcc_policy_write`.
- **Process/run code:** fail-closed unless governed through
  `kcc_policy_exec`.
- **Fresh/parallel workers:** only proven by an installed headless profile;
  unproven parallel degrades to serial. The adapter never fakes fresh or
  parallel workers and never fakes policy enforcement.

## Tool mapping

| Operation | dsh behavior |
|--|--|
| read, read_image, glob, grep, todo_write | native read-only allowlist, direct |
| write / edit / process / bash / network | fail closed |
| subagent / workflow / code-runtime / ralph | fail closed |
| MCP / Cordis / unknown tools | fail closed |
| governed mutation | exactly `kcc_policy_exec` / `kcc_policy_write` |
| controller / status / resume | KCC owns it; workers never wrap it |

## Parallel execution realization

**Documented, not yet built.** The dsh adapter realizes the spawner contract
`run(independent_items)` from
[[../protocols/parallel-execution|parallel-execution]] with **N headless
`dsh --profile headless` processes** - one per wave item - only after the
headless profile is proven installed (feature-probe, never an exact-version
gate). Until proven, parallel degrades to local sequential execution.

- **Mechanism:** the orchestrator launches one `dsh --profile headless` process
  per wave item, each scoped to its story/enabler and that item's declared
  impacted files under `src/IDEA-{ID}-{slug}/...`.
- **Barrier:** the orchestrator waits on all spawned processes for the wave,
  then collects their results before starting the next wave.
- **Merge-safety:** the planner's file-disjoint wave rule means the concurrent
  processes write non-overlapping files; optional git-worktree isolation per
  process for risky waves.
- **Proof:** fresh/parallel capability is only reported after the installed
  headless profile and generated skills are probed, and only `approval_mode=NEVER`
  + `mutation_enforcement=KCC_POLICY_GATE` after live doctor evidence.

## Fresh-session hardening scope

DSH hardening applies only to fresh sessions. The hardened profile/guard
(sandbox `workspace-write`, `approval_mode=NEVER`,
`mutation_enforcement=KCC_POLICY_GATE`) is copied only when the installer is
explicitly invoked; `framework-init` prints the install commands by default and
never silently mutates DSH_HOME. Live DSH evidence is disposable: doctor and
smoke runs happen only in disposable profiles/workspaces, and the hardened
grant is awarded only after the doctor proves the effective profile and guard.

## Caveats

- `.dsh/` is local generated output; it should not be committed. Edit
  `.KCC/capabilities/` (or `.KCC/kernel/`) and rerun the sync script.
- The root `AGENTS.md` is shared with the Codex and OpenCode adapters; see
  [[codex]] and [[opencode]].
- Skill packages are reference/local by design; per-agent tool enforcement is
  the policy-guard profile/plugin (Plan 08 Task 5 / Task 7), not the generated
  files - generating skills without it is documentation, not Full Autopilot.
