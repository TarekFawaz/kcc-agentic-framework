#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# kcc-limit-hook.sh - Claude Code StopFailure hook (matcher: rate_limit). When a session stops on a
# usage limit, it records the limit, writes a limit-hard restore point, and arms kcc-limit-watch so
# the session is resumed after the reset (session-continuity protocol).
#
# Why this exists: the status line is the only place Claude Code hands out usage percentages, and it
# does not run in the VS Code extension or in `claude -p`. So the soft/hard guard (kcc-limit-guard)
# never sees data there. A limit that is hit anyway is always reported through StopFailure, and the
# session transcript carries the exact reset time (apiErrorParams.rate_limit_info.resetsAt).
#
# Reset time, in order: transcript resetsAt (epoch) -> "resets 10:50pm (Europe/Stockholm)" text in the
# hook's error_message or the transcript tail -> continuity.default_wait_minutes (the watcher's fallback).
# If the human continues the session by hand before the reset, the watcher sees the transcript change
# (--skip-if-active) and does not start a second writer.
#
# Usage (.claude/settings.json):
#   "StopFailure": [{"matcher": "rate_limit", "hooks": [{"type": "command",
#     "command": "bash \"$CLAUDE_PROJECT_DIR/.KCC/tools/kcc-limit-hook.sh\""}]}]
# Args: [--repo-root PATH] [--dry-run]   --dry-run: decide and print, write and arm nothing.
# Hook output and exit code are ignored by Claude Code; this script never fails the session.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root|-RepoRoot) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --dry-run|-DryRun) DRY=1; shift ;;
    *) shift ;;
  esac
done

INPUT="$(cat || true)"
jfield() { printf '%s' "$INPUT" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | sed -E 's/^[^:]*:[[:space:]]*"(.*)"$/\1/' || true; }

SID="$(jfield session_id)"
TP="$(jfield transcript_path | sed 's/\\\\/\\/g')"
ERR_TYPE="$(jfield error_type)"
ERR_MSG="$(jfield error_message)"
if [[ -n "$ERR_TYPE" && "$ERR_TYPE" != "rate_limit" ]]; then exit 0; fi
if [[ -n "$TP" ]] && command -v cygpath >/dev/null 2>&1; then TP="$(cygpath -u "$TP" 2>/dev/null || printf '%s' "$TP")"; fi

NOW="$(date +%s)"
COORD="$REPO_ROOT/coordination"

# "10:50pm" + "Europe/Stockholm" -> next such wall-clock time as an epoch (GNU date; empty elsewhere).
clock_reset() {
  local t="$1" tz="$2" e
  # Git Bash on Windows has no zone database and silently reads TZ=Europe/... as UTC; probe first.
  [[ "$(TZ=Asia/Kolkata date +%z 2>/dev/null)" == "+0530" ]] || return 0
  e="$(TZ="$tz" date -d "$t" +%s 2>/dev/null)" || return 0
  [[ "$e" =~ ^[0-9]+$ ]] || return 0
  if (( e <= NOW )); then e="$(TZ="$tz" date -d "tomorrow $t" +%s 2>/dev/null)" || return 0; fi
  [[ "$e" =~ ^[0-9]+$ ]] && printf '%s' "$e"
}

find_reset() {
  local tries="$1" r="" tail_txt="" m
  while :; do
    if [[ -n "$TP" && -f "$TP" ]]; then
      tail_txt="$(tail -n 400 "$TP" 2>/dev/null || true)"
      r="$(printf '%s' "$tail_txt" | grep -o '"rate_limit_info":{"status":"rejected","resetsAt":[0-9]\{10\}' | tail -n 1 | grep -o '[0-9]\{10\}$' || true)"
      [[ -n "$r" ]] || r="$(printf '%s' "$tail_txt" | grep -o '"resetsAt":[0-9]\{10\}' | tail -n 1 | grep -o '[0-9]\{10\}$' || true)"
    fi
    if [[ -z "$r" ]]; then
      m="$ERR_MSG"
      [[ -n "$tail_txt" ]] && m="$m
$(printf '%s' "$tail_txt" | grep -o 'resets [0-9][0-9:]*[ap]m ([A-Za-z_]*/[A-Za-z_]*)' | tail -n 1)"
      if [[ "$m" =~ resets\ ([0-9]{1,2}(:[0-9]{2})?\ ?[ap]m)\ \(([A-Za-z_]+/[A-Za-z_]+)\) ]]; then
        r="$(clock_reset "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}")"
      fi
    fi
    # A reset time already in the past belongs to an earlier hit.
    if [[ "$r" =~ ^[0-9]+$ ]] && (( r <= NOW )); then r=""; fi
    [[ -n "$r" || "$tries" -le 0 ]] && break
    tries=$((tries - 1)); sleep 1   # the transcript is written asynchronously and may lag the hook
  done
  printf '%s' "$r"
}

RESETS="$(find_reset 3)"

MARK_DIR="$COORD/checkpoints"
MARK="$MARK_DIR/.limit-hook-${SID:-nosession}-${RESETS:-$((NOW / 3600))}"
if [[ -f "$MARK" && "$DRY" -eq 0 ]]; then exit 0; fi

GRACE="$(tr -d '\r' < "$REPO_ROOT/.KCC/settings.json" 2>/dev/null | sed -n 's/^ *"resume_grace_seconds": *\([0-9]*\).*/\1/p' | head -n 1)"
GRACE="${GRACE:-120}"
RESUME_AT=null; [[ -n "$RESETS" ]] && RESUME_AT=$((RESETS + GRACE))

if [[ "$DRY" -eq 1 ]]; then
  echo "kcc-limit-hook: session=${SID:-?} transcript=${TP:-none} resets_at=${RESETS:-unknown} resume_at=$RESUME_AT"
  exit 0
fi

mkdir -p "$MARK_DIR" "$COORD/run" 2>/dev/null || true
: > "$MARK" 2>/dev/null || true
printf '{"harness":"claude","source":"stop-failure-hook","at":%s,"resets_at":%s,"resume_at":%s,"resumes":0,"status":"waiting"}\n' "$NOW" "${RESETS:-null}" "$RESUME_AT" > "$COORD/run/limit.json"

# Arm first: it is the part that matters, and the checkpoint below can take many seconds on Windows.
bash "$SCRIPT_DIR/kcc-limit-watch.sh" --arm --harness claude ${SID:+--session-id "$SID"} ${RESETS:+--reset-at "$RESETS"}   ${TP:+--skip-if-active "$TP"} --repo-root "$REPO_ROOT" >/dev/null 2>&1 || true
(
  if [[ -f "$SCRIPT_DIR/backchannel-append.sh" ]]; then
    bash "$SCRIPT_DIR/backchannel-append.sh" --kind limit-reached --from kcc-limit-hook ${SID:+--session "$SID"}       --payload "{\"level\":\"hard\",\"harness\":\"claude\",\"source\":\"stop-failure-hook\",\"resets_at\":${RESETS:-null}}"       --repo-root "$REPO_ROOT" --no-dashboard >/dev/null 2>&1 || true
  fi
  bash "$SCRIPT_DIR/kcc-checkpoint.sh" --reason limit-hard --harness claude ${SID:+--session-id "$SID"} --repo-root "$REPO_ROOT" >/dev/null 2>&1 || true
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
