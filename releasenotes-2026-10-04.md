---
title: KCC Release Notes 0.5.0 (2026-10-04)
aliases:
  - release-notes-0.5.0
  - releasenotes-2026-10-04
tags:
  - framework/documentation
  - release-notes
created: 2026-10-04
updated: 2026-10-04
version: 0.5.0
status: active
---

# KCC Release Notes - 0.5.0 (2026-10-04)

Release 0.5.0 is the first numbered release of the KCC framework. It
implements the same KCC v0.4 operating-model specification as before; the
specification itself did not change.

The release has three parts: the optimisations proven on a real project are
now in the framework, KCC installs as a command-line program instead of a
folder you copy, and the framework can be fitted to the solution it is used
on.

## 0.5.1 (2026-10-04) - fix for macOS and Linux

Use 0.5.1. Release 0.5.0 works on Windows only.

- **Fixed:** on macOS and Linux, `kcc tailor`, `kcc sync`, and `kcc upgrade`
  ended with an error because the bash `sync-adapters` script exited with
  code 1. Two causes: the Codex step returned a failure when the optional
  Codex-skills flag was not set, and regenerating `orchestrator.json` failed
  when the file held no run-state keys. Windows was not affected.
- **Added:** a target folder can be given as a path: `kcc init claude
  ../app`, `kcc tailor ../app`, `kcc doctor ../app`, `kcc upgrade ../app`.
  `kcc init` creates the folder if needed, and `kcc tool --dir <path>`
  targets another workspace.
- **Added:** `kcc <command> --help` shows the usage, and `--Help` /
  `--VERSION` are accepted in any letter case.
- **Added:** the release workflow generates the winget manifest and the
  Homebrew formula.

## Highlights

| Area | What you get |
|--|--|
| `kcc` command line | One self-contained program for Windows, macOS, and Linux. No Node and no PowerShell 7 needed. Guide: [CLI-Guide.md](./CLI-Guide.md) |
| Tailoring | `kcc tailor` keeps only the agents, skills, and dialects that fit your solution |
| Lower token cost | Generated agents are about 60% smaller; the `auto` skill is about 80% smaller |
| Scripted gates | Lifecycle checks are tool results with exit codes, not prose an agent interprets |
| Auto-continue | A run that hits a usage limit waits for the reset and resumes, on any harness |
| Git workflow | Branch and commit-message rules enforced by git hooks; an agent that prepares pull requests |
| Pipelines | CI and deploy templates for GitHub Actions, Azure DevOps, GitLab CI, and Jenkins |
| Local MCP server | Protocols by section, the gate tools, and every skill, for any MCP-capable harness |

Counts: 18 agents (was 17), 25 skills (was 22), 26 dialects.

## New

### Command line (`kcc`)

- `kcc init [harness]` writes `.KCC/` into a project from the copy inside the
  program and generates the harness adapters. Nothing to clone.
- `kcc upgrade` moves a project to a new framework version. Framework files
  you edited are kept and listed, never overwritten.
- `kcc doctor` checks an installation and names the fix for each problem.
- `kcc sync`, `kcc validate`, and `kcc tool <name>` run the framework scripts
  with the right shell for the system.
- Install with `winget install Tikasway.KCC` (Windows) or
  `brew install tarekfawaz/kcc/kcc` (macOS, Linux) once those channels are
  published, or with the script installers `install.ps1` and `install.sh`,
  which verify the download against the release checksums.

### Tailoring

- `kcc tailor` takes the solution context from questions, a context file
  (`.json`, `.yaml`, or a free-form `.md` brief), or the `/solution-onboard`
  baseline.
- It sets aside what cannot apply: for example the UX designer for a project
  with no user interface, the infrastructure agents when nothing is deployed,
  and every language dialect the project does not use.
- Nothing is deleted. `kcc tailor --reset` restores the full framework, and
  `kcc upgrade` keeps the tailoring.
- New skill `/tailor-workflow`: an agent drafts solution-specific agent
  addenda, agents, and skills under `migrations/TAILOR-{NNN}/`. Drafts are
  never promoted automatically.

### Auto-continue and usage limits

- `kcc run` supervises the lifecycle driver. On a usage or rate limit it
  writes a restore point, reads the reset time from the harness output,
  waits, and resumes, up to `continuity.max_resumes` times.
- `kcc run --wrap -- <command>` gives the same protection to any harness
  command you run yourself.
- Detection is the same for Claude Code, Codex, OpenCode, and a configured
  generic command: structured output first, then the wording in
  `.KCC/kernel/limit-patterns.json`. New wording is added as data.
- `kcc limits` shows usage, the last limit hit, and the next resume.
- Restore points (`kcc-checkpoint`), a usage-limit guard and status line for
  Claude Code, and `kcc-handover` to move a run between harnesses.

### Scripted gates and production quality

- `check-run-conformance`, `check-traceability`, `check-wave-scope`,
  `check-impl-lock`: every `auto` exit check is a script with a stable JSON
  result and exit code.
- `quality-gate`: build, lint, tests, coverage floor (default 80%), lockfile,
  secret scan, dependency audit, and SAST. A missing scanner is reported as
  deferred and never counts as a pass.
- `review.md` requires an `## Evidence` block.
- `kcc-run`: a deterministic driver that executes the lifecycle state by
  state through the harness command line and checks each state.

### Git workflow

