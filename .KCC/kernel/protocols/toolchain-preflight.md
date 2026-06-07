---
# Functional fields
description: >
  Ensure the build/test toolchain exists before implementation and before
  verification, so lifecycle runs do not silently degrade to a "blocked" stub.
  Derives required tools from the selected dialects, detects what is present,
  and gates any system-mutating install behind explicit human approval.
inputs: The selected dialects / TechnicalDecisionBrief, the current OS, and the lifecycle step (pre-implement or pre-test).
outputs: A detection report (present/missing + versions), a human decision (install / human-install / defer), and either an installed toolchain or a recorded toolchain-deferred state.

# Obsidian metadata
title: "Toolchain Preflight Protocol"
aliases:
  - toolchain-preflight
  - toolchain-gate
tags:
  - framework/protocol
  - toolchain
  - environment
  - kcc/v04
created: 2026-06-06
updated: 2026-06-07
version: 1.3.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Toolchain Preflight

## Purpose

A real pilot run revealed that when the build toolchain (e.g. `node` / `npm` /
`pnpm`) is not installed, verification silently degrades to a "blocked" stub
that neither runs the suites nor reports a real verdict. The human then has to
install the toolchain by hand and re-run `/spec-test`.

This protocol closes that gap. Before any build-dependent work, the orchestrator
**detects** the required toolchain, and if anything is missing it stops at a
**human-gated install** decision instead of proceeding blind. Verification never
silently passes when its tools could not run.

## When it runs

The preflight runs at **two** lifecycle points:

1. **Before implementation** - after planning + the implement-gate budget
   approval, immediately before the implementer (or the parallel fan-out) writes
   any build-dependent code.
2. **Before `/spec-test`** - re-check immediately before the verifier runs any
   build/lint/test suite.

Both points invoke the same install gate (below).

## Deriving required tools

Derive the required tool set from the **selected dialects** for the spec (the
same dialect files loaded by the implementer/verifier from
`.KCC/kernel/protocols/dialects/`) and from the `TechnicalDecisionBrief.md`
tech-stack decisions. Use this mapping as the baseline:

| Dialect / stack signal | Required tools |
|--|--|
| `fullstack-nextjs`, `frontend-react`, `backend-nodejs` | `node` (LTS), a package manager (`pnpm` or `npm`), `git` |
| `fullstack-python`, `backend-python` | `python`, `pip` (or `uv`), `git` |
| `backend-go` | `go`, `git` |
| `backend-rust` | `rustup` / `cargo`, `git` |
| `backend-java` | a JDK (`java`/`javac`), `maven` or `gradle`, `git` |
| `backend-dotnet`, `fullstack-dotnet` | `dotnet` SDK, `git` |
| flutter / mobile | `dart`, `flutter`, `git` |
| `devops-cloud` | `terraform`, the cloud CLI (`aws` / `az` / `gcloud`), `git` |
| `devops-k8s-onprem-agnostic` | `terraform`, `kubectl`, `helm`, `git` |
| **always** | `git` |

If multiple dialects apply, union their tool sets. Prefer the package manager the
`TechnicalDecisionBrief.md` named (e.g. `pnpm` via `corepack`); fall back to the
dialect default.

## Detection

For each derived tool, probe for presence and version:

- **PowerShell:** `Get-Command <tool> -ErrorAction SilentlyContinue`, then a
  version probe (`<tool> --version`) when present.
- **bash:** `command -v <tool>`, then `<tool> --version` when present.

Record each tool as **PRESENT** (with its version) or **MISSING**. The helper
[`.KCC/tools/toolchain-preflight.ps1`](../../tools/toolchain-preflight.ps1) /
[`.KCC/tools/toolchain-preflight.sh`](../../tools/toolchain-preflight.sh) does
exactly this detection and prints a per-OS suggested install command for each
missing tool; it exits non-zero if any tool is missing. The helper is
**detection + suggestion only** - it never installs anything itself.

Before detection starts, emit `toolchain-preflight-started` to
`coordination/backchannel.jsonl` with the stage, selected dialects, and derived
tool list. After detection finishes, emit `toolchain-preflight-result` with
the present/missing lists and suggested commands. These events are required in
both success and missing-tool cases.

## The install gate (human-gated)

If any tool is MISSING, present the human with:

1. the **missing list** (tool + why it is required, derived from which dialect);
2. the **EXACT per-OS install commands** that would be run; and
3. three choices:

There are exactly **three** outcomes, and **none of them changes the declared
stack**. The architecture ADR / `TechnicalDecisionBrief.md` dictates the stack;
the preflight only decides how the *declared* stack's toolchain becomes
available (or that the build is deferred):

| Choice | Behavior |
|--|--|
| `install` | The AI installs **the declared stack's toolchain** via package managers **after this explicit human approval**, re-detects, then **builds the declared stack**. |
| `human-install` | The human installs the declared stack's tools out-of-band; the AI re-runs detection and **builds the declared stack** once all tools are PRESENT. |
| `defer` | The AI **still writes the declared-stack code**, but marks the build/test step `TOOLCHAIN_DEFERRED`: it does NOT build, does NOT run the suites, and does **NOT** substitute a different, toolchain-free stack. Verification writes a **toolchain-deferred** verdict (NOT pass) and records which commands could not run. The lifecycle does not silently pass. |

