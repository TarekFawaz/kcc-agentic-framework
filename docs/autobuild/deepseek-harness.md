---
title: DeepSeek Harness (dsh) Adapter
aliases:
  - deepseek-harness
  - dsh-harness
tags:
  - framework/documentation
  - autobuild
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

The DeepSeek harness (`dsh` CLI) is one adapter of the harness-neutral
autobuild core: same neutral source, its own generated surface, its own
proven capability level. The adapter reports **only proven
capabilities** - skill generation alone is never treated as Full
Autopilot enforcement.

See [autobuild harnesses and capability levels](./harnesses.md) for the
tiers, the capability model, and report parity; this page covers the
dsh-specific commands and the worker boundary.

## Generated surface

One `.KCC/` neutral source is materialized into a `.dsh/` tree of
native skill packages:

| Neutral source | Generated dsh file |
|---|---|
| `.KCC/capabilities/skills/{name}.md` | `.dsh/skills/{name}/SKILL.md` |
| one-time scaffold | root `AGENTS.md` (created only if absent, then preserved) |

`.dsh/` is local generated output - it is not committed. Edit
`.KCC/capabilities/` (or `.KCC/kernel/`) and rerun the sync script, like
every other harness adapter.

## Sync and initialize (exact commands)

Regenerate the dsh surface:

```powershell
# Windows (PowerShell stack):
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1 dsh
# or the full all-harness run:
powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1
```

```bash
# macOS/Linux (bash stack):
bash .KCC/tools/sync-adapters.sh dsh
# or the full all-harness run:
bash .KCC/tools/sync-adapters.sh
```

First-run initializer, scoped to dsh:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 dsh
```

```bash
bash .KCC/tools/framework-init.sh dsh
```

`framework-init` **prints** the hardened-profile install command by
default and never silently mutates `DSH_HOME`; pass
`--install-dsh-profile` (sh) / `-InstallDshProfile` (ps1) only when you
actually want the installer to run.

Generated harness conformance reads only (verifies the generated worker
boundary DSH-001..DSH-005 and the rest of the harness surface):

```bash
bash .KCC/tools/check-run-conformance.sh --scope harness
```

## Hardened profile and guard (explicit install)

The policy-guard piece lives in `.KCC/adapters/dsh/` (profile package +
Cordis mutation guard + signed policy bundle). Installing it is
**explicit only**:

```bash
bash .KCC/adapters/dsh/install.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\adapters\dsh\install.ps1
```

What the installer does, and what it does not do:

- Copies the hardened `kcc-autobuild` profile into
  `$DSH_HOME/profiles/kcc-autobuild` (sandbox `workspace-write`,
  approval `never`, gate wiring) and installs the repo adapter via
  `dsh plugin --profile kcc-autobuild add .KCC/adapters/dsh/plugin`.
- Provisions the signed policy bundle + owner-only secret
  machine-locally (default: empty policy = fail closed). No secret is
  committed and no secret travels on a CLI argument.
- Applies to **fresh sessions only**; the install copy runs only when
  explicitly invoked and `--force` / `-Force` is required to replace an
  existing profile.
- Never runs the live proof itself: the doctor is a separate, gated,
  disposable step.

## Capability proof (probe and doctor)

```bash
# Feature probe: native AGENTS.md + generated .dsh skills + dsh CLI
# boot + installed headless profile (fresh/parallel workers). Output is
# the proven capability report (feature-based, never an exact-version gate).
kcc-autobuild harness probe dsh

# Read-only preflight of the disposable kcc-autobuild profile.
# NEVER a proof: it checks the template exists and boots.
kcc-autobuild harness doctor dsh

# Live proof (disposable profile, one worker probe):
#   - invokes kcc_harness_status exactly once
#   - accepts exactly one KCC_DSH_STATUS: <json> line proving
#     {"sandbox":"workspace-write","approval":"never","guard":"kcc-policy-gate"}
#   - any extra/missing/prompt-like/erroring output fails
kcc-autobuild harness doctor dsh --live
```

`approval_mode=NEVER` + `mutation_enforcement=KCC_POLICY_GATE` are
granted **only after a passed live doctor**. An offline doctor outcome,
a failed doctor, or raw skill files never grant hardened capabilities -
skill generation alone is insufficient for Full Autopilot.

## Two modes of operation

| Mode | When | What the dsh worker does |
|---|---|---|
| **Pre-lock (interactive)** | Before LOCK: H1 scope confirmation, H2 prototype walkthrough, readiness evidence, red-team review, the LOCK decision. | Interactive `dsh` sessions with the human in the loop; every gate decision is recorded by KCC. |
| **Post-lock (hardened fresh workers)** | After LOCK: bounded tasks dispatched from the handoff pack under `coordination/autobuild/<RUN>/`. | `dsh --profile headless` fresh workers with the generated boundary enforced by the hardened profile/guard. |

Generated worker boundary (verbatim, every `.dsh/skills/*/SKILL.md`):

- Post-lock workers use the DSH native read-only allowlist directly
  (read, read_image, glob, grep, todo_write) and never escalate it.
- process, write, network, subagent, workflow, code-runtime, MCP,
  Cordis, and unknown operations **fail closed** (denied without
  prompt).
- Governed actions use exactly `kcc_policy_exec` / `kcc_policy_write`.
- KCC owns controller, status, and resume.

## Report parity and chain of custody

A dsh worker's raw report may carry harness-metadata fields
(`harness_id`, `dsh`, `profile`, `worker_id`, `started_at`,
`finished_at`, `stdout`, `stderr`, `banner`, `kcc_dsh_status`, `logs`,
...). The adapter normalizes by removing **harness metadata only**; lease
identity, AC/Test evidence, usage, deviations, policy trace and outputs
are preserved identically to any other harness (Codex included) - the
cross-harness parity contract is pinned by
[`test_parity.py`](../../.KCC/runtime/tests/harnesses/test_parity.py).

The report file is the completion contract: process exit 0 without a
fresh, valid ExecutionReport at the report path fails, and a report
that does not bind to the dispatched lease/task/workspace identity is
rejected. KCC alone verifies chain-of-custody evidence (lease, commits,
CI, tests, policy); the adapter never claims to.

## Caveats

- Do not claim "works on every CLI" - the core is harness-neutral and
  dsh reports only what its probe and doctor proved.
- Fresh/parallel workers are proven only by an installed, bootable
  headless profile; unproven parallel degrades to local sequential.
- Live doctor runs happen only in disposable profiles (temporary
  `DSH_HOME`, files copied, `node_modules` symlinked); nothing
  user-level is modified by the proof.
- `.dsh/` is local generated output, not source; the root `AGENTS.md`
  is shared with the Codex and OpenCode adapters.

## Related

- [Autobuild harnesses and capability levels](./harnesses.md)
- [DeepSeek harness adapter kernel doc](../../.KCC/kernel/adapters/deepseek-harness.md)
- [Hardened profile package README](../../.KCC/adapters/dsh/README.md)
- [KCC Quickstart](../../QUICKSTART.md)

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](../../LICENSE).
