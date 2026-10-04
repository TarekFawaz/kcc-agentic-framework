---
# Functional fields (consumed by harness adapters)
name: spec-merge
description: >
  Prepare an approved spec for merging: check branch and commit hygiene, merge
  lane branches into the spec branch, and write the pull-request draft plus
  the exact push / PR / tag commands for a human to run. Usage: /spec-merge SPEC-{ID}
argument-placeholder: <ARGS>
delegates-to:
  - repo-steward
maturity: L1
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Spec Merge Skill
aliases:
  - spec-merge
  - merge-skill
tags:
  - framework/skill
  - lifecycle/merge
  - git
created: 2026-10-04
updated: 2026-10-04
version: 1.0.0
status: active
---

# Spec Merge

Prepare the merge of <ARGS>.

`/spec-merge` is an OPTIONAL step after `/spec-review`, like `/spec-deploy`.
It is not part of the `auto` state machine and runs only when a human invokes
it. It prepares the pull request; it does not push, open, or merge one.
Rules: `.KCC/kernel/protocols/git-workflow.md`.

## Argument Parsing

Parse the SPEC-ID (required). Accept `SPEC-{ID}` or `SPEC-{ID}-{slug}`.

## Steps

1. **Locate the spec folder.** Resolve to
   `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/`. Abort if not found.
2. **Require an approved review.** `review.md` must exist with verdict
   `APPROVED`. `CHANGES_NEEDED`, `QUALITY_DEFERRED`, `TOOLCHAIN_DEFERRED`, or
   no review -> refuse with
   `spec-merge: SPEC-{ID} has no APPROVED review - run /spec-test first`.
3. **Require a git repo.** `repo-bootstrap -Json` must report `git: repo`.
   Otherwise refuse with `spec-merge: no git repository (repo-bootstrap decision: skip)`.
4. **Invoke `repo-steward`** with the SPEC-ID, in this order, stopping at the
   first task that reports an error:
   - `merge-lanes` (only when `lane/SPEC-{ID}-w*` branches exist),
   - `hygiene` (`check-branch`, `check-commit-msg` over the spec's commits),
   - `pr-draft`.
5. **Display the result.** Show the path of
   `specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/pr.md`, the hygiene table,
   the proposed tag and changelog entry, and the command block from `pr.md`.
6. **Hard reminder.** Print:
   `Nothing was pushed or merged into a protected branch. YOU run the push and
   pull-request commands above, and the merge happens on the host after approval.`

## Quality Gates

- An `APPROVED` `review.md` MUST exist before any branch is merged or any
  file is written.
- No AutoPolicy covers this skill; it never runs inside `auto`.
- The agent MUST NOT run `git push`, merge into a protected branch,
  force-push, rewrite pushed history, or create a tag.
- A hygiene error (`BRANCH-*`, `COMMIT-MSG-*` with severity `error`) stops the
  skill before `pr.md` is written.
- The agent MUST emit `Confidence: NN%`. Below threshold triggers
  `/critical-human-gate` per the standard protocol.

## Related

- Repo steward: [[../agents/repo-steward]]
- Git workflow protocol: [[../../kernel/protocols/git-workflow]]
- Repo bootstrap protocol: [[../../kernel/protocols/repo-bootstrap]]
- Spec review skill: [[spec-review]]
- Spec deploy skill: [[spec-deploy]]
- Critical human gate: [[critical-human-gate]]
