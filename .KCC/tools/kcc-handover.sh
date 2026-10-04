#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# kcc-handover.sh - hand a running KCC session to another harness
# (session-continuity protocol, "Harness handover").
#
#   1. writes a fresh restore point (kcc-checkpoint --reason handover)
#   2. writes coordination/handover/HO-{NNN}.md: handover envelope with the
#      target entrypoint (CLAUDE.md / AGENTS.md) and the paths to read (never
#      file contents), plus next_action
#   3. makes sure the target harness adapter outputs exist (runs
#      sync-adapters --harness <target> only when they are missing)
#   4. prints the launch command, or runs it with --launch:
#        --unattended : continuity.resume[target] (with --session-id) or
#                       continuity.start[target] from .KCC/settings.json
#        interactive  : the harness binary with the prompt
#      prompt = "Read coordination/handover/HO-{NNN}.md and continue"
#   5. emits handover-issued
#
# Usage:
#   kcc-handover.sh --to claude|codex|opencode|generic [--from HARNESS]
#                   [--session-id TARGET_SESSION] [--launch] [--unattended]
#                   [--json] [--dry-run] [--repo-root PATH]
# PowerShell-style flags (-To, -From, -SessionId, -Launch, -Unattended, -Json,
# -DryRun, -RepoRoot) are accepted too. Never adds a permission-bypass flag.
# Exit: 0 ok (a missing launch command is a warning), 1 --launch with no launch
# command for the target, 2 usage/environment error.
set -euo pipefail

TOOL_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TO=""
FROM=""
TARGET_SID=""
LAUNCH=0
UNATTENDED=0
JSON=0
DRY=0

usage() { echo "usage: kcc-handover.sh --to claude|codex|opencode|generic [--from H] [--session-id ID] [--launch] [--unattended] [--json] [--dry-run] [--repo-root PATH]" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to|-To) TO="${2:-}"; shift 2 ;;
    --from|-From) FROM="${2:-}"; shift 2 ;;
    --session-id|-SessionId) TARGET_SID="${2:-}"; shift 2 ;;
    --launch|-Launch) LAUNCH=1; shift ;;
    --unattended|-Unattended) UNATTENDED=1; shift ;;
    --json|-Json) JSON=1; shift ;;
    --dry-run|-DryRun) DRY=1; shift ;;
    --repo-root|-RepoRoot) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

valid_h() { case "$1" in claude|codex|opencode|generic) return 0 ;; *) return 1 ;; esac; }
valid_h "$TO" || { echo "error: --to must be claude|codex|opencode|generic" >&2; usage; exit 2; }
if [[ -z "$FROM" ]]; then
  if [[ -n "${KCC_HARNESS:-}" ]]; then FROM="$KCC_HARNESS"
  elif [[ -n "${CLAUDECODE:-}" || -n "${CLAUDE_PROJECT_DIR:-}" ]]; then FROM="claude"
  else FROM="generic"; fi
fi
valid_h "$FROM" || { echo "error: --from must be claude|codex|opencode|generic" >&2; exit 2; }
[[ -d "$REPO_ROOT/.KCC" ]] || { echo "error: no .KCC workspace at $REPO_ROOT" >&2; exit 2; }

json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
jq_str() { if [[ -z "$1" ]]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi; }

KCC_JSON_AWK='
function jparse(str){ delete J; JS=str; JN=length(JS); JP=1; _jv("") }
function _jws(  c){ while(JP<=JN){ c=substr(JS,JP,1); if(c==" "||c=="\t"||c=="\n"||c=="\r") JP++; else break } }
function _jstr(   o,c,e){ JP++; o=""; while(JP<=JN){ c=substr(JS,JP,1); if(c=="\\"){ e=substr(JS,JP+1,1); if(e=="n"||e=="t") o=o " "; else if(e=="r") o=o ""; else if(e=="u"){ o=o "?"; JP+=4 } else o=o e; JP+=2; continue } if(c=="\""){ JP++; return o } o=o c; JP++ } return o }
function _jv(path,   c,k,idx,v){ _jws(); if(JP>JN) return; c=substr(JS,JP,1)
  if(c=="{"){ JP++; _jws(); if(substr(JS,JP,1)=="}"){ JP++; return } while(JP<=JN){ _jws(); if(substr(JS,JP,1)!="\""){ JP=JN+1; break } k=_jstr(); _jws(); JP++; _jv((path=="") ? k : (path "." k)); _jws(); c=substr(JS,JP,1); JP++; if(c!=",") break } return }
  if(c=="["){ JP++; idx=0; _jws(); if(substr(JS,JP,1)=="]"){ JP++; return } while(JP<=JN){ _jv(path "[" idx "]"); idx++; _jws(); c=substr(JS,JP,1); JP++; if(c!=",") break } return }
  if(c=="\""){ J[path]=_jstr(); return }
  v=""; while(JP<=JN){ c=substr(JS,JP,1); if(index(",}] \t\r\n",c)) break; v=v c; JP++ } if(v=="null") v=""; J[path]=v }
