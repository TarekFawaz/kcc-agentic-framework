#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC hardened DSH profile installer (Plan 08, Task 5).
#
# EXPLICIT ONLY: this installer copies the hardened kcc-autobuild profile
# into $DSH_HOME/profiles and installs the repo adapter via
#   dsh plugin --profile kcc-autobuild add .KCC/adapters/dsh/plugin
# Nothing DSH_HOME-related runs implicitly: framework-init only PRINTS
# the command below by default.
#
#   bash .KCC/adapters/dsh/install.sh
#
# Options:
#   --dsh-home DIR          DSH home (default: $DSH_HOME or ~/.dsh)
#   --profile NAME          profile name (default: kcc-autobuild)
#   --gate-command CMD      local kcc-autobuild CLI (default: $KCC_AUTOBUILD_GATE_COMMAND or kcc-autobuild)
#   --python PY             python with kcc_autobuild installed (default: $KCC_AUTOBUILD_PYTHON or python3)
#   --credentials-file F    credentials document of the host dsh home
#   --rules-file F          JSON array of exact-match policy rules (default: empty = fail closed)
#   --force                 replace an already installed profile
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADAPTER_DIR="$SCRIPT_DIR"

DSH_HOME_VALUE="${DSH_HOME:-$HOME/.dsh}"
PROFILE_NAME="kcc-autobuild"
GATE_COMMAND="${KCC_AUTOBUILD_GATE_COMMAND:-kcc-autobuild}"
PYTHON="${KCC_AUTOBUILD_PYTHON:-python3}"
CREDENTIALS_FILE=""
RULES_FILE=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dsh-home) DSH_HOME_VALUE="$2"; shift 2 ;;
    --profile) PROFILE_NAME="$2"; shift 2 ;;
    --gate-command) GATE_COMMAND="$2"; shift 2 ;;
    --python) PYTHON="$2"; shift 2 ;;
    --credentials-file) CREDENTIALS_FILE="$2"; shift 2 ;;
    --rules-file) RULES_FILE="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

if [[ -z "$CREDENTIALS_FILE" ]]; then
  CREDENTIALS_FILE="$DSH_HOME_VALUE/.credentials.yaml"
fi

# --- Preconditions (fail closed, nothing DSH_HOME-related happens silently)
command -v dsh >/dev/null 2>&1 || { echo "error: dsh CLI not found on PATH" >&2; exit 1; }
command -v pnpm >/dev/null 2>&1 || { echo "error: pnpm not found (dsh plugin forwards to pnpm)" >&2; exit 1; }
[[ -d "$ADAPTER_DIR/plugin" ]] || { echo "error: repo adapter missing: $ADAPTER_DIR/plugin" >&2; exit 1; }
"$PYTHON" -c "import kcc_autobuild" 2>/dev/null || {
  echo "error: $PYTHON cannot import kcc_autobuild (use --python with the runtime venv)" >&2; exit 1;
}

# Plugin peer scope: the linked plugin resolves its imports from its own
# realpath, so the dsh installation's @deepseek-ai scope is linked into
# plugin/node_modules (exactly like dsh-agentmemory's checkout does).
DSH_BIN_REAL="$(readlink -f "$(command -v dsh)")"   # .../@deepseek-ai/dsh/lib/bin.js
DSH_PKG_DIR="$(cd "$(dirname "$DSH_BIN_REAL")/.." && pwd)"  # .../@deepseek-ai/dsh
SCOPE_DIR="$DSH_PKG_DIR/node_modules/@deepseek-ai"
[[ -d "$SCOPE_DIR" ]] || { echo "error: cannot resolve the dsh @deepseek-ai scope: $SCOPE_DIR" >&2; exit 1; }

PROFILE_DIR="$DSH_HOME_VALUE/profiles/$PROFILE_NAME"
GATE_DIR="$PROFILE_DIR/gate"
GATE_BUNDLE_FILE="$GATE_DIR/policy-bundle.json"
GATE_SECRET_FILE="$GATE_DIR/.gate-secret"

