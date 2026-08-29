---
title: Autobuild Harnesses and Capability Levels
aliases:
  - autobuild-harnesses
  - harness-capabilities
  - harness-neutral-core
tags:
  - framework/documentation
  - autobuild
  - harness
created: 2026-08-28
updated: 2026-08-28
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Autobuild harnesses and capability levels

The autobuild control plane is a **harness-neutral core with
adapter-specific capability levels**. The core never claims it "works
on every CLI": every capability statement is harness-specific, and a
harness adapter reports only what its probe actually proved. Unproven
capabilities degrade honestly instead of being faked.

## Capability model

The runtime models what a harness can do with three canonical enums
([`ApprovalMode`](../../.KCC/runtime/src/kcc_autobuild/harnesses/models.py)):

| Enum | Values | Meaning |
|---|---|---|
| `ApprovalMode` | `none` / `ask` / `never` / `unknown` | How a harness asks the human for approval |
| `MutationEnforcement` | `none` / `prompt-only` / `kcc-policy-gate` | How mutation safety is enforced |
| `ExecutionStrategy` | `local` / `serial-worker` / `parallel-workers` / `full-autopilot` | The proven execution strategy |

A probe outcome carries a `HarnessCapabilities` set that is **unknown by
default** (every capability false, confidence 0). Adapters prove
capabilities at probe time (`read`, `write`, `exec`, `fresh-workers`,
`parallel-workers`, `subagents`, `kcc-policy-gate`, `approval-none`,
`approval-never`, `approval-passive`) and report confidence; a broken
probe yields a set that claims nothing.

Two laws are enforced, not documented:

- **Full Autopilot** requires `read` + `write` + `exec` +
  `KCC_POLICY_GATE` + approval `none`/`never` (plus proven fresh and
  parallel workers). Anything less is never called Full Autopilot.
- **Unproven parallel degrades to serial.** A harness that cannot prove
  fresh/parallel workers is scheduled local-sequential regardless of
  what its vendor documentation claims.

Selection is capability-only ([`HarnessRegistry`](../../.KCC/runtime/src/kcc_autobuild/harnesses/registry.py)):
stable ties, capability score, and a requested harness must be detected
and usable or selection fails closed. The scheduler consumes
capability/strategy, never hardcoded CLI names.

## Capability tiers

| Tier | Harness | Runtime capability position |
|---|---|---|
| **Tier 1 - native generated surfaces** | Codex, Claude Code, OpenCode, Generic `.agents`, Ollama, DeepSeek (`dsh`) | One `.KCC/` neutral source generates native per-harness outputs (`.codex/`, `.claude/`, `.opencode/`, `.agents/`, `ollama/`, `.dsh/`). Generated surfaces document the workflow; they do not by themselves prove enforcement. |
| **Tier 2 - first-party Full Autopilot proof targets** | Codex, DSH | These two are the designed first-party proof targets of the runtime. DSH has the runtime feature probe + live doctor and the hardened policy-guard profile/plugin; the cross-harness parity fixtures pin Codex and DSH to one identical ExecutionReport shape, and the capability-only registry selection consumes a Codex probe with stable ties. Full Autopilot is granted only after a passed live proof (for DSH: `doctor dsh --live`), never by file presence. |
| **Tier 3 - compatibility** | any file+command harness via the generic adapter | Local shell + filesystem probe only; fresh/parallel workers, subagents and policy enforcement are **never** proven by the generic adapter, so its strategy is `local` (local sequential). It never fakes unsupported subagent, parallel, or permission semantics. |

The tiers are capability levels, not rankings: a Tier 1 native surface
that never ran the live proof is documented as *unproven*, and a Tier 3
generic environment that honestly runs local-sequential is documented as
exactly that.

## How a capability is proven

- **Feature probe, never an exact-version gate.** Adapters observe the
  CLI boot, profile boot and workspace facts (native `AGENTS.md`,
  generated skill packages). No version string is parsed or required.
- **Fresh/parallel workers** are proven only by an installed, bootable
  headless profile - never by prose, never by generated skill files.
- **Policy enforcement** (`approval_mode=NEVER` +
  `mutation_enforcement=KCC_POLICY_GATE`) is granted only after a
  passed **live doctor** proof against the effective hardened profile
  and guard. An offline doctor outcome is never a proof.