function g(k){ return (k in J) ? J[k] : "" }
'
json_fields() { # json-text key... -> values joined by \037
  local text="$1"; shift
  printf '%s' "$text" | awk -v keys="$*" "$KCC_JSON_AWK"'
{ buf = buf $0 "\n" }
END { jparse(buf); n = split(keys, ks, " "); out = ""; for (i = 1; i <= n; i++) out = out ((i > 1) ? "\037" : "") g(ks[i]); print out }'
}

COORD="$REPO_ROOT/coordination"
HODIR="$COORD/handover"
WARNINGS=()
TZ=UTC0 printf -v CREATED '%(%Y-%m-%dT%H:%M:%SZ)T' -1 2>/dev/null || CREATED=""
[[ "$CREATED" == *T*Z ]] || CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TODAY="${CREATED%%T*}"

# ---- 1. restore point ---------------------------------------------------------------
CP_ARGS=(--reason handover --harness "$FROM" --json --repo-root "$REPO_ROOT")
[[ "$DRY" -eq 1 ]] && CP_ARGS+=(--dry-run)
CP_JSON="$(bash "$SCRIPT_DIR/kcc-checkpoint.sh" "${CP_ARGS[@]}")" || { echo "error: kcc-checkpoint failed" >&2; exit 2; }
IFS=$'\037' read -r CP_ID CP_PATH NEXT_ACTION SPEC STAGE TRACE OPEN_GATES FROM_SID <<< "$(json_fields "$CP_JSON" checkpoint.id checkpoint.path checkpoint.next_action checkpoint.spec checkpoint.stage checkpoint.trace_session checkpoint.open_gates checkpoint.session_id)" || true

# ---- 2. envelope ------------------------------------------------------------------------
max=0
if [[ -d "$HODIR" ]]; then
  for f in "$HODIR"/HO-*.md; do
    [[ -e "$f" ]] || continue
    b="${f##*/HO-}"; b="${b%.md}"
    [[ "$b" =~ ^[0-9]+$ ]] || continue
    (( 10#$b > max )) && max=$((10#$b))
  done
fi
printf -v HO_ID 'HO-%03d' $((max + 1))
HO_REL="coordination/handover/$HO_ID.md"
PROMPT="Read $HO_REL and continue"
case "$TO" in claude) ENTRY="CLAUDE.md" ;; *) ENTRY="AGENTS.md" ;; esac

# ---- 3. adapter outputs --------------------------------------------------------------------
case "$TO" in
  claude) NEEDED=(.claude/agents .claude/skills CLAUDE.md) ;;
  codex) NEEDED=(.codex/agents .codex/skills AGENTS.md) ;;
  opencode) NEEDED=(.opencode/agents .opencode/commands AGENTS.md) ;;
  generic) NEEDED=(.agents/agents .agents/skills .agents/manifest.json) ;;
