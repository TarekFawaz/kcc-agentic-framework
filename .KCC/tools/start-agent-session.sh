#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 native bash visible-session launcher for macOS/Linux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS="generic"
AGENT=""
TITLE="KCC agent session"
PROMPT_FILE=""
SANDBOX=0
ALLOW_NETWORK=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage:
  .KCC/tools/start-agent-session.sh --harness codex --agent planner --title "SPEC planner" --prompt-file prompt.md

Options:
  --harness claude|codex|opencode|generic|ollama
  --agent <name>
  --title <window title>
  --prompt-file <path>
  --sandbox
  --allow-network
  --yes
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness|-Harness) HARNESS="$2"; shift 2 ;;
    --agent|-Agent) AGENT="$2"; shift 2 ;;
    --title|-Title) TITLE="$2"; shift 2 ;;
    --prompt-file|--promptfile|-PromptFile) PROMPT_FILE="$2"; shift 2 ;;
    --repo-root|-RepoRoot) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --sandbox|-Sandbox) SANDBOX=1; shift ;;
    --allow-network|-AllowNetwork) ALLOW_NETWORK=1; shift ;;
    --yes|-Yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$AGENT" ]] || { echo "error: --agent is required" >&2; usage; exit 2; }
[[ -z "$PROMPT_FILE" || -f "$PROMPT_FILE" ]] || { echo "error: prompt file not found: $PROMPT_FILE" >&2; exit 1; }

prompt_arg=""
if [[ -n "$PROMPT_FILE" ]]; then
  prompt_arg=" < \"$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")\""
fi

case "$HARNESS" in
  claude) base_cmd="claude" ;;
  codex) base_cmd="codex" ;;
  opencode) base_cmd="opencode" ;;
  ollama) base_cmd="ollama run" ;;
  generic) base_cmd="${SHELL:-/bin/sh}" ;;
  *) echo "error: unsupported harness: $HARNESS" >&2; exit 2 ;;
esac

if (( SANDBOX == 1 )); then
  dockerfile="$REPO_ROOT/.KCC/sandbox/Dockerfile.$HARNESS"
  [[ -f "$dockerfile" ]] || dockerfile="$REPO_ROOT/.KCC/sandbox/Dockerfile.generic"
  image="kcc-${HARNESS}-agent:local"
  net_arg="--network none"
  (( ALLOW_NETWORK == 1 )) && net_arg=""
  run_cmd="docker build -t $image -f \"$dockerfile\" \"$REPO_ROOT\" && docker run --rm -it $net_arg -v \"$REPO_ROOT:/workspace\" -w /workspace $image $base_cmd$prompt_arg"
else
  run_cmd="cd \"$REPO_ROOT\" && $base_cmd$prompt_arg"
fi

echo "KCC session plan"
echo "  Harness : $HARNESS"
echo "  Agent   : $AGENT"
echo "  Title   : $TITLE"
echo "  Sandbox : $SANDBOX"
echo "  Command : $run_cmd"
echo

if (( ASSUME_YES == 0 )); then
  printf 'Open a visible terminal session now? [y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled. Command not launched."; exit 0 ;;
  esac
fi

if [[ "$OSTYPE" == darwin* ]] && command -v osascript >/dev/null 2>&1; then
  escaped="${run_cmd//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  osascript -e "tell application \"Terminal\" to do script \"$escaped\""
elif command -v gnome-terminal >/dev/null 2>&1; then
  gnome-terminal --title="$TITLE" -- bash -lc "$run_cmd"
elif command -v konsole >/dev/null 2>&1; then
  konsole --new-tab --workdir "$REPO_ROOT" -e bash -lc "$run_cmd" >/dev/null 2>&1 &
elif command -v xterm >/dev/null 2>&1; then
  xterm -T "$TITLE" -e bash -lc "$run_cmd" >/dev/null 2>&1 &
else
  echo "No supported terminal app found. Run this command manually:"
  echo "$run_cmd"
fi
