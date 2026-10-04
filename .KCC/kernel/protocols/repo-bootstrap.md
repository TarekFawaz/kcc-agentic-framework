---
title: Repo Bootstrap Protocol
aliases:
  - repo-bootstrap
tags:
  - framework/protocol
  - git
  - guardrail
created: 2026-09-21
updated: 2026-10-04
version: 1.1.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Repo Bootstrap

Version control is the base layer for restore points, wave-scope checks,
handovers, and the git hooks ([[git-workflow]]). Every KCC workspace settles its repo
state **before the first lifecycle write**. `/solution-onboard` and `auto`
(state 0) run the gate below. It is human-gated in every scenario, including
`--silent --assume`, because it can touch remotes and credentials.

## Detect

`.KCC/tools/repo-bootstrap.ps1|.sh -Json` reports:

| Field | Values |
|--|--|
| `git` | `absent` \| `repo` |
| `commits` | count (0 = unborn branch) |
| `remote` | `none` \| remote URL with credentials redacted |
| `auth` | `credential-helper` \| `gh` \| `ssh-agent` \| `none` (detected, never read) |
| `hooks` | `kcc-pre-commit` installed \| missing |
| `hooks_installed` | list of installed KCC hooks: `pre-commit`, `commit-msg`, `pre-push` |
| `dirty` | count of uncommitted files |

## Gate (ask once, record the answer)

If `git=absent` or `commits=0`, ask:

`init-local` · `connect-remote` · `skip`

| Choice | Action (`repo-bootstrap -Apply <choice>`) |
|--|--|
| `init-local` | `git init`, write the KCC `.gitignore` if missing, install the KCC hooks, initial commit `chore: KCC workspace bootstrap`. |
| `connect-remote` | As `init-local`, then ask for the remote URL and add it. Authentication uses what the human already has: the OS credential manager or credential helper, `gh auth login`, or an SSH agent. If none is set up, print the exact command for the human to run, then re-detect. **Never** accept, store, echo, or write a token or password into any file, env file, URL, or trace. |
| `skip` | Record `repo-bootstrap: skipped`. Git-dependent features degrade: restore points become file snapshots under `coordination/checkpoints/`, and wave-scope uses file hashes. |

Record the decision in `HumanDecisions.md` and emit `repo-bootstrap-decision`.
Don't ask again in later runs unless the state changes.

## Hooks

`-Apply init-local` (and `connect-remote`) install three hooks from
`.KCC/tools/hooks/` into the repo's hooks directory; `-InstallHook` installs
or refreshes them on their own.

| Hook | Marker | Runs |
|--|--|--|
| `pre-commit` | `KCC-PRE-COMMIT` | `check-impl-lock --staged`, `quality-gate --fast` |
| `commit-msg` | `KCC-COMMIT-MSG` | `check-commit-msg` |
| `pre-push` | `KCC-PRE-PUSH` | `check-branch --push`, `quality-gate` (mode `git.pre_push_gate`) |

Per hook: an identical KCC hook is left alone, an older KCC hook is updated,
and a foreign hook is preserved as `<hook>.local` and chained (it runs
first). A foreign hook plus an existing `<hook>.local` is `RB-HOOK-CONFLICT`:
merge them by hand. Detect reports `RB-HOOK-MISSING` (warning) naming every
KCC hook that is not installed. What the hooks enforce is defined in
[[git-workflow]].

## Push policy

KCC never pushes on its own. A push is an explicit human action, or an
explicit `auto` gate answer, and is never silent. The `pre-push` hook also
blocks a direct push to a protected branch; see [[git-workflow]].
