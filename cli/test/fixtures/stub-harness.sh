#!/usr/bin/env bash
# Stub harness for lifecycle tests. kcc-run calls it in place of `claude -p` with the state's prompt as $1.
# It writes the artifacts a real orchestrator would produce for that state (or deliberately does not,
# per .kcc-stub/mode), so a test can prove the state machine: order, exit checks that refuse empty
# states, gates, resume. Modes: happy | empty-idea | over-arch | empty-wave | no-fix.
set -u
prompt="${1:-}"
# Spawn budget: the stub runs once per dispatch, and under Git Bash on Windows every process costs ~0.4 s, so the preamble below uses
# builtins for what used to be about twenty processes (dirname, cat, grep, head, date).
sd="${0%/*}"; [ "$sd" = "$0" ] && sd=.
cd "$sd/.." || exit 1
root="$PWD"
mode=happy; if [ -f .kcc-stub/mode ]; then IFS= read -r mode < .kcc-stub/mode || true; fi
state=""; spec=""; wave=""
re_state='KCC run state ([0-9]+)'; re_spec='for (SPEC-[0-9]+)'; re_wave='wave ([0-9]+)'
if [[ "$prompt" =~ $re_state ]]; then state="${BASH_REMATCH[1]}"; fi
if [[ "$prompt" =~ $re_spec ]]; then spec="${BASH_REMATCH[1]}"; fi
if [[ "$prompt" =~ $re_wave ]]; then wave="${BASH_REMATCH[1]}"; fi
if ! TZ=UTC printf -v clock '%(%H:%M:%S)T' -1 2>/dev/null; then clock="$(date -u +%H:%M:%S)"; fi
# epoch milliseconds: EPOCHREALTIME (bash 5; its decimal point depends on the locale) or date
now_ms() { if [ -n "${EPOCHREALTIME:-}" ]; then ms="${EPOCHREALTIME//[.,]/}"; ms="${ms:0:13}"; else ms="$(date +%s%3N)"; fi; }
# A lane (kcc run) is a copy of the workspace: one calls file per spec, so two lanes never write the same file and the merge has no clash.
calls=.kcc-stub/calls.log; [ -d .kcc-lane ] && calls=".kcc-stub/calls-${spec:-run}.log"
printf '%s state=%s spec=%s wave=%s mode=%s\n' "$clock" "${state:-?}" "${spec:-}" "${wave:-}" "$mode" >> "$calls"
# Every prompt, for tests that read what a state was told (the scoped re-verification wording, the human note).
prompts=.kcc-stub/prompts.log; [ -d .kcc-lane ] && prompts=".kcc-stub/prompts-${spec:-run}.log"
printf '%s\n' "$prompt" >> "$prompts"
# Epoch milliseconds at the start and the end of the dispatch, for tests that compare when two dispatches ran.
now_ms; printf '%s start %s %s\n' "$ms" "${state:-?}" "${spec:-}" >> ".kcc-stub/times-${spec:-run}.log"
nap=1; if [ -f .kcc-stub/sleep ]; then IFS= read -r nap < .kcc-stub/sleep || true; fi
sleep "$nap"
now_ms; printf '%s end %s %s\n' "$ms" "${state:-?}" "${spec:-}" >> ".kcc-stub/times-${spec:-run}.log"
IDEA=IDEA-001-demo
ID="ideation/$IDEA"
SPECS="specs/$IDEA-Specs"
# w FILE < text: writes stdin to FILE, making the folder first (builtins: no dirname, no cat)
w() { local dn="${1%/*}" content; [ "$dn" = "$1" ] && dn=.; [ -d "$dn" ] || mkdir -p "$dn"; IFS= read -r -d '' content || true; printf '%s' "$content" > "$1"; }

case "${state:-}" in
  1)
    [ "$mode" = empty-idea ] && exit 0
    w "$ID/idea-001-demo.md" <<'EOF'
---
id: IDEA-001
title: Demo
status: Ready for spec
depthlevel: 2
---
# IDEA-001 Demo

## Reasoning
A tiny demo app to prove the lifecycle.

## Phases
1. Skeleton.

## Assumptions
- Local only.
EOF
    w "$ID/Research.md" <<'EOF'
# Research
## Domain
common
## Findings
- Well-known CRUD web app.
EOF
    w "$ID/QuickRoadmap.md" <<'EOF'
# Quick roadmap
| Order | Epic | Depends on |
|--|--|--|
| 1 | Skeleton | None |
EOF
    w "$ID/SpecWriterStarter.md" <<'EOF'
