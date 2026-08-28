#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 native bash first-run initializer for macOS/Linux.
#
# The dsh harness entry point generates project-local .dsh skills only.
# The hardened kcc-autobuild DSH profile (Plan 08, Task 5) is NEVER
# installed silently: it is PRINTED by default and runs only with
# --install-dsh-profile (installers copy the profile only when explicitly
# invoked and framework-init never silently mutates DSH_HOME).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS="all"
INSTALL_DSH_PROFILE=0
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    claude|codex|opencode|generic|ollama|dsh|all)
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
    --install-dsh-profile|-InstallDshProfile)
      INSTALL_DSH_PROFILE=1; shift ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

echo
echo "Initializing KCC framework for harness: $HARNESS"
echo "Repo root: $REPO_ROOT"
echo

bash "$SCRIPT_DIR/sync-adapters.sh" "$HARNESS" "${ARGS[@]}"

if [[ "$HARNESS" == "dsh" || "$HARNESS" == "all" ]]; then
  echo
  echo "dsh hardened profile (Plan 08, Task 5): the kcc-autobuild profile is"
  echo "NOT installed by default (no silent DSH_HOME mutation)."
  echo
  INSTALL_SCRIPT="$REPO_ROOT/.KCC/adapters/dsh/install.sh"
  echo "  install:    bash '$INSTALL_SCRIPT'"
  echo "  live proof: kcc-autobuild harness doctor dsh --live --template kcc-autobuild"
  echo
  if [[ "$INSTALL_DSH_PROFILE" == "1" ]]; then
    echo "[dsh      ] executing the explicit DSH profile installer:"
    bash "$INSTALL_SCRIPT"
  else
    echo "[dsh      ] profile installer NOT executed (re-run with --install-dsh-profile to install)."
  fi
fi
