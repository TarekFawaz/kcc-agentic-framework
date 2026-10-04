#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# kcc-limit-watch.sh - wait for a usage-limit reset, then resume the KCC run
# UNATTENDED (session-continuity protocol).
#
# Modes:
#   --arm   spawn a detached background copy of this script in --run mode and
#           return immediately (no-op when a live watcher already holds the lock)
#   --run   foreground loop: wait until --reset-at (+ continuity.resume_grace_seconds)
#           or continuity.default_wait_minutes, run the resume command, and repeat
#           if the resumed session hits the limit again (max continuity.max_resumes)
#   --wrap  -- <command...>  run a harness command (codex, opencode, generic,
#           or claude), stream its output, detect rate-limit messages
#           ("usage limit", "rate limit", "429", "try again in/at ...") and on a
#           hit: kcc-checkpoint limit-hard, wait for the parsed reset, resume.
#
# Resume command = continuity.resume[harness] when a session id is known,
# else continuity.start[harness] (.KCC/settings.json), with {session_id},
# {permission_mode}, {resume_prompt} (and {command} = wrapped argv[0] for
# generic) substituted. resume_prompt:
#   "Read coordination/checkpoints/latest.md and continue the KCC run from next_action."
# This tool NEVER adds a permission-bypass flag and refuses to run a template
# that contains one (--dangerously-skip-permissions, bypassPermissions,
# --dangerously-bypass-approvals-and-sandbox, --yolo).
#
# Log: coordination/limit-watch.log. Events: limit-reached, resume-scheduled,
# resume-started (checkpoint-created comes from kcc-checkpoint).
# Single instance: coordination/limit-watch.lock.d (heartbeat; stale after 10 min).
#
# Usage:
#   kcc-limit-watch.sh --arm|--run [--harness claude|codex|opencode|generic]
#       [--session-id ID] [--reset-at EPOCH|ISO8601] [--wait-minutes N]
#       [--grace-seconds N] [--max-resumes N] [--command TEMPLATE]
#       [--dry-run] [--repo-root PATH]
#   kcc-limit-watch.sh --wrap --harness codex [--session-id ID] -- codex exec "..."
# PowerShell-style flags (-Arm, -Run, -Wrap, -Harness, -SessionId, -ResetAt,
# -WaitMinutes, -GraceSeconds, -MaxResumes, -Command, -DryRun, -RepoRoot) work too.
# Exit: 0 resumed run finished (or armed / dry-run), 1 gave up or resumed run
# failed, 2 usage/environment error.
set -euo pipefail

SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "$SELF")"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODE=""
HARNESS="claude"
SESSION_ID=""
RESET_AT=""
WAIT_MIN=""
GRACE=""
MAX_RESUMES=""
CMD_OVERRIDE=""
DRY=0
WRAP_CMD=()
PASS_ARGS=()

usage() {
  sed -n '/^# Usage:/,/^# Exit:/p' "$SELF" | sed 's/^# \{0,1\}//' >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arm|-Arm) MODE="arm"; shift ;;
    --run|-Run) MODE="run"; shift ;;
    --wrap|-Wrap) MODE="wrap"; shift ;;
    --harness|-Harness) HARNESS="${2:-}"; PASS_ARGS+=(--harness "$HARNESS"); shift 2 ;;
    --session-id|-SessionId) SESSION_ID="${2:-}"; PASS_ARGS+=(--session-id "$SESSION_ID"); shift 2 ;;
    --reset-at|-ResetAt) RESET_AT="${2:-}"; PASS_ARGS+=(--reset-at "$RESET_AT"); shift 2 ;;
    --wait-minutes|-WaitMinutes) WAIT_MIN="${2:-}"; PASS_ARGS+=(--wait-minutes "$WAIT_MIN"); shift 2 ;;
    --grace-seconds|-GraceSeconds) GRACE="${2:-}"; PASS_ARGS+=(--grace-seconds "$GRACE"); shift 2 ;;
    --max-resumes|-MaxResumes) MAX_RESUMES="${2:-}"; PASS_ARGS+=(--max-resumes "$MAX_RESUMES"); shift 2 ;;
    --command|-Command) CMD_OVERRIDE="${2:-}"; PASS_ARGS+=(--command "$CMD_OVERRIDE"); shift 2 ;;
    --repo-root|-RepoRoot) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --dry-run|-DryRun) DRY=1; PASS_ARGS+=(--dry-run); shift ;;
    --) shift; WRAP_CMD=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$MODE" ]] || { echo "error: one of --arm, --run, --wrap is required" >&2; usage; exit 2; }
