#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 native bash first-run initializer for macOS/Linux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS="all"
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    claude|codex|opencode|generic|ollama|all)
      HARNESS="$1"; shift ;;
    --harness|-Harness)
      HARNESS="$2"; shift 2 ;;
    --repo-root|-RepoRoot)
      REPO_ROOT="$(cd "$2" && pwd)"
      ARGS+=(--repo-root "$REPO_ROOT")
      shift 2 ;;
    --install-codex-skills|-InstallCodexSkills)
      ARGS+=(--install-codex-skills); shift ;;
    --install-codex-prompts|-InstallCodexPrompts)
      ARGS+=(--install-codex-prompts); shift ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

echo
echo "Initializing KCC framework for harness: $HARNESS"
echo "Repo root: $REPO_ROOT"
echo

exec "$SCRIPT_DIR/sync-adapters.sh" "$HARNESS" "${ARGS[@]}"
