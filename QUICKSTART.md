# KCC Quickstart

From clone to your first **agentic AI workflow** in five minutes.

Pick one harness path - Codex CLI, Claude Code, OpenCode, DeepSeek Harness
(dsh), or a generic/Ollama runner. The lifecycle stays the same because every
adapter is generated from the same `.KCC/kernel/` and `.KCC/capabilities/`
source. The core is harness-neutral with adapter-specific capability levels -
each harness proves its own read/write/exec, worker, and policy capabilities.

---

## What this is

A **spec-driven workflow framework** and a working implementation of the
**KCC v0.4 operating model** (Kernel + Capabilities + Cells). You bring a
raw idea; the framework walks you through:

```text
interrogate -> create -> token-budget -> plan -> token-budget -> implement -> test -> review -> (deploy)
```

Each stage has a dedicated agent role. Meta-agents (Butler + Token Guard)
wrap every turn at minimum token burn. Multi-harness - Claude Code, Codex
CLI, OpenCode, generic, Ollama, DeepSeek Harness (dsh) all materialize
from a single neutral source at `.KCC/kernel/` + `.KCC/capabilities/`.

You write zero framework code. You write specs and let the agents do the
rest.

---

## Prerequisites

- **Windows PowerShell or native bash**
  - Windows: use the `.ps1` tools.
  - macOS/Linux: use the `.sh` tools.
