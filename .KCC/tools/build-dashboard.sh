#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 native bash dashboard generator for macOS/Linux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPEN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root|-RepoRoot)
      REPO_ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    --open|-Open)
      OPEN=1
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

json_field() {
  local line="$1"
  local keys="$2"
  local key value
  IFS='|' read -r -a key_list <<< "$keys"
  for key in "${key_list[@]}"; do
    value="$(printf '%s\n' "$line" | sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" | head -n 1)"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done
  printf ''
}

count_dirs() {
  local dir="$1"
  local pattern="$2"
  if [[ -d "$dir" ]]; then
    find "$dir" -maxdepth 1 -type d -name "$pattern" | wc -l | tr -d '[:space:]'
  else
    printf '0'
  fi
}

count_files() {
  local dir="$1"
  local pattern="$2"
  if [[ -d "$dir" ]]; then
    find "$dir" -type f -name "$pattern" | wc -l | tr -d '[:space:]'
  else
    printf '0'
  fi
}

OUT_DIR="$REPO_ROOT/dashboard"
OUT_FILE="$OUT_DIR/index.html"
mkdir -p "$OUT_DIR"

IDEAS="$(count_dirs "$REPO_ROOT/ideation" 'IDEA-*')"
SPECS="$(count_dirs "$REPO_ROOT/specs" 'SPEC-*')"
if [[ -d "$REPO_ROOT/specs" ]]; then
  SPECS="$(find "$REPO_ROOT/specs" -type d -name 'SPEC-*' | wc -l | tr -d '[:space:]')"
fi
BACKLOG_ITEMS="$(count_files "$REPO_ROOT/specs" '*.md')"
SESSIONS="$(count_dirs "$REPO_ROOT/Traces" 'Session-*')"
MEMORY_ENTRIES="$(count_files "$REPO_ROOT/memory" '*.md')"
EVENTS=0
LOG="$REPO_ROOT/coordination/backchannel.jsonl"
if [[ -f "$LOG" ]]; then
  EVENTS="$(grep -cve '^[[:space:]]*$' "$LOG" || true)"
fi

{
  cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>KCC Dashboard</title>
<style>
  :root{--bg:#0f1117;--panel:#171a23;--line:#262b38;--fg:#e6e9ef;--mut:#8a92a6;--acc:#4f8cff}
  *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,Segoe UI,Roboto,Arial,sans-serif}
  header{padding:18px 24px;border-bottom:1px solid var(--line)} h1{margin:0;font-size:18px}.sub{color:var(--mut);font-size:12px}
  main{padding:20px 24px;max-width:1120px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:12px;margin-bottom:18px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px}.num{font-size:24px;font-weight:700}.lbl{color:var(--mut)}
  table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line)} th,td{padding:8px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top} th{color:var(--mut);font-weight:600}
  code{font-family:Consolas,Menlo,monospace}.empty{color:var(--mut);font-style:italic}
</style>
</head>
<body>
<header>
  <h1>KCC Dashboard</h1>
  <div class="sub">Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) from $(printf '%s' "$REPO_ROOT" | html_escape)</div>
</header>
<main>
<section class="grid">
  <div class="card"><div class="num">$IDEAS</div><div class="lbl">Ideas</div></div>
  <div class="card"><div class="num">$SPECS</div><div class="lbl">Specs</div></div>
  <div class="card"><div class="num">$BACKLOG_ITEMS</div><div class="lbl">Backlog/docs</div></div>
  <div class="card"><div class="num">$EVENTS</div><div class="lbl">Backchannel events</div></div>
  <div class="card"><div class="num">$SESSIONS</div><div class="lbl">Trace sessions</div></div>
  <div class="card"><div class="num">$MEMORY_ENTRIES</div><div class="lbl">Memory docs</div></div>
</section>
<section class="card">
  <h2>Recent Activity</h2>
EOF
  if [[ ! -f "$LOG" || "$EVENTS" == "0" ]]; then
    echo '<p class="empty">No backchannel events yet.</p>'
  else
    echo '<table><thead><tr><th>Time</th><th>Kind</th><th>From</th><th>Scope</th><th>Payload</th></tr></thead><tbody>'
    tail -n 50 "$LOG" | while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "${line//[[:space:]]/}" ]] && continue
      ts="$(json_field "$line" 'ts|timestamp')"
      kind="$(json_field "$line" 'kind|event')"
      from="$(json_field "$line" 'from|agent|source')"
      spec="$(json_field "$line" 'spec|idea_id|target')"
      printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td><td><code>%s</code></td></tr>\n' \
        "$(printf '%s' "$ts" | html_escape)" \
        "$(printf '%s' "$kind" | html_escape)" \
        "$(printf '%s' "$from" | html_escape)" \
        "$(printf '%s' "$spec" | html_escape)" \
        "$(printf '%s' "$line" | html_escape)"
    done
    echo '</tbody></table>'
  fi
  cat <<EOF
</section>
</main>
</body>
</html>
EOF
} > "$OUT_FILE"

echo "Dashboard written to $OUT_FILE"
echo "  ideas=$IDEAS specs=$SPECS events=$EVENTS sessions=$SESSIONS memory=$MEMORY_ENTRIES"

if [[ "$OPEN" -eq 1 ]]; then
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$OUT_FILE" >/dev/null 2>&1 &
  elif command -v open >/dev/null 2>&1; then
    open "$OUT_FILE" >/dev/null 2>&1 &
  else
    echo "Open not supported on this host; file is at $OUT_FILE"
  fi
fi
