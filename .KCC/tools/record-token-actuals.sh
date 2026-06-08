#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# Record ACTUAL token usage for a session - the missing producer for the
# token-actuals contract. Mirror of record-token-actuals.ps1.
#
# Writes one session-total actual row to the active session's TokenUsage.md and
# emits an actual-recorded backchannel event. Always exits 0 (hook safety).
#
# Sources: harness-reported (parsed from a Claude Code transcript JSONL),
# manual-meter (human/billing counts), unavailable (honest no-accounting).
#
# Usage:
#   bash record-token-actuals.sh --from-hook-stdin
#   bash record-token-actuals.sh --transcript-path /path/session.jsonl
#   bash record-token-actuals.sh --manual-total N [--manual-input N --manual-output N]
#   bash record-token-actuals.sh --unavailable --reason "..."
#   (optional: --spec SPEC-001  --repo-root PATH)

set -u

FROM_HOOK=0
TRANSCRIPT=""
MANUAL_TOTAL=""
MANUAL_INPUT=""
MANUAL_OUTPUT=""
UNAVAILABLE=0
REASON=""
SPEC=""
REPO_ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --from-hook-stdin) FROM_HOOK=1; shift ;;
    --transcript-path) TRANSCRIPT="$2"; shift 2 ;;
    --manual-total) MANUAL_TOTAL="$2"; shift 2 ;;
    --manual-input) MANUAL_INPUT="$2"; shift 2 ;;
    --manual-output) MANUAL_OUTPUT="$2"; shift 2 ;;
    --unavailable) UNAVAILABLE=1; shift ;;
    --reason) REASON="$2"; shift 2 ;;
    --spec) SPEC="$2"; shift 2 ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

info() { echo "[record-token-actuals] $*"; }

# Read hook stdin and pull transcript_path / cwd.
if [ "$FROM_HOOK" -eq 1 ]; then
  HOOK_JSON="$(cat)"
  if command -v python3 >/dev/null 2>&1; then
    TP="$(printf '%s' "$HOOK_JSON" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d.get("transcript_path","")); print(d.get("cwd",""))
except Exception:
    print(""); print("")' 2>/dev/null)"
    TRANSCRIPT="$(printf '%s\n' "$TP" | sed -n '1p')"
    HOOK_CWD="$(printf '%s\n' "$TP" | sed -n '2p')"
    [ -z "$REPO_ROOT" ] && [ -n "$HOOK_CWD" ] && REPO_ROOT="$HOOK_CWD"
  else
    TRANSCRIPT="$(printf '%s' "$HOOK_JSON" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
  fi
fi

if [ -z "$REPO_ROOT" ]; then
  TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
  PARENT="$(dirname "$TOOL_DIR")"
  if [ "$(basename "$PARENT")" = ".KCC" ]; then REPO_ROOT="$(dirname "$PARENT")"; else REPO_ROOT="$PARENT"; fi
fi
[ -d "$REPO_ROOT" ] && REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

