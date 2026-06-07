#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# bootstrap-mac-linux.sh
# -----------------------------------------------------------------------------
# First-run helper for macOS / Linux users.
#
# 1. Checks basic POSIX tools used by the native bash entrypoints.
# 2. Marks every .sh tool in .KCC/tools/ and tools/ as executable.
# 3. Runs a smoke test against validate-kcc.sh to confirm the toolchain works.
#
# Why this exists: the .sh tools may be committed from Windows and ship without
# the filesystem executable bit. Running this once after clone unblocks all the
# .sh entrypoints. Safe to re-run.
# -----------------------------------------------------------------------------

set -euo pipefail

# Resolve repo root (this script lives at {repo}/.KCC/tools/bootstrap-mac-linux.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "KCC bootstrap for macOS / Linux"
echo "Repo root: $REPO_ROOT"
echo

# ---------- Step 1: check native bash dependencies ----------
missing_cmds=()
for cmd in bash find sed awk grep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing_cmds+=("$cmd")
    fi
done
if (( ${#missing_cmds[@]} > 0 )); then
    echo "ERROR: missing required command(s): ${missing_cmds[*]}"
    echo "Install the missing command(s), then re-run this bootstrap."
    exit 1
fi
echo "OK: native bash dependencies present"
echo

# ---------- Step 2: chmod +x every .sh tool ----------
echo "Making .sh tools executable..."
SH_FILES=(
    "$REPO_ROOT/.KCC/tools/framework-init.sh"
    "$REPO_ROOT/.KCC/tools/sync-adapters.sh"
    "$REPO_ROOT/.KCC/tools/validate-kcc.sh"
    "$REPO_ROOT/.KCC/tools/adapt-workflow.sh"
    "$REPO_ROOT/.KCC/tools/show-backchannel.sh"
    "$REPO_ROOT/.KCC/tools/start-agent-session.sh"
    "$REPO_ROOT/.KCC/tools/bootstrap-mac-linux.sh"
    "$REPO_ROOT/tools/framework-init.sh"
    "$REPO_ROOT/tools/sync-adapters.sh"
    "$REPO_ROOT/tools/validate-kcc.sh"
    "$REPO_ROOT/tools/adapt-workflow.sh"
    "$REPO_ROOT/tools/show-backchannel.sh"
    "$REPO_ROOT/tools/start-agent-session.sh"
)
fixed=0
missing=0
for f in "${SH_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        chmod +x "$f"
        fixed=$((fixed + 1))
    else
        echo "  WARN: not found: $f"
        missing=$((missing + 1))
    fi
done
echo "OK: made $fixed file(s) executable; $missing missing"
echo

# ---------- Step 3: smoke test ----------
echo "Smoke test: running validate-kcc.sh..."
if "$REPO_ROOT/.KCC/tools/validate-kcc.sh" >/dev/null 2>&1; then
    echo "OK: validate-kcc passed"
else
    echo "WARN: validate-kcc returned non-zero. Run it directly for details:"
    echo "      $REPO_ROOT/.KCC/tools/validate-kcc.sh"
fi
echo

echo "Bootstrap complete."
echo
echo "Next steps:"
echo "  1. Initialize the framework for your harness:"
echo "       ./.KCC/tools/framework-init.sh <harness>     # claude | codex | opencode | generic | ollama"
echo "  2. Or sync existing adapters:"
echo "       ./.KCC/tools/sync-adapters.sh"
echo "  3. Or start a sandboxed session:"
echo "       ./.KCC/tools/start-agent-session.sh --sandbox --harness claude"
echo
echo "See QUICKSTART.md for the full guided tour."
