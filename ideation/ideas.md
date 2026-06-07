---
title: Ideas MOC
aliases:
  - ideas
  - ideas-moc
tags:
  - ideation
  - entrypoint
  - progress-tracking
  - kcc/v04
created: 2026-05-24
updated: 2026-05-29
version: 1.1.0
status: active
---

# Ideas

The map-of-content for every idea that enters the framework. Populated
by `/idea-interrogator` (creates rows) and updated by `spec-writer` /
`/auto` as ideas move through their status taxonomy.

The status taxonomy and update responsibilities are defined in
[[../.KCC/kernel/protocols/progress-tracking|the progress-tracking protocol]].

## Status taxonomy

| Status | Meaning |
|--|--|
| `Drafting` | Idea-interrogator is collecting answers |
| `Ready for spec` | Briefing complete; `SpecWriterStarter.md` ready |
| `Handed off` | `/spec-create` invoked; per-idea spec index exists |
| `In delivery` | At least one spec is `In progress` or further |
| `Done` | Every spec for the idea is `Done` |
| `Parked` | Intentionally on hold; not abandoned |
| `Abandoned` | Will not proceed |

## Snapshot

- **Total ideas**: 0
- **Drafting**: 0
- **Ready for spec**: 0
- **Handed off**: 0
- **In delivery**: 0
- **Done**: 0
- **Parked**: 0
- **Abandoned**: 0

## Ideas

| IDEA-ID | Date | Brief | ROI confidence | Status | Spec index | Effort estimate | Token budget |
|--|--|--|--|--|--|--|--|
| _(no ideas yet - populated by `/idea-interrogator`)_ |  |  |  |  |  |  |  |

> Row shape: `IDEA-{ID}` `YYYY-MM-DD` `{one-line brief}` `{Low/Medium/High}` `{Status from taxonomy}` `[[../specs/IDEA-{ID}-{slug}-Specs/IDEA-{ID}-{slug}-Specs|IDEA-{ID} specs]]` `{S/M/L or person-days}` `{tokens or $ from token-guard}`

## Related

- Progress tracking protocol: [[../.KCC/kernel/protocols/progress-tracking]]
- Idea layout protocol: [[../.KCC/kernel/protocols/idea-layout]]
- Spec layout protocol: [[../.KCC/kernel/protocols/spec-layout]]
- Architecture governance: [[../.KCC/kernel/protocols/architecture-governance]]
- Architecture documentation: [[../.KCC/kernel/protocols/architecture-documentation]]
- Auto mode skill: [[../.KCC/capabilities/skills/auto]]
- All specs: [[../specs/specs|Specs MOC]]
- Architecture MOC: [[../architecture/architecture|Architecture MOC]]
- Progress landing page: [[../progress|Progress]]
