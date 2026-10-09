#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# kcc-hint.sh - give a running KCC session a hint about behaviour or expectations
# (hint protocol: .KCC/kernel/protocols/hints.md).
#
# A hint is one short note from the human. It is stored in coordination/hints/hints.tsv and
# delivered to the main agent and to running subagents on their next tool call, prompt, or
# start, so it works while a session is busy. Hints never waive a gate or a safety rule.
#
# Usage:
#   kcc-hint.sh add "<text>" [--to all|main|subagents|<agent-type>] [--expires-minutes N]
#                            [--by NAME] [--spec ID]
#   kcc-hint.sh list [--json]
#   kcc-hint.sh clear <H-NNN|all>
#   kcc-hint.sh pending [--for main|<agent-type>] [--all]   hints this reader has not seen yet
#                                                           (harnesses without hooks: Codex, OpenCode)
#   kcc-hint.sh inject [--event <name>]                     hook mode: stdin = hook JSON,
#                                                           stdout = hookSpecificOutput JSON
# Common: [--repo-root PATH]
#
# Store: one line per hint, tab separated:
#   id  to  expires_epoch(0=never)  created_epoch  by  text(JSON-escaped, no raw tabs/newlines)
# Delivered ids per reader: coordination/hints/seen/<reader>. Cleared hints move to
# coordination/hints/archive.tsv. Hook mode is the hot path: with no hints it reads stdin and exits.
# Requires bash 3.2+, grep, sed, awk. No python/jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CMD="${1:-}"
[[ $# -gt 0 ]] && shift

TO="all"; EXPIRES_MIN=0; BY="human"; SPEC=""; JSON=0; FOR="main"; ALL=0; EVENT=""
POS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to|-To) TO="${2:-all}"; shift 2 ;;
    --expires-minutes|-ExpiresMinutes) EXPIRES_MIN="${2:-0}"; shift 2 ;;
    --by|-By) BY="${2:-human}"; shift 2 ;;
    --spec|-Spec) SPEC="${2:-}"; shift 2 ;;
    --json|-Json) JSON=1; shift ;;
    --for|-For) FOR="${2:-main}"; shift 2 ;;
    --all|-All) ALL=1; shift ;;
    --event|-Event) EVENT="${2:-}"; shift 2 ;;
    --repo-root|-RepoRoot) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^# Requires/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) POS+=("$1"); shift ;;
  esac
done

DIR="$REPO_ROOT/coordination/hints"
HINTS="$DIR/hints.tsv"
ARCHIVE="$DIR/archive.tsv"
SEEN="$DIR/seen"
TAB=$'\t'

die() { echo "kcc-hint: $1" >&2; exit 2; }
now() { date +%s; }
lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
unescape() { awk '{ s = $0; gsub(/\\\\/, "\001", s); gsub(/\\n/, "\n", s); gsub(/\\"/, "\"", s); n = split(s, p, "\001"); s = p[1]; for (i = 2; i <= n; i++) s = s "\\" p[i]; print s }'; }
emit_event() { # kind payload-json
  [[ -f "$SCRIPT_DIR/backchannel-append.sh" ]] || return 0
  bash "$SCRIPT_DIR/backchannel-append.sh" --kind "$1" --from kcc-hint --to broadcast ${SPEC:+--spec "$SPEC"} \
    --payload "$2" --repo-root "$REPO_ROOT" --no-dashboard >/dev/null 2>&1 || true
}

applies() { # hint-to reader-kind(main|sub) reader-type
  case "$1" in
    all) return 0 ;;
    main) [[ "$2" == main ]] ;;
    subagents) [[ "$2" == sub ]] ;;
    *) [[ "$2" == sub && "$(lc "$1")" == "$(lc "$3")" ]] ;;
  esac
}

