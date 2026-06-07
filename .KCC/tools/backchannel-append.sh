#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 native bash backchannel appender for macOS/Linux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KIND=""
FROM=""
TO="broadcast"
SPEC=""
SESSION=""
PAYLOAD=""
NO_DASHBOARD=0

usage() {
  cat >&2 <<'EOF'
usage: backchannel-append.sh --kind KIND --from AGENT [--to TARGET] [--spec ID] [--session ID] [--payload JSON|key=val;...] [--repo-root PATH] [--no-dashboard]
EOF
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

payload_from_pairs() {
  local raw="$1"
  local first=1
  printf '{'
  IFS=';' read -r -a pairs <<< "$raw"
  for pair in "${pairs[@]}"; do
    [[ -z "${pair//[[:space:]]/}" ]] && continue
    local key="${pair%%=*}"
    local val=""
    [[ "$pair" == *"="* ]] && val="${pair#*=}"
    key="$(printf '%s' "$key" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    val="$(printf '%s' "$val" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -z "$key" ]] && continue
    (( first == 0 )) && printf ','
    first=0
    if [[ "$val" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
      printf '"%s":%s' "$(json_escape "$key")" "$val"
    else
      printf '"%s":"%s"' "$(json_escape "$key")" "$(json_escape "$val")"
    fi
  done
  printf '}'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind|-Kind) KIND="$2"; shift 2 ;;
    --from|-From) FROM="$2"; shift 2 ;;
    --to|-To) TO="$2"; shift 2 ;;
    --spec|-Spec) SPEC="$2"; shift 2 ;;
    --session|-Session) SESSION="$2"; shift 2 ;;
    --payload|-Payload) PAYLOAD="$2"; shift 2 ;;
    --repo-root|-RepoRoot) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --no-dashboard|-NoDashboard) NO_DASHBOARD=1; shift ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$KIND" || -z "$FROM" ]]; then
  usage
  exit 2
fi

mkdir -p "$REPO_ROOT/coordination"
LOG="$REPO_ROOT/coordination/backchannel.jsonl"
touch "$LOG"

next_num=1
if [[ -s "$LOG" ]]; then
  while IFS= read -r line; do
    id="$(printf '%s\n' "$line" | sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"BC-([0-9]+)".*/\1/p' | tail -n 1)"
    if [[ -n "$id" ]]; then
      next_num=$((10#$id + 1))
    fi
  done < <(tail -n 50 "$LOG")
fi

printf -v ID 'BC-%05d' "$next_num"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ -z "${PAYLOAD//[[:space:]]/}" ]]; then
  PAYLOAD_JSON='{}'
elif [[ "${PAYLOAD#"${PAYLOAD%%[![:space:]]*}"}" == \{* ]]; then
  PAYLOAD_JSON="$PAYLOAD"
else
  PAYLOAD_JSON="$(payload_from_pairs "$PAYLOAD")"
fi

SPEC_JSON="null"
SESSION_JSON="null"
[[ -n "$SPEC" ]] && SPEC_JSON="\"$(json_escape "$SPEC")\""
[[ -n "$SESSION" ]] && SESSION_JSON="\"$(json_escape "$SESSION")\""

LINE="{\"ts\":\"$TS\",\"id\":\"$ID\",\"from\":\"$(json_escape "$FROM")\",\"to\":\"$(json_escape "$TO")\",\"kind\":\"$(json_escape "$KIND")\",\"spec\":$SPEC_JSON,\"session\":$SESSION_JSON,\"payload\":$PAYLOAD_JSON}"
printf '%s\n' "$LINE" >> "$LOG"

if [[ "$NO_DASHBOARD" -eq 0 && "${KCC_SKIP_DASHBOARD:-}" != "1" && "${KCC_SKIP_DASHBOARD:-}" != "true" && -x "$SCRIPT_DIR/build-dashboard.sh" ]]; then
  "$SCRIPT_DIR/build-dashboard.sh" --repo-root "$REPO_ROOT" >/dev/null 2>&1 || true
fi

printf '%s\n' "$LINE"
