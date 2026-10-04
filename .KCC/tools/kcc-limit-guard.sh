#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# kcc-limit-guard.sh - Claude Code PreToolUse hook enforcing the KCC usage-limit
# thresholds (session-continuity protocol).
#
# Reads coordination/usage.json (written by kcc-statusline) and compares
# max(five_hour.pct, seven_day.pct) with .KCC/settings.json continuity.soft_pct /
# continuity.hard_pct (defaults 95 / 99).
#
#   below soft : exit 0, no output (normal permission flow).
#   soft       : exit 0 + JSON hookSpecificOutput.additionalContext telling
#                Claude to finish the current unit and spawn nothing new.
#                Once per limit window (marker file): write CP limit-soft and
#                emit limit-reached.
#   hard       : once per window: write CP limit-hard, emit limit-reached, arm
#                kcc-limit-watch (detached). Then block the tool: exit 2, reason
#                on stderr (Claude sees it as the denial reason).
#                Exception: Bash commands invoking kcc-checkpoint,
#                kcc-limit-watch or kcc-handover are allowed.
#   usage.json missing, unreadable, older than 10 minutes, or its window
#   already reset -> allow (exit 0).
#
# Hook facts (https://code.claude.com/docs/en/hooks.md): PreToolUse stdin has
# session_id, tool_name, tool_input; exit 2 blocks the call and stderr becomes
# the reason; exit 0 + hookSpecificOutput.additionalContext adds context.
#
# Usage (.claude/settings.json):
#   "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command",
#     "command": "bash \"$CLAUDE_PROJECT_DIR/.KCC/tools/kcc-limit-guard.sh\""}]}]
# Args: [--repo-root PATH] [--max-age-seconds N] [--dry-run]
#   --dry-run: decide and print, but write no CP, marker, event, or watcher.
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
REPO_ROOT="$SCRIPT_DIR/../.."
MAX_AGE=600
DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root|-RepoRoot) REPO_ROOT="${2:-.}"; shift 2 ;;
    --max-age-seconds|-MaxAgeSeconds) MAX_AGE="${2:-600}"; shift 2 ;;
    --dry-run|-DryRun) DRY=1; shift ;;
    *) shift ;;
  esac
done

HOOK_INPUT=""
IFS= read -r -d '' HOOK_INPUT || true

COORD="$REPO_ROOT/coordination"
USAGE="$COORD/usage.json"
[[ -f "$USAGE" ]] || exit 0
SETTINGS="$REPO_ROOT/.KCC/settings.json"
[[ -f "$SETTINGS" ]] || SETTINGS=""

NOW=""
printf -v NOW '%(%s)T' -1 2>/dev/null || NOW=""
[[ "$NOW" =~ ^[0-9]+$ ]] || NOW="$(date +%s)"

# level<US>pct<US>window<US>resets_at<US>session_id<US>soft<US>hard
DECISION="$(awk -v now="$NOW" -v maxage="$MAX_AGE" -v uf="$USAGE" -v sf="$SETTINGS" '
function jparse(str){ delete J; JS=str; JN=length(JS); JP=1; _jv("") }
function _jws(  c){ while(JP<=JN){ c=substr(JS,JP,1); if(c==" "||c=="\t"||c=="\n"||c=="\r") JP++; else break } }
function _jstr(   o,c,e){ JP++; o=""; while(JP<=JN){ c=substr(JS,JP,1); if(c=="\\"){ e=substr(JS,JP+1,1); if(e=="n"||e=="t") o=o " "; else if(e=="r") o=o ""; else if(e=="u"){ o=o "?"; JP+=4 } else o=o e; JP+=2; continue } if(c=="\""){ JP++; return o } o=o c; JP++ } return o }
function _jv(path,   c,k,idx,v){ _jws(); if(JP>JN) return; c=substr(JS,JP,1)
  if(c=="{"){ JP++; _jws(); if(substr(JS,JP,1)=="}"){ JP++; return } while(JP<=JN){ _jws(); if(substr(JS,JP,1)!="\""){ JP=JN+1; break } k=_jstr(); _jws(); JP++; _jv((path=="") ? k : (path "." k)); _jws(); c=substr(JS,JP,1); JP++; if(c!=",") break } return }
  if(c=="["){ JP++; idx=0; _jws(); if(substr(JS,JP,1)=="]"){ JP++; return } while(JP<=JN){ _jv(path "[" idx "]"); idx++; _jws(); c=substr(JS,JP,1); JP++; if(c!=",") break } return }
  if(c=="\""){ J[path]=_jstr(); return }
  v=""; while(JP<=JN){ c=substr(JS,JP,1); if(index(",}] \t\r\n",c)) break; v=v c; JP++ } if(v=="null") v=""; J[path]=v }
