---
# Functional fields (consumed by harness adapters)
name: idea-interrogator
description: >
 Interrogate a raw idea and produce an Obsidian-friendly idea folder with `idea-{ID}-{slug}.md`, linked artifacts, architecture depth, and a spec-writer handoff. Usage: /idea-interrogator <idea>
argument-placeholder: <ARGS>
delegates-to:
  - idea-interrogator
  - technical-interrogator
  - ux-ui-designer
  - security-analyst
  - infrastructure-planner
  - token-guard
maturity: L2
maintainer: tarek.fawaz1983@gmail.com
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"

# Obsidian metadata (used in the vault, ignored by harness adapters)
title: Idea Interrogator Skill
aliases:
  - idea-interrogator-skill
tags:
  - framework/skill
  - lifecycle/interrogate
created: 2026-05-24
updated: 2026-05-29
version: 2.6.0
status: active
---

# Idea Interrogator

Interrogate the idea: <ARGS>

This skill drives a deep, structured interrogation in BOTH modes:

- **HITL** (direct `/idea-interrogator <idea>` invocation): full 11-step flow,
  ending with the human choosing `/spec-create`, park, or revise.
- **`auto`** (invoked from `auto <idea>`): identical 11-step flow EXCEPT the
  orchestrator decides the next move after step 8; the skill does not ask the
  step-9 question.

`auto --silent --assume` does not skip interrogation. It allows the agent to
document low-risk assumptions in place of human answers for the foundational,
technical, UX, security, and infrastructure interrogations. It must still
stop for prohibited assumptions (legal, security, privacy, compliance, data
sensitivity, authentication/authorization, destructive actions, external
spend, production-impacting decisions) or any confidence below the configured
threshold (95% default).

## Steps

1. **Bootstrap ideation.** Ensure `ideation/` exists. If `ideation/ideas.md`
   does not exist, create it with Obsidian frontmatter and this table:

   ```markdown
   | Idea | Date | Brief | ROI confidence | Status | Specs/Epics |
   |--|--|--|--|--|--|
   ```

2. **Reasoning step (FIRST output).** Delegate to the **idea-interrogator**
   agent with `<ARGS>` and the current mode (`auto` or `HITL`). The agent's
   FIRST artifact is the `## Reasoning` section inside the new
   `idea-{ID}-{slug}.md`. It contains:
   - the agent's interpretation of the input,
   - the agent's framing of the problem,
   - the category it places this in: `new-idea`, `update-to-existing-solution`,
     `problem-statement`, or `file-path-driven`,
   - the questions it intends to ask in the next steps.

   In HITL mode, pause and ask the human "Is this framing correct? (confirm /
   revise / abort)" before continuing.
   In `auto` mode without `--silent --assume`, do the same pause.
   In `auto --silent --assume`, write the framing and proceed.

3. **Foundational interrogation.** The idea-interrogator agent asks
   feasibility / viability / economic-worth questions in addition to the
   standard 5 foundational questions (problem, audience, outcome, scope,
   constraints):
   - Feasibility: "Is this technically doable in the available window?"
   - Viability: "Is the audience real, reachable, and willing?"
   - Economic worth: "Is the build + run cost worth the value?"

   **Branch - update-to-existing-solution.** If the category from step 2 is
   `update-to-existing-solution`, the agent MUST add an
   "Impact + Gap Analysis + Alternatives" section to `HumanAnswers.md`:
   - Read `solution/solution.md` if it exists (from `/solution-onboard`).
   - Identify what the proposed change touches.
   - Identify gaps the change creates.
   - Propose at least 2 alternatives to the proposed change.
   - Ask the human to choose which path to pursue.

4. **Tech-stack challenge.** Invoke `/technical-interrogator` with the idea
   folder. The technical-interrogator agent MUST CHALLENGE the human's
   tech-stack assumptions, not just record them. Example: if the human says
   "we'll use Java because that's what we use" for a small CLI tool, the
   agent must surface alternatives (Go, Rust, single-binary trade-offs) and
   ask for an explicit decision. Output: `TechnicalDecisionBrief.md` in the
   idea folder.