echo
echo "KCC hardened $PROFILE_NAME profile installer"
echo "  DSH_HOME:     $DSH_HOME_VALUE"
echo "  profile:      $PROFILE_NAME"
echo "  gate command: $GATE_COMMAND"
echo "  credentials:  $CREDENTIALS_FILE"
echo

if [[ -f "$PROFILE_DIR/package.json" && "$FORCE" == "0" ]]; then
  echo "error: profile $PROFILE_NAME already installed at $PROFILE_DIR (use --force to replace)" >&2
  exit 1
fi

# 1. Profile manifest + root composition seed (base + headless bundles).
mkdir -p "$PROFILE_DIR" "$GATE_DIR"
cp "$ADAPTER_DIR/profile/package.json" "$PROFILE_DIR/package.json"
cp "$ADAPTER_DIR/profile/cordis.yml" "$PROFILE_DIR/cordis.yml"
cp "$ADAPTER_DIR/profile/pnpm-workspace.yaml" "$PROFILE_DIR/pnpm-workspace.yaml"

# 2. Hardened patch layer (machine-local substitutions).
sed \
  -e "s|{{KCC_PROFILE_GATE_COMMAND}}|$GATE_COMMAND|g" \
  -e "s|{{KCC_PROFILE_GATE_BUNDLE_FILE}}|$GATE_BUNDLE_FILE|g" \
  -e "s|{{KCC_PROFILE_GATE_SECRET_FILE}}|$GATE_SECRET_FILE|g" \
  -e "s|{{KCC_PROFILE_CREDENTIALS_FILE}}|$CREDENTIALS_FILE|g" \
  "$ADAPTER_DIR/profile/cordis.patch.yml" > "$PROFILE_DIR/cordis.patch.yml"
echo "[install   ] hardened patch: $PROFILE_DIR/cordis.patch.yml"

# 3. Plugin peer scope (module resolution from the linked realpath).
mkdir -p "$ADAPTER_DIR/plugin/node_modules"
ln -sfn "$SCOPE_DIR" "$ADAPTER_DIR/plugin/node_modules/@deepseek-ai"
echo "[install   ] plugin peer scope: $ADAPTER_DIR/plugin/node_modules/@deepseek-ai -> $SCOPE_DIR"

# 4. Signed policy bundle + owner-only secret (default: empty = fail closed).
if [[ -n "$RULES_FILE" ]]; then
  RULES_ARGS=(--rules-file "$RULES_FILE")
else
  RULES_ARGS=()
fi
"$PYTHON" "$ADAPTER_DIR/gate/sign-policy.py" --out-dir "$GATE_DIR" "${RULES_ARGS[@]}"

# 5. Install the repo adapter into the profile (explicit, contract step).
( cd "$REPO_ROOT" && DSH_HOME="$DSH_HOME_VALUE" dsh plugin --profile "$PROFILE_NAME" add "$ADAPTER_DIR/plugin" )
echo "[install   ] repo adapter installed: dsh plugin --profile $PROFILE_NAME add $ADAPTER_DIR/plugin"

# 6. Post-install boot proof (composition only; the live provider proof is
#    the doctor's job: kcc-autobuild harness doctor dsh --live --template kcc-autobuild).
cd "$REPO_ROOT"
DSH_HOME="$DSH_HOME_VALUE" dsh --profile "$PROFILE_NAME" --dump-config > "$PROFILE_DIR/.boot-config.txt"
if grep -q "kcc-policy-gate" "$PROFILE_DIR/.boot-config.txt"; then
  echo "[install   ] boot proof: $PROFILE_NAME profile composes the kcc-policy-gate row"
else
  echo "error: $PROFILE_NAME profile boot does not compose the kcc-policy-gate row" >&2
  exit 1
fi

echo
echo "Hardened $PROFILE_NAME profile installed."
echo "  Live proof:  kcc-autobuild harness doctor dsh --live --template $PROFILE_NAME"
echo "  Worker run:  dsh --profile $PROFILE_NAME \"<bounded task prompt>\""
echo "  framework-init prints this command by default (add --install-dsh-profile to run it)."
