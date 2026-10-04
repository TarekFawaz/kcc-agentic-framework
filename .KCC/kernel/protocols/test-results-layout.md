---
# Functional fields
description: Folder convention for test artifacts (test-run summaries, per-bug evidence, and screenshots) produced by the verifier and implementer.
inputs: An IDEA-ID and SPEC-ID, plus test runs, bug findings, and screenshots produced during implementation and verification.
outputs: A `TestResults/IDEA-{ID}/SPEC-{ID}/` folder with `test-run-summary.md`, one bug file per issue, and a `screenshots/` subfolder.

# Obsidian metadata
title: "Test Results Layout Protocol"
aliases:
  - test-results-layout
  - test results convention
tags:
  - framework/protocol
  - testing
  - kcc/v04
  - documentation
created: 2026-06-04
updated: 2026-06-04
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Test Results Layout

All test artifacts — pass/fail summaries, per-bug evidence, and screenshots —
live under a single, predictable tree so nothing is ever dumped at the repo
root. The verifier owns this folder during `/spec-test`; the implementer
writes only screenshots here during visual checks. The verdict itself stays in
the spec's `review.md` (see [[spec-layout]]), which links back into this tree.

---

## Folder shape (REQUIRED)

```text
TestResults/
`-- IDEA-{ID}/
    `-- SPEC-{ID}/
        |-- test-run-summary.md                   # all ACs pass/fail for this spec
        |-- Story-{ID}-AC-{n}-Bug-{ID}.md         # one md PER bug/issue
        |-- Enabler-{ID}-AC-{n}-Bug-{ID}.md       # same naming for enabler-scoped bugs
        `-- screenshots/                          # ALL screenshots, never at root
            |-- Story-001-AC-2-before.png
            `-- Story-001-AC-2-after.png
```

- `IDEA-{ID}` and `SPEC-{ID}` use the durable zero-padded IDs (e.g.
  `IDEA-001`, `SPEC-003`).
- `TestResults/` is real, kept output the human wants — it is **NOT**
  gitignored.

---

## Hard rules

1. **Nothing test-related is written to the repo root.** Summaries, bug files,
   and screenshots all go under `TestResults/IDEA-{ID}/SPEC-{ID}/`.
2. **All screenshots go in `screenshots/`** — never the spec folder, never the
   repo root, never alongside source.
3. **Browser profile temp dirs are not committed and not at root.** Browser
   automation that needs a throwaway profile (e.g. an Edge/Chromium profile
   dir, the `.tmp-edge-profile-*` pattern) must target a gitignored temp
   location — prefer the repo-local `.tmp/` directory or the OS temp dir
   (`$env:TEMP`), **never** the repo root. Loose scratch screenshots
   (`.tmp-*.png`) are likewise gitignored if a tool insists on writing them.
4. **One bug file per issue.** Do not batch multiple bugs into one file.

---

## Bug-file naming rule

```text
Story-{ID}-AC-{n}-Bug-{ID}.md
Enabler-{ID}-AC-{n}-Bug-{ID}.md
```

- `{ID}` after `Story`/`Enabler` is the backlog item's zero-padded id
  (`Story-001`).
- `AC-{n}` is the acceptance criterion the bug violates (`AC-2`).
- `Bug-{ID}` is a zero-padded, per-spec bug counter starting at `Bug-001`
  (`Bug-001`, `Bug-002`, ...).

Example: `Story-001-AC-2-Bug-003.md`.

---

## Bug-file template

```markdown
---
title: "SPEC-{ID} Story-{ID} AC-{n} Bug-{ID}"
tags:
  - testing
  - bug
  - severity/{blocker|critical|major|minor|trivial}
created: YYYY-MM-DD
updated: YYYY-MM-DD
version: 1.0.0
status: open
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Bug-{ID}: {short title}

- **Spec:** SPEC-{ID}
- **Backlog item:** Story-{ID} / Enabler-{ID}
- **Acceptance criterion:** AC-{n} — {criterion text}
- **Severity:** blocker | critical | major | minor | trivial

## Steps to reproduce
1. ...
2. ...

## Expected
{what the AC requires}

## Actual
{what actually happened}

## Evidence
- ![before](screenshots/Story-{ID}-AC-{n}-before.png)
- ![after](screenshots/Story-{ID}-AC-{n}-after.png)

## Related
- Backlog item: [[../../../specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/Backlog/Story-{ID}-{slug}]]
- Spec: [[../../../specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/SPEC-{ID}-{slug}]]
- Test run summary: [[test-run-summary]]
```

Every bug file MUST link back (via `[[..]]` wikilink) to its story/enabler
backlog file and to the spec file. A failing AC also gets a
`Backlog/Bug-*.md` item that links here as its `Evidence` (spec-layout ->
*Bug item shape*).

---

## `test-run-summary.md` template

One per spec; a table of every acceptance criterion with pass/fail and a link
to any bug file.

```markdown
---
title: "SPEC-{ID} Test Run Summary"
tags:
  - testing
  - test-run
created: YYYY-MM-DD
updated: YYYY-MM-DD
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# SPEC-{ID} Test Run Summary

| Backlog item | AC | Status | Bug file |
|--|--|--|--|
| Story-001 | AC-1 | PASS | — |
| Story-001 | AC-2 | FAIL | [[Story-001-AC-2-Bug-001]] |
| Enabler-001 | AC-1 | PASS | — |

## Related
- Verdict: [[../../../specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/review]]
- Spec: [[../../../specs/IDEA-{ID}-{slug}-Specs/SPEC-{ID}-{slug}/SPEC-{ID}-{slug}]]
```

---

## Relationship to `review.md`

`review.md` (in the spec folder) remains the single **verdict** file —
`APPROVED` or `CHANGES_NEEDED`. It links to
`TestResults/IDEA-{ID}/SPEC-{ID}/test-run-summary.md` and to individual bug
files for detail. The TestResults tree holds the evidence; `review.md` holds
the decision.

---

## Related
- Spec layout: [[spec-layout]]
- Trace layout: [[trace-layout]]
- Verifier agent: [[.KCC/capabilities/agents/verifier]]
- Implementer agent: [[.KCC/capabilities/agents/implementer]]
- Spec test skill: [[.KCC/capabilities/skills/spec-test]]
- Obsidian standard: [[obsidian-standard]]