5. **UX interrogation (conditional).** If the idea is user-facing, invoke
   `/ux-ui-interrogator` with the idea folder. The ux-ui-designer agent MUST
   present AT LEAST 3 design-system options the human can pick from
   (e.g. Material Design, Fluent, Tailwind + shadcn, Carbon, Atlassian
   Design, Ant Design, custom) with a one-sentence trade-off each. Output:
   `UXDecisionBrief.md` in the idea folder.

6. **Security interrogation.** Invoke `/security-interrogator` with the idea
   folder. Output: `SecurityDecisionBrief.md` in the idea folder.

7. **Infrastructure interrogation (conditional).** If the architecture depth
   is `distributed` or `regulated`, or if the technical brief flags
   deployment/SLO/cost/DR concerns, invoke `/infrastructure-interrogator`.
   Output: `InfrastructureDecisionBrief.md` in the idea folder.

8. **Confirmation step.** The agent restates EVERY captured answer
   (foundational + tech + UX + security + infrastructure if scoped) in a
   single consolidated `## Final Confirmation` block at the bottom of
   `HumanAnswers.md` and asks the human one question: "Confirm all / revise
   {section} / abort". This is the last gate before idea breakdown.

   In `auto --silent --assume`, write the consolidated block and proceed
   unless any answer is an assumption flagged with confidence below threshold
   or in the prohibited list.

9. **Idea breakdown.** The agent populates two NEW sections in
   `idea-{ID}-{slug}.md`:
   - `## Phases` - high-level roadmap sections, each grouping a small number
     of likely epics. Phases are NOT a new primitive; they are a navigation
     section inside the parent idea file.
   - `## Epics (likely specs)` - each phase lists 1-N likely epics with a
     one-line description. Spec-writer will later materialize these as
     `SPEC-{ID}` folders under `specs/IDEA-{ID}-{slug}-Specs/`.

10. **Effort + cost estimation (UPFRONT, always shown).**
    - **Human-team effort.** The agent writes an `## Effort Estimate` table
      in `idea-{ID}-{slug}.md` with one row per epic:
      `phase | epic | story points | complexity | estimate (man-days, +/-20%)`.
      Convert story points x complexity factor to man-days, display the
      +/-20% band, and sum the totals at the bottom (man-days + weeks).
    - **Token cost.** Invoke `/token-estimate` in upfront idea-scope mode
      (sibling D's new mode) with the idea folder as input. It returns a
      pessimistic +/-50% forecast per lifecycle step (interrogate, plan,
      implement, test, review) for the entire idea, in tokens and $. The
      agent embeds the forecast in `## Effort Estimate`.

    Both estimations are ALWAYS shown - included in HITL direct invocation
    and in `auto --silent --assume` (where they are shown as awareness, not
    for approval).

11. **Mode-dependent close-out.**
    - **HITL mode:** ask the human "Do you want to create the specs now
      (/spec-create), park this idea, or revise?" Wait for the decision.
      - `/spec-create` -> hand off; update `ideation/ideas.md` status to
        `Handed off` once specs land.
      - `park` -> set status to `Parked`.
      - `revise` -> reopen the interrogation at the requested step.
    - **`auto` mode:** DO NOT ask. The orchestrator (sibling B's `/auto`
      rewrite) decides per its own rules whether to chain into
      `/spec-create`, pause for the budget gate, or stop.

12. **Console summary.** After the agent completes, display:
    - The new IDEA-ID and folder path.
    - The parent idea file path: `ideation/IDEA-{ID}-{slug}/idea-{ID}-{slug}.md`.
    - The selected architecture depth and category from the reasoning step.
    - A one-paragraph summary from `idea-{ID}-{slug}.md` or `Conclusion.md`.
    - The total man-day + token-cost estimate from step 10.
    - The recommended next step from `SpecWriterStarter.md`.
    - The generated artifact links from `idea-{ID}-{slug}.md`.

13. **Confidence gate.** If any delegated agent reports confidence below the
    configured threshold (95% by default), invoke `/critical-human-gate`
    before continuing.

## Related

- Agent: [[.KCC/capabilities/agents/idea-interrogator]]
- Idea layout: [[.KCC/kernel/protocols/idea-layout]]
- Spec layout: [[.KCC/kernel/protocols/spec-layout]]
- Auto mode: [[.KCC/kernel/protocols/auto-mode]]
- Confidence gate: [[.KCC/kernel/protocols/confidence-gate]]
- Token budget: [[.KCC/kernel/protocols/token-budget]]
