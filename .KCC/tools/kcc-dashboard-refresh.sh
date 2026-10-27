#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# Claude Code hook (PostToolUse, SubagentStop): keeps dashboard/index.html live while a run works.
# A chat-driven `auto` run only rewrote the dashboard at stage ends, so the page showed no working
# agents and no progress in between. This hook rebuilds it in the background, at most every
# KCC_DASHBOARD_REFRESH_SECONDS (default 15), and only in a workspace that has a run (a backchannel).
# It never blocks or fails the tool call. Mirror: kcc-dashboard-refresh.ps1.
ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
cat >/dev/null 2>&1 || true
[ -f "$ROOT/coordination/backchannel.jsonl" ] || exit 0
stamp="$ROOT/dashboard/.refresh"
now="$(date +%s)"; last=0
[ -f "$stamp" ] && last="$(cat "$stamp" 2>/dev/null || echo 0)"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
min="${KCC_DASHBOARD_REFRESH_SECONDS:-15}"
[ $((now - last)) -ge "$min" ] || exit 0
mkdir -p "$ROOT/dashboard" 2>/dev/null && printf '%s' "$now" > "$stamp" 2>/dev/null
if command -v powershell >/dev/null 2>&1 && [ -f "$ROOT/.KCC/tools/build-dashboard.ps1" ]; then
  (nohup powershell -NoProfile -ExecutionPolicy Bypass -File "$ROOT/.KCC/tools/build-dashboard.ps1" -RepoRoot "$ROOT" >/dev/null 2>&1 &)
elif [ -f "$ROOT/.KCC/tools/build-dashboard.sh" ]; then
  (nohup bash "$ROOT/.KCC/tools/build-dashboard.sh" --repo-root "$ROOT" >/dev/null 2>&1 &)
fi
exit 0