- Model: protected `main`, short-lived `spec/SPEC-{ID}` branches, lane
  branches for parallel waves, merge by pull request after an approved
  review. Configurable in `.KCC/settings.json -> git`.
- Commit-message convention: `SPEC-003 Story-001: subject`, or maintenance
  prefixes such as `chore:` and `docs:`.
- Hooks: `pre-commit` (implementation lock and secret scan), `commit-msg`
  (message convention), `pre-push` (protected-branch guard and quality gate).
- New agent `repo-steward` and skill `/spec-merge`: checks branch and commit
  hygiene, merges wave lanes, and writes the pull-request draft. It never
  pushes.
- `repo-bootstrap`: a one-time gate to init a repository or connect a remote.
  It never stores credentials. KCC never pushes on its own.

### Pipelines

- `ci` templates (quality gate, restore, build, test, package) and `deploy`
  templates (dev, staging, production with manual approval) for four CI
  providers, next to the existing quality-gate stage templates.
- Placeholder commands fail until replaced, so an unfinished pipeline cannot
  pass by accident. Deployments are never started automatically.

### Local MCP server

- `kcc mcp` runs on the developer's own machine over stdio. It is not a
  shared service.
- Resources such as `kcc://protocol/auto-mode#hard-stops` return one section
  instead of a whole file.
- Tools wrap the gate scripts and return their JSON. Every skill is available
  as a prompt.
- `kcc init --mcp` or `kcc mcp --register` registers it for Claude Code,
  Codex, and OpenCode.

### Other

- `/bug-report`: a human-reported bug becomes a Bug backlog item and goes
  through a regression test, the fix, and the normal gates.
- Spec layout v6: a spec is one lean file plus `Backlog/` items; a per-idea
  `ROADMAP.md` carries the token plan.
- One orchestrator source (`coordination/orchestrator.md` and
  `orchestrator.json` v2.0); `CLAUDE.md` and `AGENTS.md` are short and point
  to it.
- Agents gain an `effort` setting; model classes map to current model
  aliases per harness.
- The migrator detects every supported harness by its own markers.

## Breaking changes

1. Generated Claude agents have new frontmatter (`name`, `model`, `effort`,
   `tools`). Regenerate `.claude/`.
2. `orchestrator.json` schema 1.0 -> 2.0. Read the model class from
   `agents[].spawn.model_class`.
3. Spec layout v5 -> v6. Existing v5 specs keep working and produce
   `SPEC-LEGACY` warnings.
4. `auto` states are renumbered 0-18.
5. `check-run-conformance` prints one line per finding, then a summary line.
6. The Claude settings template adds a status line and two `PreToolUse`
   hooks. An existing `.claude/settings.json` is not changed; merge them by
   hand.
7. `settings.json` gains the sections `repo`, `spec_sizing`, `quality`,
   `continuity`, `run`, and `git`. Missing sections use defaults.
8. Once the git hooks are installed, commits with a message outside the
   convention and direct pushes to a protected branch are blocked.

## Upgrading an existing project

1. Install `kcc` ([CLI-Guide.md](./CLI-Guide.md)).
2. In the project: `kcc init <harness>`. Add `--force` if you never edited
   the framework files.
3. Copy the new sections from `.KCC/kernel/templates/settings.json.template`
   into your `.KCC/settings.json`.
4. Claude Code users: merge the hooks from
   `.KCC/kernel/templates/claude-settings.json`.
5. `kcc tool repo-bootstrap --install-hook`, then `kcc doctor`.

Full steps: [docs/upgrade-v0.5.md](./docs/upgrade-v0.5.md).

## Known limits

- The macOS and Linux binaries and `install.sh` have not been run on real
  machines yet. The release workflow builds and smoke-tests them.
- The pipeline templates were checked for valid YAML only; they have not run
  on any CI provider.
- Usage percentages exist only for Claude Code. For other harnesses a limit
  is detected when it is hit. The Codex and OpenCode wording has not been
  confirmed against live limit events.
- `kcc run` executes specs and waves in sequence; parallel fan-out is still
  done by the in-harness `auto` skill.
- `kcc upgrade` reports conflicts; it does not merge them.
- The MCP server is local to one machine. A shared registry for teams in one
  organisation is planned, not built.
- `repo-steward`, `/spec-merge`, and `/tailor-workflow` are generated for
  every harness but have not been exercised end to end.
- The winget package (`Tikasway.KCC`) and the Homebrew tap
  (`tarekfawaz/kcc`) are prepared by the release workflow but not published
  yet: the tap repository and the two publishing secrets must be created,
  and Microsoft must accept the winget package. Until then use the script
  installers. There is no npm package.

## More

| Topic | Document |
|--|--|
| Installing and using the command line | [CLI-Guide.md](./CLI-Guide.md) |
| Command reference | [docs/cli.md](./docs/cli.md) |
| Tailoring | [docs/tailoring.md](./docs/tailoring.md) |
| MCP server | [docs/mcp.md](./docs/mcp.md) |
| Git workflow and pipelines | [docs/git-workflow.md](./docs/git-workflow.md) |
| Upgrade steps and breaking changes | [docs/upgrade-v0.5.md](./docs/upgrade-v0.5.md) |
| File-level change list of the framework port | [docs/plans/UPGRADE-2026-09-21.md](./docs/plans/UPGRADE-2026-09-21.md) |

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](./LICENSE).
