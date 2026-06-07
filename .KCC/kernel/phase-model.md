---
# Functional fields (none - this is a kernel governance document,
# not consumed by harness adapters)

# Obsidian metadata
title: KCC Phase Model
aliases:
  - phase-model
  - maturity-ladder
  - kcc-phase
tags:
  - kcc/kernel
  - framework/documentation
  - phase-model
created: 2026-05-25
updated: 2026-05-25
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# KCC Phase Model

KCC v0.4 defines a three-phase maturity ladder for an organization's
adoption of agentic SDLC. Each phase has a **ceiling** - a class of
work it cannot honestly do - and crossing the ceiling requires
specific structural changes, not just better prompts.

This document restates the three phases and then locates **this
framework's current implementation** on the ladder.

## The three phases

### Phase 1 - AI assists humans

Humans drive every meaningful decision; AI accelerates discrete tasks
(summarize, draft, rename, search). The SDLC is unchanged from the
pre-AI shape - there are just chat windows next to the IDE.

**Ceiling.** No structural learning loop. AI memory is per-session.
Code review, design review, and decision authority remain entirely
with humans. AI cannot be trusted with a multi-step task without
per-step approval.

**Typical artifacts.** Inline copilots, chat-driven refactors, ad-hoc
prompt libraries.

### Phase 2 - SDLC restructured around AI

The lifecycle itself is rebuilt to keep humans **on** the loop rather
than **in** it. Specs, plans, and reviews are first-class artifacts
designed for AI consumption. Structural memory exists. Trust is
**behavior-based**: agents earn or lose autonomy based on observed
performance against criteria, not on per-turn human comfort.

**Ceiling.** Agents still can't own a full spec end-to-end without
human checkpoints at lifecycle boundaries. There is no honest
delegation of an entire epic to an agent crew, because the
behavior-trust signal isn't yet rich enough to let go on the Golden
Path.

**Typical artifacts.** Spec-driven workflow with named lifecycle
stages, an automated [[inspector|Inspector Pipeline]], a behavior-
scoring meta-agent, enforced confidence gates, persistent memory with
curated entries.

### Phase 3 - Agents as first-class collaborators

Agents own entire epics on **Golden Path** capabilities (capabilities
that have accumulated enough behavior-trust evidence to clear a
defined bar). Humans are consulted on architecture-class decisions,
safety-class proposals (e.g. [[lethal-trifecta]]), and novel work
outside the Golden Path. The lifecycle continues to run, but most
turns do not require per-turn human approval - the gates exist and
fire only when an agent's confidence dips or a safety pattern
triggers.

**Ceiling.** Phase 3 still requires humans for:

- Net-new capability classes (no behavior-trust history).
- Anything triggering the Lethal Trifecta.
- Architecture-class decisions with cross-team blast radius.
- Cost decisions above an approved envelope.

It is **not** a vision of unattended autonomy. It is a vision of
**proportional** human attention.

## Where this framework sits today: Phase 1.5

This implementation is honestly at **Phase 1.5** - somewhere between
"AI assists humans" and "SDLC restructured", with real structural
moves done but the defining Phase 2 capabilities not yet shipped.

What this framework already has (above pure Phase 1):

- A formalized lifecycle (`interrogate -> create -> plan -> implement ->
  test -> review`) with named agent roles.
- A spec-driven workflow with epic/story/enabler decomposition.
- Confidence gates and the [[critical-human-gate]] skill.
- Two meta-agents ([[butler]] memory custodian, [[token-guard]] cost
  custodian) running on every lifecycle skill.
- An auto-mode (HOTL) that chains lifecycle stages without per-step
  prompting (but still pauses for the foundational human Q&A).
- Persistent memory under `memory/` with a curated schema.
- A backchannel (`coordination/backchannel.jsonl`) for inter-agent
  events.

What this framework does **not** yet have (the Phase 2 gap):

- [ ] Automated [[inspector|Inspector Pipeline]] (today: scaffold
      only, manual execution).
- [ ] Behavior-scoring of agents over time - the butler tracks
      memory, not agent-performance percentiles.
- [ ] Enforced maturity-ladder per capability (the `maturity: L2`
      field exists on agents but nothing reads it for trust decisions).
- [ ] Cells / cell-team structure (sibling work item - see
      [[cells]]).
- [ ] Continuous evidence aggregation from `Traces/` into a queryable
      observation surface.
- [ ] Behavior-based promotion: today, every capability change
      requires a human commit. Phase 2 needs the Inspector loop
      closing.

## What would land this framework at Phase 2

Checkbox-grade requirements:

- [ ] **Inspector Pipeline is automated.** All five stages
      ([[observe]], [[detect]], [[propose]], [[review]], [[promote]])
      execute without manual driver, with the human reviewing only
      stage 4. See [[kernel/inspector/README]].
- [ ] **Butler does behavior-scoring** in addition to memory curation
      - emits per-agent confidence-vs-actual calibration, gate-abort
      rates, override-on-handoff rates.
- [ ] **Maturity ladder is enforced.** Agents with `maturity: L1` are
      blocked from auto-mode promotion. Agents with `maturity: L3`
      auto-promote on Golden Path capabilities.
- [ ] **Cells are real.** Cell-team structure with team-level
      ownership of `.KCC/capabilities/` subsets, distinct from the
      kernel maintainer role.
- [ ] **Trace-to-memory is automated.** Closing a session
      auto-triggers butler-remember, not just on `auto` chains.
- [ ] **Cost envelopes are enforced.** Token-guard `estimate-aborted`
      events actually halt execution, not just emit a warning.

## What would land this framework at Phase 3

Checkbox-grade requirements (Phase 2 is a prerequisite):

- [ ] **Golden Path capabilities exist** - at least one
      end-to-end lifecycle (e.g. backend-python CRUD) classed as
      Golden Path with documented trust evidence.
- [ ] **Agents own specs on the Golden Path without per-turn human
      approval.** The human is consulted only at: idea
      interrogation, architecture review, safety-gate firings, and
      epic-close.
- [ ] **Multi-spec parallel execution** - agent crews concurrently
      driving multiple specs to Done with cross-spec coordination via
      the backchannel.
- [ ] **Safety patterns enforced at runtime, not just lint time.**
      [[lethal-trifecta]] violations cannot run; they hard-block at
      skill invocation, not at validate-kcc.
- [ ] **Self-modification within bounds.** Cell-teams can land
      capability changes through the Inspector loop without kernel-
      maintainer involvement (kernel maintainer reviews only
      kernel-class changes).
- [ ] **Behavior-trust degradation is detected and acted on.** A
      Golden Path capability that regresses (gate-abort spike,
      override spike) is auto-downgraded out of Golden Path until it
      re-earns trust.

## See also

- [[inspector/README|Inspector Pipeline]] - the learning loop that
  Phase 2 depends on.
- [[lethal-trifecta]] - safety pattern that must hold at every
  phase.
- [[cells]] - cell-team structure (sibling work).
- [[confidence-gate]] - the existing gate primitive.
- [[backchannel]] - the inter-agent event log.
