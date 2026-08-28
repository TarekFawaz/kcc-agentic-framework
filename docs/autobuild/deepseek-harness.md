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
updated: 2026-08-29
version: 1.1.0
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

## Real smoke/evidence gate

Beyond the doctor's single status probe, the real smoke gate runs
complete disposable fresh workers end to end:

```bash
# 3 disposable fresh workers (default):
kcc-autobuild harness smoke dsh \
  --fixture .KCC/runtime/tests/harnesses/fixtures/dsh-smoke \
  --runs 3

# more runs, explicit disposable temp root:
kcc-autobuild harness smoke dsh \
  --fixture .KCC/runtime/tests/harnesses/fixtures/dsh-smoke \
  --runs 3 --temp-root /tmp/kcc-smoke
```

Every run is one fresh worker in a **disposable hardened profile** (a
temporary `DSH_HOME` templated from the installed `kcc-autobuild`
profile; config files copied, `node_modules` symlinked, the gate wiring
re-rendered to disposable paths with a **bounded disposable allow
policy** - exactly the two governed outputs, one report path per run and
the single `python3` exec) and a **disposable workspace** holding a
private copy of the fixture (`AGENTS.md` + `input/`). The worker must:

1. read/code/test with **no raw mutation** - native read/glob/grep only;
2. mutate **only through `kcc_policy_write` / `kcc_policy_exec`** under
   the disposable allow policy (the governed verification run must
   actually execute and leave its `.exec-proof.txt` marker behind);
3. deliberately attempt the built-in write and bash tools and get both
   **guard-denied without a prompt** (the raw marker files must never
   appear);
4. call `kcc_harness_status` exactly once and end its answer with
   exactly one `KCC_DSH_STATUS:` line proving sandbox `workspace-write`,
   approval `never`, guard `kcc-policy-gate`;
5. emit a fresh valid, identity-bound `ExecutionReport` at the run's
   report path - the report file is the completion contract, so exit 0
   without one fails that run.

Every durable artifact (worker reports, governed outputs, captured
stdout/stderr, the disposable allow policy, the gate policy trace) is
copied under `coordination/autobuild/evaluations/dsh-smoke/runs/run-<n>/`
and **secret-scanned**; any `sk-...` plaintext finding or any
prompt-like marker found in a durable artifact fails the evaluation
(zero human prompts, zero secret findings). The evidence document is
written to `coordination/autobuild/evaluations/dsh-smoke.json`
(`HarnessSmokeEvidence` with `harness_id`, `runs_requested`,
`runs_passed`, `status_probe_passed`, `authorized_mutation_passed`,
`unauthorized_mutation_denied`, `human_prompts`, `secret_findings`,
`evidence_refs` and the derived `passed` verdict - `passed` requires all
runs, the status proof, the authorized governed mutation, the denied
direct mutation and zero prompts/secrets). The command **exits 0 only
when the smoke passed**.

The smoke never promotes a rollout itself: it records fresh live
evidence for KCC. Plan 07 R3 consumes the fresh Plan 08 real DSH smoke
evidence (`dsh_live_smoke_passed=True`, zero human prompts, zero secret
findings) together with the cross-harness parity contract when it
proposes production authority. Generic CI never pretends live DSH
exists - the evidence comes from this disposable, gated run only.

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
