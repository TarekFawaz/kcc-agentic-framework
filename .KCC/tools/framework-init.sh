#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 native bash first-run initializer for macOS/Linux.
#
# The dsh harness entry point generates project-local .dsh skills only.
# The hardened kcc-autobuild DSH profile (Plan 08, Task 5) is NEVER
# installed silently: it is PRINTED by default and runs only with
# --install-dsh-profile (installers copy the profile only when explicitly
# invoked and framework-init never silently mutates DSH_HOME).
# The autobuild runtime (Plan 07, Task 5) is OPT-IN and PRINTED only:
# with --enable-autobuild framework-init checks the interpreter is
# Python 3.11+ and prints the runtime install command; it never runs an
# installer, and plain KCC init continues unchanged when Python 3.11+
# or the runtime is absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS="all"
INSTALL_DSH_PROFILE=0
ENABLE_AUTOBUILD=0
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
    --enable-autobuild|-EnableAutobuild)
      ENABLE_AUTOBUILD=1; shift ;;
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

echo
if [[ "$ENABLE_AUTOBUILD" == "0" ]]; then
  echo "Autobuild runtime not enabled - existing KCC init continues unchanged."
  echo "Re-run with --enable-autobuild to check Python 3.11+ and print the runtime install command."
else
  echo "Autobuild runtime (optional): Python 3.11+ check - print install command only, never execute."
  PYTHON_BIN="${KCC_AUTOBUILD_PYTHON:-python3}"
  RUNTIME_DIR="$REPO_ROOT/.KCC/runtime"
  if command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    PYVER="$(LC_ALL=C "$PYTHON_BIN" -c 'import sys; print(".".join(str(p) for p in sys.version_info[:3]))' 2>/dev/null || true)"
    if [[ -n "$PYVER" ]] && awk -v v="$PYVER" 'BEGIN { split(v, a, "."); exit !((a[1]*100 + a[2]) >= 311) }'; then
      echo "[autobuild] Autobuild runtime ready: Python $PYVER detected (>= 3.11). Install command (printed only, never executed):"
    elif [[ -n "$PYVER" ]]; then
      echo "[autobuild] Python $PYVER detected; Autobuild runtime requires Python 3.11+ (install command printed only, never executed):"
    else
      echo "[autobuild] Python version probe failed; Autobuild runtime requires Python 3.11+ (install command printed only, never executed):"
    fi
  else
    echo "[autobuild] $PYTHON_BIN not found; Autobuild runtime requires Python 3.11+ (install command printed only, never executed):"
  fi
  echo "[autobuild]   $PYTHON_BIN -m pip install -e '$RUNTIME_DIR'"
  echo "[autobuild] No silent install: existing KCC init continues even when the runtime is missing."
fi
