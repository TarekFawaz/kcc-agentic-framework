#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# check-commit-msg.sh - validate a commit message against the KCC convention.
# Mirror of check-commit-msg.ps1. Read-only.
# Protocol: .KCC/kernel/protocols/git-workflow.md
# Contract: .KCC/kernel/contracts/tool-contract.md
#
# Accepted subject lines (first non-empty, non-comment line):
#   SPEC-NNN (Story|Enabler|Bug)-NNN[ T-NNN]: subject
#   SPEC-NNN: subject
#   (chore|docs|ci|build|test|refactor|fix|feat)[(scope)][!]: subject
#   Merge ... | Revert ... | fixup! ... | squash! ... | amend! ...   (pass)
# settings.json git.commit_pattern (POSIX ERE), when set, replaces the three
# built-in formats. When a SPEC / item id is given and specs/ exists, the spec
# folder and the Backlog item must exist.
#
# Usage:
#   bash check-commit-msg.sh --file PATH      [--repo-root PATH] [--json]
#   bash check-commit-msg.sh --message TEXT   [--repo-root PATH] [--json]
#
# Violations: COMMIT-MSG-001 empty | 002 format | 003 unknown spec |
#             004 unknown backlog item | 005 specs/ absent (warning) |
#             006 subject longer than 72 characters (warning)
# Exit: 0 pass | 1 violations | 2 usage/environment
set -euo pipefail

TOOL_VERSION="1.0.0"
REPO_ROOT=""
MSG_FILE=""
MESSAGE=""
HAVE_MESSAGE=0
SCOPE="message"
JSON=0

usage_fail() { echo "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root|-RepoRoot) [ $# -ge 2 ] || usage_fail "--repo-root needs a value"; REPO_ROOT="$2"; shift 2 ;;
    --file|-File) [ $# -ge 2 ] || usage_fail "--file needs a value"; MSG_FILE="$2"; shift 2 ;;
    --message|-Message) [ $# -ge 2 ] || usage_fail "--message needs a value"; MESSAGE="$2"; HAVE_MESSAGE=1; shift 2 ;;
    --scope|-Scope) [ $# -ge 2 ] || usage_fail "--scope needs a value"; SCOPE="$2"; shift 2 ;;
    --json|-Json) JSON=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
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

if [ -n "$MSG_FILE" ] && [ "$HAVE_MESSAGE" -eq 1 ]; then usage_fail "use --file or --message, not both"; fi
if [ -z "$MSG_FILE" ] && [ "$HAVE_MESSAGE" -eq 0 ]; then
  usage_fail "usage: check-commit-msg (--file <path> | --message <text>) [--repo-root <path>] [--json]"
fi
if [ -n "$MSG_FILE" ]; then
  [ -f "$MSG_FILE" ] || usage_fail "message file not found: $MSG_FILE"
  MESSAGE="$(cat "$MSG_FILE")"
fi

ERRORS=0
WARNINGS=0
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
SETTINGS_FLAT="$(json_flatten_file "$REPO_ROOT/.KCC/settings.json")"
CUSTOM_PATTERN="$(flat_get "$SETTINGS_FLAT" git.commit_pattern)"

# ---------------------------------------------------------------- subject
SUBJECT="$(printf '%s\n' "$MESSAGE" | tr -d '\r' | awk '/^[ \t]*$/ { next } /^#/ { next } { print; exit }')"

RE_ITEM='^SPEC-[0-9]+ (Story|Enabler|Bug)-[0-9]+( T-[0-9]+)?: [^[:space:]]'
RE_SPEC='^SPEC-[0-9]+: [^[:space:]]'
RE_MAINT='^(chore|docs|ci|build|test|refactor|fix|feat)(\([A-Za-z0-9._/-]+\))?!?: [^[:space:]]'
RE_PASS='^(Merge |Revert |fixup! |squash! |amend! )'
RE_IDS='^(SPEC-[0-9]+)( (Story|Enabler|Bug)-([0-9]+))?'
CONVENTION="'SPEC-NNN (Story|Enabler|Bug)-NNN: subject', 'SPEC-NNN: subject', or '(chore|docs|ci|build|test|refactor|fix|feat)(scope)?: subject'"

