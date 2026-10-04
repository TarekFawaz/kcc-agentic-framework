#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# Implementation lock: may code be written into src/IDEA-{ID}-*/ yet?
# Mirror of check-impl-lock.ps1. Read-only.
#
# OPEN when, for at least one spec of that idea, plan.md declares a ready status
# (status: ready | | Status | Ready | | **Status:** ready) AND an implement budget
# approval exists: a coordination/backchannel.jsonl line with kind
# estimate-approved | estimate-auto-approved | auto-policy-approved[-bounded|-unlimited]
# mentioning the SPEC-ID or IDEA-ID, or a Traces/Session-*/HumanDecisions.md line
# mentioning the SPEC-ID plus "implement" and "approv".
# Paths outside src/IDEA-*/ are always allowed.
#
# Usage:
#   bash check-impl-lock.sh --path FILE   [--repo-root PATH] [--json]
#   bash check-impl-lock.sh --staged      [--repo-root PATH] [--json]
#   bash check-impl-lock.sh --hook        (Claude Code PreToolUse JSON on stdin;
#                                          locked -> reason on stderr, exit 2)
# Violation: LOCK-001 (fix_owner human).

set -euo pipefail

TOOL_VERSION="1.0.0"
REPO_ROOT=""
PATH_ARG=""
STAGED=0
HOOK=0
SCOPE="all"
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --path) PATH_ARG="${2:-}"; shift 2 ;;
    --staged) STAGED=1; shift ;;
    --hook|-Hook|-hook) HOOK=1; shift ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

usage_fail() { echo "$1" >&2; exit 2; }

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$REPO_ROOT" ]; then
  PARENT="$(dirname "$TOOL_DIR")"
  if [ "$(basename "$PARENT")" = ".KCC" ]; then REPO_ROOT="$(dirname "$PARENT")"; else REPO_ROOT="$PARENT"; fi
fi
if [ ! -d "$REPO_ROOT" ]; then
  if [ "$HOOK" -eq 1 ]; then exit 0; fi
  usage_fail "workspace not found: $REPO_ROOT"
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

ERRORS=0
VJSON=""
HUMAN=""
LOCK_REASON=""

je() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
violation() {
  local id="$1" sev="$2" owner="$3" msg="$4" file="${5:-}" obj
  ERRORS=$((ERRORS + 1))
  obj="{\"id\":\"$(je "$id")\",\"severity\":\"$sev\",\"fix_owner\":\"$(je "$owner")\",\"file\":\"$(je "$file")\",\"message\":\"$(je "$msg")\"}"
  if [ -z "$VJSON" ]; then VJSON="$obj"; else VJSON="$VJSON,$obj"; fi
  HUMAN="$HUMAN[ERROR] $id ($owner) $file: $msg
"
  return 0
}

# Convert Windows / MSYS paths into this shell's form and make them absolute.
to_abs() { # path base-dir
  local p="$1" b="$2" drv rest
  case "$p" in
    [A-Za-z]:[\\/]*)
      if command -v cygpath >/dev/null 2>&1; then p="$(cygpath -u "$p")"
      else drv="$(lower "${p%%:*}")"; rest="${p#?:}"; rest="${rest//\\//}"; p="/$drv$rest"; fi ;;
  esac
  p="${p//\\//}"
  case "$p" in
    /*) ;;
    *)
      case "$b" in
        [A-Za-z]:[\\/]*) if command -v cygpath >/dev/null 2>&1; then b="$(cygpath -u "$b")"; else drv="$(lower "${b%%:*}")"; rest="${b#?:}"; rest="${rest//\\//}"; b="/$drv$rest"; fi ;;
      esac
      p="${b%/}/$p" ;;
  esac
  # collapse . and .. segments
  printf '%s' "$p" | awk -F'/' '{
    n = 0
    for (i = 2; i <= NF; i++) { if ($i == "" || $i == ".") continue; if ($i == "..") { if (n > 0) n--; continue } s[++n] = $i }
    out = ""; for (i = 1; i <= n; i++) out = out "/" s[i]; if (out == "") out = "/"; print out }'
}

# Workspace-relative path, or the marker __OUTSIDE__.
workspace_rel() { # path base-dir
  local full root lf lr
  full="$(to_abs "$1" "$2")"
  root="${REPO_ROOT%/}"
  lf="$(lower "$full")"; lr="$(lower "$root")"
  if [ "$lf" = "$lr" ]; then printf ''; return 0; fi
  case "$lf" in "$lr"/*) printf '%s' "${full:$((${#root} + 1))}"; return 0 ;; esac
  printf '__OUTSIDE__'
}

# Sets LOCK_REASON ('' when open) for one IDEA-ID.
lock_reason() {
  local idea="$1" g d plan any_plan=0 ready="" sid bc hd s lidea
  lidea="$(lower "$idea")"
  if [ -d "$REPO_ROOT/specs" ]; then
    for g in "$REPO_ROOT/specs"/*; do
      [ -d "$g" ] || continue
      case "$(lower "$(basename "$g")")" in
        "$lidea"[0-9]*) continue ;;
        "$lidea"|"$lidea"-*) ;;
        *) continue ;;
      esac
      for d in "$g"/SPEC-*; do
        [ -d "$d" ] || continue
        plan="$d/plan.md"
        [ -f "$plan" ] || continue
        any_plan=1
        if grep -qiE '^[[:space:]|>*-]*\**status\**[^[:alnum:]_]{0,6}ready([^[:alnum:]_]|$)' "$plan"; then
          sid="$(basename "$d" | grep -oE '^SPEC-[0-9]+' || true)"
          if [ -n "$sid" ]; then ready="$ready $sid"; fi
        fi
      done
    done
  fi
  if [ -z "$ready" ]; then
    if [ "$any_plan" -eq 1 ]; then LOCK_REASON="no plan.md of $idea declares status: ready"; else LOCK_REASON="no plan.md exists for any spec of $idea"; fi
    return 0
  fi
  bc=""
  if [ -f "$REPO_ROOT/coordination/backchannel.jsonl" ]; then
    bc="$(tr -d '\r' < "$REPO_ROOT/coordination/backchannel.jsonl" | grep -E '"kind"[[:space:]]*:[[:space:]]*"(estimate-approved|estimate-auto-approved|auto-policy-approved|auto-policy-approved-bounded|auto-policy-approved-unlimited)"' || true)"
  fi
  hd=""
  for s in "$REPO_ROOT/Traces"/Session-*/HumanDecisions.md; do
    [ -f "$s" ] || continue
    hd="$hd$(tr -d '\r' < "$s" | grep -i 'implement' | grep -i 'approv' || true)