function g(k){ return (k in J) ? J[k] : "" }
function isnum(v){ return (v ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) }
function slurp(f,   l,s){ s=""; while((getline l < f)>0) s=s l "\n"; close(f); return s }
BEGIN {
  soft=95; hard=99
  if (sf != "") { jparse(slurp(sf)); if (isnum(g("continuity.soft_pct"))) soft=g("continuity.soft_pct")+0; if (isnum(g("continuity.hard_pct"))) hard=g("continuity.hard_pct")+0 }
  jparse(slurp(uf))
  up=g("updated_epoch")
  if (!isnum(up) || now - up > maxage) { print "allow"; exit }
  best=-1; win=""; rs=""
  split("five_hour seven_day", ws, " ")
  for (i=1; i<=2; i++) {
    p=g(ws[i] ".pct"); r=g(ws[i] ".resets_at")
    if (!isnum(p)) continue
    if (isnum(r) && r+0 <= now) continue
    if (p+0 > best) { best=p+0; win=ws[i]; rs=r }
  }
  lvl="allow"; if (best >= hard) lvl="hard"; else if (best >= soft) lvl="soft"
  printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\n", lvl, best, win, rs, g("session_id"), soft, hard
}' 2>/dev/null || echo allow)"

IFS=$'\037' read -r LEVEL PCT WINDOW RESETS USAGE_SID SOFT HARD <<< "$DECISION" || true
[[ "$LEVEL" == "soft" || "$LEVEL" == "hard" ]] || exit 0

# Hook stdin fields (only parsed when a threshold is crossed).
HOOK_FIELDS="$(printf '%s' "$HOOK_INPUT" | awk '
function jparse(str){ delete J; JS=str; JN=length(JS); JP=1; _jv("") }
function _jws(  c){ while(JP<=JN){ c=substr(JS,JP,1); if(c==" "||c=="\t"||c=="\n"||c=="\r") JP++; else break } }
function _jstr(   o,c,e){ JP++; o=""; while(JP<=JN){ c=substr(JS,JP,1); if(c=="\\"){ e=substr(JS,JP+1,1); if(e=="n"||e=="t") o=o " "; else if(e=="r") o=o ""; else if(e=="u"){ o=o "?"; JP+=4 } else o=o e; JP+=2; continue } if(c=="\""){ JP++; return o } o=o c; JP++ } return o }
function _jv(path,   c,k,idx,v){ _jws(); if(JP>JN) return; c=substr(JS,JP,1)
  if(c=="{"){ JP++; _jws(); if(substr(JS,JP,1)=="}"){ JP++; return } while(JP<=JN){ _jws(); if(substr(JS,JP,1)!="\""){ JP=JN+1; break } k=_jstr(); _jws(); JP++; _jv((path=="") ? k : (path "." k)); _jws(); c=substr(JS,JP,1); JP++; if(c!=",") break } return }
  if(c=="["){ JP++; idx=0; _jws(); if(substr(JS,JP,1)=="]"){ JP++; return } while(JP<=JN){ _jv(path "[" idx "]"); idx++; _jws(); c=substr(JS,JP,1); JP++; if(c!=",") break } return }
  if(c=="\""){ J[path]=_jstr(); return }
  v=""; while(JP<=JN){ c=substr(JS,JP,1); if(index(",}] \t\r\n",c)) break; v=v c; JP++ } if(v=="null") v=""; J[path]=v }
{ buf = buf $0 "\n" }
END { jparse(buf); printf "%s\037%s\037%s\n", J["session_id"], J["tool_name"], J["tool_input.command"] }' 2>/dev/null || true)"
IFS=$'\037' read -r HOOK_SID TOOL_NAME TOOL_CMD <<< "$HOOK_FIELDS" || true
SID="${HOOK_SID:-$USAGE_SID}"

