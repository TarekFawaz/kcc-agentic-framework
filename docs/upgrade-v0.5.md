# Upgrading To Release 0.5.0

Release 0.5.0 is the first numbered release of this framework
implementation. "KCC v0.4" in other documents names the operating-model
specification this framework implements; that has not changed.

This page lists what is new, what breaks, and how to move an existing cell.
The detailed change list of the framework port is
[plans/UPGRADE-2026-09-21.md](./plans/UPGRADE-2026-09-21.md).

## What is new

| Area | Change |
|--|--|
| Command line | `kcc`: one self-contained program for Windows, macOS, and Linux. `init`, `tailor`, `upgrade`, `sync`, `validate`, `doctor`, `run`, `limits`, `mcp`, `tool`. See [cli.md](./cli.md) |
| Tailoring | `kcc tailor` keeps only the agents, skills, and dialects that fit the solution; `/tailor-workflow` drafts solution-specific additions. See [tailoring.md](./tailoring.md) |
| Token cost | Generated agents are about 60% smaller. Long templates moved to on-demand `capabilities/agents/refs/`. Shared rules live once in `contracts/agent-runtime.md`. The `auto` skill is a compact closed state machine |
| Scripted gates | Every `auto` exit check is a tool result: `check-run-conformance`, `check-traceability`, `check-wave-scope`, `check-impl-lock`, `quality-gate` |
| Production quality | `quality-gate`: build, lint, tests, coverage floor (default 80%), lockfile, secrets, dependency audit, SAST. `review.md` needs an `## Evidence` block |
| Spec layout v6 | A spec is one lean file plus `Backlog/` items; a per-idea `ROADMAP.md` carries the token plan; Bug backlog items |
| Bug reports | `/bug-report`: regression test first, then the fix, then the normal gates |
| Repository | `repo-bootstrap` gate (init / connect remote / skip). KCC never pushes on its own |
| Git workflow | Branch model, commit-message convention, `pre-commit`, `commit-msg`, and `pre-push` hooks, the `repo-steward` agent, `/spec-merge`. See [git-workflow.md](./git-workflow.md) |
| Pipelines | CI and deploy templates for GitHub Actions, Azure DevOps, GitLab CI, and Jenkins, next to the quality-gate stage templates |
| Continuity | Restore points (`kcc-checkpoint`), a usage-limit guard and status line for Claude Code, `kcc-handover` between harnesses |
| Auto-continue | `kcc run` detects a usage limit on any harness from its output, waits for the reset, and resumes. Wording per harness is data in `kernel/limit-patterns.json` |
| Deterministic driver | `kcc-run` executes the lifecycle state by state through the harness command line and checks each state with a script |
| MCP | `kcc mcp`: section-level reads, the gate tools, and every skill as a prompt, over stdio. See [mcp.md](./mcp.md) |
| Orchestrator | One source: `coordination/orchestrator.md` and `orchestrator.json` v2.0. `CLAUDE.md` and `AGENTS.md` are short and point to it |

## Breaking changes

1. **Generated Claude agents have new frontmatter** (`name`, `model`,
   `effort`, `tools`). Regenerate `.claude/`; never keep hand-edited copies
   there.
2. **`orchestrator.json` schema 1.0 -> 2.0.** `agents[]` carries
   `summary`, `inputs`, `outputs`, `spawn`, `definition`. Read the model
   class from `spawn.model_class`.
3. **Spec layout v5 -> v6.** New specs do not create `backlog.md`,
   `parallelization.md`, `budget.md`, or `handovers.md`. Existing v5 specs
   keep working: the checkers read the old files and report `SPEC-LEGACY`
   warnings. Migration steps: `spec-layout` protocol, *Legacy v5 specs*.
4. **`auto` state numbering** is now 0-18 plus DONE / STOPPED / ABORTED /
   SUSPENDED.
5. **`check-run-conformance` output**: one line per finding, then
   `Errors: N  Warnings: M`. The JSON keeps the old fields next to the
   contract fields.
6. **Claude settings template** adds `statusLine`, a `PreToolUse` limit
   guard, and the implementation lock. An existing `.claude/settings.json`
   is never overwritten; merge the entries by hand (step 4 below).
7. **`settings.json` gains sections**: `repo`, `spec_sizing`, `quality`,
   `continuity`, `run`, `git`. Missing sections fall back to defaults.
8. **Git hooks.** Once installed, commits with a message outside the
   convention and direct pushes to a protected branch are blocked. Bypass is
   an explicit human action (`--no-verify`).

## Upgrade an existing cell

1. **Install the command line** ([cli.md](./cli.md#install)).
2. **Adopt and upgrade the framework files**, from the project root:

   ```text
   kcc init <your harness>
   ```

   A hand-copied `.KCC/` has no lock file, so `kcc` cannot tell an old
   framework file from one you edited. It adds what is missing and keeps
   every existing file that differs from the 0.5.0 version. For a cell that
   never customised the framework, take the shipped versions:

   ```text
   kcc init <your harness> --force
   ```

   If you did customise agents or protocols, run without `--force`, read the
   list of kept files, and merge those by hand (compare with
   `kcc upgrade --dry-run --force`).
3. **Add the new settings sections.** `.KCC/settings.json` is yours and is
   not overwritten. Copy `repo`, `spec_sizing`, `quality`, `continuity`,
   `run`, and `git` from `.KCC/kernel/templates/settings.json.template`, and
   keep your `solution`, `workspace`, and `tracker` values.
4. **Merge the Claude Code hooks** (Claude Code users): copy `statusLine`
   and the two `PreToolUse` entries from
   `.KCC/kernel/templates/claude-settings.json` into `.claude/settings.json`.
5. **Refresh the entrypoints.** `CLAUDE.md` and `AGENTS.md` are preserved if
   they exist. To get the lean versions, move your `## Context` text aside,
   delete both files, run `kcc sync`, and paste the context back.
6. **Install the git hooks** if the project uses git:

   ```text
   kcc tool repo-bootstrap --install-hook
   ```

7. **Tailor** (optional, recommended): `kcc tailor`.
8. **Check:**

   ```text
   kcc doctor
   kcc validate
   kcc tool check-run-conformance
   ```

   `SPEC-LEGACY` warnings for existing v5 specs are expected.

Without the command line, the same result comes from copying the new
`.KCC/` over the old one and running `framework-init`, as before.

## Later upgrades

```text
(run the installer again)
kcc upgrade
```

`kcc upgrade` replaces only files you did not change, keeps your tailoring,
and regenerates the adapters.

## Known limits of this release

- The macOS and Linux binaries are built and smoke-tested by the release
  workflow; they have not been used on real projects yet.
- Usage percentages exist only for Claude Code. For other harnesses a limit
  is detected when it is hit, from the output wording. The wording for Codex
  and OpenCode in `limit-patterns.json` has not been confirmed against live
  limit events; add what you observe.
- `kcc run` executes specs and waves in sequence. Parallel fan-out is still
  done by the in-harness `auto` skill.
- `kcc upgrade` reports conflicts; it does not merge them.
- The MCP server is local to one machine. A shared registry for teams is
  planned, not built.
- Pipeline templates are starting points with placeholders.
- Open items of the framework port itself are listed in
  [plans/UPGRADE-2026-09-21.md](./plans/UPGRADE-2026-09-21.md), section 7.
