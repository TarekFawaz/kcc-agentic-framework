---
title: Repo Steward PR Template
tags:
  - framework/agent-ref
updated: 2026-10-04
---

# Repo Steward PR Template

## pr.md

````markdown
---
title: "SPEC-{ID} pull request draft"
tags:
  - spec/pr
created: {YYYY-MM-DD}
updated: {YYYY-MM-DD}
version: 1.0.0
status: draft
---

# SPEC-{ID}: {spec title}

## Pull request
- Title: `SPEC-{ID}: {delivery in one line}`
- Head: `spec/SPEC-{ID}`
- Base: `{protected branch}`

## Summary
{2-4 sentences: what a user gets from this spec. From the spec file.}

## Backlog items
| Item | Title | Status |
|--|--|--|
| Story-001 | {title} | done |

## Acceptance criteria
| # | Criterion | Status |
|--|--|--|
| AC-1 | {text} | PASS |

## Evidence
{`## Evidence` table copied verbatim from review.md}

Review verdict: **APPROVED** ([[review]])

## Commit hygiene
| Check | Exit code | Violations |
|--|--|--|
| `check-branch` | 0 | - |
| `check-commit-msg` ({n} commits) | 0 | - |

## Release proposal
- Last tag: `{vX.Y.Z | none}`
- Proposed tag: `{vX.Y.Z}` ({major | minor | patch}: {reason})
- Changelog entry:

```markdown
## [{X.Y.Z}] - {YYYY-MM-DD}
### Added
- {line} (SPEC-{ID} Story-001)
### Changed
### Fixed
```

## Commands (run by a human - the agent never runs these)

```bash
git push -u origin spec/SPEC-{ID}
gh pr create --base {protected branch} --head spec/SPEC-{ID} --title "SPEC-{ID}: {delivery}" --body-file {path to this pr.md}
# after the pull request is approved and merged on the host:
git switch {protected branch}
git pull --ff-only
git tag -a {vX.Y.Z} -m "SPEC-{ID}: {delivery}"
git push origin {vX.Y.Z}
git branch -d spec/SPEC-{ID}
```

## Open questions
- ...

## Confidence
````