WIN_LABEL="5h"; [[ "$WINDOW" == "seven_day" ]] && WIN_LABEL="7d"
PCT_LABEL="$PCT"
CPDIR="$COORD/checkpoints"
MARK="$CPDIR/.limit-$LEVEL-$WINDOW-${RESETS:-none}"

reset_label() {
  [[ "$RESETS" =~ ^[0-9]+$ ]] || { printf 'unknown'; return; }
  local s=""
  printf -v s '%(%Y-%m-%d %H:%M %Z)T' "$RESETS" 2>/dev/null || s="epoch $RESETS"
  printf '%s' "$s"
}

emit_limit() { # level
  [[ -f "$SCRIPT_DIR/backchannel-append.sh" ]] || return 0
  bash "$SCRIPT_DIR/backchannel-append.sh" --kind limit-reached --from kcc-limit-guard --session "$SID" \
    --payload "{\"level\":\"$1\",\"window\":\"$WINDOW\",\"pct\":$PCT,\"resets_at\":${RESETS:-null},\"harness\":\"claude\"}" \
    --repo-root "$REPO_ROOT" --no-dashboard >/dev/null 2>&1 || true
}

first_in_window=0
if [[ ! -f "$MARK" ]]; then
  first_in_window=1
  if [[ "$DRY" -eq 0 ]]; then
    mkdir -p "$CPDIR" 2>/dev/null || true
    : > "$MARK" 2>/dev/null || true
  fi
fi

if [[ "$LEVEL" == "soft" ]]; then
  CP_NOTE=""
  if [[ "$first_in_window" -eq 1 && "$DRY" -eq 0 ]]; then
    emit_limit soft
    bash "$SCRIPT_DIR/kcc-checkpoint.sh" --reason limit-soft --harness claude ${SID:+--session-id "$SID"} --repo-root "$REPO_ROOT" >/dev/null 2>&1 || true
    CP_NOTE=" Restore point written to coordination/checkpoints/latest.md."
  fi
  MSG="KCC soft limit: finish current unit, spawn nothing new. Usage ${PCT_LABEL}% of the ${WIN_LABEL} window (soft ${SOFT}%, hard ${HARD}%, resets $(reset_label)).${CP_NOTE} Do not start new subagents, waves, or specs; wrap up the current unit and let the checkpoint carry next_action."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"},"systemMessage":"%s"}\n' "$MSG" "KCC soft limit ${PCT_LABEL}% (${WIN_LABEL}): finishing current unit, nothing new will be spawned."
  exit 0
fi

# ---- hard -------------------------------------------------------------------
if [[ "$TOOL_NAME" == "Bash" && "$TOOL_CMD" =~ kcc-(checkpoint|limit-watch|handover) ]]; then
  exit 0
fi

if [[ "$first_in_window" -eq 1 && "$DRY" -eq 0 ]]; then
  emit_limit hard
  bash "$SCRIPT_DIR/kcc-checkpoint.sh" --reason limit-hard --harness claude ${SID:+--session-id "$SID"} --repo-root "$REPO_ROOT" >/dev/null 2>&1 || true
  bash "$SCRIPT_DIR/kcc-limit-watch.sh" --arm --harness claude ${SID:+--session-id "$SID"} ${RESETS:+--reset-at "$RESETS"} --repo-root "$REPO_ROOT" >/dev/null 2>&1 || true
fi

echo "KCC hard limit: tool use stopped at ${PCT_LABEL}% of the ${WIN_LABEL} usage window (hard ${HARD}%, resets $(reset_label)). A limit-hard restore point is in coordination/checkpoints/latest.md and kcc-limit-watch is armed to resume this session unattended after the reset. Do not retry tools; end your turn now with a one-line status. (Allowed: Bash running kcc-checkpoint, kcc-limit-watch or kcc-handover.)" >&2
exit 2
