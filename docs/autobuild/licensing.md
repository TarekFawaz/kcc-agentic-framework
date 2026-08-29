---
title: Autobuild Licensing and Attribution Baselines
aliases:
  - autobuild-licensing
  - licensing-baselines
tags:
  - framework/documentation
  - autobuild
  - legal
created: 2026-08-29
updated: 2026-08-29
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Autobuild licensing and attribution baselines

The autobuild runtime and its harness adapters carry two licensing
surfaces: KCC's **own custom license** and the **upstream Superpowers
material** that the bounded engineering skills adapt. The baselines below
are **immutable**: they are the durable reference for attribution and
license identity. A change to a baseline requires a new baseline entry
with a rationale and its own commit — never an in-place rewrite of a
frozen value.

## KCC framework baseline (own license)

| Field | Baseline |
|---|---|
| License | Custom (**non-SPDX**) bespoke grant of permission; KCC declares no SPDX identifier. The text is the one in `LICENSE` ("Licensed under the terms in this LICENSE..."). |
| GitHub license detection | **NOASSERTION** — GitHub's license detector maps no SPDX template to the custom text, and the project does not assert a known SPDX license. |
| Pinned commit | `708bd761a4ca39abcb2161de9b1109b913cafda8` (2026-06-18, "Update LICENSE", Tarek Fawaz) — the immutable baseline of the license text. |
| LICENSE Git blob | `ae6d7670ed9310494163033a2146d07de2ef4e81` |
| Copyright | © 2026 Tarek Fawaz · tikasway.dev |

Verify the recorded values against the repository:

```bash
# Pinned commit's LICENSE blob must equal the frozen blob.
git rev-parse 708bd761a4ca39abcb2161de9b1109b913cafda8:LICENSE
# ae6d7670ed9310494163033a2146d07de2ef4e81

# Working-tree LICENSE must equal the frozen blob.
git hash-object LICENSE
# ae6d7670ed9310494163033a2146d07de2ef4e81
```

## Superpowers baseline (upstream attribution)

| Field | Baseline |
|---|---|
| Source project | [`obra/superpowers`](https://github.com/obra/superpowers) |
| Release | **v6.3.0** |
| Pinned commit | `b36e0829c6d0140e93cfef2ca599b1b07d4a7797` — the point-of-adaptation commit |
| License | MIT |
| Copyright | Copyright (c) 2025 Jesse Vincent |

The KCC adaptations derived from the pinned source are the five bounded
engineering skills under `.KCC/capabilities/skills/`
(`engineering-tdd`, `engineering-debug`, `engineering-request-review`,
`engineering-receive-review`, `engineering-verify`) plus the
`autobuild-task-execute` orchestration skill that delegates to them.
Each adaptation keeps the MIT notice, adds KCC-native frontmatter and
task-local bounding, and is distributed under the framework's own
terms; **no upstream file is redistributed unmodified**. The complete
adapted-file inventory and the verbatim MIT notice live in
[`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md).

## Immutability rules

- The baseline values above are frozen at what is recorded here; facade
  or generated copies never become the source of truth.
- Any license or attribution change is a new baseline record: a new
  pinned commit/release value, a stated reason, and its own commit with
  a reviewer of record. Frozen values are never silently edited.
- Generated harness surfaces carry attribution generated from the
  neutral `.KCC/capabilities/` source. To change attribution, edit the
  neutral source and regenerate with
  [`sync-adapters`](../codex-claude-opencode-ollama.md) — never hand-edit
  generated files.
- KCC's own license text is `LICENSE`; it is not an SPDX license and
  must not be re-labeled with a GitHub-detected or SPDX identifier that
  was never asserted.

## Related

- [Autobuild operations](./operations.md) - operator commands, run
  states, pause/resume, BLOCKED auto-recheck, EXTERNAL_WAIT, HALTED
- [Harnesses and capability levels](./harnesses.md) - two-mode operation
  and report parity
- [Autonomy metrics and rollout gates](./rollout.md) - R1/R2/R3 gates
- [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) - adapted
  file inventory and verbatim MIT notice
- [`LICENSE`](../../LICENSE) - the KCC framework license text

---

KCC framework (c) 2026 Tarek Fawaz, [tikasway.dev](https://tikasway.dev/kcc). Licensed under the terms in [LICENSE](../../LICENSE).
