#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# check-branch.sh - validate a branch name, or a push target, against the KCC
# git workflow. Mirror of check-branch.ps1. Read-only.
# Protocol: .KCC/kernel/protocols/git-workflow.md
# Contract: .KCC/kernel/contracts/tool-contract.md
#
# Settings (.KCC/settings.json -> git; built-in defaults when absent):
#   model              trunk | off            (off = no branch / push checks)
#   protected_branches ["main"]               (* is a wildcard; [] = none)
#   branch_patterns    spec/SPEC-{ID}, lane/SPEC-{ID}-w{N},
#                      bug/SPEC-{ID}-Bug-{NNN}, chore/{slug}
#
# Usage:
#   bash check-branch.sh [--branch NAME] [--repo-root PATH] [--json]
#   bash check-branch.sh --push [--remote-ref REF] [--repo-root PATH] [--json]
#
# --push without --remote-ref reads the git pre-push lines on stdin
# (<local ref> <local sha> <remote ref> <remote sha>); with a terminal on
# stdin it checks a push of the current branch.
#
# Violations: BRANCH-001 name matches no allowed pattern | BRANCH-002 on a
#   protected branch (warning) | BRANCH-003 push targets a protected branch |
#   BRANCH-004 push creates the protected branch on the remote (warning) |
#   BRANCH-005 detached HEAD (warning)
# Exit: 0 pass | 1 violations | 2 usage/environment
set -euo pipefail

TOOL_VERSION="1.0.0"
REPO_ROOT=""
BRANCH=""
PUSH=0
REMOTE_REF=""
SCOPE=""
JSON=0

usage_fail() { echo "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root|-RepoRoot) [ $# -ge 2 ] || usage_fail "--repo-root needs a value"; REPO_ROOT="$2"; shift 2 ;;
    --branch|-Branch) [ $# -ge 2 ] || usage_fail "--branch needs a value"; BRANCH="$2"; shift 2 ;;
    --push|-Push) PUSH=1; shift ;;
    --remote-ref|-RemoteRef) [ $# -ge 2 ] || usage_fail "--remote-ref needs a value"; REMOTE_REF="$2"; shift 2 ;;
    --scope|-Scope) [ $# -ge 2 ] || usage_fail "--scope needs a value"; SCOPE="$2"; shift 2 ;;
    --json|-Json) JSON=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) usage_fail "unknown arg: $1" ;;
  esac
done

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$REPO_ROOT" ]; then
  PARENT="$(dirname "$TOOL_DIR")"
  if [ "$(basename "$PARENT")" = ".KCC" ]; then REPO_ROOT="$(dirname "$PARENT")"; else REPO_ROOT="$PARENT"; fi
fi
[ -d "$REPO_ROOT" ] || usage_fail "workspace not found: $REPO_ROOT"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
if [ -n "$REMOTE_REF" ] && [ "$PUSH" -eq 0 ]; then usage_fail "--remote-ref is only valid with --push"; fi
if [ -z "$SCOPE" ]; then if [ "$PUSH" -eq 1 ]; then SCOPE="push"; else SCOPE="name"; fi; fi

ERRORS=0
WARNINGS=0
CHECKED=0
VJSON=""
HUMAN=""

je() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
violation() { # id severity owner message [file]
  local id="$1" sev="$2" owner="$3" msg="$4" file="${5:-}" obj label
  if [ "$sev" = "error" ]; then ERRORS=$((ERRORS + 1)); label="ERROR"; else WARNINGS=$((WARNINGS + 1)); label="WARNING"; fi
  obj="{\"id\":\"$(je "$id")\",\"severity\":\"$sev\",\"fix_owner\":\"$(je "$owner")\",\"file\":\"$(je "$file")\",\"message\":\"$(je "$msg")\"}"
  if [ -z "$VJSON" ]; then VJSON="$obj"; else VJSON="$VJSON,$obj"; fi
  HUMAN="$HUMAN[$label] $id ($owner) $file: $msg
"
  return 0
}

