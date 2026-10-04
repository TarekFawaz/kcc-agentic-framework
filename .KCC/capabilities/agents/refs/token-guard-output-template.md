---
title: Token Guard Output Templates
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Token Guard Output Templates

## Output Format

Print this table to the human (Markdown). Keep prose around it to a single
inputs line and the approval question - nothing else.

```markdown
### Token Budget - {SPEC-ID or "free-form prompt"}
Inputs: criteria={N}, files={N}, risk={low|med|high}, plan_steps={N|n/a}

| Step        | Model-class       | Input tokens | Output tokens | Est. cost ($)   | Band            |
|--|--|--|--|--|--|
| interrogate | strong-reasoning  | ...          | ...           | $...            | $low - $high    |
| create      | strong-reasoning  | ...          | ...           | $...            | $low - $high    |
| plan        | strong-reasoning  | ...          | ...           | $...            | $low - $high    |
| implement   | balanced          | ...          | ...           | $...            | $low - $high    |
| test        | balanced          | ...          | ...           | $...            | $low - $high    |
| review      | strong-reasoning  | ...          | ...           | $...            | $low - $high    |
| **TOTAL**   |                   | ...          | ...           | **$...**        | **$low - $high**|

ROI: ideation/IDEA-{ID}-{slug}/ROI.md  (or: "no traceable idea - not persisted")
Backchannel: BC-NNNNN

Approve, revise, or abort?
```

When an approved AutoPolicy covers the estimate, replace the approval prompt
with:

```markdown
AutoPolicy: auto-approved (cumulative ${used} of ${cap} {currency}; threshold {NN}%)
```

When AutoPolicy exists but needs first approval, replace the approval prompt
with:

```markdown
Approve auto-spend up to {amount} {currency} with assumptions documented and confidence gate at {threshold}%? approve / revise / abort
```

**Local model rows** drop the dollar column entirely. Format example:

```markdown
| implement   | local-fast        | 14336        | 4301          | n/a (local)     | tokens only     |
```

Add a single footer line beneath the table when any local rows are present:
`> Local infra cost is tracked separately; this agent reports token counts only for local model-classes.`

If step 3 widened the band, add a second footer:
`> Band widened to +/-50% due to recent INC-{NNN} (prior estimate ran ~2x over).`

For Mode B (prompt), collapse the table to a single row labelled `prompt`
and skip the ROI/Backchannel lines.

For Mode C (idea-scope), use this **forecast block** (suitable for embedding
in `idea-{ID}-{slug}.md` and in `auto`'s human-facing display). Display it
in **every scenario** (HITL idea-interrogator, `/auto` Scenarios 1/2/3,
`--silent --assume`) - it is awareness, not a gate, except when a
`--budget` cap is in force and the TOTAL exceeds it.

```markdown
### Token Budget - IDEA-{ID} (upfront, idea-scope estimate)

Inputs: phases={n}, epics={n}, total story points={n}, avg complexity={low|med|high|huge}
Confidence band: +/-50% (will tighten to +/-20% after the first SPEC is created)
Rates: see `.KCC/kernel/templates/ROI.md`

| Step        | Per-step total tokens | Per-step ($) | Per-step band   |
|--|--|--|--|
| interrogate | ...                   | $...         | $low - $high    |
| create      | ...                   | $...         | $low - $high    |
| plan        | ...                   | $...         | $low - $high    |
| implement   | ...                   | $...         | $low - $high    |
| test        | ...                   | $...         | $low - $high    |
| review      | ...                   | $...         | $low - $high    |
| **TOTAL**   | **...**               | **$...**     | **$low - $high**|

Local-class steps (if any): token counts only, no $ conversion.

Approve, revise, abort? (only required in scenarios with a budget cap; in
HITL and silent modes this is awareness only)
```

Add a footer beneath the table:
`> Band will tighten to +/-20% once the first SPEC for IDEA-{ID} is created and Mode A produces a real anchor.`

When called by `/auto` in Scenario 3 with `--budget N` and the TOTAL
exceeds the cap, append after the table:
`> AutoPolicy cap exceeded by ${over}. STOP - human must raise cap, revise scope, or abort.`