- **Git** - every spec gets its own branch
- **One agent harness** of your choice:
  - **[Claude Code](https://docs.claude.com/claude-code)** - reads `CLAUDE.md` + `.claude/`
  - **[Codex CLI](https://github.com/openai/codex)** - reads `AGENTS.md`
  - **[OpenCode](https://opencode.ai)** - reads `AGENTS.md`
  - **[DeepSeek Harness](https://tikasway.dev/kcc)** (`dsh`) - reads root `AGENTS.md` + `.dsh/skills/` (see [the dsh adapter doc](./docs/autobuild/deepseek-harness.md))
- **Docker** (optional) - only needed if you'll use sandboxed sessions
  via `start-agent-session.ps1 --sandbox` or if any of your agents trip
  the Lethal Trifecta detector and auto-engage the sandbox.

---

## What you get after clone

A clean framework seed is intentionally small:

```text
my-project/
|-- README.md                  <- public overview + operating-model background
|-- QUICKSTART.md              <- this file
|-- PLAN.md                    <- future activities and roadmap
|-- progress.md                <- single status landing page
|-- CLI-PLAN.md                <- future native CLI roadmap
|-- LICENSE  CONTRIBUTING.md  CODE_OF_CONDUCT.md  SECURITY.md  MAINTAINERS.md
|-- .gitignore  .markdownlint.json
|-- .KCC/
|   |-- README.md
|   |-- kernel/                <- contracts, protocols, dialects, adapters, templates
|   |-- capabilities/          <- agents + skills (17 + 22)
|   |-- tools/                 <- PowerShell + native bash tools + bootstrap
|   |-- sandbox/               <- Dockerfiles per harness + sandbox-runtime protocol
|   `-- settings.json          <- workspace + tracker + AutoPolicy defaults
|-- docs/
|   |-- alignment-matrix.md    <- implementation status vs KCC v0.4 (color-coded)
    `-- diagrams/              <- animated GIF + Mermaid + draw.io sources
```

After first run, the framework adds:

```text
|-- AGENTS.md  CLAUDE.md       <- root entrypoints (created from kernel templates)
|-- .claude/  .codex/  .opencode/  .agents/  ollama/   <- adapter surfaces for this cell (regenerated; gitignored by default)
|-- .dsh/                                     <- DeepSeek Harness skill surface (regenerated; local output, not committed)
|-- memory/  coordination/  architecture/
|-- solution/  ideation/  specs/  Traces/  migrations/
`-- src/IDEA-{ID}-{slug}/...   <- one source folder per idea
```

---

## Recommended 5-minute setup

### 1. Get the repo on disk

```powershell
git clone https://github.com/TarekFawaz/kcc-agentic-framework.git my-project
cd my-project
```

### 2. (Mac/Linux only) Run the bootstrap

```bash
bash .KCC/tools/bootstrap-mac-linux.sh
```

This marks native bash tools executable and smoke-tests the toolchain.
Safe to re-run.

### 3. Initialize for your harness

Recommended first path if you are using Codex:

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 codex
```

Other harnesses:

```powershell
# all harnesses (default):
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1

# or just the one you'll use:
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 claude
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 codex
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 opencode
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 generic
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 ollama
powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 dsh
```

On Mac/Linux equivalent: `./.KCC/tools/framework-init.sh claude` (or
whichever harness).

`framework-init dsh` generates the `.dsh/` skill surface and **prints**
the hardened-profile install command by default - it never silently
mutates `DSH_HOME`. See the
[DeepSeek harness adapter doc](./docs/autobuild/deepseek-harness.md) for
the explicit install and proof commands.

This reads `.KCC/kernel/` + `.KCC/capabilities/`, creates the root
entrypoints (`AGENTS.md` + `CLAUDE.md` if missing), state folders
(`ideation/`, `specs/`, `solution/`, `architecture/`, `memory/`,
`Traces/`, `coordination/`, `migrations/`), and writes per-harness
adapters. Existing root entrypoints are preserved.

### 4. (Optional but recommended) Validate

```powershell
powershell -ExecutionPolicy Bypass -File .KCC\tools\validate-kcc.ps1
```

Checks structural layout, every capability has `maturity: L1|L2|L3` and
`maintainer:`, and runs the Lethal Trifecta detector across agents. Clean
run prints `Errors: 0, Warnings: 0`.

### 5. (Optional) Onboard an existing codebase

If you're adding KCC to an existing project rather than a greenfield one:

```text
/solution-onboard . --depth=standard
```

`solution-cartographer` maps the codebase into `solution/solution.md`.
Then `solution-inspector` interrogates you about workspace topology
(single vs multi-repo, cross-repo dependencies, tracker choice) and
populates `.KCC/settings.json`. Use `--depth=minimal` for small tools,
`--depth=deep` for larger systems, `--skip-inspector` to skip the
interrogation.

That's it. You're ready to interrogate your first idea.

## First Idea

Use whichever syntax your harness supports. The simplest universal prompt is:

```text
auto build a CLI that converts CSV to JSON
```

KCC will start with interrogation, then move through spec creation, budget
estimate, planning, implementation, testing, and review with the required gates.

---

## Four paths

### Path A - Claude Code

```powershell
cd my-project
claude
```

In the session:

```text
/idea-interrogator "build a CLI that converts CSV to JSON"
```

The agent writes a Reasoning section first (so you can correct its
framing), then asks foundational questions about problem / audience /
outcome / scope / constraints, then chains to
`/technical-interrogator` (which challenges your tech-stack choices),
`/ux-ui-interrogator` (which presents at least 3 design-system options),
`/security-interrogator`, `/infrastructure-interrogator` when applicable.
After confirmation it writes the Phases + Epics roadmap and the
**upfront budget** (per-step token + $ forecast at +/-50%, tightening to
+/-20% after the first SPEC).

### Path B - Codex CLI

```powershell
cd my-project
codex
```

Codex auto-discovers the root `AGENTS.md`. At the prompt:

```text
Interrogate the idea: "build a CLI that converts CSV to JSON".
Follow the workflow described in AGENTS.md.
```

Same lifecycle, same agents - Codex calls them by neutral name rather
than via slash commands.

### Path C - OpenCode

```powershell
cd my-project
opencode
```

OpenCode also reads `AGENTS.md`. Same prompt as Path B.

### Path D - DeepSeek Harness (dsh)

```powershell
cd my-project
dsh
```

`dsh` reads the root `AGENTS.md` as the directive catalogue plus the
generated `.dsh/skills/` packages. Same prompt as Path B. For autobuild
post-lock work, install the hardened `kcc-autobuild` profile (explicit
installer under `.KCC/adapters/dsh/`, never automatic) and prove the
effective profile/guard with `kcc-autobuild harness doctor dsh --live`
before any Full Autopilot claim:
[docs/autobuild/deepseek-harness.md](./docs/autobuild/deepseek-harness.md).

---

## The lifecycle in one diagram

```text
       idea
         |
         v
  /idea-interrogator       Reasoning -> 5 foundational Qs -> impact/gap/alts (if existing) ->
         |                 tech-stack challenge -> UX design-system options -> security -> confirm ->
         |                 Phases + Epics -> upfront budget + effort estimate (man-days, +/-20%)
         v
  /spec-create             writes IDEA-{ID}-{slug}-Specs/IDEA-{ID}-{slug}-Specs.md (index)
         |                 + SPEC-{ID}-{slug}/SPEC-{ID}-{slug}.md (epic)
         |                 + backlog.md + Backlog/Story-* + Backlog/Enabler-*
         v
  [token-budget gate]      /token-estimate forecast -> human approve / revise / abort
         |                 (or AutoPolicy auto-approve within cap)
         v
  /spec-plan               planner refines parallelization.md, writes plan.md
         |                 including ## Atomic test cases mapped to AC IDs
         v
  [token-budget gate]      refined estimate -> approve / revise / abort
         v
  /spec-implement          writes code under src/IDEA-{ID}-{slug}/...
         |                 turns atomic test cases into real tests via
         |                 testing-unit / testing-integration dialects
         v
  /spec-test               verifier runs tests, fills review.md (PASS/FAIL per AC + per test)
         |
         v
  /spec-review             quick diff review against epic + story/enabler criteria
         |
         v
  (optional) /spec-deploy  infrastructure-implementer writes pipeline + IaC stubs;
                           NEVER auto-executes; human runs the actual deploy
```

---

## Operating scenarios

| Operating scenario | Trigger | What happens |
|---|---|---|
| **1. Default HOTL** | `auto <idea>` | Starts with human interrogation, then runs the lifecycle. Required gates still pause for the human. Architecture docs produced. Upfront budget shown as awareness. |
| **2. Full hand-off HOTL** | `auto <idea> --silent --assume` | Agents decide everything they are allowed to decide and document assumptions. No interrogation questions are asked. Unlimited budget. Max parallel agents. Only stops on confidence < threshold (95% default), agent loop > 3 trials, or prohibited assumption (legal, security, privacy, compliance, destructive, etc.). |
| **3. Controlled hand-off HOTL** | `auto <idea> --silent --assume --accuracy 99% --budget 200` | Same as 2 plus accuracy and upfront budget controls. Stops if estimate exceeds cap or any decision falls below accuracy threshold. |
| **4. Direct HITL** | `/idea-interrogator <idea>` | Human-led interrogation. Ends with "create specs / park / revise" question. |
| **5. Individual skills** | `/spec-create`, `/spec-plan`, etc. | Human-led. Start anywhere. |

Plus two continuation modes:

- `auto IDEA-{ID}` - resume from an existing idea folder
- `auto SPEC-{ID}` - continue an existing spec from its current step
- `auto all` - take every non-done spec through `plan -> review`

AutoPolicy typo aliases accepted: `--slient` -> `--silent`,
`--acuuracy` -> `--accuracy`, `--parralel` -> `--parallel`.

---

## The `auto` skill in depth

`auto` is the Human-On-The-Loop entrypoint. It runs the full lifecycle for you
but **never** treats automation as permission to skip governance. Fresh ideas
always begin with interrogation.

### Invocation forms

| Form | Meaning |
|---|---|
| `auto <idea text>` | Treat the text as a fresh idea; start at interrogation. |
| `auto <file-path>` | Use the file contents as the raw idea input. |
| `auto <folder-path>` | Treat as an existing solution; require impact/gap/alternatives analysis first. |
| `auto IDEA-{ID}` | Resume an existing idea from the first missing artifact. |
| `auto SPEC-{ID}` | Continue an existing spec from its current lifecycle step. |
| `auto all` | Take every spec whose status is not Done through `plan -> review`. |
| `auto` (no args) | Print usage and exit - no agent dispatch, no file writes. |

### Parameters and their impact

| Parameter | Default | Impact |
|---|---|---|
| `--silent` | off | Suppresses status interruptions. The run does not ask clarifying questions or narrate between steps. It still **stops at non-silent-able gates** (see below). Typo alias `--slient`. |
| `--assume` | off | Lets agents **document low-risk assumptions** instead of asking. Assumptions are written into the decision briefs and `architecture/assumptions.md`. Prohibited topics are never assumed (CR-7). |
| `--accuracy NN%` | `95` | Sets the **per-decision confidence floor** (CR-4). Every agent ends with `Confidence: NN%`; below the floor triggers `/critical-human-gate`. In controlled mode (Scenario 3) this is a *refinement loop*, not a hard abort. Typo alias `--acuuracy`. Does **not** change the ROI gate. |
| `--budget NN [CCY]` | unlimited | Sets the **hosted-model spend cap**. Currency defaults to USD. In Scenario 2 the budget is shown as awareness only; in **Scenario 3 it is a hard gate** - if the upfront or cumulative estimate crosses the cap, the run stops for `revise scope / increase cap / abort`. Local-model rows are token-only (no currency). |
| `--parallel` | off | **Forces parallel agent sessions.** (1) Spec creation fans out **one subagent per selected epic** instead of running sequentially. (2) Standing consent: pre-authorizes opening parallel windows, so the Scenario-1 step-13 `approve windows` prompt is skipped. Scenario-independent - combine with any of 1/2/3. Typo alias `--parralel`. |

### How parallelism works (with and without `--parallel`)

Parallelism is driven by the operating scenario, the planner's wave plan, **and**
the `--parallel` flag:

- **Scenario 1 without `--parallel`:** spec creation is sequential (one
  `/spec-create` per epic); at step 13 the run shows the proposed sessions from
  `parallelization.md` and asks `approve windows / sequential / abort`.
- **Scenarios 2 & 3 (`--silent --assume`):** maximum parallel sessions allowed by
  default; the pre-flight warning covers your consent. In Scenario 3 the
  `--budget` cap still bounds the whole wave set. (Spec creation is still
  sequential here unless you add `--parallel`.)
- **With `--parallel` (any scenario):** spec creation fans out one subagent per
  selected epic (barrier before planning), and the later L1/L2 implementation
  fan-out runs without the per-spec window prompt. The human still picks *which*
  epics to create.
- The fan-out mechanics (L1 across specs, L2 across independent stories/enablers,
  wave/barrier semantics, file-disjoint merge safety) are defined in
  [[.KCC/kernel/protocols/parallel-execution]] and the per-spec
  `parallelization.md`.

### Gates that never go silent

Even under `--silent --assume`, the run **always stops** for these:

| Gate | Rule |
|---|---|
| CR-7 prohibited assumptions | Legal, security posture, data sensitivity, privacy, compliance, audit, secrets, destructive actions, external spend, production-impacting decisions - always human-gated. |
| CR-9 toolchain install | Detecting a missing build/test toolchain is fine; **installing** it is never silent - it routes to an `install / human-install / defer` gate logged to four sinks. |
| CR-11 ROI gate | The idea's ROI confidence has a **fixed 60% floor** (not affected by `--accuracy`). Below it, the run pauses even in silent mode. |
| CR-3 loop detection | Three consecutive failures for the same `(agent, step)` pair invoke `/critical-human-gate`. |
| CR-12 stack change | The implementation stack is fixed by the architecture ADR. Swapping it is a prohibited silent assumption - it requires a new ADR + human approval. |

### Silent-mode default ambition

When you hand off with `--silent --assume`, agents aim for a sensible middle,
not the cheapest possible output:

- **Architecture depth:** `standard` (apps/APIs/services), not `lite`.
- **Scope:** multiple specs when the idea spans distinct concerns (no silent
  collapse to a single spec - CR-13).
- **Quality:** production-leaning baseline (auth where relevant, input
  validation, error handling, tests, OpenAPI for APIs) - not gold-plated.
- **Research:** a moderate web-research pass before assuming, not from zero.

---

## Interrogation: concept, chain, and depth levels

Interrogation is how a raw idea becomes a decision-complete brief before any
code is planned. It is **mandatory for fresh ideas** and optional for ad-hoc
fixes (where you can start at `/spec-create`).

### The interrogation chain

```text
/idea-interrogator        always - foundational problem/audience/outcome/scope/constraints + ROI
   |
/technical-interrogator   always - challenges (not just records) your tech-stack choices
   |
/ux-ui-interrogator       conditional - any user-facing surface (web, mobile, dashboard, CLI TUI, report)
/security-interrogator    conditional - identity, data sensitivity, public exposure, compliance, secrets, privacy
/infrastructure-interrogator  conditional - anything deployable/shippable: API, service, container, cloud, on-prem, package
```

Each specialist produces a typed decision brief
(`TechnicalDecisionBrief.md`, `UXDecisionBrief.md`, `SecurityDecisionBrief.md`,
`InfrastructureDecisionBrief.md`) in the idea folder. Under `--silent --assume`
the specialists still run and still produce briefs - they document assumptions
instead of asking - but never assume security posture, data sensitivity, or
compliance.

### Architecture depth levels

Depth is human-controlled at idea introduction and decides how much
architecture detail the architect must produce:

| Depth | Use for | Adds |
|---|---|---|
| `lite` | Minimal CLI/script/docs-only changes | C4 Context, >=1 flowchart, fitness functions, technical budgets, NFRs. |
| `standard` (**default**) | Apps/APIs/services with users, persistence, or integrations | Above + C4 Container, DFDs when data flow is non-trivial, guardrails, quality gates, ADRs, spec-local `arch.md`. |
| `deep` | Distributed, regulated, multi-service systems | Above + C4 Component, sequence diagrams per cross-service flow, trust-boundary / data-sensitivity / security-flow / DR / SLO diagrams. |

Legacy names still map: `minimal -> lite`, `distributed -> deep`,
`regulated -> deep` (plus security/DR/data-sensitivity diagrams).

### Solution-onboard depth (existing codebases)

A separate depth flag governs `/solution-onboard <path> --depth=...`:

| Depth | Cartographer | Inspector |
|---|---|---|
| `minimal` | yes | no (skips workspace interrogation) |
| `standard` (**default**) | yes | yes (topology questions) |
| `deep` | yes | yes + deeper cross-repo / tracker probing (ask first) |

`--skip-inspector` bypasses the inspector regardless of depth.

---

## Defaults at a glance

| Setting | Default | How to change |
|---|---|---|
| Operating mode | HITL (human approves each handoff) | use `auto` for HOTL |
| Confidence floor (CR-4) | **95%** | `--accuracy NN%` |
| ROI confidence floor (CR-11) | **60%** (fixed) | not tunable |
| Budget cap | unlimited | `--budget NN [CCY]` |
| Currency | USD | `--budget NN EUR` etc. |
| Architecture depth | `standard` | declare in the idea file |
| Solution-onboard depth | `standard` | `--depth=minimal\|deep` |
| Validator mode | `cell` | `-Mode repo` / `--mode repo` |
| Loop-detection threshold | 3 failures per `(agent, step)` | not tunable |
| Parallelism | sequential (Sc.1) / max (Sc.2-3); spec creation sequential | `--parallel` (forces spec-creation fan-out + window consent) |
| Silent-mode ambition | mid-level, production-leaning, moderate research | (built in) |

---

## Sandboxed sessions (optional but recommended for enterprise)

Any agent session can be launched inside a Docker container with the
cell directory mounted read-write and the kernel + capabilities mounted
read-only.

```powershell
.KCC\tools\start-agent-session.ps1 --sandbox --harness claude
```

Default network policy is **deny**. Opt in with `--allow-network`.

The Lethal Trifecta detector (in `validate-kcc.ps1`) auto-engages the
sandbox for any agent matching the
**untrusted-input + private-data + external-comms** pattern. Override
with `--no-sandbox`; the override is logged to
`coordination/backchannel.jsonl`.

Full convention in
[`.KCC/kernel/protocols/sandbox-runtime.md`](./.KCC/kernel/protocols/sandbox-runtime.md).

---

## Worked example

Want to see every step on a concrete, tiny project? A full walkthrough -
a **csvtojson CLI from idea to deploy** (interrogate -> spec -> plan ->
implement -> test -> review -> deploy, plus the one-command `auto` shortcut) -
lives in [example-solutions.md](./example-solutions.md).

---

## Where things live

| Concern | Path |
|---|---|
| Existing solution baseline | `solution/solution.md` |
| Workspace topology / settings | `.KCC/settings.json` |
| Raw ideas | `ideation/IDEA-{ID}-{slug}/idea-{ID}-{slug}.md` |
| Idea index (status board) | `ideation/ideas.md` |
| Specs grouped per idea | `specs/IDEA-{ID}-{slug}-Specs/IDEA-{ID}-{slug}-Specs.md` |
| Epic spec | `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/SPEC-{ID}-{slug}.md` |
| Story / enabler backlog | `specs/.../SPEC-{ID}-{slug}/Backlog/Story-*.md` + `Enabler-*.md` |
| Plan (with atomic test cases) | `specs/.../SPEC-{ID}-{slug}/plan.md` |
| Verification report | `specs/.../SPEC-{ID}-{slug}/review.md` |
| Token budget log | `specs/.../SPEC-{ID}-{slug}/budget.md` |
| Handover envelope log | `specs/.../SPEC-{ID}-{slug}/handovers.md` |
| Deploy summary (optional) | `specs/.../SPEC-{ID}-{slug}/deploy.md` |
| Source code (per idea) | `src/IDEA-{ID}-{slug}/...` |
| Agent traces | `Traces/Session-{slug}-{datetime}/` (7 artifact files) |
| Top-level traces MOC | `Traces/traces.md` |
| Long-term memory | `memory/` (Butler-owned) |
| Memory calibration table | `memory/calibration/agent-calibration.md` |
| Cross-agent backchannel | `coordination/backchannel.jsonl` |
| Backchannel viewer | `.KCC/tools/show-backchannel.ps1` (`.sh` equivalent on Mac/Linux) |
| Architecture artifacts | `architecture/architecture.md` + `architecture/{c4-context,c4-container,...}.md` |
| Single status landing page | `progress.md` |
| Cross-idea spec status | `specs/specs.md` |
| Neutral framework source | `.KCC/kernel/`, `.KCC/capabilities/` |
| Canonical tools | `.KCC/tools/*.ps1` + `.KCC/tools/*.sh` |
| Sandbox Dockerfiles | `.KCC/sandbox/Dockerfile.{claude,codex,opencode,generic}` |
| Compatibility wrappers | `tools/*.ps1` + `tools/*.sh` |
| Claude adapter surface | `.claude/agents/`, `.claude/skills/` |
| Codex adapter surface | `.codex/agents/`, `.codex/skills/`, `.codex/config.toml` |
| OpenCode adapter surface | `.opencode/agents/`, `.opencode/commands/`, `.opencode/skills/`, `opencode.json` |
| DeepSeek Harness adapter surface | `.dsh/skills/*/SKILL.md` |

---

## Tool reference

Every tool lives in `.KCC/tools/` and ships as a PowerShell `.ps1` and a native
bash `.sh` pair unless noted. Windows examples shown; on Mac/Linux use the `.sh`
form (e.g. `bash .KCC/tools/validate-kcc.sh`). Run `bootstrap-mac-linux.sh` once
after clone so the `.sh` tools are executable.

| Tool | What it does | Key parameters | Example |
|---|---|---|---|
| `framework-init` | First-run initializer: creates root entrypoints, state folders, and harness adapter outputs from `.KCC/`. For `dsh` it prints the hardened-profile install command by default. | `Harness` (claude\|codex\|opencode\|generic\|ollama\|dsh\|all, default all) | `.KCC\tools\framework-init.ps1 codex` |
| `sync-adapters` | Regenerates per-harness files from `.KCC/kernel/` + `.KCC/capabilities/`. Run after any kernel/capability edit. | `Harness` (default all) | `.KCC\tools\sync-adapters.ps1 -Harness claude` |
| `validate-kcc` | Validates structure, capability metadata, generated/runtime boundaries, stale refs, parser health, and scans for control-char/mojibake/BOM corruption. | `-Mode cell` (default) \| `repo` | `.KCC\tools\validate-kcc.ps1 -Mode repo` |
| `backchannel-append` | Appends exactly one event to `coordination/backchannel.jsonl` (monotonic `BC-NNNNN` id, UTC ts). Best-effort refreshes the dashboard. | `-Kind` `-From` (req); `-To` `-Spec` `-Session` `-Payload` `-NoDashboard` | `.KCC\tools\backchannel-append.ps1 -Kind brief-issued -From butler -Spec SPEC-007` |
| `build-dashboard` | Generates a self-contained offline `dashboard/index.html` from ideas, specs, backchannel, traces, verdicts, and memory. | `-Open` (launch in browser) | `.KCC\tools\build-dashboard.ps1 -Open` |
| `show-backchannel` | Read-only human view of the backchannel log. | `-Last N` (default 20); `-From` `-Kind` `-Spec` `-Json` | `.KCC\tools\show-backchannel.ps1 -Last 20 -Kind approval` |
| `start-agent-session` | Opens a visible local or Docker-sandboxed harness window for an agent role. Auto-engages sandbox on a Lethal-Trifecta match. | `-Agent` (req); `-Harness` `-Sandbox` `-DryRun` `-Prompt`/`-PromptFile` | `.KCC\tools\start-agent-session.ps1 -Harness claude -Agent idea-interrogator -Sandbox` |
| `toolchain-preflight` | Detects whether build/test tools are present and suggests per-OS install commands. **Never installs** (install is human-gated). | `-Tools` (req, comma list) | `.KCC\tools\toolchain-preflight.ps1 -Tools node,pnpm,git` |
| `memory-append` | Butler's deterministic memory writer: adds one entry and updates the index + MOC. (PowerShell only.) | `-Type` `-Title` `-Summary` `-Body` (req); `-Tags` `-RelatedSpecs` | `.KCC\tools\memory-append.ps1 -Type decision -Title "Use SQLite" -Summary "..." -Body "..."` |
| `kcc-inspect` | Basic Inspector detect/propose over real backchannel/trace/test signals; writes proposal stubs. Never fabricates patterns. (PowerShell only.) | `-MinEvents` (8) `-MinOccurrences` (2) | `.KCC\tools\kcc-inspect.ps1` |
| `adapt-workflow` | Scaffolds a `migrations/IMPORT-{NNN}/` folder for importing an external agentic workflow. Semantic translation is the migrator agent's job. | `-SourcePath` (req); `-Format` (auto) `-DryRun` | `.KCC\tools\adapt-workflow.ps1 -SourcePath ../Other -Format cursor` |
| `bootstrap-mac-linux` | One-time macOS/Linux helper: sets `+x` on all `.sh` tools and smoke-tests the validator. (bash only.) | none | `bash .KCC/tools/bootstrap-mac-linux.sh` |

Root `tools/*.ps1` / `tools/*.sh` are thin compatibility wrappers - prefer the
`.KCC/tools/` paths in new work.

---

## What to read next

- [README](./README.md) - KCC operating-model background + local-cell orientation
- [How to use KCC](./docs/how-to-use-kcc.md) - scenarios for fresh ideas, existing solutions, and adapting workflows
- [KCC tools reference](./docs/kcc-tools-reference.md) - `.ps1` and `.sh` tools with arguments and examples
- [Agentic AI operating model](./docs/agentic-ai-operating-model.md) - short public explanation of the KCC model
- [Spec-driven AI development](./docs/spec-driven-ai-development.md) - lifecycle and artifact overview
- [AI agent governance](./docs/ai-agent-governance.md) - cost, confidence, trace, and toolchain gates
- [KCC vs agent frameworks](./docs/kcc-vs-agent-frameworks.md) - how KCC compares to prompts, assistants, and execution frameworks
- [Harness support](./docs/codex-claude-opencode-ollama.md) - Codex, Claude Code, OpenCode, generic, and Ollama outputs
- [Autobuild harnesses and capability levels](./docs/autobuild/harnesses.md) - harness-neutral core, capability tiers, report parity, two-mode operation
- [DeepSeek Harness (dsh) adapter](./docs/autobuild/deepseek-harness.md) - dsh sync, install, profile proof, and worker boundary
- [Example solutions](./example-solutions.md) - full csvtojson CLI walkthrough, idea to deploy
- [Alignment matrix](./docs/alignment-matrix.md) - implementation status vs KCC v0.4
- [[AGENTS]] - the root entrypoint Codex / OpenCode load (full agent + skill catalog)
- [[CLAUDE]] - the root entrypoint Claude Code loads (same content, Claude-flavored)
- [[.KCC/kernel/README]] - the framework format spec (agent + skill file format, model classes)
- [[.KCC/kernel/cells]] - Cells convention (this repo is one cell; the harness outputs are its adapter surfaces)
- [[.KCC/kernel/protocols/workspace]] - Workspace layer above Cells (multi-repo, tracker)
- [[.KCC/kernel/protocols/spec-layout]] - folder hierarchy: `IDEA-Specs/SPEC/Backlog/Story+Enabler`
- [[.KCC/kernel/protocols/idea-layout]] - idea folder convention
- [[.KCC/kernel/protocols/auto-mode]] - operating scenarios + parallel-session rules
- [[.KCC/kernel/protocols/confidence-gate]] - below-threshold human gate
- [[.KCC/kernel/protocols/token-budget]] - three estimation modes + formula
- [[.KCC/kernel/protocols/accuracy-calibration]] - Butler's calibration loop
- [[.KCC/kernel/protocols/architecture-documentation]] - always-on C4 + flowcharts + DFDs
- [[.KCC/kernel/protocols/sandbox-runtime]] - Docker sandbox + auto-trifecta engagement
- [[.KCC/kernel/protocols/deployment]] - deploy lifecycle stage + supported targets / CI
- [[.KCC/kernel/protocols/progress-tracking]] - markdown status convention + future tracker hook
- [[.KCC/kernel/protocols/handover]] - cross-harness handover envelope
- [[.KCC/kernel/phase-model]] - KCC Phase 1/2/3 + this framework's current phase (1.8)
- [[.KCC/kernel/inspector/README]] - Inspector Pipeline scaffold
- [[CLI-PLAN]] - native CLI roadmap (v1.1+)

---

## Troubleshooting

| Symptom | Probable cause | Fix |
|---|---|---|
| Claude Code says "skill not found" | `.KCC/capabilities/skills/*.md` edited but sync not run | `powershell -ExecutionPolicy Bypass -File .KCC\tools\sync-adapters.ps1` |
| Claude Code says "agent not found" | Same - sync not run, or malformed frontmatter | Rerun sync; if it errors, the error names the file. Fix and rerun. |
| Codex / OpenCode ignores agents | Init wasn't run for that harness, or `AGENTS.md` is missing | `.KCC\tools\framework-init.ps1 codex` (or `opencode`) creates root docs + native outputs |
| Spec folder created but `specs/specs.md` empty | spec-writer interrupted before updating the MOC | Re-run `/spec-create` (idempotent) or hand-edit the row |
| `plan.md` stuck at `> awaiting planner` | `/spec-plan` never ran, or token-budget declined | Run `/spec-plan SPEC-XXX` again, approve the budget |
| `validate-kcc.ps1` fails to launch | Execution policy blocked | Use `powershell -ExecutionPolicy Bypass -File .KCC\tools\validate-kcc.ps1` |
| Sync script parser error after editing | Editor inserted non-ASCII (smart quotes, em-dashes) into a `.ps1` | Save the script as UTF-8 with BOM, or keep `.ps1` edits ASCII-only. PS 5.1 misreads UTF-8 no-BOM with non-ASCII. |
| Mac/Linux: `.sh` says "permission denied" | Shell tools lost the executable bit | `bash .KCC/tools/bootstrap-mac-linux.sh` (sets +x on all shell tools) |
| Mac/Linux: `.sh` behaves differently from `.ps1` | Native bash parity bug | Prefer the `.ps1` tool for that run, then file a parity issue with command, OS, and output. |
| Sandbox session: "docker not found" | Docker Desktop / engine not installed | Install from <https://docker.com/get-started>, then re-run the session with `--sandbox`. |
| Trifecta validator warns on an agent | An agent declares `read` + memory access + `web`/`exec` without `confidence-gate: required` | Either add `confidence-gate: required` to the agent frontmatter and route its delegating skill through `/critical-human-gate`, OR narrow the agent's `tools-required`. |
| Lifecycle stops at "Confidence: NN%" | Agent reported below the threshold (default 95%) | `/critical-human-gate` was invoked. Choose `approve` / `revise` / `escalate` / `abort`. |
| `auto <idea>` won't proceed past interrogation | Missing required decision brief (TechnicalDecisionBrief, etc.) | Run the matching `/technical-interrogator` / `/security-interrogator` / etc. directly, then resume with `auto IDEA-{ID}`. |
| Traces folder missing | Framework not initialized | Run `powershell -ExecutionPolicy Bypass -File .KCC\tools\framework-init.ps1 <your-harness>`. |

If nothing here matches, open [[.KCC/kernel/README]] and confirm your file
layout against its "Layout" section, or read the matching protocol doc
linked under [What to read next](#what-to-read-next).

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](./LICENSE).