### Stack is never changed by a missing toolchain (PROHIBITION)

A missing toolchain is **NEVER** a license to change the architecture/stack.
Substituting a toolchain-free stack (for example, generating a static HTML/JS
app instead of the declared TypeScript + React + Node API) to dodge a missing
`node`/`npm` is a **prohibited silent assumption** and a re-architecture. It
requires a **new/updated ADR + explicit human approval** via
[[confidence-gate|/critical-human-gate]] - it must never happen silently, in
any mode. The only sanctioned responses to a missing toolchain are the three
outcomes above (`install` / `human-install` / `defer`); all three keep the
declared stack intact.

### Install boundary

Installs are a **FULL SYSTEM install via package managers**, always behind this
human approval gate:

- **Windows:** `winget install <id>` (fallback `choco install <pkg>` or
  `scoop install <pkg>`).
- **macOS:** `brew install <pkg>`.
- **Linux:** `apt-get install -y <pkg>` (Debian/Ubuntu) or `dnf install -y <pkg>`
  (Fedora/RHEL) or the distro equivalent.
- **Tool-specific globals:** `corepack enable`, `npm i -g pnpm`,
  `rustup` toolchain installs, etc.

Admin/elevation may be required (e.g. `sudo`, an elevated PowerShell). Surface
this to the human as part of the gate; the human may need to run the elevated
command themselves (`human-install`).

## Security framing (never silent)

Toolchain install is a **sensitive, human-only gate**: it mutates the system and
uses the network. It is a **prohibited-assumption class** under
[[auto-mode]] CR-7. **Even under `auto --silent --assume`, the toolchain gate
STILL stops for the human.** The AI must never run an install silently and must
never assume the toolchain into existence. Equally, the AI must never react to a
missing toolchain by silently swapping the declared stack for a toolchain-free
one - that too is a prohibited silent assumption requiring a new ADR + human
approval (see the prohibition above).

### Four-sink traceability (every gate decision)

Every toolchain `install` / `human-install` / `defer` decision MUST be recorded
to **all four** sinks. These writes go through Butler's trace custody and the
deterministic `.KCC/tools/backchannel-append.ps1` / `.sh` helper - never
freehand JSON or a single-sink shortcut:

1. **`Traces/Session-*/HumanDecisions.md`** - the human's choice (`install` /
   `human-install` / `defer`), the exact commands offered, and the chooser, per
   [[trace-layout]].
2. **`coordination/backchannel.jsonl`** - the event chain via the helper:
   `toolchain-preflight-started` (stage + dialects + derived tools),
   `toolchain-preflight-result` (detected `present` + `missing` + suggested
   commands), `toolchain-gate-decision` (the choice, missing tools, commands,
   and the `HumanDecisions.md` path), and on an approved install
   `toolchain-install-complete` (the **command** run, the **result** status, and
   the **re-detected version**).
3. **`Traces/Session-*/ToolsUsed.md`** - the install command actually run.
4. **`Traces/Session-*/Actions.md`** - the action taken (e.g. "approved + ran
   winget install; re-detected python 3.12.10" or "deferred build/test").

Worked example - human approves `winget install Python.Python.3.12`:

```text
HumanDecisions.md : "install" chosen; command winget install Python.Python.3.12
backchannel       : toolchain-gate-decision  -> decision="install"
                    toolchain-install-complete -> command="winget install
                      Python.Python.3.12", status="installed",
                      installed={"python":"3.12.10"}  (version after re-detect)
ToolsUsed.md      : winget install Python.Python.3.12
Actions.md        : ran approved install; re-detected python 3.12.10
```

If the AI performs an approved install, record the command and result in
`Traces/Session-*/ToolsUsed.md` and the action in `Traces/Session-*/Actions.md`,
re-run detection, and emit `toolchain-install-complete` with the `command`,
`status: installed | failed`, the re-detected `installed` versions, and the
`ToolsUsed.md` path. If the human chooses `human-install`, emit
`toolchain-gate-decision` immediately and emit a later
`toolchain-preflight-result` when the human asks the AI to re-detect.

When the decision needs to pause the run, route it through
[[confidence-gate|/critical-human-gate]] like any other hard gate.

## Deferred fallback

If the human chooses `defer` (or declines an install):

- the implementer **still writes the real declared-stack code** and marks the
  build/test step `TOOLCHAIN_DEFERRED`; it does not substitute a different
  stack;
- the verifier writes a **toolchain-deferred** verdict in `review.md` - this is
  **NOT** APPROVED; and
- the `TestResults/IDEA-{ID}/SPEC-{ID}/test-run-summary.md` records, explicitly,
  which build/lint/test commands could not run because their tools were missing,
  so the gap is visible and the human can resume after installing.

A deferred run is resumable: re-running the preflight after the tools exist lets
the lifecycle continue from the build/test step.

## Related

- Auto mode (CR-7 prohibited assumptions, gating): [[auto-mode]]
- Confidence / critical human gate: [[confidence-gate]]
- Trace layout (HumanDecisions.md): [[trace-layout]]
- Helper scripts: `.KCC/tools/toolchain-preflight.ps1`,
  `.KCC/tools/toolchain-preflight.sh`
