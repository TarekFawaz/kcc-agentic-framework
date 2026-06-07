---
title: Example Solutions - Worked Walkthroughs
aliases:
  - example-solutions
  - worked-examples
  - examples
tags:
  - documentation
  - examples
  - kcc/v04
created: 2026-06-07
updated: 2026-06-07
version: 1.0.0
status: active
---

# Example Solutions

End-to-end worked walkthroughs of the KCC lifecycle. Start with
[QUICKSTART.md](./QUICKSTART.md) for setup and concepts; come here when you want
to see every step on a concrete, tiny project.

---

## Worked example - csvtojson CLI

Let's actually ship something tiny so you see every step.

### Step 1 - Interrogate

```text
/idea-interrogator "build a CLI that converts CSV to JSON"
```

The agent writes `ideation/IDEA-001-csv-to-json/idea-001-csv-to-json.md`
with a Reasoning section first. It asks ~5 foundational questions:

- "What runtime - Node, Python, .NET, Go?"
- "Streaming or load-into-memory?"
- "Pretty-printed or minified JSON?"
- "Custom delimiter support? Quoting rules?"
- "Where will this run - local dev, CI, server?"

Then `/technical-interrogator` may challenge: "For a small CLI, Go or
Rust would give a single-binary distribution with no JVM dependency - do
you want to consider those?"

After all answers, `/ux-ui-interrogator` is skipped (CLI, no UI),
`/security-interrogator` runs lightly (just CSV input - low risk),
`/infrastructure-interrogator` is skipped.

The agent emits the **upfront budget** (e.g. "estimated 80k input / 25k
output tokens across the full lifecycle, $0.45-$0.90 at current rates"),
the **effort estimate** (e.g. "~2 person-days for a human team"), and
the Phases + Epics roadmap.

### Step 2 - Create the spec

```text
/spec-create IDEA-001
```

The `spec-writer` creates:

```text
specs/
|-- specs.md                                       (updated with new row)
`-- IDEA-001-csv-to-json-Specs/
    |-- IDEA-001-csv-to-json-Specs.md              (per-idea spec index)
    `-- SPEC-001-cli-skeleton/
        |-- SPEC-001-cli-skeleton.md               (epic folder note)
        |-- backlog.md                              (INVEST-checked stories + enablers)
        |-- Backlog/
        |   |-- Story-001-parse-csv-stream.md
        |   |-- Story-002-emit-json-stream.md
        |   |-- Enabler-001-cli-argparse.md
        |   `-- Enabler-002-error-handling.md
        |-- parallelization.md                      (dependency waves)
        |-- plan.md                                 (stub: > awaiting planner)
        |-- review.md                               (stub: > awaiting verifier)
        |-- budget.md                               (stub: > awaiting token-guard)
        `-- handovers.md                            (stub: > no handovers yet)
```

### Step 3 - Token-budget gate, then plan

```text
/token-estimate SPEC-001          # forecast for the spec
# approve when prompted

/spec-plan SPEC-001
```

The `planner` fills `plan.md` with ordered file changes mapped to
stories/enablers PLUS an **`## Atomic test cases`** table (T-001, T-002,
...) mapping each acceptance criterion to a unit or integration test the
implementer will write.

### Step 4 - Token-budget gate, then implement

```text
/token-estimate SPEC-001          # refined now that plan exists
# approve

/spec-implement SPEC-001
```

The `implementer` creates branch `spec/SPEC-001`, writes files under
`src/IDEA-001-csv-to-json/...`, turns each Test ID into real test code
using the `testing-unit` + `testing-integration` dialects, commits per
logical change.

### Step 5 - Test + Review

```text
/spec-test SPEC-001
/spec-review SPEC-001
```

The `verifier` fills `review.md` with PASS/FAIL per epic AC + per
story/enabler AC + per Test ID, and verdict `APPROVED` or
`CHANGES_NEEDED`.

If APPROVED, you merge the branch. Done.

### Optional Step 6 - Deploy

```text
/spec-deploy SPEC-001 --ci=github-actions --cloud=aws
```

The `infrastructure-implementer` writes `.github/workflows/...` and IaC
stubs under `infrastructure/terraform/SPEC-001-cli-skeleton/...` plus a
`deploy.md` summary in the spec folder. **It does not run the
deployment** - you do that manually.

### Shortcut - one command

```text
auto "build a CLI that converts CSV to JSON"
```

The framework pauses for the 5 foundational questions, the technical
interrogation, permission before opening parallel sessions, any
confidence < 95% gate, and the two token-budget approvals. Or run quiet:

```text
auto "build a CLI that converts CSV to JSON" --silent --assume --accuracy 95% --budget 5 USD
```

One upfront budget approval, then silent unless something needs the
human. Add `--parallel` to fan out spec creation across epics and
pre-authorize parallel session windows (see
[QUICKSTART.md](./QUICKSTART.md#the-auto-skill-in-depth)).

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](./LICENSE).
