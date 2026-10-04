---
title: Session Continuity Protocol
aliases:
  - session-continuity
  - restore-point
  - limit-watch
tags:
  - framework/protocol
  - continuity
  - harness
created: 2026-09-21
updated: 2026-09-21
version: 1.0.0
status: active
copyright: "KCC framework (c) 2026 Tarek Fawaz"
homepage: "https://tikasway.dev/kcc"
license: "Licensed under the terms in LICENSE"
---

# Session Continuity

A KCC run must survive a usage limit, a crash, or a switch to another
harness without losing state or redoing work. There is one artifact for all
three cases, the **restore point**, and three tools.

## Restore point (`coordination/checkpoints/CP-{NNN}.md`)

Written by `kcc-checkpoint`. It uses the handover-envelope shape
([[handover]]) with these fields:

| Field | Content |
|--|--|
| `id`, `created`, `reason` | `limit-soft` \| `limit-hard` \| `spec-reviewed` \| `manual` \| `handover` |
| `harness`, `session_id` | Where it was written. The session id is used for native resume. |
| `auto` | Scenario, AutoPolicy JSON, current state number, spec, wave, loop counters |
| `trace_session` | Active `Traces/Session-*` path |
| `open_gates` | Pending human decisions, with their allowed answers |
| `done_since_last` | Artifacts written and events emitted since the previous CP |
| `next_action` | One imperative line, e.g. `Run state 15 wave 2 for SPEC-003 (Story-004, Story-005)` |
| `git` | HEAD sha plus a `kcc/cp-{NNN}` tag, or a file-hash manifest when git was skipped |
| `resume_prompt` | The exact text a fresh session receives |

`coordination/checkpoints/latest.md` always points to the newest restore
point. `kcc-checkpoint` builds the file from disk state: `orchestrator.json`,
the backchannel, and the trace session. It takes no model input, so a
restore point costs almost no tokens.

## Usage-limit watch

| Threshold | Default | Action |
|--|--|--|
| soft | 95% | Finish the current unit. Spawn nothing new. Write CP `limit-soft`. |
| hard | 99% | Stop tool use now. Write CP `limit-hard`. Arm the watcher. |

Thresholds live in `.KCC/settings.json` -> `continuity`.

**Where usage data comes from:**

| Harness | Source | Detection |
|--|--|--|
| Claude Code | status-line JSON `rate_limits.five_hour` / `seven_day` (`used_percentage`, `resets_at`) and `context_window.used_percentage`, written to `coordination/usage.json` by `.KCC/tools/kcc-statusline` | A `PreToolUse` hook (`kcc-limit-guard`) reads `usage.json` and blocks at the hard threshold |
| Codex, OpenCode, generic | not exposed | The watcher detects rate-limit errors in the harness output or exit code, or the human runs `kcc-checkpoint -Reason manual`. The reset time comes from the error text, or `continuity.default_wait_minutes` |

**Watcher (`kcc-limit-watch`):** a detached background process. It sleeps
until `resets_at` plus `continuity.resume_grace_seconds`, then resumes the run
**unattended** using the harness's resume template from
`.KCC/settings.json` -> `continuity.resume` (example defaults):

| Harness | Unattended resume template |
|--|--|
| claude | `claude -p --resume {session_id} --permission-mode {permission_mode} "{resume_prompt}"` |
| codex | `codex exec resume {session_id} "{resume_prompt}"` |
| opencode | `opencode run --session {session_id} "{resume_prompt}"` |
| generic | `{command} "{resume_prompt}"` (configured per workspace) |

Unattended runs use an explicit, configured permission mode (default
`acceptEdits`, plus the project allowlist). They **never** default to a
permission-bypass mode. The watcher writes its log to
`coordination/limit-watch.log`, emits `limit-reached`, `checkpoint-created`,
`resume-scheduled`, and `resume-started`, and gives up after
`continuity.max_resumes` attempts (default 5). If the resumed session hits
the limit again, the cycle repeats.

### Supervised runs (`kcc run`)

With the `kcc` CLI installed, `kcc run` is the supervisor for every harness
and replaces the detached watcher: the process that started the run also
waits and resumes it, so nothing depends on a background process surviving.

| Mode | Command | What is supervised |
|--|--|--|
| Driver | `kcc run --input <...>` / `kcc run --resume` | The `kcc-run` state machine. It runs with `KCC_SUPERVISED=1`, so on a limit it writes the `limit-hard` restore point and `coordination/run/limit.json`, exits 5, and arms no watcher. The CLI waits and calls `kcc-run --resume` |
| Wrap | `kcc run --wrap [--harness <name>] -- <command...>` | Any harness command line. The CLI reads its output, writes the restore point itself, waits, and resumes with the `continuity.resume` template (or `continuity.start` when no session id was seen) |

Limit detection is the same for every harness, in this order:

1. **Structured output.** A JSON line of a failing run that carries a
   rate-limit key (`structured_keys` in the pattern table) or status 429.
2. **Pattern table.** `.KCC/kernel/limit-patterns.json`:
   `limit_regex.default` plus `limit_regex.<harness>`, matched against the
   last lines of output. `kcc-run`, `kcc-limit-watch`, and the CLI all read
   this one file; add a harness's wording there, not in the scripts. A bare
   `429` counts only with a failing exit code.
3. **Fallback wait.** When the output names no reset time,
   `continuity.default_wait_minutes` is used.

The reset time is read from the output: an epoch (`resets_at`, `|<epoch>`),
`Retry-After`, a relative time (`try again in 2 hours 5 minutes`), an ISO
timestamp, or a clock time (`resets at 3pm`, taken as the next occurrence).

The supervisor resumes at the reset time plus `resume_grace_seconds`, at
most `max_resumes` times, then exits 5. `--no-wait` exits 5 at the first
limit instead (driver mode then arms `kcc-limit-watch` as before). A resume
template that contains a permission-bypass flag is refused. `kcc limits`
shows the usage windows, the last limit, and the next resume;
`coordination/run/limit.json` holds the same record.

## Harness handover (`kcc-handover`)

`kcc-handover -To <harness> [-Launch] [-Unattended]` does the following:

1. Writes a fresh restore point (reason `handover`).
2. Writes `coordination/handover/HO-{NNN}.md`: the envelope, the target
   harness's entrypoint (`CLAUDE.md` or `AGENTS.md`), and the paths to read
   (never file contents).
3. Makes sure the target harness's adapter outputs exist (runs `sync-adapters`
   for that harness when missing).
4. Prints the launch command, or runs it with `-Launch`, using
   `continuity.resume` (or `continuity.start` for a fresh session). The
   prompt is `Read coordination/handover/HO-{NNN}.md and continue`.

The receiving session reads the envelope and resumes `auto` at `next_action`.
Agent profiles come from `orchestrator.json`, so the model and effort are
resolved for the new harness automatically. The trace session and
backchannel continue unbroken. Emit `handover-issued` and `handover-accepted`.