# ---------------------------------------------------------------- settings (no jq)
AWK_FLAT='
function skip() { while (pos <= n && index(" \t\r\n", substr(s, pos, 1)) > 0) pos++ }
function rstr(   c, nx, out) {
  pos++; out = ""
  while (pos <= n) {
    c = substr(s, pos, 1)
    if (c == "\\") {
      nx = substr(s, pos + 1, 1)
      if (nx == "n") out = out " "; else if (nx == "t") out = out " "; else if (nx == "r") out = out ""
      else if (nx == "u") { out = out "?"; pos += 4 } else out = out nx
      pos += 2; continue
    }
    if (c == "\"") { pos++; return out }
    out = out c; pos++
  }
  return out
}
function val(path,   c, k, i, st, tok) {
  skip(); if (pos > n) return
  c = substr(s, pos, 1)
  if (c == "{") {
    pos++; skip()
    if (substr(s, pos, 1) == "}") { pos++; return }
    while (pos <= n) {
      skip(); k = rstr(); skip(); pos++
      val((path == "" ? k : path "." k))
      skip(); c = substr(s, pos, 1); pos++
      if (c != ",") return
    }
    return
  }
  if (c == "[") {
    pos++; skip()
    if (substr(s, pos, 1) == "]") { pos++; return }
    i = 0
    while (pos <= n) {
      val(path "[" i "]"); i++
      skip(); c = substr(s, pos, 1); pos++
      if (c != ",") return
    }
    return
  }
  if (c == "\"") { tok = rstr(); print path "\t" tok; return }
  st = pos
  while (pos <= n && index(",}] \t\r\n", substr(s, pos, 1)) == 0) pos++
  tok = substr(s, st, pos - st); print path "\t" tok
}
{ s = s $0 "\n" }
END { n = length(s); pos = 1; val("") }
'
json_flatten_file() { if [ -f "$1" ]; then awk "$AWK_FLAT" "$1" 2>/dev/null || true; fi; }
flat_get() { # flat-text key
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { v = $2 } END { if (v != "" && v != "null") print v }'
}
flat_values() { # flat-text key-prefix -> one value per line
  printf '%s\n' "$1" | awk -F'\t' -v p="$2" 'index($1, p) == 1 && $2 != "" && $2 != "null" { print $2 }'
}

SETTINGS_FILE="$REPO_ROOT/.KCC/settings.json"
SETTINGS_FLAT="$(json_flatten_file "$SETTINGS_FILE")"
MODEL="$(flat_get "$SETTINGS_FLAT" git.model | tr 'A-Z' 'a-z')"
[ -n "$MODEL" ] || MODEL="trunk"
case "$MODEL" in trunk|off) ;; *) usage_fail "settings.json git.model must be trunk or off (found '$MODEL')" ;; esac

PATTERNS="$(flat_values "$SETTINGS_FLAT" "git.branch_patterns.")"
if [ -z "$PATTERNS" ]; then
  PATTERNS='spec/SPEC-{ID}
