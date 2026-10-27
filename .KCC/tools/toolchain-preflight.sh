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

# A tool may carry a major-version constraint from plan.md '## Toolchain': node@>=20, node@20, node@>=20<25.
version_ok() { # $1 version text, $2 constraint
  local major op n rest
  [[ -z "$2" ]] && return 0
  major="$(printf '%s' "$1" | grep -oE '[0-9]+' | head -n 1)"
  [[ -z "$major" ]] && return 0
  if [[ "$2" =~ ^[0-9]+$ ]]; then [[ "$major" -eq "$2" ]]; return; fi
  rest="$2"
  while [[ "$rest" =~ ^(\>=|\<=|\>|\<|=)([0-9]+)(.*)$ ]]; do
    op="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
    case "$op" in
      ">=") [[ "$major" -ge "$n" ]] || return 1 ;;
      "<=") [[ "$major" -le "$n" ]] || return 1 ;;
      ">") [[ "$major" -gt "$n" ]] || return 1 ;;
      "<") [[ "$major" -lt "$n" ]] || return 1 ;;
      "=") [[ "$major" -eq "$n" ]] || return 1 ;;
    esac
  done
  return 0
}

for spec in "$@"; do
  tool="${spec%%@*}"; constraint=""
  [[ "$spec" == *@* ]] && constraint="${spec#*@}"
  if command -v "$tool" >/dev/null 2>&1; then
    version="$("$tool" --version 2>/dev/null | head -n 1 || true)"
    [[ -z "$version" ]] && version="present"
    if version_ok "$version" "$constraint"; then
      printf 'PRESENT  %s  (%s)\n' "$tool" "$version"
    else
      missing+=("$tool@$constraint")
      printf 'WRONG    %s  (%s; the plan needs %s)\n' "$tool" "$version" "$constraint"
      printf '         install: %s\n' "$(install_suggestion "$tool" "$os")"
    fi
  else
    missing+=("$tool")
    printf 'MISSING  %s\n' "$tool"
    printf '         install: %s\n' "$(install_suggestion "$tool" "$os")"
  fi
done

# Environment limits a run should know before it spends time on them. A Docker daemon that cannot reach a registry (TLS interception by
# a proxy or antivirus, no network) fails every image pull and build; one tiny pull here tells the verifier to defer those checks at
# once instead of finding out after a 20-minute build attempt (round 12). Printed as `LIMIT <what>: <why>`; never a missing tool.
probe_docker_registry() {
  local out rc=0 t=()
  # The daemon first: `docker` on PATH with Docker Desktop (or the service) stopped is not a registry problem (round 14 named it one).
  if ! docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
    echo 'LIMIT docker-daemon unreachable: docker is installed but its daemon is not running (start Docker Desktop or the docker service); image pulls, builds and compose up will fail until it is'
    return 0
  fi
  command -v timeout >/dev/null 2>&1 && t=(timeout 90)
  out="$("${t[@]}" docker pull -q hello-world:latest 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    out="$(printf '%s\n' "$out" | { grep -vE '^[[:space:]]*$' || true; } | tail -n 1 | cut -c1-200)"
    printf 'LIMIT docker-registry unreachable: the Docker daemon cannot pull from the registry (exit %s: %s); image builds and compose up --build will fail on this machine\n' "$rc" "${out:-no output}"
    return 0
  fi
  echo "PROBE    docker-registry reachable (docker pull hello-world)"
  # The daemon may trust the proxy's certificate while the build containers do not (Docker Desktop behind an antivirus: npm ci inside
  # RUN fails with UNABLE_TO_VERIFY_LEAF_SIGNATURE, BuildKit cannot fetch its frontend). One RUN that opens a TLS connection shows it.
  local d; d="$(mktemp -d 2>/dev/null || mktemp -d -t kccprobe)"
  printf 'FROM alpine:3.21\nRUN wget -q -O /dev/null https://registry.npmjs.org/-/ping\n' > "$d/Dockerfile"
  local ctx="$d"; if command -v cygpath >/dev/null 2>&1; then ctx="$(cygpath -w "$d")"; fi
  rc=0; out="$("${t[@]}" docker build --no-cache -q -t kcc-preflight-probe "$ctx" 2>&1)" || rc=$?
  rm -rf "$d"; docker image rm -f kcc-preflight-probe >/dev/null 2>&1 || true
  if [[ $rc -eq 0 ]]; then echo "PROBE    docker-build-network reachable (a RUN step reached registry.npmjs.org over TLS)"; return 0; fi
  out="$(printf '%s\n' "$out" | { grep -iE 'certificate|x509|tls|ssl|unable to|could not resolve|network|error' || true; } | tail -n 1 | cut -c1-200)"
  printf 'LIMIT docker-build-network unreachable: a RUN step inside a build cannot reach registries over TLS (exit %s: %s); npm ci / pip install / apk inside docker build and compose up --build will fail on this machine (a proxy or antivirus intercepts TLS; see KCC_CA_BUNDLE)\n' "$rc" "${out:-no matching output}"
}
for spec in "$@"; do
  if [[ "${spec%%@*}" == "docker" ]] && command -v docker >/dev/null 2>&1; then probe_docker_registry; break; fi
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