# Resolve active session.
SESSION=""
ORCH="$REPO_ROOT/coordination/orchestrator.json"
if [ -f "$ORCH" ]; then
  AS="$(grep -oE '"active_session"[[:space:]]*:[[:space:]]*"[^"]*"' "$ORCH" | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -1)"
  if [ -n "$AS" ] && [ -d "$REPO_ROOT/$AS" ]; then SESSION="$REPO_ROOT/$AS"; fi
fi
if [ -z "$SESSION" ] && [ -d "$REPO_ROOT/Traces" ]; then
  SESSION="$(find "$REPO_ROOT/Traces" -maxdepth 1 -type d -name 'Session-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
fi
if [ -z "$SESSION" ]; then info "no active Traces/Session-* folder found; nothing to record."; exit 0; fi
TOKEN_FILE="$SESSION/TokenUsage.md"

SOURCE=""; IN=""; OUT=""; TOT=""; CACHE_READ=0; CACHE_CREATE=0; TURNS=0; UREASON=""

if [ "$UNAVAILABLE" -eq 1 ]; then
  SOURCE="unavailable"; [ -z "$REASON" ] && REASON="harness did not expose usage metadata"; UREASON="$REASON"
elif [ -n "$MANUAL_TOTAL" ]; then
  SOURCE="manual-meter"; TOT="$MANUAL_TOTAL"; IN="$MANUAL_INPUT"; OUT="$MANUAL_OUTPUT"
elif [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  PARSED=""
  if command -v python3 >/dev/null 2>&1; then
    PARSED="$(python3 - "$TRANSCRIPT" <<'PY'
import sys,json
fi=fc=fr=fo=turns=0
with open(sys.argv[1],'r',encoding='utf-8',errors='replace') as f:
    for line in f:
        line=line.strip()
        if not line: continue
        try: o=json.loads(line)
        except Exception: continue
        u=None
        m=o.get('message') if isinstance(o,dict) else None
        if isinstance(m,dict): u=m.get('usage')
        if u is None and isinstance(o,dict): u=o.get('usage')
        if not isinstance(u,dict): continue
        fi+=int(u.get('input_tokens') or 0)
        fc+=int(u.get('cache_creation_input_tokens') or 0)
        fr+=int(u.get('cache_read_input_tokens') or 0)
        fo+=int(u.get('output_tokens') or 0)
        turns+=1
print(fi, fc, fr, fo, turns)
PY
)"
  elif command -v jq >/dev/null 2>&1; then
    PARSED="$(jq -rs '
      [ .[] | (.message.usage // .usage) | select(.!=null) ] as $u
      | [ ($u|map(.input_tokens//0)|add), ($u|map(.cache_creation_input_tokens//0)|add),
          ($u|map(.cache_read_input_tokens//0)|add), ($u|map(.output_tokens//0)|add), ($u|length) ]
      | @tsv' "$TRANSCRIPT" 2>/dev/null | tr '\t' ' ')"
  fi
  if [ -n "$PARSED" ]; then
    set -- $PARSED
    fi_in="${1:-0}"; fc="${2:-0}"; fr="${3:-0}"; fo="${4:-0}"; TURNS="${5:-0}"
    CACHE_CREATE="$fc"; CACHE_READ="$fr"
    IN=$(( fi_in + fc ))   # fresh input only; cache_read tracked separately
    OUT="$fo"
    TOT=$(( IN + OUT ))
    SOURCE="harness-reported"
    if [ "$TURNS" -eq 0 ]; then SOURCE="unavailable"; UREASON="transcript had no usage metadata: $TRANSCRIPT"; fi
  else
    SOURCE="unavailable"; UREASON="no JSON parser (python3/jq) available to read transcript"
  fi
else
  SOURCE="unavailable"; UREASON="no transcript path, manual counts, or usable hook input provided"
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SPEC_LINE="${SPEC:-session-total}"
[ -f "$TOKEN_FILE" ] || printf '# Token Usage\n' > "$TOKEN_FILE"
{
  printf '\n## %s - actual token usage (session total)\n\n' "$TS"
  printf '```yaml\n'
  printf -- '- ts: %s\n' "$TS"
  printf '  agent: session\n  stage: session-total\n  spec: %s\n  source: %s\n' "$SPEC_LINE" "$SOURCE"
  if [ "$SOURCE" = "unavailable" ]; then
    printf '  actual_input_tokens: null\n  actual_output_tokens: null\n  actual_total_tokens: null\n  unavailable_reason: %s\n' "$UREASON"
  else
    printf '  actual_input_tokens: %s\n  actual_output_tokens: %s\n  actual_total_tokens: %s\n' "$IN" "$OUT" "$TOT"
    if [ "$SOURCE" = "harness-reported" ]; then printf '  actual_cache_read_tokens: %s\n' "$CACHE_READ"; fi
    printf '  unavailable_reason:\n'
    if [ "$SOURCE" = "harness-reported" ]; then printf '  # input = fresh (input + cache_creation=%s); cache_read=%s reused at reduced rate; %s assistant turns\n' "$CACHE_CREATE" "$CACHE_READ" "$TURNS"; fi
  fi
  printf '```\n'
} >> "$TOKEN_FILE"

if [ "$SOURCE" = "unavailable" ]; then info "recorded source=unavailable in $TOKEN_FILE ($UREASON)"; else info "recorded $SOURCE actual: input=$IN output=$OUT total=$TOT -> $TOKEN_FILE"; fi

APPEND="$REPO_ROOT/.KCC/tools/backchannel-append.sh"
if [ -f "$APPEND" ]; then
  if [ "$SOURCE" = "unavailable" ]; then
    PAYLOAD="source=unavailable;unavailable_reason=$UREASON"
  else
    PAYLOAD="source=$SOURCE;actual_input_tokens=$IN;actual_output_tokens=$OUT;actual_total_tokens=$TOT"
    [ "$SOURCE" = "harness-reported" ] && PAYLOAD="$PAYLOAD;actual_cache_read_tokens=$CACHE_READ"
  fi
  if [ -n "$SPEC" ]; then
    bash "$APPEND" --kind actual-recorded --from butler --payload "$PAYLOAD" --spec "$SPEC" --no-dashboard >/dev/null 2>&1 || true
  else
    bash "$APPEND" --kind actual-recorded --from butler --payload "$PAYLOAD" --no-dashboard >/dev/null 2>&1 || true
  fi
fi

exit 0