lane/SPEC-{ID}-w{N}
bug/SPEC-{ID}-Bug-{NNN}
chore/{slug}'
fi
PROTECTED="$(flat_values "$SETTINGS_FLAT" "git.protected_branches[")"
if [ -z "$PROTECTED" ]; then
  # An explicit empty array means "no protected branches"; an absent key means the default.
  if [ -f "$SETTINGS_FILE" ] && tr -d ' \t\r\n' < "$SETTINGS_FILE" | grep -q '"protected_branches":\[\]'; then PROTECTED=""; else PROTECTED="main"; fi
fi

# Template -> anchored ERE. {ID} {N} {NNN} = digits, {slug} = name, * = anything.
tmpl_to_re() {
  printf '%s' "$1" | sed \
    -e 's/{ID}/%%D%%/g' -e 's/{NNN}/%%D%%/g' -e 's/{N}/%%D%%/g' -e 's/{slug}/%%S%%/g' -e 's/\*/%%A%%/g' \
    -e 's/[][\.^$+?(){}|]/\\&/g' \
    -e 's/%%D%%/[0-9]+/g' -e 's#%%S%%#[A-Za-z0-9][A-Za-z0-9._/-]*#g' -e 's/%%A%%/.*/g'
}
matches_any() { # name template-list
  local name="$1" t re
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    re="^($(tmpl_to_re "$t"))\$"
    if [[ "$name" =~ $re ]]; then return 0; fi
  done <<EOF
$2
EOF
  return 1
}
is_protected() { [ -n "$PROTECTED" ] && matches_any "$1" "$PROTECTED"; }
allowed_list() { printf '%s' "$PATTERNS" | tr '\n' ',' | sed 's/,$//; s/,/, /g'; }
is_zero_sha() { [[ "$1" =~ ^0+$ ]]; }

check_name() { # branch
  local b="$1"
  CHECKED=$((CHECKED + 1))
  if is_protected "$b"; then
    violation "BRANCH-002" "warning" "repo-steward" "'$b' is a protected branch; commit on a work branch and merge by pull request" "$b"
    return 0
  fi
  if ! matches_any "$b" "$PATTERNS"; then
    violation "BRANCH-001" "error" "repo-steward" "branch '$b' matches no allowed pattern ($(allowed_list))" "$b"
  fi
  return 0
}

check_push_ref() { # local-sha remote-ref remote-sha
  local lsha="$1" rref="$2" rsha="$3" b
  case "$rref" in refs/heads/*) b="${rref#refs/heads/}" ;; refs/*) return 0 ;; *) b="$rref" ;; esac
  CHECKED=$((CHECKED + 1))
  if is_protected "$b"; then
    if is_zero_sha "$lsha"; then
      violation "BRANCH-003" "error" "human" "push deletes protected branch '$b'; this is never done from a KCC workspace" "$b"
    elif is_zero_sha "$rsha"; then
      violation "BRANCH-004" "warning" "human" "push creates protected branch '$b' on the remote (initial publish); later changes reach it by pull request only" "$b"
    else
      violation "BRANCH-003" "error" "human" "push targets protected branch '$b' directly; push a work branch and open a pull request" "$b"
    fi
    return 0
  fi
  if is_zero_sha "$lsha"; then return 0; fi
  if ! matches_any "$b" "$PATTERNS"; then
    violation "BRANCH-001" "error" "repo-steward" "branch '$b' matches no allowed pattern ($(allowed_list))" "$b"
  fi
  return 0
}

current_branch() { git -C "$REPO_ROOT" symbolic-ref --short -q HEAD 2>/dev/null || true; }

if [ "$MODEL" = "off" ]; then
  :
elif [ "$PUSH" -eq 1 ]; then
  if [ -n "$REMOTE_REF" ]; then
    check_push_ref "1" "$REMOTE_REF" "1"
  elif [ -t 0 ]; then
    BRANCH="${BRANCH:-$(current_branch)}"
    if [ -n "$BRANCH" ]; then check_push_ref "1" "refs/heads/$BRANCH" "1"
    else violation "BRANCH-005" "warning" "human" "detached HEAD; no branch to check" ""; fi
  else
    while IFS=' ' read -r lref lsha rref rsha || [ -n "${lref:-}" ]; do
      rsha="${rsha%$'\r'}"
      [ -n "${rref:-}" ] || continue
      check_push_ref "$lsha" "$rref" "$rsha"
    done
  fi
else
  if [ -z "$BRANCH" ]; then
    command -v git >/dev/null 2>&1 || usage_fail "git not found; pass --branch <name>"
    git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || usage_fail "not a git repository; pass --branch <name>"
    BRANCH="$(current_branch)"
  fi
  if [ -n "$BRANCH" ]; then check_name "$BRANCH"
  else violation "BRANCH-005" "warning" "human" "detached HEAD; no branch to check" ""; fi
fi

STATUS="pass"
if [ "$ERRORS" -gt 0 ]; then STATUS="fail"; fi
if [ "$JSON" -eq 1 ]; then
  printf '{"tool":"check-branch","version":"%s","scope":"%s","model":"%s","branch":"%s","checked":%d,"errors":%d,"warnings":%d,"status":"%s","violations":[%s]}\n' \
    "$TOOL_VERSION" "$(je "$SCOPE")" "$MODEL" "$(je "$BRANCH")" "$CHECKED" "$ERRORS" "$WARNINGS" "$STATUS" "$VJSON"
else
  echo "KCC branch check ($SCOPE, model $MODEL): $CHECKED ref(s) checked"
  printf '%s' "$HUMAN"
  echo "Errors: $ERRORS  Warnings: $WARNINGS"
fi
if [ "$ERRORS" -gt 0 ]; then exit 1; fi
exit 0
