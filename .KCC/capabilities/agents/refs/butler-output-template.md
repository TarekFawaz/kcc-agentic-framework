---
title: Butler Output Templates
tags:
  - framework/agent-ref
updated: 2026-09-21
---

# Butler Output Templates

## Output Format

### Trace custody (both modes)

Trace writes are side effects, not part of the returned text. In brief mode you
ensure the session folder + pointer exist before returning the context pack; in
remember mode you append the seven trace files before returning the remember
confirmation. Note trace activity in one trailing line of the relevant block,
e.g. `_Trace: appended turn to Traces/Session-{slug}-{datetime} (7 files)._` or
`_Trace: session Traces/Session-{slug}-{datetime} active._`.

### Brief mode

```markdown
# Butler Context Pack - {topic or SPEC-ID}
_Generated: {ISO-8601 timestamp}_

## Relevant Decisions
- **[DEC-NNN]** {one-line summary} - {why it matters here}
- ...

## Applicable Patterns
- **[PAT-NNN]** {pattern name} - {when to apply it on this turn}
- ...

## Known Pitfalls
- **[INC-NNN]** {what went wrong before} - {how to avoid repeating it}
- **[backchannel]** {token-guard event of interest, if any}
- ...

_If a section has no entries, write "_none on file_" under its heading._
```

Total pack length: **~500 tokens hard cap**.

### Remember mode

```markdown
# Butler Remember - {input descriptor}
_Stored at: {ISO-8601 timestamp}_

- **{ID}** ({type}) - {one-line rationale for keeping it}
- ...

_Updated `memory/index.json`. Emitted backchannel: BC-NNNNN._
```

If nothing was retained, emit a single sentence: `No new entries - nothing
non-obvious or reusable in this report.` (Still emit a `remember-stored`
event with an empty `entry_ids` array.)