# Spec writer starter
## Epics
| Epic | Outcome | Depends on |
|--|--|--|
| SPEC-001 skeleton | one feature end to end, runnable | None |
## Open questions
- none
EOF
    ;;
  4)
    for b in TechnicalDecisionBrief InfrastructureDecisionBrief UXDecisionBrief SecurityDecisionBrief; do
      w "$ID/$b.md" <<EOF
# $b
- Decision: defaults from the standards catalogue.
## Open questions
- none
EOF
    done
    ;;
  5)
    w "$ID/Assumptions.md" <<'EOF'
# Assumptions
| Question | Assumed answer | Rule | Risk |
|--|--|--|--|
| none | - | - | low |
EOF
    ;;
  6)
    w "architecture/architecture.md" <<'EOF'
---
title: Architecture Document - Demo
status: proposed
---
# Architecture Document - Demo

## 1. Overview
A single container web app with a SQLite file. This document is deliberately short: fast track keeps the
decisions that block code and nothing else. The paragraphs below exist so the document is a real narrative
and not a stub, which is what the conformance check requires of an architecture document.

## 2. Context
```mermaid
C4Context
  Person(user, "User")
  System(app, "Demo app")
  Rel(user, app, "uses")
```
Source: [[c4-context]]

## 3. Containers
```mermaid
C4Container
  Container(api, "API", "Node", "serves JSON")
  ContainerDb(db, "SQLite", "file", "stores data")
  Rel(api, db, "reads/writes")
```
Source: [[c4-container]]

## 5. Key workflows
See [[flowcharts/create-item]].

## Decisions
| Decision | Library / version | Citation | Status |
|--|--|--|--|
| HTTP framework | fastify ^5 | standards-catalog -> APIs | Accepted |
| Password storage | argon2 ^0.41 | standards-catalog -> Security | Accepted |

## Toolchain
| Tool | Version |
|--|--|
| node | >=20 |

## 8. Quality attributes
See [[quality-gates]].
EOF
    w "architecture/flowcharts/create-item.md" <<'EOF'
# Create item
```mermaid
flowchart TD
  A[Form] --> B[POST /items] --> C[(SQLite)]
```
EOF
    w "architecture/quality-gates.md" <<'EOF'
# Quality gates
| Gate | Rule |
|--|--|
| QG-QUALITY | lint, tests, coverage >= 80 |
EOF
    if [ "$mode" = over-arch ]; then
      w "architecture/adrs/ADR-0001-style.md" <<'EOF'
