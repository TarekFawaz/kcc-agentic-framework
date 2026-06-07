#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# Detect whether a build/test toolchain is present, and suggest per-OS
# install commands for whatever is missing.
#
# Detection + suggestion only. This script NEVER installs anything. Toolchain
# install is a human-gated, system-mutating action (see
# .KCC/kernel/protocols/toolchain-preflight.md). The agent runs installs at
# runtime only after explicit human approval.
#
# Usage:
#   .KCC/tools/toolchain-preflight.sh node pnpm git
#
# Exit code: 0 if all tools are present, 1 if any tool is missing.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: toolchain-preflight.sh <tool> [<tool> ...]" >&2
  exit 2
fi

# Detect the current OS family.
os_family() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) echo "linux" ;;
  esac
}

# Pick a Linux package-manager hint.
linux_installer() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt-get install -y"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf install -y"; return; fi
  echo "apt-get install -y"
}

# Suggest an install command for a missing tool on the current OS.
install_suggestion() {
  local tool="$1" os="$2"
  # Tool-specific globals first.
  case "$tool" in
    pnpm) echo "corepack enable; corepack prepare pnpm@latest --activate   (or: npm i -g pnpm)"; return ;;
    cargo) echo "install rustup from https://rustup.rs (rustup-init), then: rustup default stable"; return ;;
    flutter) echo "install Flutter SDK from https://docs.flutter.dev/get-started/install"; return ;;
  esac

  case "$os" in
    macos)
      case "$tool" in
        node|npm) echo "brew install node" ;;
        git) echo "brew install git" ;;
        python) echo "brew install python" ;;
        go) echo "brew install go" ;;
        dotnet) echo "brew install --cask dotnet-sdk" ;;
        terraform) echo "brew install terraform" ;;
        kubectl) echo "brew install kubectl" ;;
        helm) echo "brew install helm" ;;
        dart) echo "brew install dart" ;;
        *) echo "brew install $tool" ;;
      esac ;;
    windows)
      case "$tool" in
        node|npm) echo "winget install OpenJS.NodeJS.LTS   (fallback: choco/scoop)" ;;
        git) echo "winget install Git.Git" ;;
        python) echo "winget install Python.Python.3.12" ;;
        go) echo "winget install GoLang.Go" ;;
        dotnet) echo "winget install Microsoft.DotNet.SDK.8" ;;
        terraform) echo "winget install HashiCorp.Terraform" ;;
        kubectl) echo "winget install Kubernetes.kubectl" ;;
        helm) echo "winget install Helm.Helm" ;;
        dart) echo "winget install Google.DartSDK" ;;
        *) echo "winget install <package-for-$tool>" ;;
      esac ;;
    *)
      local inst pkg
      inst="$(linux_installer)"
      case "$tool" in
        node) pkg="nodejs" ;;
        go) pkg="golang-go" ;;
        python) pkg="python3" ;;
        dotnet) pkg="dotnet-sdk-8.0" ;;
        *) pkg="$tool" ;;
      esac
      echo "sudo $inst $pkg   (may require elevation)" ;;
  esac
}

os="$(os_family)"
missing=()

echo "Toolchain preflight (OS: $os)"
echo "-----------------------------------"

for tool in "$@"; do
  if command -v "$tool" >/dev/null 2>&1; then
    version="$("$tool" --version 2>/dev/null | head -n 1 || true)"
    [[ -z "$version" ]] && version="present"
    printf 'PRESENT  %s  (%s)\n' "$tool" "$version"
  else
    missing+=("$tool")
    printf 'MISSING  %s\n' "$tool"
    printf '         install: %s\n' "$(install_suggestion "$tool" "$os")"
  fi
done

echo "-----------------------------------"
if [[ ${#missing[@]} -gt 0 ]]; then
  printf 'MISSING TOOLS: %s\n' "$(IFS=', '; echo "${missing[*]}")"
  echo "Toolchain install is a HUMAN-GATED action. Do NOT install silently."
  echo "See .KCC/kernel/protocols/toolchain-preflight.md (install / human-install / defer)."
  exit 1
fi

echo "All required tools are present."
exit 0
