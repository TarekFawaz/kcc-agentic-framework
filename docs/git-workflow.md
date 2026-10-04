# Git Workflow, Hooks, And Pipelines

KCC gives a project one branching model, one commit-message convention,
three git hooks that enforce them, an agent that prepares merges, and
pipeline templates for CI and deployment. The rules are specified in
`.KCC/kernel/protocols/git-workflow.md`; this page is the how-to.

One rule sits above everything else: **KCC never pushes, never merges into a
protected branch, and never deploys on its own.** Agents prepare and print
the commands; a human runs them.

## Set up

```text
kcc tool repo-bootstrap                          # shows the repo state and the choices
kcc tool repo-bootstrap --apply init-local       # git init on main, .gitignore, the three hooks
kcc tool repo-bootstrap --apply connect-remote --remote-url <url>
kcc tool repo-bootstrap --install-hook           # install or refresh the hooks in an existing repo
```

A hook you already had is kept as `<hook>.local` and runs first.
Credentials come from your existing git credential helper, `gh`, or
ssh-agent; a URL with a password in it is refused.

## Branches

| Branch | Name | Merges into |
|--|--|--|
| Trunk | `main` (protected) | - |
| Spec | `spec/SPEC-003` | `main`, by pull request after review APPROVED |
| Parallel wave lane | `lane/SPEC-003-w2` | its spec branch, locally |
| Bug | `bug/SPEC-003-Bug-001` | the branch it came from |
| Maintenance | `chore/update-deps` | `main`, by pull request |

Work never happens on `main`. Pushed history is never rewritten.

## Commit messages

```text
SPEC-003 Story-001: add CSV parser
SPEC-003 Bug-002 T-014: reject an empty header row
SPEC-003: plan v1.0.1
chore: bump dependencies
docs(readme): describe the install step
```

The spec and the backlog item named in a message must exist under `specs/`.
Merge, revert, `fixup!`, and `squash!` commits are accepted as git writes
them. Subjects over 72 characters get a warning.

Check a message or a branch by hand:

```text
kcc tool check-commit-msg --message "SPEC-003 Story-001: add CSV parser"
kcc tool check-branch
kcc tool check-branch --branch feature/x --json
```

## Hooks

| Hook | Checks | Blocks when |
|--|--|--|
| `pre-commit` | implementation lock on staged files; secret scan of staged files | source is committed without an approved plan and budget, or a secret is staged |
| `commit-msg` | the message convention | the message does not follow it |
| `pre-push` | branch name and push target; then the quality gate | the push goes straight to a protected branch, the branch name is not allowed, or the gate fails |

The first push that creates `main` on a new remote is allowed with a
warning. If a scanner such as gitleaks is not installed, the hook warns and
lets the action through; that is not a pass, and the full `quality-gate`
still reports it. Skipping a hook (`--no-verify`) is a human decision, never
an agent's.

## Configuration

`.KCC/settings.json`:

```json
"git": {
  "model": "trunk",
  "protected_branches": ["main"],
  "branch_patterns": {
    "spec": "spec/SPEC-{ID}",
    "lane": "lane/SPEC-{ID}-w{N}",
    "bug": "bug/SPEC-{ID}-Bug-{NNN}",
    "chore": "chore/{slug}"
  },
  "commit_pattern": null,
  "pre_push_gate": "fast"
}
```

| Key | Meaning |
|--|--|
| `model` | `trunk`, or `off` to disable branch and push checks (commit messages are still checked) |
| `protected_branches` | Branches that only change by pull request. `*` is a wildcard; `[]` means none |
| `branch_patterns` | Allowed branch names. `{ID}`, `{N}`, `{NNN}` are digits, `{slug}` is a free name |
| `commit_pattern` | A regular expression that replaces the built-in subject forms |
| `pre_push_gate` | `fast` (secret scan), `full` (the whole quality gate), or `off` |

Typical changes: add `"release": "release/{slug}"` to `branch_patterns`;
for a single-developer repository without pull requests set
`protected_branches` to `[]` and add `"trunk": "main"` to the patterns.

## Merging a spec: `/spec-merge`

After the verifier's `review.md` says APPROVED:

```text
/spec-merge SPEC-003
```

The `repo-steward` agent checks the branch and every commit message, merges
wave lanes into the spec branch, and writes `pr.md` in the spec folder: a
pull-request title and body built from the spec and the review's Evidence
block, plus proposed tag and changelog lines. It then prints the exact
`git push` and pull-request commands for you to run. It does not push, does
not merge into `main`, and does not force-push.

`/spec-merge` is optional and is not part of `auto`.

## Pipelines

Templates live in `.KCC/kernel/templates/pipelines/` for GitHub Actions,
Azure DevOps, GitLab CI, and Jenkins:

| Template | Stages |
|--|--|
| `quality-gate/` | Runs `quality-gate --require` so CI enforces the same gate as the local run |
| `ci/` | quality gate, restore, build, test, package |
| `deploy/` | dev, staging, production; staging and production wait for the provider's manual approval |

`/spec-deploy SPEC-003 --ci=github-actions` has the
`infrastructure-implementer` agent fill a template from the approved
infrastructure decisions and write it into the project. Build, test,
package, and deploy commands in the templates are placeholders that fail
until you replace them, so an unfinished pipeline cannot pass by accident.
Deploy pipelines start only by hand.

The templates have been checked for YAML validity only. They have not been
run on any of the four providers; expect to adjust them on first use.