# ADR-0001 style
## Status
Accepted
EOF
    fi
    ;;
  9|10|11)
    N="$(cat .kcc-stub/specs 2>/dev/null || echo 1)"
    slug_of() { case "$1" in 1) echo skeleton ;; *) echo "feature-$1" ;; esac; }
    skipped() { grep -qx "$spec" ".kcc-stub/$1" 2>/dev/null; } # .kcc-stub/nowrite and .kcc-stub/noplan list specs a dispatch must leave unfinished
    stub_note() { # n -> the stub note the split writes: id, title, status, one-line Delivery, Depends on
      local n="$1" s; s="SPEC-00$1-$(slug_of "$1")"
      w "$SPECS/$s/$s.md" <<EOF
---
id: SPEC-00$n
title: Feature $n
status: Draft
---
# SPEC-00$n: Feature $n

- Delivery: one thin user-visible feature ($n).
- Depends on: $([ "$n" = 1 ] && echo None || echo SPEC-001)
EOF
    }
    full_note() { # n -> the whole spec: note, arch.md, one Story
      local n="$1" s; s="SPEC-00$1-$(slug_of "$1")"
      w "$SPECS/$s/$s.md" <<EOF
---
id: SPEC-00$n
title: Feature $n
status: Draft
---
# SPEC-00$n: Feature $n

| Priority | Category | Status | Wave | Depends on | Blocks | Index |
|--|--|--|--|--|--|--|
| P1 | Feature | Draft | 1 | $([ "$n" = 1 ] && echo None || echo SPEC-001) | None | [[../IDEA-001-demo-Specs|IDEA-001 specs]] |

## Delivery Brief
- Who: a user. Gets: one item created and listed end to end. Value: proves the stack. Measured by: AC-1.

## Acceptance Criteria
- AC-1 Given the app runs, when an item is posted, then it is listed.

## Backlog
| Key | Type | Title | Status | Wave |
|--|--|--|--|--|
| [[Backlog/Story-001-create-item|Story-001]] | Story | Create and list an item | Draft | 1 |

## Architecture
See [[arch]].
EOF
      w "$SPECS/$s/arch.md" <<EOF
# SPEC-00$n architecture slice
Skeleton: API + SQLite, see [[../../../architecture/architecture|Architecture Document]].
EOF
      w "$SPECS/$s/Backlog/Story-001-create-item.md" <<EOF
# Story-001: Create and list an item

| Type | Parent | Priority | Estimate | Status | Dialect | Depends on | Blocks |
|--|--|--|--|--|--|--|--|
| Story | [[../$s|SPEC-00$n]] | P1 | S | Draft | backend-nodejs | None | None |

## Acceptance Criteria
- [ ] AC-1 - Given the app runs, when an item is posted, then it is listed.

## Impacted Files
- \`src/IDEA-001-demo/app.ts\` - the app

## Test Hints
- unit: posting then listing (AC-1)

INVEST: independent, negotiable, valuable, estimable, small, testable.
EOF
    }
    case "$state" in
      9)
        [ -f .kcc-stub/noindex ] || w "$SPECS/IDEA-001-demo-Specs.md" <<'EOF'
# IDEA-001 specs
Source idea: [[../../ideation/IDEA-001-demo/idea-001-demo|IDEA-001]]
EOF
        {
          printf '# Roadmap - IDEA-001: Demo\n\n## Execution Plan\n'
          printf '| Order | Spec | Delivery | Depends on | Lane | Est. tokens | Restore point |\n|--|--|--|--|--|--|--|\n'
          n=1; while [ "$n" -le "$N" ]; do
            s="SPEC-00$n-$(slug_of "$n")"
            printf '| %s | [[%s/%s|SPEC-00%s]] | feature %s | %s | A | n/a | CP after review |\n' "$n" "$s" "$s" "$n" "$n" "$([ "$n" = 1 ] && echo None || echo SPEC-001)"
            n=$((n + 1))
          done
        } | w "$SPECS/ROADMAP.md"
        n=1; while [ "$n" -le "$N" ]; do
          case "$prompt" in
            *--split-only*) stub_note "$n" ;;
            *) full_note "$n" ;; # the full table has no WRITE state: SPECS writes every spec
          esac
          n=$((n + 1))
        done
        ;;
      10)
        skipped nowrite && exit 0
        n="${spec#SPEC-00}"; full_note "$n"
        ;;
      11)
        skipped noplan && exit 0
        n="${spec#SPEC-00}"; s="SPEC-00$n-$(slug_of "$n")"
        w "$SPECS/$s/plan.md" <<EOF
---
spec-id: SPEC-00$n
title: "SPEC-00$n Implementation Plan"
version: 1.0.0
status: ready
---
# SPEC-00$n Implementation Plan

## Ordered Changes
1. Story-001 - \`src/IDEA-001-demo/app.ts\`.

## Waves
| Wave | Items | Files | File-disjoint | Notes |
|--|--|--|--|--|
| 1 | Story-001 | src/IDEA-001-demo/app.ts | yes | |

## Toolchain
| Tool | Version |
|--|--|
| git | |

## Atomic test cases
| Test ID | Item | AC | Level | Description |
|--|--|--|--|--|
| T-00$n | Story-001 | AC-1 | unit | post then list |

## Gates coverage
| Gate | Covered by |
|--|--|
| QG-QUALITY | check:QG-TEST |
EOF
        ;;
    esac
    ;;
  15)
    [ "$mode" = empty-wave ] && exit 0
    w "src/IDEA-001-demo/app.ts" <<'EOF'
// T-001
export const items: string[] = [];
EOF
    ;;
  19)
    # the FIX state: close every open Bug item (mode no-fix leaves them open)
    [ "$mode" = no-fix ] && exit 0
    for f in "$SPECS"/*/Backlog/Bug-*.md; do [ -f "$f" ] && sed -i 's/| open |/| fixed |/' "$f"; done
    ;;
  16)
    # the verifier: writes review.md with the verdict named in .kcc-stub/verdict (CHANGES_NEEDED, QUALITY_DEFERRED, APPROVED, ...);
    # writes nothing when that file is absent. The status words follow the review template (lower case, hyphenated).
    if [ -f .kcc-stub/verdict ]; then
      verdict="$(tr -d '\r\n' < .kcc-stub/verdict)"
      sdir="$(ls -d "$SPECS/$spec"-*/ 2>/dev/null | head -n 1)"
      if [ -n "$sdir" ]; then
        status="$(printf '%s' "$verdict" | tr 'A-Z_' 'a-z-')"
        w "${sdir}review.md" <<EOF
---
spec-id: $spec
status: $status
verdict: $verdict
commit: abc1234def5678
---
# $spec Verification Report

## Evidence
- \`quality-gate\` exit 3

## Verdict
**$verdict**
EOF
      fi
    fi
    ;;
  18)
    w "coordination/run/closed.md" <<'EOF'
# Closed
| Gate | Result |
|--|--|
| QG-QUALITY | n/a (stub) |
EOF
    ;;
esac
echo "stub: state ${state:-?} done"
exit 0
