#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 native bash backchannel viewer for macOS/Linux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAST=20
FROM=""
KIND=""
SPEC=""
JSON=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --last|-Last)
      LAST="$2"; shift 2 ;;
    --from|-From)
      FROM="$2"; shift 2 ;;
    --kind|-Kind)
      KIND="$2"; shift 2 ;;
    --spec|-Spec)
      SPEC="$2"; shift 2 ;;
    --repo-root|-RepoRoot)
      REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --json|-Json)
      JSON=1; shift ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

LOG="$REPO_ROOT/coordination/backchannel.jsonl"
if [[ ! -f "$LOG" ]]; then
  echo "No backchannel log found at $LOG"
  exit 0
fi

extract_json_field() {
  local line="$1"
  local keys="$2"
  local key
  IFS='|' read -r -a key_list <<< "$keys"
  for key in "${key_list[@]}"; do
    local value
    value="$(printf '%s\n' "$line" | sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" | head -n 1)"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done
  printf ''
}

matches=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "${line//[[:space:]]/}" ]] && continue
  [[ -n "$FROM" && "$line" != *"\"agent\":\"$FROM\""* && "$line" != *"\"from\":\"$FROM\""* && "$line" != *"\"source\":\"$FROM\""* ]] && continue
  [[ -n "$KIND" && "$line" != *"\"kind\":\"$KIND\""* && "$line" != *"\"event_kind\":\"$KIND\""* && "$line" != *"\"event\":\"$KIND\""* ]] && continue
  [[ -n "$SPEC" && "$line" != *"$SPEC"* ]] && continue
  matches+=("$line")
done < "$LOG"

count="${#matches[@]}"
if (( count == 0 )); then
  echo "No matching backchannel events."
  exit 0
fi

start=0
if (( count > LAST )); then
  start=$((count - LAST))
fi

if (( JSON == 1 )); then
  for ((i=start; i<count; i++)); do
    printf '%s\n' "${matches[$i]}"
  done
  exit 0
fi

printf '%-24s  %-18s  %-18s  %-18s  %s\n' "Time" "Kind" "Agent" "Target" "Summary"
printf '%-24s  %-18s  %-18s  %-18s  %s\n' "----" "----" "-----" "------" "-------"
for ((i=start; i<count; i++)); do
  line="${matches[$i]}"
  time="$(extract_json_field "$line" 'ts|timestamp|time|at|created_at')"
  kind="$(extract_json_field "$line" 'kind|event_kind|event')"
  agent="$(extract_json_field "$line" 'agent|from|source')"
  target="$(extract_json_field "$line" 'spec|spec_id|target|idea_id')"
  summary="$(extract_json_field "$line" 'summary|message|decision|note')"
  [[ -z "$kind" ]] && kind="invalid-json"
  [[ -z "$summary" ]] && summary="$line"
  printf '%-24.24s  %-18.18s  %-18.18s  %-18.18s  %.100s\n' "$time" "$kind" "$agent" "$target" "$summary"
done
