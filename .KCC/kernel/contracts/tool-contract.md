---
title: Tool Contract
aliases:
  - tool-contract
tags:
  - kcc/kernel
  - contract
created: 2026-09-21
updated: 2026-09-21
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Tool Contract

Every KCC tool under `.KCC/tools/` follows this contract, so the `auto` flow
and every harness can call any tool the same way and parse its result
without reading prose.

## Pairing

Each tool ships as `name.ps1` (PowerShell 5.1 compatible: no `&&`, no
ternary, ASCII-only source) **and** `name.sh` (bash 3.2+ compatible, LF line
endings, `set -euo pipefail`). Both implement the same checks, IDs, and
exit codes.

## Arguments

| PowerShell | bash | Meaning |
|--|--|--|
| `-RepoRoot <path>` | `--repo-root <path>` | Workspace root. Default: parent of `.KCC`. |
| `-Json` | `--json` | Print one JSON object on stdout; nothing else. |
| `-Spec SPEC-{ID}` | `--spec SPEC-{ID}` | Limit to one spec (where applicable). |
| `-Scope <name>` | `--scope <name>` | Sub-check selector (where applicable). |
| `-DryRun` | `--dry-run` | Report intended actions; change nothing (mutating tools only). |

## Exit codes

| Code | Meaning |
|--|--|
| 0 | Pass. `Errors: 0`. Warnings are allowed. |
| 1 | Violations found (at least one `error`). |
| 2 | Usage or environment error (bad args, missing workspace). |
| 3 | Deferred: a required external tool is missing and the human deferred the install. Never counts as a pass. |

## Output

Human mode: one line per finding, then a summary line `Errors: N  Warnings: M`.

JSON mode:

```json
{
  "tool": "check-traceability",
  "version": "1.0.0",
  "scope": "all",
  "errors": 1,
  "warnings": 0,
  "status": "fail",
  "violations": [
    {"id": "TRACE-AC-001", "severity": "error", "fix_owner": "planner",
     "file": "specs/.../SPEC-001-x.md", "message": "AC-2 has no Test ID"}
  ]
}
```

`status` is one of `pass`, `fail`, `deferred`. Every violation has a stable
`id`, a `severity` (`error` or `warning`), and a `fix_owner` (agent name or
`human`). This is what the self-healing loop routes on.

## Behaviour

- **Read-only** unless the tool's name says it mutates (`kcc-checkpoint`,
  `kcc-handover`, `quality-gate -Fix`). Mutating tools support `-DryRun`.
- **No network**, except scanners run by `quality-gate`. Those are installed
  only through the toolchain preflight gate.
- **Never print secrets.** Redact anything matching a credential pattern.
- **Emit evidence:** tools that close a gate append a backchannel event through
  `backchannel-append` when `-Emit` / `--emit` is passed.
- **Idempotent:** running a tool twice yields the same result.

## quality-gate checks and scopes

`quality-gate` (`--scope all` by default, or a comma list) runs: `lock`, `build`,
`lint`, `test`, `coverage`, `secrets`, `deps`, `sast`, `static`, `sbom`, `image`.

- `static` -> `QG-STATIC static-rules`. Reads `architecture/static-rules.tsv`
  (tab-separated, `#` comments; columns `id`, `files`, `forbidden`,
  `allowed_in`, `message`; the regexes are matched against paths relative to
  the workspace, `allowed_in` may be empty). No file: `skipped`. A malformed
  line, or any hit outside `allowed_in`, fails (`file:line rule-id` in the
  evidence file). `node_modules`, `dist`, `build`, `.git`, `coverage` and
  lockfiles are not scanned; test files are.
- `image` -> `QG-IMAGE image-scan` (`trivy fs` on the source) **and**
  `QG-IMAGE image-scan-built` (`trivy image --ignore-unfixed` on every image the
  compose file builds). Findings with a fix fail; findings with no fix are
  counted in the message and never gate. An image that is not built, or a
  missing `docker`/`trivy`, is `deferred`, never a pass; the tool never builds
  or installs.
