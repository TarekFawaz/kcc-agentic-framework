#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# kcc-statusline.sh - Claude Code status-line command for KCC session continuity.
#
# Reads the Claude Code status-line JSON from stdin (documented fields:
# rate_limits.five_hour/seven_day.used_percentage + resets_at (Unix epoch
# seconds), context_window.used_percentage, session_id), atomically writes
# coordination/usage.json, and prints one compact line:
#   KCC 5h 42% · 7d 18% · ctx 31%
# A " SOFT" / " HARD" suffix appears once continuity.soft_pct / hard_pct
# (.KCC/settings.json) is reached.
#
# If KCC_STATUSLINE_CHAIN is set, the same stdin is piped to that command
# (via bash -c) and its output is printed instead of ours; usage.json is still
# written, so an existing personal status line keeps working.
#
# Usage (.claude/settings.json):
#   "statusLine": {"type": "command",
#                  "command": "bash \"$CLAUDE_PROJECT_DIR/.KCC/tools/kcc-statusline.sh\""}
# Args: [--repo-root PATH] [--json]   (--json prints the usage.json object)
#
# No python/jq. Hot path = bash builtins + one awk + one mv (Claude Code
# debounces status updates at 300ms and cancels in-flight runs). Never fails
# the status bar: errors degrade to printing "KCC" and exit 0.
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && SCRIPT_DIR="."
REPO_ROOT="$SCRIPT_DIR/../.."
JSON_OUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root|-RepoRoot) REPO_ROOT="${2:-.}"; shift 2 ;;
    --json|-Json) JSON_OUT=1; shift ;;
    *) shift ;;
  esac
done

INPUT=""
IFS= read -r -d '' INPUT || true

NOW=""
printf -v NOW '%(%s)T' -1 2>/dev/null || NOW=""
[[ "$NOW" =~ ^[0-9]+$ ]] || NOW="$(date +%s)"
ISO=""
TZ=UTC0 printf -v ISO '%(%Y-%m-%dT%H:%M:%SZ)T' -1 2>/dev/null || ISO=""
[[ "$ISO" == *T*Z ]] || ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

SETTINGS="$REPO_ROOT/.KCC/settings.json"
[[ -f "$SETTINGS" ]] || SETTINGS=""
COORD="$REPO_ROOT/coordination"
[[ -d "$COORD" ]] || mkdir -p "$COORD" 2>/dev/null || true
TMP="$COORD/.usage.json.$$.tmp"

# One awk: parse the status JSON (+ settings thresholds), write the usage.json
# body to $TMP, print the display line (or the JSON with --json) on stdout.
LINE="$(awk -v now="$NOW" -v iso="$ISO" -v sf="$SETTINGS" -v tmp="$TMP" -v jsonout="$JSON_OUT" '
function jparse(str){ delete J; JS=str; JN=length(JS); JP=1; _jv("") }
function _jws(  c){ while(JP<=JN){ c=substr(JS,JP,1); if(c==" "||c=="\t"||c=="\n"||c=="\r") JP++; else break } }
function _jstr(   o,c,e){ JP++; o=""; while(JP<=JN){ c=substr(JS,JP,1); if(c=="\\"){ e=substr(JS,JP+1,1); if(e=="n"||e=="t") o=o " "; else if(e=="r") o=o ""; else if(e=="u"){ o=o "?"; JP+=4 } else o=o e; JP+=2; continue } if(c=="\""){ JP++; return o } o=o c; JP++ } return o }
function _jv(path,   c,k,idx,v){ _jws(); if(JP>JN) return; c=substr(JS,JP,1)
  if(c=="{"){ JP++; _jws(); if(substr(JS,JP,1)=="}"){ JP++; return } while(JP<=JN){ _jws(); if(substr(JS,JP,1)!="\""){ JP=JN+1; break } k=_jstr(); _jws(); JP++; _jv((path=="") ? k : (path "." k)); _jws(); c=substr(JS,JP,1); JP++; if(c!=",") break } return }
  if(c=="["){ JP++; idx=0; _jws(); if(substr(JS,JP,1)=="]"){ JP++; return } while(JP<=JN){ _jv(path "[" idx "]"); idx++; _jws(); c=substr(JS,JP,1); JP++; if(c!=",") break } return }
  if(c=="\""){ J[path]=_jstr(); return }
  v=""; while(JP<=JN){ c=substr(JS,JP,1); if(index(",}] \t\r\n",c)) break; v=v c; JP++ } if(v=="null") v=""; J[path]=v }
function g(k){ return (k in J) ? J[k] : "" }
function num(v){ return (v ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) ? v : "" }
function jnum(v){ return (v=="") ? "null" : v }
function jstr(v){ gsub(/\\/,"\\\\",v); gsub(/"/,"\\\"",v); return "\"" v "\"" }
function shown(v){ if(v=="") return "--"; if(v==int(v)) return int(v) "%"; return sprintf("%.1f%%", v) }
{ buf = buf $0 "\n" }
END {
  soft=95; hard=99
  if (sf != "") { s=""; while ((getline l < sf) > 0) s = s l "\n"; close(sf); jparse(s)
    if (num(g("continuity.soft_pct"))!="") soft=g("continuity.soft_pct")+0
    if (num(g("continuity.hard_pct"))!="") hard=g("continuity.hard_pct")+0 }
  jparse(buf)
  sid=g("session_id")
  f5=num(g("rate_limits.five_hour.used_percentage")); r5=num(g("rate_limits.five_hour.resets_at"))
  f7=num(g("rate_limits.seven_day.used_percentage")); r7=num(g("rate_limits.seven_day.resets_at"))
  cx=num(g("context_window.used_percentage"))
  body=sprintf("{\"harness\":\"claude\",\"session_id\":%s,\"five_hour\":{\"pct\":%s,\"resets_at\":%s},\"seven_day\":{\"pct\":%s,\"resets_at\":%s},\"context_pct\":%s,\"updated\":\"%s\",\"updated_epoch\":%s}", (sid=="" ? "null" : jstr(sid)), jnum(f5), jnum(r5), jnum(f7), jnum(r7), jnum(cx), iso, now)
  printf "%s\n", body > tmp; close(tmp)
  if (jsonout == 1) { print body; exit }
  m=-1; if (f5!="" && f5+0>m) m=f5+0; if (f7!="" && f7+0>m) m=f7+0
  flag=""; if (m>=hard) flag=" HARD"; else if (m>=soft) flag=" SOFT"
  printf "KCC 5h %s \302\267 7d %s \302\267 ctx %s%s\n", shown(f5), shown(f7), shown(cx), flag
}' <<< "$INPUT" 2>/dev/null || true)"

if [[ -s "$TMP" ]]; then
  mv -f "$TMP" "$COORD/usage.json" 2>/dev/null || rm -f "$TMP" 2>/dev/null || true
fi

if [[ "$JSON_OUT" -eq 0 && -n "${KCC_STATUSLINE_CHAIN:-}" ]]; then
  CHAIN_OUT="$(printf '%s' "$INPUT" | bash -c "$KCC_STATUSLINE_CHAIN" 2>/dev/null || true)"
  if [[ -n "$CHAIN_OUT" ]]; then
    printf '%s\n' "$CHAIN_OUT"
    exit 0
  fi
fi

if [[ -n "$LINE" ]]; then
  printf '%s\n' "$LINE"
else
  printf 'KCC\n'
fi
exit 0