esac
MISSING=()
for p in "${NEEDED[@]}"; do [[ -e "$REPO_ROOT/$p" ]] || MISSING+=("$p"); done
ADAPTERS="present"
if [[ ${#MISSING[@]} -gt 0 ]]; then
  if [[ "$DRY" -eq 1 ]]; then
    ADAPTERS="would-sync"
  else
    sync_rc=0
    bash "$SCRIPT_DIR/sync-adapters.sh" --harness "$TO" --repo-root "$REPO_ROOT" >/dev/null 2>&1 || sync_rc=$?
    still=()
    for p in "${NEEDED[@]}"; do [[ -e "$REPO_ROOT/$p" ]] || still+=("$p"); done
    if [[ ${#still[@]} -eq 0 ]]; then
      ADAPTERS="synced"
      [[ "$sync_rc" -ne 0 ]] && WARNINGS+=("HO-W-SYNC-RC: sync-adapters --harness $TO exited $sync_rc but the adapter outputs now exist")
    else
      ADAPTERS="sync-failed"
      WARNINGS+=("HO-W-SYNC: sync-adapters --harness $TO did not create: ${still[*]}; run it manually")
    fi
  fi
fi

[[ -f "$REPO_ROOT/$ENTRY" ]] || WARNINGS+=("HO-W-ENTRY: target entrypoint $ENTRY does not exist yet (framework-init/sync-adapters creates it)")

# ---- 4. command -------------------------------------------------------------------------------
SETTINGS_OUT=""
if [[ -f "$REPO_ROOT/.KCC/settings.json" ]]; then
  SETTINGS_OUT="$(json_fields "$(cat "$REPO_ROOT/.KCC/settings.json")" continuity.permission_mode "continuity.resume.$TO" "continuity.start.$TO")"
fi
IFS=$'\037' read -r PERM TPL_RESUME TPL_START <<< "$SETTINGS_OUT" || true
PERM="${PERM//[^A-Za-z]/}"
case "$PERM" in ""|bypassPermissions) PERM="acceptEdits" ;; esac
SID="${TARGET_SID//[^A-Za-z0-9._:-]/}"
COMMAND=""
if [[ "$UNATTENDED" -eq 1 ]]; then
  TPL=""
  if [[ -n "$SID" && -n "$TPL_RESUME" ]]; then TPL="$TPL_RESUME"; else TPL="$TPL_START"; fi
  if [[ -n "$TPL" ]]; then
    TPL="${TPL//\{session_id\}/$SID}"; TPL="${TPL//\{permission_mode\}/$PERM}"; TPL="${TPL//\{resume_prompt\}/$PROMPT}"
    COMMAND="$TPL"
  fi
else
  case "$TO" in
    claude) COMMAND="claude \"$PROMPT\"" ;;
    codex) COMMAND="codex \"$PROMPT\"" ;;
    opencode) COMMAND="opencode --prompt \"$PROMPT\"" ;;
    generic) COMMAND="" ;;
  esac
fi
LC_CMD="$(printf '%s' "$COMMAND" | tr 'A-Z' 'a-z')"
if [[ "$LC_CMD" == *dangerously-skip-permissions* || "$LC_CMD" == *bypasspermissions* || "$LC_CMD" == *dangerously-bypass-approvals* || "$LC_CMD" == *--yolo* ]]; then
  echo "error: refusing a launch command with a permission-bypass flag: $COMMAND" >&2; exit 2
fi
[[ -z "$COMMAND" ]] && WARNINGS+=("HO-W-CMD: no launch command for $TO (configure continuity.start.$TO in .KCC/settings.json); open the harness and paste: $PROMPT")

render() {
  cat <<EOF
---
id: $HO_ID
created: $CREATED
from: $FROM
to: $TO
entrypoint: $ENTRY
checkpoint: ${CP_PATH}
next_action: "${NEXT_ACTION//\"/\'}"
prompt: "$PROMPT"
tags:
  - kcc/handover
---

# Handover $HO_ID ($FROM -> $TO)

## Envelope ID

HANDOVER-$TODAY-${HO_ID#HO-} ($HO_ID)

## Spec reference

${SPEC:-none recorded}

## From

- role: orchestrator (auto)
- harness: $FROM
- session_id: ${FROM_SID:-unknown}

## To

- role: orchestrator (auto)
- harness: $TO
- entrypoint: $ENTRY
- agent profiles: resolved from coordination/orchestrator.json for $TO (model + effort)

## Lifecycle stage

${STAGE:-unknown}

## Input context

Read these paths (contents are intentionally not copied here):

- $ENTRY
- ${CP_PATH} (restore point; also coordination/checkpoints/latest.md)
- coordination/orchestrator.json
- coordination/backchannel.jsonl
- ${TRACE:-Traces/ (no active session pointer)}
- .KCC/settings.json

## Output / deliverable

Restore point $CP_ID (reason handover). Open gates: ${OPEN_GATES:-0}.

## Ask

Resume the KCC auto run at next_action: ${NEXT_ACTION}
Emit handover-accepted (backchannel-append) once you have read this envelope.

## Constraints / non-goals

- Do not redo work recorded in the restore point's done_since_last.
- Resolve open human gates before continuing.
- Continue the same trace session and backchannel; do not start new ones.
- Never use a permission-bypass mode.

## Human notes

Launch: ${COMMAND:-none configured; open $TO and paste the prompt}
EOF
}

if [[ "$DRY" -eq 0 ]]; then
  mkdir -p "$HODIR"
  render > "$COORD/handover/$HO_ID.md"
  if [[ -f "$SCRIPT_DIR/backchannel-append.sh" ]]; then
    bash "$SCRIPT_DIR/backchannel-append.sh" --kind handover-issued --from kcc-handover --spec "$SPEC" --session "$FROM_SID" \
      --payload "{\"ho_id\":\"$HO_ID\",\"cp_id\":\"$CP_ID\",\"from\":\"$FROM\",\"to\":\"$TO\",\"path\":\"$HO_REL\",\"entrypoint\":\"$ENTRY\",\"unattended\":$( [[ $UNATTENDED -eq 1 ]] && echo true || echo false )}" \
      --repo-root "$REPO_ROOT" --no-dashboard >/dev/null 2>&1 || WARNINGS+=("HO-W-EMIT: backchannel-append failed")
  fi
fi

LAUNCHED=false
RC=0
# a missing command is a warning unless --launch was requested (handled below)

if [[ "$JSON" -eq 1 ]]; then
  V=""
  for w in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do
    V="$V${V:+,}{\"id\":\"${w%%:*}\",\"severity\":\"warning\",\"fix_owner\":\"human\",\"file\":null,\"message\":\"$(json_escape "${w#*: }")\"}"
  done
  MJ=""; for m in "${MISSING[@]+"${MISSING[@]}"}"; do MJ="$MJ${MJ:+,}\"$m\""; done
  printf '{"tool":"kcc-handover","version":"%s","scope":"all","errors":0,"warnings":%d,"status":"pass","dry_run":%s,"violations":[%s],"handover":{"id":"%s","path":"%s","from":"%s","to":"%s","entrypoint":"%s","checkpoint":"%s","next_action":%s,"adapters":"%s","missing_adapters":[%s],"unattended":%s,"prompt":%s,"command":%s,"launch":%s}}\n' \
    "$TOOL_VERSION" "${#WARNINGS[@]}" "$( [[ $DRY -eq 1 ]] && echo true || echo false )" "$V" "$HO_ID" "$HO_REL" "$FROM" "$TO" "$ENTRY" "$CP_PATH" "$(jq_str "$NEXT_ACTION")" "$ADAPTERS" "$MJ" \
    "$( [[ $UNATTENDED -eq 1 ]] && echo true || echo false )" "$(jq_str "$PROMPT")" "$(jq_str "$COMMAND")" "$( [[ $LAUNCH -eq 1 && $DRY -eq 0 ]] && echo true || echo false )"
else
  [[ "$DRY" -eq 1 ]] && echo "[dry-run] would write $HO_REL and restore point $CP_ID (nothing written)" || echo "$HO_ID written: $HO_REL (restore point $CP_ID)"
  echo "from $FROM -> to $TO, entrypoint $ENTRY, adapters: $ADAPTERS${MISSING[*]:+ (missing: ${MISSING[*]})}"
  echo "next_action: $NEXT_ACTION"
  echo "command: ${COMMAND:-<none>}"
  for w in "${WARNINGS[@]+"${WARNINGS[@]}"}"; do echo "warning: $w"; done
  echo "Errors: 0  Warnings: ${#WARNINGS[@]}"
fi

if [[ "$LAUNCH" -eq 1 && "$DRY" -eq 0 ]]; then
  if [[ -z "$COMMAND" ]]; then echo "error: nothing to launch for $TO" >&2; exit 1; fi
  cd "$REPO_ROOT"
  if [[ "$UNATTENDED" -eq 1 ]]; then
    bash -c "$COMMAND" < /dev/null
  else
    bash -c "$COMMAND"
  fi
  exit $?
fi
exit "$RC"
