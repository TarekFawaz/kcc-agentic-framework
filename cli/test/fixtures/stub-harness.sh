#!/usr/bin/env bash
# Stub harness for lifecycle tests. kcc-run calls it in place of `claude -p` with the state's prompt as $1.
# It writes the artifacts a real orchestrator would produce for that state (or deliberately does not,
# per .kcc-stub/mode), so a test can prove the state machine: order, exit checks that refuse empty
# states, gates, resume. Modes: happy | empty-idea | over-arch | empty-wave | no-fix.
set -u
prompt="${1:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 1
mode="$(cat .kcc-stub/mode 2>/dev/null || echo happy)"
state="$(printf '%s' "$prompt" | grep -oE 'KCC run state [0-9]+' | grep -oE '[0-9]+$' | head -n 1)"
spec="$(printf '%s' "$prompt" | grep -oE 'for SPEC-[0-9]+' | grep -oE 'SPEC-[0-9]+' | head -n 1)"
wave="$(printf '%s' "$prompt" | grep -oE 'wave [0-9]+' | grep -oE '[0-9]+' | head -n 1)"
printf '%s state=%s spec=%s wave=%s mode=%s\n' "$(date -u +%H:%M:%S)" "${state:-?}" "${spec:-}" "${wave:-}" "$mode" >> .kcc-stub/calls.log
sleep 1
IDEA=IDEA-001-demo
ID="ideation/$IDEA"
SPECS="specs/$IDEA-Specs"
w() { mkdir -p "$(dirname "$1")"; cat > "$1"; }

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
  9)
    w "$SPECS/IDEA-001-demo-Specs.md" <<'EOF'
# IDEA-001 specs
Source idea: [[../../ideation/IDEA-001-demo/idea-001-demo|IDEA-001]]
- [[SPEC-001-skeleton/SPEC-001-skeleton|SPEC-001]]
EOF
    w "$SPECS/ROADMAP.md" <<'EOF'
# Roadmap - IDEA-001: Demo

## Execution Plan
| Order | Spec | Delivery | Depends on | Lane | Est. tokens | Restore point |
|--|--|--|--|--|--|--|
| 1 | [[SPEC-001-skeleton/SPEC-001-skeleton|SPEC-001]] | walking skeleton | None | A | n/a | CP after review |
EOF
    w "$SPECS/SPEC-001-skeleton/SPEC-001-skeleton.md" <<'EOF'
---
id: SPEC-001
title: Walking skeleton
status: Draft
---
# SPEC-001: Walking skeleton

| Priority | Category | Status | Wave | Depends on | Blocks | Index |
|--|--|--|--|--|--|--|
| P1 | Feature | Draft | 1 | None | None | [[../IDEA-001-demo-Specs|IDEA-001 specs]] |

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
    w "$SPECS/SPEC-001-skeleton/arch.md" <<'EOF'
# SPEC-001 architecture slice
Skeleton: API + SQLite, see [[../../../architecture/architecture|Architecture Document]].
EOF
    w "$SPECS/SPEC-001-skeleton/Backlog/Story-001-create-item.md" <<'EOF'
# Story-001: Create and list an item

| Type | Parent | Priority | Estimate | Status | Dialect | Depends on | Blocks |
|--|--|--|--|--|--|--|--|
| Story | [[../SPEC-001-skeleton|SPEC-001]] | P1 | S | Draft | backend-nodejs | None | None |

## Acceptance Criteria
- [ ] AC-1 - Given the app runs, when an item is posted, then it is listed.

## Impacted Files
- `src/IDEA-001-demo/app.ts` - the app

## Test Hints
- unit: posting then listing (AC-1)

INVEST: independent, negotiable, valuable, estimable, small, testable.
EOF
    w "$SPECS/SPEC-001-skeleton/plan.md" <<'EOF'
---
spec-id: SPEC-001
title: "SPEC-001 Implementation Plan"
version: 1.0.0
status: ready
---
# SPEC-001 Implementation Plan

## Ordered Changes
1. Story-001 - `src/IDEA-001-demo/app.ts`.

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
| T-001 | Story-001 | AC-1 | unit | post then list |
EOF
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