- **Real smoke evidence** (`harness smoke dsh`) is the fresh live
  proof beyond the doctor: disposable fresh workers must complete
  read/code/test with no raw mutation, mutate only through the KCC
  wrappers under the disposable allow policy, get the deliberate
  built-in write/bash attempt guard-denied without a prompt, prove the
  status and each emit a valid ExecutionReport; durable artifacts are
  secret-scanned and
  `coordination/autobuild/evaluations/dsh-smoke.json` carries the
  `HarnessSmokeEvidence` verdict (`passed` requires all runs, status,
  authorized mutation, denied direct mutation and zero
  prompts/secrets). Plan 07 R3 consumes this fresh DSH smoke evidence
  together with the parity contract before proposing production
  authority, and generic CI never pretends live DSH exists.
- **Skill generation alone is insufficient for Full Autopilot.** It
  documents the worker boundary; the policy-guard profile/plugin
  enforces it.

## Execution-report parity

Every harness worker returns one ExecutionReport. The report may carry
harness-metadata fields (invocation facts, model names, durations,
captured output) next to the canonical fields; the adapter normalizes
the raw document by removing **harness metadata only**
([`normalize_harness_metadata`](../../.KCC/runtime/src/kcc_autobuild/bridge.py)).
Every other field is preserved and still validated against the strict
`ExecutionReport` schema, so a non-metadata extra field fails closed
instead of being silently dropped.

Lease identity, acceptance criteria, Test IDs, usage, deviations,
policy trace and evidence are never treated as harness metadata. The
cross-harness parity contract is pinned by
[`test_parity.py`](../../.KCC/runtime/tests/harnesses/test_parity.py):
a Codex-flavored raw report and a DSH-flavored raw report normalize to
the identical document and validate to identical `ExecutionReport`
models, and both bind to the same leased task identity. KCC still
verifies chain-of-custody evidence (lease, commits, CI, tests, policy)
before any report claim is accepted - the report is a claim, not proof.

## Two modes of operation

The same harness serves two modes, and the mode changes the worker
boundary, not the workflow:

| Mode | When | Worker model |
|---|---|---|
| **Pre-lock (interactive)** | Before the Build Contract is locked: H1 scope confirmation, H2 prototype walkthrough, readiness evidence, red-team review, final LOCK. | Human gates stay in the loop; the harness asks, and KCC records every decision in the decision log. |
| **Post-lock (hardened fresh workers)** | After LOCK: bounded task dispatch from the handoff pack. | Fresh workers use the native read-only allowlist directly; process/write/network/subagent/workflow/code-runtime/MCP/Cordis/unknown operations fail closed; governed actions use exactly `kcc_policy_exec` / `kcc_policy_write`; KCC owns controller, status, and resume. |

Hardening applies **only to fresh sessions**: installers copy the
hardened profile only when explicitly invoked, and `framework-init`
prints the install commands by default without silently mutating
`DSH_HOME`.

## Commands

Sync the neutral source into every harness surface (Windows / macOS +
Linux):

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
```

```bash
bash .KCC/tools/sync-adapters.sh
```

Per-harness (e.g. `dsh`): pass the harness name to either script.
`framework-init` is the first-run initializer and may also be scoped to
one harness; for `dsh` it **prints** the hardened-profile install
command by default (add `--install-dsh-profile` /
`-InstallDshProfile` to actually run it).

Capability evidence for a fitted harness adapter:

```bash
# Feature probe: prints the proven capability report.
kcc-autobuild harness probe dsh

# Read-only preflight of the disposable profile (never a proof).
kcc-autobuild harness doctor dsh

# Live proof: one disposable worker, one kcc_harness_status call,
# exactly one KCC_DSH_STATUS line proving sandbox workspace-write,
# approval never, guard kcc-policy-gate.
kcc-autobuild harness doctor dsh --live
```

Generated harness surfaces are conformance-checked read-only:

```bash
bash .KCC/tools/check-run-conformance.sh --scope harness
```

## Related

- [Autobuild autonomy metrics and rollout gates](./rollout.md) - R1/R2/R3
  gate table and the R3 production-authority proposal policy
- [DeepSeek harness](./deepseek-harness.md) - dsh adapter, sync,
  install, profile proof, and worker boundary details
- [Codex, Claude Code, OpenCode, and Ollama](../codex-claude-opencode-ollama.md) - generated native surfaces
- [KCC Quickstart](../../QUICKSTART.md)

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](../../LICENSE).