"
  done
  for sid in $ready; do
    if [ -n "$bc" ] && printf '%s\n' "$bc" | grep -qE "(^|[^A-Za-z0-9])($sid|$idea)([^0-9]|\$)"; then LOCK_REASON=""; return 0; fi
    if [ -n "$hd" ] && printf '%s\n' "$hd" | grep -qE "(^|[^A-Za-z0-9])$sid([^0-9]|\$)"; then LOCK_REASON=""; return 0; fi
  done
  ready="$(printf '%s' "$ready" | sed 's/^ //; s/ /, /g')"
  LOCK_REASON="plan ready for $ready but no implement budget approval (backchannel estimate-approved / estimate-auto-approved / auto-policy-approved* event, or HumanDecisions.md implement approval) references it or $idea"
  return 0
}

# Returns 0 when allowed, 1 when locked (and records LOCK-001).
check_path() { # path base-dir
  local r idea
  r="$(workspace_rel "$1" "$2")"
  [ "$r" != "__OUTSIDE__" ] || return 0
  idea="$(printf '%s' "$r" | grep -ioE '^src/IDEA-[0-9]+(-[^/]*)?/' | head -n 1 | sed -E 's#^src/##; s#^([A-Za-z]+-[0-9]+).*$#\1#' || true)"
  [ -n "$idea" ] || return 0
  idea="$(upper "$idea")"
  lock_reason "$idea"
  [ -n "$LOCK_REASON" ] || return 0
  violation "LOCK-001" "error" "human" "Implementation is locked for $r: $LOCK_REASON. Finish /spec-plan (plan.md status: ready) and approve the implement budget first." "$r"
  return 1
}

# Extract a top-level-ish JSON string value by key from flattened JSON.
json_str() { # json key
  printf '%s' "$1" | awk -v k="$2" '{
    re = "\"" k "\"[ \t]*:[ \t]*\"([^\"\\\\]|\\\\.)*\""
    if (match($0, re)) {
      v = substr($0, RSTART, RLENGTH); sub(/^"[^"]*"[ \t]*:[ \t]*"/, "", v); sub(/"$/, "", v)
      out = ""; n = length(v)
      for (i = 1; i <= n; i++) {
        ch = substr(v, i, 1)
        if (ch == "\\" && i < n) { i++; nx = substr(v, i, 1); if (nx == "n") out = out "\n"; else if (nx == "t") out = out "\t"; else out = out nx }
        else out = out ch
      }
      print out
    }
  }'
}

BASE_DIR="$REPO_ROOT"
if [ "$HOOK" -eq 1 ]; then
  RAW="$(cat | tr '\r\n' '  ' || true)"
  FP="$(json_str "$RAW" file_path || true)"
  if [ -z "$FP" ]; then FP="$(json_str "$RAW" notebook_path || true)"; fi
  [ -n "$FP" ] || exit 0
  CWD="$(json_str "$RAW" cwd || true)"
  if [ -n "$CWD" ]; then BASE_DIR="$CWD"; fi
  if check_path "$FP" "$BASE_DIR"; then exit 0; fi
  echo "KCC implementation lock (LOCK-001): writing $FP is blocked - $LOCK_REASON. Run /spec-plan until plan.md has status: ready and get the implement budget approved (token-estimate), then retry." >&2
  exit 2
fi

TARGETS=""
if [ "$STAGED" -eq 1 ]; then
  TARGETS="$(git -C "$REPO_ROOT" -c core.quotepath=off diff --cached --name-only --relative 2>/dev/null)" || usage_fail "not a git repository (or git failed); --staged needs git."
elif [ -n "$PATH_ARG" ]; then
  TARGETS="$PATH_ARG"
else
  usage_fail "usage: check-impl-lock (--path <file> | --staged | --hook) [--repo-root <path>] [--json]"
fi

CHECKED=0
while IFS= read -r t; do
  [ -n "$t" ] || continue
  CHECKED=$((CHECKED + 1))
  check_path "$t" "$BASE_DIR" || true
done <<EOF
$TARGETS
EOF

STATUS="pass"
if [ "$ERRORS" -gt 0 ]; then STATUS="fail"; fi
if [ "$JSON" -eq 1 ]; then
  printf '{"tool":"check-impl-lock","version":"%s","scope":"%s","checked":%d,"errors":%d,"warnings":0,"status":"%s","violations":[%s]}\n' \
    "$TOOL_VERSION" "$(je "$SCOPE")" "$CHECKED" "$ERRORS" "$STATUS" "$VJSON"
else
  echo "KCC implementation lock: $CHECKED path(s) checked"
  printf '%s' "$HUMAN"
  echo "Errors: $ERRORS  Warnings: 0"
fi
if [ "$ERRORS" -gt 0 ]; then exit 1; fi
exit 0
