#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 native bash backchannel appender for macOS/Linux.
#
# Run it (`bash backchannel-append.sh --kind K --from A ...`) or source it (`source backchannel-append.sh`): sourcing only
# defines bc_append, so a caller that emits many events (kcc-run) appends them in-process instead of paying a process
# (and, under Git Bash on Windows, ~12 forks) per event. Same line format, same id numbering, same dashboard rule.

bc_src="${BASH_SOURCE[0]}"
case "$bc_src" in */*) bc_dir="${bc_src%/*}" ;; *) bc_dir="." ;; esac
if [[ "$bc_dir" == /* ]]; then BC_TOOLS_DIR="$bc_dir"; else BC_TOOLS_DIR="$PWD/$bc_dir"; fi
unset bc_src bc_dir

# JSON-escape $1 into BC_ESC (no subshell).
bc_jesc() {
  local s="$1" bs='\'
  s="${s//"$bs"/"$bs$bs"}"
  s="${s//\"/"$bs\""}"
  s="${s//$'\n'/"${bs}n"}"
  s="${s//$'\r'/"${bs}r"}"
  s="${s//$'\t'/"${bs}t"}"
  BC_ESC="$s"
}

# "k=v;k2=v2" -> BC_PAYLOAD (a JSON object); numbers stay numbers.
bc_pairs() {
  local raw="$1" first=1 pair key val out='{' pairs=()
  IFS=';' read -r -a pairs <<< "$raw"
  for pair in "${pairs[@]}"; do
    [[ -z "${pair//[[:space:]]/}" ]] && continue
    key="${pair%%=*}"
    val=""
    [[ "$pair" == *"="* ]] && val="${pair#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    [[ -z "$key" ]] && continue
    (( first == 0 )) && out+=','
    first=0
    bc_jesc "$key"; key="$BC_ESC"
    if [[ "$val" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
      out+="\"$key\":$val"
    else
      bc_jesc "$val"
      out+="\"$key\":\"$BC_ESC\""
    fi
  done
  BC_PAYLOAD="$out}"
}

# bc_append KIND FROM TO SPEC SESSION PAYLOAD REPO_ROOT NO_DASHBOARD -> appends one line, sets BC_LINE and BC_ID. Returns 1 on an I/O error.
bc_append() {
  local kind="$1" from="$2" to="$3" spec="$4" session="$5" payload="$6" root="$7" nodash="${8:-0}"
  local log="$root/coordination/backchannel.jsonl" next_num=1 ts payload_json spec_json="null" session_json="null" i all line
  local re_id='^.*"id"[[:space:]]*:[[:space:]]*"BC-([0-9]+)"'
  [[ -d "$root/coordination" ]] || mkdir -p "$root/coordination" || return 1
  : >> "$log" || return 1
  if [[ -s "$log" ]]; then
    # The last line among the final 50 that carries an id wins: the file is read once ($(<file) is not a fork) and its lines are taken
    # off the end (this replaces tail -n 50 | sed | tail -n 1, three processes).
    all="$(<"$log")"
    for (( i = 0; i < 50 && ${#all} > 0; i++ )); do
      line="${all##*$'\n'}"
      if [[ "$line" =~ $re_id ]]; then
        next_num=$((10#${BASH_REMATCH[1]} + 1))
        break
      fi
      if [[ "$all" == *$'\n'* ]]; then all="${all%$'\n'*}"; else all=""; fi
    done
  fi
  printf -v BC_ID 'BC-%05d' "$next_num"
  # printf's %(...)T needs bash 4.2; TZ=UTC in front of the builtin makes it UTC. Older bash (macOS 3.2) asks date.
  if ! TZ=UTC printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1 2>/dev/null; then ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
  if [[ -z "${payload//[[:space:]]/}" ]]; then
    payload_json='{}'
  elif [[ "${payload#"${payload%%[![:space:]]*}"}" == \{* ]]; then
    payload_json="$payload"
  else
    bc_pairs "$payload"; payload_json="$BC_PAYLOAD"
  fi
  if [[ -n "$spec" ]]; then bc_jesc "$spec"; spec_json="\"$BC_ESC\""; fi
  if [[ -n "$session" ]]; then bc_jesc "$session"; session_json="\"$BC_ESC\""; fi
  bc_jesc "$from"; from="$BC_ESC"
  bc_jesc "$to"; to="$BC_ESC"
  bc_jesc "$kind"; kind="$BC_ESC"
  BC_LINE="{\"ts\":\"$ts\",\"id\":\"$BC_ID\",\"from\":\"$from\",\"to\":\"$to\",\"kind\":\"$kind\",\"spec\":$spec_json,\"session\":$session_json,\"payload\":$payload_json}"
  printf '%s\n' "$BC_LINE" >> "$log" || return 1
  if [[ "$nodash" -eq 0 && "${KCC_SKIP_DASHBOARD:-}" != "1" && "${KCC_SKIP_DASHBOARD:-}" != "true" && -x "$BC_TOOLS_DIR/build-dashboard.sh" ]]; then
    "$BC_TOOLS_DIR/build-dashboard.sh" --repo-root "$root" >/dev/null 2>&1 || true
  fi
  return 0
}

# Sourced: only the functions are wanted.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

set -euo pipefail

SCRIPT_DIR="$BC_TOOLS_DIR"
KIND=""
FROM=""
TO="broadcast"
SPEC=""
SESSION=""
PAYLOAD=""
NO_DASHBOARD=0
REPO_ROOT=""

usage() {
  cat >&2 <<'EOF'
usage: backchannel-append.sh --kind KIND --from AGENT [--to TARGET] [--spec ID] [--session ID] [--payload JSON|key=val;...] [--repo-root PATH] [--no-dashboard]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind|-Kind) KIND="$2"; shift 2 ;;
    --from|-From) FROM="$2"; shift 2 ;;
    --to|-To) TO="$2"; shift 2 ;;
    --spec|-Spec) SPEC="$2"; shift 2 ;;
    --session|-Session) SESSION="$2"; shift 2 ;;
    --payload|-Payload) PAYLOAD="$2"; shift 2 ;;
    --repo-root|-RepoRoot) [[ -d "$2" ]] || cd "$2"; REPO_ROOT="$2"; [[ ${#REPO_ROOT} -gt 1 ]] && REPO_ROOT="${REPO_ROOT%/}"; shift 2 ;;
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

if [[ -z "$REPO_ROOT" ]]; then REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"; fi

bc_append "$KIND" "$FROM" "$TO" "$SPEC" "$SESSION" "$PAYLOAD" "$REPO_ROOT" "$NO_DASHBOARD"
printf '%s\n' "$BC_LINE"