case "$HARNESS" in claude|codex|opencode|generic) ;; *) echo "error: --harness must be claude|codex|opencode|generic" >&2; exit 2 ;; esac
[[ -d "$REPO_ROOT/.KCC" ]] || { echo "error: no .KCC workspace at $REPO_ROOT" >&2; exit 2; }
if [[ "$MODE" == "wrap" && ${#WRAP_CMD[@]} -eq 0 ]]; then echo "error: --wrap needs -- <command...>" >&2; exit 2; fi

COORD="$REPO_ROOT/coordination"
mkdir -p "$COORD"
LOG="$COORD/limit-watch.log"
STATE="$COORD/limit-watch.state"
LOCK="$COORD/limit-watch.lock.d"
RESUME_PROMPT="Read coordination/checkpoints/latest.md and continue the KCC run from next_action."

now() { local n=""; printf -v n '%(%s)T' -1 2>/dev/null || n=""; [[ "$n" =~ ^[0-9]+$ ]] || n="$(date +%s)"; printf '%s' "$n"; }
iso_now() { local s=""; TZ=UTC0 printf -v s '%(%Y-%m-%dT%H:%M:%SZ)T' -1 2>/dev/null || s=""; [[ "$s" == *T*Z ]] || s="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; printf '%s' "$s"; }
fmt_epoch() { local s=""; printf -v s '%(%Y-%m-%d %H:%M:%S %Z)T' "$1" 2>/dev/null || s="epoch $1"; printf '%s' "$s"; }
log() { local line; line="$(iso_now) [$MODE/$HARNESS pid $$] $*"; printf '%s\n' "$line" >> "$LOG"; printf '%s\n' "$line" >&2; }
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
emit() { # kind payload-json
  [[ "$DRY" -eq 1 ]] && return 0
  [[ -f "$SCRIPT_DIR/backchannel-append.sh" ]] || return 0
  bash "$SCRIPT_DIR/backchannel-append.sh" --kind "$1" --from kcc-limit-watch --session "$SESSION_ID" --payload "$2" --repo-root "$REPO_ROOT" --no-dashboard >/dev/null 2>&1 || log "warning: could not emit $1"
}

# ---- settings (continuity) -----------------------------------------------------
SETTINGS_OUT=""
if [[ -f "$REPO_ROOT/.KCC/settings.json" ]]; then
  SETTINGS_OUT="$(awk -v h="$HARNESS" '
function jparse(str){ delete J; JS=str; JN=length(JS); JP=1; _jv("") }
function _jws(  c){ while(JP<=JN){ c=substr(JS,JP,1); if(c==" "||c=="\t"||c=="\n"||c=="\r") JP++; else break } }
function _jstr(   o,c,e){ JP++; o=""; while(JP<=JN){ c=substr(JS,JP,1); if(c=="\\"){ e=substr(JS,JP+1,1); if(e=="n"||e=="t") o=o " "; else if(e=="r") o=o ""; else if(e=="u"){ o=o "?"; JP+=4 } else o=o e; JP+=2; continue } if(c=="\""){ JP++; return o } o=o c; JP++ } return o }
function _jv(path,   c,k,idx,v){ _jws(); if(JP>JN) return; c=substr(JS,JP,1)
  if(c=="{"){ JP++; _jws(); if(substr(JS,JP,1)=="}"){ JP++; return } while(JP<=JN){ _jws(); if(substr(JS,JP,1)!="\""){ JP=JN+1; break } k=_jstr(); _jws(); JP++; _jv((path=="") ? k : (path "." k)); _jws(); c=substr(JS,JP,1); JP++; if(c!=",") break } return }
  if(c=="["){ JP++; idx=0; _jws(); if(substr(JS,JP,1)=="]"){ JP++; return } while(JP<=JN){ _jv(path "[" idx "]"); idx++; _jws(); c=substr(JS,JP,1); JP++; if(c!=",") break } return }
  if(c=="\""){ J[path]=_jstr(); return }
  v=""; while(JP<=JN){ c=substr(JS,JP,1); if(index(",}] \t\r\n",c)) break; v=v c; JP++ } if(v=="null") v=""; J[path]=v }
function g(k){ return (k in J) ? J[k] : "" }
{ buf = buf $0 "\n" }
END { jparse(buf); printf "%s\037%s\037%s\037%s\037%s\037%s\n", g("continuity.resume_grace_seconds"), g("continuity.default_wait_minutes"), g("continuity.max_resumes"), g("continuity.permission_mode"), g("continuity.resume." h), g("continuity.start." h) }' "$REPO_ROOT/.KCC/settings.json" 2>/dev/null || true)"
fi
IFS=$'\037' read -r S_GRACE S_WAIT S_MAX S_PERM S_RESUME S_START <<< "$SETTINGS_OUT" || true
[[ -n "$GRACE" ]] || GRACE="${S_GRACE:-120}"
[[ -n "$WAIT_MIN" ]] || WAIT_MIN="${S_WAIT:-300}"
[[ -n "$MAX_RESUMES" ]] || MAX_RESUMES="${S_MAX:-5}"
PERM_MODE="${S_PERM:-acceptEdits}"
[[ "$GRACE" =~ ^[0-9]+$ ]] || GRACE=120
[[ "$WAIT_MIN" =~ ^[0-9]+$ ]] || WAIT_MIN=300
[[ "$MAX_RESUMES" =~ ^[0-9]+$ ]] || MAX_RESUMES=5
PERM_MODE="${PERM_MODE//[^A-Za-z]/}"
case "$PERM_MODE" in bypassPermissions|"") PERM_MODE="acceptEdits" ;; esac

# ---- helpers -------------------------------------------------------------------
to_epoch() { # EPOCH | ISO-8601 -> epoch (empty if unparseable)
  local v="$1"
  if [[ "$v" =~ ^[0-9]+$ ]]; then printf '%s' "$v"; return; fi
  [[ -z "$v" ]] && return 0
  date -d "$v" +%s 2>/dev/null && return 0
  date -j -f '%Y-%m-%dT%H:%M:%SZ' "$v" +%s 2>/dev/null || true
}

parse_reset() { # file -> epoch or empty
  local f="$1" n spec kind a b c
  n="$(now)"
  local secs_midnight hh mm ss
  printf -v hh '%(%H)T' -1 2>/dev/null || hh="$(date +%H)"
  printf -v mm '%(%M)T' -1 2>/dev/null || mm="$(date +%M)"
  printf -v ss '%(%S)T' -1 2>/dev/null || ss="$(date +%S)"
  secs_midnight=$((10#$hh * 3600 + 10#$mm * 60 + 10#$ss))
  spec="$(tail -n 80 "$f" 2>/dev/null | awk '
  { lines[++n] = tolower($0); orig[n] = $0 }
  END {
    for (i = n; i >= 1; i--) {
      t = lines[i]
      if (match(t, /\|[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]/)) { print "epoch " substr(t, RSTART + 1, 10); exit }
      if (match(t, /"?resets?_?at"?[: =]+[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]/)) { s = substr(t, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print "epoch " s; exit }
      if (match(t, /retry-after:? *[0-9]+/)) { s = substr(t, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print "rel " s; exit }
      if (match(t, /(again|retry|resets?|available|wait)[a-z ]* in [0-9][0-9a-z .,]*/)) {
        s = substr(t, RSTART, RLENGTH); sub(/.* in /, "", s); tot = 0
        while (match(s, /^[ ,]*(and)?[ ]*[0-9]+(\.[0-9]+)? *[a-z]+/)) {
          part = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
          sub(/^[ ,]*(and)?[ ]*/, "", part)
          num = part; sub(/[^0-9.].*$/, "", num); u = part; sub(/^[0-9.]+ */, "", u)
          if (u ~ /^(h|hr|hrs|hour|hours)$/) tot += num * 3600
          else if (u ~ /^(m|min|mins|minute|minutes)$/) tot += num * 60
          else if (u ~ /^(s|sec|secs|second|seconds)$/) tot += num
          else break
        }
        if (tot > 0) { print "rel " int(tot); exit }
      }
      if (match(orig[i], /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9](:[0-9][0-9])?(Z|[+-][0-9][0-9]:?[0-9][0-9])?/)) { print "iso " substr(orig[i], RSTART, RLENGTH); exit }
      if (match(t, /(again|resets?|reset|available)[a-z ]* at [0-9][0-9]?(:[0-9][0-9])? *(am|pm)?/) || match(t, /resets? [0-9][0-9]?(:[0-9][0-9])? *(am|pm)/)) {
        s = substr(t, RSTART, RLENGTH); sub(/^[a-z ]+/, "", s)
        h = s; sub(/[^0-9].*$/, "", h); m = 0
        if (match(s, /:[0-9][0-9]/)) m = substr(s, RSTART + 1, 2) + 0
        if (s ~ /pm/ && h + 0 < 12) h += 12
        if (s ~ /am/ && h + 0 == 12) h = 0
        print "clock " (h + 0) " " m; exit
      }
    }
  }' || true)"
  read -r kind a b <<< "$spec" || true
  case "$kind" in
    epoch) printf '%s' "$a" ;;
    rel) printf '%s' $((n + a)) ;;
    iso) to_epoch "$a${b:+ $b}" ;;
    clock)
      c=$((n - secs_midnight + a * 3600 + b * 60))
      (( c <= n )) && c=$((c + 86400))
      printf '%s' "$c" ;;
    *) : ;;
  esac
}

LIMIT_RE='usage limit|rate limit|rate-limit|ratelimit|limit reached|quota exceeded|exceeded your (current )?quota|too many requests|resource_exhausted|limit exceeded'
is_limit_hit() { # file rc
  local t
  t="$(tail -n 60 "$1" 2>/dev/null | tr 'A-Z' 'a-z' || true)"
  if printf '%s' "$t" | grep -Eq "$LIMIT_RE"; then return 0; fi
  if [[ "$2" != "0" ]] && printf '%s' "$t" | grep -Eq '(^|[^0-9])429([^0-9]|$)'; then return 0; fi
  return 1
}

parse_session_id() { # file -> id or empty
  grep -Eio "session[ _-]?id[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9_.:-]{6,}" "$1" 2>/dev/null | tail -n 1 | sed -E "s/.*[:=][[:space:]]*[\"']?//" || true
}

latest_cp() { # -> "id reason"
  local f="$COORD/checkpoints/latest.md"
  [[ -f "$f" ]] || { printf ' '; return; }
  awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f && /^id:/{id=$2} f && /^reason:/{r=$2} END{printf "%s %s", id, r}' "$f"
}

build_command() { # -> command string (stdout), rc 2 if none
  local tpl="" sid="${SESSION_ID//[^A-Za-z0-9._:-]/}" cmd0=""
  if [[ -n "$CMD_OVERRIDE" ]]; then tpl="$CMD_OVERRIDE"
  elif [[ -n "$sid" && -n "$S_RESUME" ]]; then tpl="$S_RESUME"
  elif [[ -n "$S_START" ]]; then tpl="$S_START"
  elif [[ ${#WRAP_CMD[@]} -gt 0 ]]; then tpl='{command} "{resume_prompt}"'
  else return 2; fi
  [[ ${#WRAP_CMD[@]} -gt 0 ]] && cmd0="$(printf '%q' "${WRAP_CMD[0]}")"
  tpl="${tpl//\{session_id\}/$sid}"
  tpl="${tpl//\{permission_mode\}/$PERM_MODE}"
  tpl="${tpl//\{resume_prompt\}/$RESUME_PROMPT}"
  tpl="${tpl//\{command\}/$cmd0}"
  printf '%s' "$tpl"
}

refuses_bypass() {
  local lc; lc="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  [[ "$lc" == *dangerously-skip-permissions* || "$lc" == *bypasspermissions* || "$lc" == *dangerously-bypass-approvals* || "$lc" == *--yolo* ]]
}

# ---- lock ----------------------------------------------------------------------
lock_is_live() {
  [[ -d "$LOCK" ]] || return 1
  [[ -f "$LOCK/heartbeat" ]] || { [[ -z "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]]; return; }
  [[ -z "$(find "$LOCK/heartbeat" -mmin +10 2>/dev/null)" ]]
}
acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then :; else
    if lock_is_live; then return 1; fi
    rm -rf "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || return 1
  fi
  printf 'pid=%s\nmode=%s\nharness=%s\nstarted=%s\n' "$$" "$MODE" "$HARNESS" "$(iso_now)" > "$LOCK/owner"
  : > "$LOCK/heartbeat"
  trap 'rm -rf "$LOCK" 2>/dev/null || true' EXIT
  return 0
}
heartbeat() { : > "$LOCK/heartbeat" 2>/dev/null || true; }

read_attempts() { local a=0; [[ -f "$STATE" ]] && a="$(sed -n 's/^attempts=//p' "$STATE" | head -n 1)"; [[ "$a" =~ ^[0-9]+$ ]] || a=0; printf '%s' "$a"; }
write_attempts() { [[ "$DRY" -eq 1 ]] && return 0; printf 'attempts=%s\nupdated=%s\nharness=%s\nsession_id=%s\n' "$1" "$(iso_now)" "$HARNESS" "$SESSION_ID" > "$STATE"; }

# ---- arm -------------------------------------------------------------------------
if [[ "$MODE" == "arm" ]]; then
  if lock_is_live; then
    log "watcher already running (lock $LOCK); not arming another"
    echo "already-armed"
    exit 0
  fi
  if [[ "$DRY" -eq 1 ]]; then
    echo "[dry-run] would spawn: bash $SELF --run ${PASS_ARGS[*]} --repo-root $REPO_ROOT"
    exit 0
  fi
  nohup bash "$SELF" --run "${PASS_ARGS[@]+"${PASS_ARGS[@]}"}" --repo-root "$REPO_ROOT" >/dev/null 2>&1 < /dev/null &
  child=$!
  disown "$child" 2>/dev/null || true
  log "armed detached watcher pid $child"
  echo "armed pid $child"
  exit 0
fi

# ---- run one resume cycle (wait + resume), repeat on limit hits --------------------
OUT_FILE=""
cleanup_out() { [[ -n "$OUT_FILE" ]] && rm -f "$OUT_FILE" 2>/dev/null || true; }

wait_and_resume() { # $1 = reset epoch (may be empty)
  local reset="$1" attempts target n cmd rc before after
  while :; do
    attempts=$(( $(read_attempts) + 1 ))
    if (( attempts > MAX_RESUMES )); then
      log "giving up: $((attempts - 1)) resume attempts already made (max_resumes=$MAX_RESUMES). Resume manually from coordination/checkpoints/latest.md."
      write_attempts 0
      return 1
    fi
    n="$(now)"
    if [[ "$reset" =~ ^[0-9]+$ ]]; then target=$((reset + GRACE)); else target=$((n + WAIT_MIN * 60)); fi
    (( target < n )) && target="$n"
    cmd="$(build_command)" || { log "error: no resume/start template for harness $HARNESS in .KCC/settings.json continuity (pass --command)"; return 2; }
    if refuses_bypass "$cmd"; then
      log "error: refusing to run a command containing a permission-bypass flag: $cmd"
      return 2
    fi
    write_attempts "$attempts"
    log "resume scheduled: attempt $attempts/$MAX_RESUMES at $(fmt_epoch "$target") (reset ${reset:-unknown}, grace ${GRACE}s): $cmd"
    emit resume-scheduled "{\"harness\":\"$HARNESS\",\"attempt\":$attempts,\"max_resumes\":$MAX_RESUMES,\"resume_at\":$target,\"reset_at\":${reset:-null},\"command\":\"$(json_escape "$cmd")\"}"
    if [[ "$DRY" -eq 1 ]]; then
      echo "[dry-run] would wait until $target ($(fmt_epoch "$target")) then run: $cmd"
      return 0
    fi
    while :; do
      n="$(now)"
      (( n >= target )) && break
      heartbeat
      local left=$((target - n)); (( left > 30 )) && left=30
      sleep "$left"
    done
    heartbeat
    before="$(latest_cp)"
    log "resume started: $cmd"
    emit resume-started "{\"harness\":\"$HARNESS\",\"attempt\":$attempts,\"command\":\"$(json_escape "$cmd")\"}"
    OUT_FILE="$(mktemp 2>/dev/null || echo "$COORD/.limit-watch.out.$$")"
    set +e
    ( cd "$REPO_ROOT" && bash -c "$cmd" ) < /dev/null 2>&1 | tee -a "$OUT_FILE" | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
    set -e
    after="$(latest_cp)"
    log "resumed command exited rc=$rc"
    local hit=0
    if is_limit_hit "$OUT_FILE" "$rc"; then hit=1; fi
    if [[ "$after" != "$before" && "${after#* }" == "limit-hard" ]]; then hit=1; fi
    if [[ "$hit" -eq 1 ]]; then
      reset="$(parse_reset "$OUT_FILE")"
      log "resumed session hit the limit again (reset ${reset:-unknown})"
      emit limit-reached "{\"level\":\"hard\",\"harness\":\"$HARNESS\",\"source\":\"limit-watch\",\"resets_at\":${reset:-null}}"
      if [[ "$after" == "$before" || "${after#* }" != "limit-hard" ]]; then
        bash "$SCRIPT_DIR/kcc-checkpoint.sh" --reason limit-hard --harness "$HARNESS" ${SESSION_ID:+--session-id "$SESSION_ID"} --repo-root "$REPO_ROOT" >/dev/null 2>&1 || log "warning: kcc-checkpoint failed"
      fi
      cleanup_out
      continue
    fi
    cleanup_out
    write_attempts 0
    return "$rc"
  done
}

if [[ "$MODE" == "run" ]]; then
  if [[ "$DRY" -eq 0 ]] && ! acquire_lock; then
    log "another watcher holds $LOCK; exiting"
    exit 0
  fi
  RESET_EPOCH="$(to_epoch "$RESET_AT")"
  [[ -n "$RESET_AT" && -z "$RESET_EPOCH" ]] && log "warning: could not parse --reset-at '$RESET_AT'; using default_wait_minutes=$WAIT_MIN"
  log "watching: harness $HARNESS session ${SESSION_ID:-none} reset ${RESET_EPOCH:-unknown}"
  set +e
  wait_and_resume "$RESET_EPOCH"
  rc=$?
  set -e
  exit "$rc"
fi

# ---- wrap ------------------------------------------------------------------------
OUT_FILE="$(mktemp 2>/dev/null || echo "$COORD/.limit-watch.out.$$")"
log "wrap: ${WRAP_CMD[*]}"
set +e
( cd "$REPO_ROOT" && "${WRAP_CMD[@]}" ) 2>&1 | tee "$OUT_FILE"
rc=${PIPESTATUS[0]}
set -e
if ! is_limit_hit "$OUT_FILE" "$rc"; then
  cleanup_out
  exit "$rc"
fi
[[ -z "$SESSION_ID" ]] && SESSION_ID="$(parse_session_id "$OUT_FILE")"
[[ -z "$RESET_AT" ]] && RESET_AT="$(parse_reset "$OUT_FILE")"
RESET_EPOCH="$(to_epoch "$RESET_AT")"
cleanup_out
log "rate limit detected in $HARNESS output (rc=$rc, session ${SESSION_ID:-unknown}, reset ${RESET_EPOCH:-unknown -> default_wait_minutes})"
emit limit-reached "{\"level\":\"hard\",\"harness\":\"$HARNESS\",\"source\":\"wrap\",\"exit_code\":$rc,\"resets_at\":${RESET_EPOCH:-null}}"
if [[ "$DRY" -eq 0 ]]; then
  bash "$SCRIPT_DIR/kcc-checkpoint.sh" --reason limit-hard --harness "$HARNESS" ${SESSION_ID:+--session-id "$SESSION_ID"} --repo-root "$REPO_ROOT" >/dev/null 2>&1 || log "warning: kcc-checkpoint failed"
  if ! acquire_lock; then
    log "another watcher holds $LOCK; it will resume the run"
    exit 0
  fi
fi
write_attempts 0
set +e
wait_and_resume "$RESET_EPOCH"
rc=$?
set -e
exit "$rc"