find_spec_dir() { # SPEC-NNN -> absolute dir or ''
  local id="$1" d
  for d in "$REPO_ROOT/specs"/*/"$id" "$REPO_ROOT/specs"/*/"$id"-* "$REPO_ROOT/specs/$id" "$REPO_ROOT/specs/$id"-*; do
    if [ -d "$d" ]; then printf '%s' "$d"; return 0; fi
  done
  return 0
}
has_item() { # spec-dir kind number
  local f
  for f in "$1/Backlog/$2-$3.md" "$1/Backlog/$2-$3"-*.md; do
    if [ -f "$f" ]; then return 0; fi
  done
  return 1
}

check_ids() {
  local spec kind num dir rel
  [[ "$SUBJECT" =~ $RE_IDS ]] || return 0
  spec="${BASH_REMATCH[1]}"; kind="${BASH_REMATCH[3]:-}"; num="${BASH_REMATCH[4]:-}"
  if [ ! -d "$REPO_ROOT/specs" ]; then
    violation "COMMIT-MSG-005" "warning" "human" "specs/ folder not found; $spec could not be verified" ""
    return 0
  fi
  dir="$(find_spec_dir "$spec")"
  if [ -z "$dir" ]; then
    violation "COMMIT-MSG-003" "error" "implementer" "$spec has no spec folder under specs/ (expected specs/IDEA-*-Specs/$spec-*/)" "specs/"
    return 0
  fi
  if [ -n "$kind" ] && ! has_item "$dir" "$kind" "$num"; then
    rel="${dir#"$REPO_ROOT"/}"
    violation "COMMIT-MSG-004" "error" "implementer" "$kind-$num is not a backlog item of $spec (expected $rel/Backlog/$kind-$num-*.md)" "$rel/Backlog"
  fi
  return 0
}

if [ -z "$SUBJECT" ]; then
  violation "COMMIT-MSG-001" "error" "implementer" "commit message is empty" ""
elif [[ "$SUBJECT" =~ $RE_PASS ]]; then
  :
else
  FORMAT_OK=0
  if [ -n "$CUSTOM_PATTERN" ]; then
    rc=0
    printf '%s\n' "$SUBJECT" | grep -Eq -- "$CUSTOM_PATTERN" 2>/dev/null || rc=$?
    if [ "$rc" -ge 2 ]; then usage_fail "settings.json git.commit_pattern is not a valid POSIX ERE: $CUSTOM_PATTERN"; fi
    if [ "$rc" -eq 0 ]; then FORMAT_OK=1; fi
    if [ "$FORMAT_OK" -eq 0 ]; then
      violation "COMMIT-MSG-002" "error" "implementer" "subject '$SUBJECT' does not match settings.json git.commit_pattern: $CUSTOM_PATTERN" ""
    fi
  else
    if [[ "$SUBJECT" =~ $RE_ITEM ]] || [[ "$SUBJECT" =~ $RE_SPEC ]] || [[ "$SUBJECT" =~ $RE_MAINT ]]; then FORMAT_OK=1; fi
    if [ "$FORMAT_OK" -eq 0 ]; then
      violation "COMMIT-MSG-002" "error" "implementer" "subject '$SUBJECT' does not follow the convention: $CONVENTION" ""
    fi
  fi
  if [ "$FORMAT_OK" -eq 1 ]; then
    check_ids
    if [ "${#SUBJECT}" -gt 72 ]; then
      violation "COMMIT-MSG-006" "warning" "implementer" "subject is ${#SUBJECT} characters; keep it at 72 or fewer" ""
    fi
  fi
fi

STATUS="pass"
if [ "$ERRORS" -gt 0 ]; then STATUS="fail"; fi
if [ "$JSON" -eq 1 ]; then
  printf '{"tool":"check-commit-msg","version":"%s","scope":"%s","subject":"%s","errors":%d,"warnings":%d,"status":"%s","violations":[%s]}\n' \
    "$TOOL_VERSION" "$(je "$SCOPE")" "$(je "$SUBJECT")" "$ERRORS" "$WARNINGS" "$STATUS" "$VJSON"
else
  echo "KCC commit message: $SUBJECT"
  printf '%s' "$HUMAN"
  echo "Errors: $ERRORS  Warnings: $WARNINGS"
fi
if [ "$ERRORS" -gt 0 ]; then exit 1; fi
exit 0
