#!/usr/bin/env sh
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# Installs the kcc command line on macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/TarekFawaz/kcc-agentic-framework/main/install.sh | sh
#
# Options (flags, or the matching environment variable):
#   --version <x.y.z>    KCC_VERSION       release to install (default: latest)
#   --dir <path>         KCC_INSTALL_DIR   target folder (default: ~/.local/bin)
#   --from <file>                          install a local binary instead of downloading
#
# The binary is self-contained: no Node and no PowerShell are needed.
set -eu

REPO="TarekFawaz/kcc-agentic-framework"
VERSION="${KCC_VERSION:-latest}"
DIR="${KCC_INSTALL_DIR:-$HOME/.local/bin}"
FROM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    -h|--help) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) echo "install.sh: unsupported system $os. On Windows use install.ps1." >&2; exit 2 ;;
esac
case "$arch" in
  x86_64|amd64) arch=x64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "install.sh: unsupported CPU $arch" >&2; exit 2 ;;
esac
asset="kcc-$os-$arch"

fetch() { # url, output file
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -q "$1" -O "$2"
  else echo "install.sh: curl or wget is required" >&2; exit 2; fi
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

mkdir -p "$DIR"
target="$DIR/kcc"

if [ -n "$FROM" ]; then
  [ -f "$FROM" ] || { echo "install.sh: file not found: $FROM" >&2; exit 2; }
  cp "$FROM" "$target"
else
  if [ "$VERSION" = "latest" ]; then base="https://github.com/$REPO/releases/latest/download"
  else base="https://github.com/$REPO/releases/download/v${VERSION#v}"; fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading $base/$asset"
  fetch "$base/$asset" "$tmp/$asset"
  fetch "$base/checksums.txt" "$tmp/checksums.txt"
  expected="$(awk -v a="$asset" '{ n = $2; sub(/^\*/, "", n); if (n == a) print $1 }' "$tmp/checksums.txt")"
  [ -n "$expected" ] || { echo "install.sh: checksums.txt has no entry for $asset" >&2; exit 1; }
  actual="$(sha256 "$tmp/$asset")"
  if [ "$actual" != "$expected" ]; then
    echo "install.sh: checksum mismatch for $asset (expected $expected, got $actual). Nothing was installed." >&2
    exit 1
  fi
  cp "$tmp/$asset" "$target"
fi
chmod +x "$target"
# The binaries are cross-compiled and unsigned; Apple Silicon refuses to run unsigned code.
if [ "$os" = "darwin" ] && command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$target" >/dev/null 2>&1 || true
fi

echo "Installed: $target"
"$target" version

case ":$PATH:" in
  *":$DIR:"*) ;;
  *) echo
     echo "$DIR is not on your PATH. Add this line to your shell profile:"
     echo "  export PATH=\"$DIR:\$PATH\"" ;;
esac
echo
echo "Next: cd into your project and run  kcc init"