# Prints "id<TAB>to<TAB>text" for each active hint that applies to the reader and is not yet seen
# (or every applicable one with $4 = all). Active = not expired.
select_hints() { # kind type seen-file all(0|1)
  [[ -s "$HINTS" ]] || return 0
  local t id to exp created by text; t="$(now)"
  while IFS="$TAB" read -r id to exp created by text || [[ -n "${id:-}" ]]; do
    [[ -n "$id" ]] || continue
    if [[ "$exp" =~ ^[0-9]+$ && "$exp" -gt 0 && "$exp" -le "$t" ]]; then continue; fi
    applies "$to" "$1" "$2" || continue
    if [[ "$4" != "1" && -f "$3" ]] && grep -qx "$id" "$3" 2>/dev/null; then continue; fi
    printf '%s\t%s\t%s\n' "$id" "$to" "$text"
  done < "$HINTS"
}

case "$CMD" in
  add)
    text="${POS[*]:-}"
    [[ -n "${text//[[:space:]]/}" ]] || die 'usage: kcc-hint add "<text>" [--to all|main|subagents|<agent-type>]'
    [[ "$TO" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || die "--to expects all, main, subagents, or an agent name (got '$TO')"
    [[ "$EXPIRES_MIN" =~ ^[0-9]+$ ]] || die "--expires-minutes expects a whole number"
    if [[ "${#text}" -gt 1200 ]]; then die "a hint is at most 1200 characters; put long guidance in a file and hint its path"; fi
    esc="$(printf '%s' "$text" | tr '\t\r' '  ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{ printf "%s%s", (NR>1 ? "\\n" : ""), $0 }')"
    BY="$(printf '%s' "$BY" | tr -d '\t\r\n')"
    mkdir -p "$DIR" "$SEEN"
    n=0; [[ -f "$DIR/.seq" ]] && n="$(tr -dc '0-9' < "$DIR/.seq")"; n=$((10#${n:-0} + 1))
    printf '%s' "$n" > "$DIR/.seq"
    printf -v id 'H-%03d' "$n"
    created="$(now)"; exp=0; [[ "$EXPIRES_MIN" -gt 0 ]] && exp=$((created + EXPIRES_MIN * 60))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(lc "$TO")" "$exp" "$created" "$BY" "$esc" >> "$HINTS"
    emit_event hint-issued "{\"hint\":\"$id\",\"to\":\"$(lc "$TO")\",\"by\":\"$BY\",\"expires_at\":$exp}"
    echo "kcc-hint: $id recorded for $(lc "$TO"). The main agent and running subagents get it on their next tool call, prompt, or start."
    ;;
  list)
    t="$(now)"
    if [[ ! -s "$HINTS" ]]; then [[ "$JSON" -eq 1 ]] && echo '[]' || echo "No active hints."; exit 0; fi
    first=1; [[ "$JSON" -eq 1 ]] && printf '['
    while IFS="$TAB" read -r id to exp created by text || [[ -n "${id:-}" ]]; do
      [[ -n "$id" ]] || continue
      if [[ "$exp" =~ ^[0-9]+$ && "$exp" -gt 0 && "$exp" -le "$t" ]]; then continue; fi
      if [[ "$JSON" -eq 1 ]]; then
        [[ "$first" -eq 1 ]] || printf ','
        first=0
        printf '{"id":"%s","to":"%s","expires_at":%s,"created":%s,"by":"%s","text":"%s"}' "$id" "$to" "$exp" "$created" "$by" "$text"
      else
        first=0
        printf '%s  [%s]  %s\n' "$id" "$to" "$(printf '%s' "$text" | unescape)"
      fi
    done < "$HINTS"
    if [[ "$JSON" -eq 1 ]]; then echo ']'; elif [[ "$first" -eq 1 ]]; then echo "No active hints."; fi
    ;;
  clear)
    target="${POS[0]:-}"
    [[ -n "$target" ]] || die "usage: kcc-hint clear <H-NNN|all>"
    [[ -s "$HINTS" ]] || { echo "kcc-hint: nothing to clear."; exit 0; }
    target="$(printf '%s' "$target" | tr 'a-z' 'A-Z')"; [[ "$target" == "ALL" ]] && target="all"
    keep="$HINTS.keep.$$"; : > "$keep"; cleared=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      id="${line%%$TAB*}"
      if [[ "$target" == "all" || "$id" == "$target" ]]; then
        printf '%s\t%s\n' "$line" "$(now)" >> "$ARCHIVE"; cleared=$((cleared + 1))
        emit_event hint-cleared "{\"hint\":\"$id\"}"
      else printf '%s\n' "$line" >> "$keep"; fi
    done < "$HINTS"
    mv -f "$keep" "$HINTS"
    [[ "$cleared" -gt 0 ]] || { echo "kcc-hint: no active hint '$target'." >&2; exit 1; }
    echo "kcc-hint: cleared $cleared hint(s)."
    ;;
  pending)
    kind=sub; [[ "$(lc "$FOR")" == "main" ]] && kind=main
    mkdir -p "$SEEN" 2>/dev/null || true
    seen="$SEEN/cli-$(printf '%s' "$FOR" | tr -c 'A-Za-z0-9_-' '_')"
    out="$(select_hints "$kind" "$FOR" "$seen" "$ALL")"
    [[ -n "$out" ]] || exit 0
    echo "Human hints (follow them as refinements of behaviour and expectations; they never waive a gate or a safety rule):"
    while IFS="$TAB" read -r id to text; do
      printf -- '- %s [to: %s]: %s\n' "$id" "$to" "$(printf '%s' "$text" | unescape)"
      [[ "$ALL" -eq 1 ]] || printf '%s\n' "$id" >> "$seen"
    done <<< "$out"
    ;;
  inject)
    INPUT="$(cat || true)"
    [[ -s "$HINTS" ]] || exit 0
    jfield() { printf '%s' "$INPUT" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | sed -E 's/^[^:]*:[[:space:]]*"(.*)"$/\1/' || true; }
    ev="${EVENT:-$(jfield hook_event_name)}"; ev="${ev:-PreToolUse}"
    sid="$(jfield session_id)"; aid="$(jfield agent_id)"; atype="$(jfield agent_type)"
    if [[ -n "$aid" ]]; then kind=sub; key="$aid"; else kind=main; key="main-${sid:-session}"; atype="main"; fi
    key="$(printf '%s' "$key" | tr -c 'A-Za-z0-9_-' '_')"
    mkdir -p "$SEEN" 2>/dev/null || true
    seen="$SEEN/$key"
    all=0
    # A fresh or rebuilt context (start, resume, clear, compact) gets every active hint again.
    if [[ "$ev" == "SessionStart" ]]; then all=1; fi
    out="$(select_hints "$kind" "$atype" "$seen" "$all")"
    [[ -n "$out" ]] || exit 0
    ctx="KCC human hints. The human gave these with 'kcc hint'. Follow them as refinements of behaviour and expectations; they never waive a gate, a safety rule, or an earlier explicit instruction."
    ids=""; relay=0
    while IFS="$TAB" read -r id to text; do
      ctx="$ctx\\n- $id [to: $to]: $text"
      ids="$ids $id"
      [[ "$kind" == "main" && "$to" != "main" ]] && relay=1
    done <<< "$out"
    if [[ "$relay" -eq 1 ]]; then
      ctx="$ctx\\nSubagents see a hint on their own next tool call. If any subagent you started is still running, relay the hint to it with SendMessage now, and put every active hint in the handover packet of each subagent you start later."
    fi
    if [[ "$all" -eq 1 ]]; then : > "$seen"; fi
    for id in $ids; do printf '%s\n' "$id" >> "$seen"; done
    emit_event hint-delivered "{\"hints\":\"${ids# }\",\"reader\":\"$kind\",\"agent_type\":\"$atype\",\"event\":\"$ev\"}"
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"},"systemMessage":"KCC hint delivered to %s:%s"}\n' "$ev" "$ctx" "${atype:-agent}" "$ids"
    ;;
  ""|help) sed -n '/^# Usage:/,/^# Requires/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; [[ -z "$CMD" ]] && exit 2 || exit 0 ;;
  *) die "unknown command '$CMD' (add, list, clear, pending, inject)" ;;
esac
