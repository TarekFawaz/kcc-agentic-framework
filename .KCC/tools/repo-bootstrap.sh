#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
#
# repo-bootstrap.sh - detect and settle the workspace repo state before the
# first lifecycle write. Mirror of repo-bootstrap.ps1.
# Protocol: .KCC/kernel/protocols/repo-bootstrap.md
# Contract: .KCC/kernel/contracts/tool-contract.md
#
# Usage:
#   bash .KCC/tools/repo-bootstrap.sh [--repo-root PATH] [--json]                  # detect
#   bash .KCC/tools/repo-bootstrap.sh --apply init-local|connect-remote|skip \
#        [--remote-url URL] [--dry-run] [--emit] [--json]
#   bash .KCC/tools/repo-bootstrap.sh --install-hook [--dry-run]
#     (installs pre-commit, commit-msg, and pre-push; see git-workflow.md)
#
# Never pushes. Never reads, stores, or echoes credentials: auth is detected
# by kind only (credential helper configured, `gh auth status` exit code,
# ssh-agent reachable). Remote URLs carrying credentials are rejected.
# Exit: 0 ok | 1 violation/failed action | 2 usage/environment
set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=""
JSON=0
APPLY=""
REMOTE_URL=""
DRY_RUN=0
INSTALL_HOOK=0
EMIT=0
HOOK_MARKER="KCC-PRE-COMMIT"
HOOK_NAMES="pre-commit commit-msg pre-push"
hook_marker() { case "$1" in pre-commit) echo "KCC-PRE-COMMIT" ;; commit-msg) echo "KCC-COMMIT-MSG" ;; pre-push) echo "KCC-PRE-PUSH" ;; esac; }

usage() {
  cat >&2 <<'EOF'
usage: repo-bootstrap.sh [--repo-root PATH] [--json]
       repo-bootstrap.sh --apply init-local|connect-remote|skip [--remote-url URL] [--dry-run] [--emit] [--json]
       repo-bootstrap.sh --install-hook [--dry-run] [--json]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root|-RepoRoot) [[ $# -ge 2 ]] || { usage; exit 2; }; REPO_ROOT="$2"; shift 2 ;;
    --apply|-Apply) [[ $# -ge 2 ]] || { usage; exit 2; }; APPLY="$2"; shift 2 ;;
    --remote-url|-RemoteUrl) [[ $# -ge 2 ]] || { usage; exit 2; }; REMOTE_URL="$2"; shift 2 ;;
    --json|-Json) JSON=1; shift ;;
    --dry-run|-DryRun) DRY_RUN=1; shift ;;
    --install-hook|-InstallHook) INSTALL_HOOK=1; shift ;;
    --emit|-Emit) EMIT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

die_usage() { echo "error: $*" >&2; exit 2; }

case "$APPLY" in ""|init-local|connect-remote|skip) ;; *) die_usage "--apply must be init-local, connect-remote, or skip" ;; esac
if [[ -n "$REMOTE_URL" && "$APPLY" != "connect-remote" ]]; then die_usage "--remote-url is only valid with --apply connect-remote"; fi

if [[ -z "$REPO_ROOT" ]]; then
  PARENT="$(dirname "$SCRIPT_DIR")"
  if [[ "$(basename "$PARENT")" == ".KCC" ]]; then REPO_ROOT="$(dirname "$PARENT")"; else REPO_ROOT="$PARENT"; fi
fi
[[ -d "$REPO_ROOT" ]] || die_usage "repo root not found: $REPO_ROOT"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
SETTINGS_FILE="$REPO_ROOT/.KCC/settings.json"
HOOK_SRC_DIR="$SCRIPT_DIR/hooks"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}
jstr() { if [[ -z "$1" ]]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }
g() { git -C "$REPO_ROOT" "$@"; }

# ---------------------------------------------------------------- findings
V_ID=(); V_SEV=(); V_OWNER=(); V_FILE=(); V_MSG=()
ACTIONS=()
add_v() { V_ID+=("$1"); V_SEV+=("$2"); V_OWNER+=("$3"); V_FILE+=("$4"); V_MSG+=("$5"); }
act() { ACTIONS+=("$1"); }

# ---------------------------------------------------------------- URL safety
# Redact userinfo on http(s) URLs and any user:pass form; strip secret-looking query values.
redact_url() {
  local u="$1" q=""
  # A query string carrying anything secret-looking is dropped wholesale (portable: no GNU sed I flag).
  if [[ "$u" == *\?* ]]; then
    q="${u#*\?}"; u="${u%%\?*}"
    if printf '%s' "$q" | grep -qiE '(token|key|secret|password|pass|auth|sig)'; then q="***"; fi
  fi
  printf '%s' "$u" | sed -E \
    -e 's#^(https?://)[^/@]+@#\1***@#' \
    -e 's#^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@:]+:[^/@]*@#\1***@#'
  if [[ -n "$q" ]]; then printf '?%s' "$q"; fi
}
url_has_credentials() {
  local u="$1"
  [[ "$u" =~ ^https?://[^/@]+@ ]] && return 0
  [[ "$u" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/@:]+:[^/@]*@ ]] && return 0
  printf '%s' "$u" | grep -qiE '[?&][^=&]*(token|key|secret|password|pass|auth|sig)[^=&]*=' && return 0
  printf '%s' "$u" | grep -qE '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[baprs]-)' && return 0
  return 1
}
url_is_plausible() {
  local u="$1"
  [[ "$u" =~ ^(https?|ssh|git)://[^[:space:]]+$ ]] && return 0
  [[ "$u" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:[^[:space:]]+$ ]] && return 0
  [[ "$u" =~ ^(/|[A-Za-z]:[/\\]|file://)[^[:space:]]*$ ]] && return 0
  return 1
}

# ---------------------------------------------------------------- detect
GIT_CLI=missing; GIT_STATE=absent; COMMITS=0; BRANCH=""; REMOTE="none"; REMOTE_NAME=""; REMOTE_RAW=""
AUTH=none; AUTH_LIST=""; HOOKS=missing; DIRTY=0; TOPLEVEL=""; HOOKS_DIR=""
HOOKS_INSTALLED=""; HOOKS_MISSING=""
DECISION=""

settings_decision() {
  [[ -f "$SETTINGS_FILE" ]] || return 0
  awk '
    /"repo"[[:space:]]*:[[:space:]]*\{/ { inr = 1; next }
    inr && /^[[:space:]]*\}/ { inr = 0 }
    inr && /"decision"[[:space:]]*:/ { if (match($0, /"decision"[[:space:]]*:[[:space:]]*"[^"]*"/)) { s = substr($0, RSTART, RLENGTH); sub(/^"decision"[[:space:]]*:[[:space:]]*"/, "", s); sub(/"$/, "", s); print s } }
  ' "$SETTINGS_FILE" | head -n 1
}

detect() {
  GIT_CLI=missing; GIT_STATE=absent; COMMITS=0; BRANCH=""; REMOTE="none"; REMOTE_NAME=""; REMOTE_RAW=""
  AUTH=none; AUTH_LIST=""; HOOKS=missing; DIRTY=0; TOPLEVEL=""; HOOKS_DIR=""
  HOOKS_INSTALLED=""; HOOKS_MISSING=""
  DECISION="$(settings_decision || true)"
  have git || return 0
  GIT_CLI=present
  if g rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_STATE=repo
    TOPLEVEL="$(cd "$REPO_ROOT" && cdup="$(git rev-parse --show-cdup)" && cd "./$cdup" && pwd)"
    if g rev-parse --verify -q HEAD >/dev/null 2>&1; then COMMITS="$(g rev-list --count HEAD 2>/dev/null || echo 0)"; fi
    BRANCH="$(g symbolic-ref --short -q HEAD 2>/dev/null || true)"
    REMOTE_NAME="$(g remote 2>/dev/null | grep -x origin || g remote 2>/dev/null | head -n 1 || true)"
    if [[ -n "$REMOTE_NAME" ]]; then
      REMOTE_RAW="$(g remote get-url "$REMOTE_NAME" 2>/dev/null || true)"
      REMOTE="$(redact_url "$REMOTE_RAW")"
    fi
    DIRTY="$(g status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    local hp; hp="$(cd "$REPO_ROOT" && git rev-parse --git-path hooks 2>/dev/null || true)"
    if [[ -n "$hp" ]]; then
      case "$hp" in /*|[A-Za-z]:*) HOOKS_DIR="$hp" ;; *) HOOKS_DIR="$REPO_ROOT/$hp" ;; esac
      if [[ -f "$HOOKS_DIR/pre-commit" ]] && grep -q "$HOOK_MARKER" "$HOOKS_DIR/pre-commit" 2>/dev/null; then HOOKS=kcc-pre-commit; fi
    fi
    local hn
    for hn in $HOOK_NAMES; do
      if [[ -n "$HOOKS_DIR" && -f "$HOOKS_DIR/$hn" ]] && grep -q "$(hook_marker "$hn")" "$HOOKS_DIR/$hn" 2>/dev/null; then HOOKS_INSTALLED="${HOOKS_INSTALLED:+$HOOKS_INSTALLED,}$hn"
      else HOOKS_MISSING="${HOOKS_MISSING:+$HOOKS_MISSING,}$hn"; fi
    done
  fi
  # Auth kinds (detected, never read).
  if [[ -n "$(git -C "$REPO_ROOT" config --get credential.helper 2>/dev/null || true)" ]]; then AUTH_LIST="${AUTH_LIST:+$AUTH_LIST,}credential-helper"; fi
  if have gh && gh auth status >/dev/null 2>&1; then AUTH_LIST="${AUTH_LIST:+$AUTH_LIST,}gh"; fi
  local agent=0
  if [[ -n "${SSH_AUTH_SOCK:-}" ]] && have ssh-add; then
    local rc=0; ssh-add -l >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 0 || $rc -eq 1 ]] && agent=1
  fi
  if [[ $agent -eq 0 ]] && have sc.exe; then
    sc.exe query ssh-agent 2>/dev/null | grep -q RUNNING && agent=1
  fi
  [[ $agent -eq 1 ]] && AUTH_LIST="${AUTH_LIST:+$AUTH_LIST,}ssh-agent"
  [[ -n "$AUTH_LIST" ]] && AUTH="${AUTH_LIST%%,*}"
  return 0
}

gate_required() {
  if [[ -n "$DECISION" ]]; then
    # A recorded decision stands unless the state regressed (repo vanished after init/connect).
    if [[ "$DECISION" != "skip" && "$GIT_STATE" == "absent" ]]; then echo true; else echo false; fi
    return
  fi
  if [[ "$GIT_STATE" == "absent" || "$COMMITS" -eq 0 ]]; then echo true; else echo false; fi
}

# ---------------------------------------------------------------- settings writer
record_decision() { # decision remote(redacted or empty)
  local dec="$1" rem="$2"
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    add_v RB-SETTINGS warning human ".KCC/settings.json" "settings.json not found; decision '$dec' not recorded"
    return 0
  fi
  local decj remj
  decj="\"$(json_escape "$dec")\""
  if [[ -n "$rem" ]]; then remj="\"$(json_escape "$rem")\""; else remj="null"; fi
  if [[ $DRY_RUN -eq 1 ]]; then act "would record repo.decision=$dec repo.remote=${rem:-null} in .KCC/settings.json"; return 0; fi
  local tmp="$SETTINGS_FILE.kcc-tmp" crlf=0
  grep -q $'\r$' "$SETTINGS_FILE" && crlf=1
  DECJ="$decj" REMJ="$remj" awk '
    { sub(/\r$/, ""); L[++n] = $0 }
    END {
      dj = ENVIRON["DECJ"]; rj = ENVIRON["REMJ"]
      rs = 0; re = 0
      for (i = 1; i <= n; i++) if (!rs && L[i] ~ /"repo"[[:space:]]*:[[:space:]]*\{/) rs = i
      if (rs) {
        if (L[rs] ~ /\}/) {
          # single-line object: rewrite it
          ind = L[rs]; sub(/".*/, "", ind)
          tail = L[rs]; sub(/.*\}/, "", tail)
          boot = "\"ask\""
          if (match(L[rs], /"bootstrap"[[:space:]]*:[[:space:]]*"[^"]*"/)) { boot = substr(L[rs], RSTART, RLENGTH); sub(/^"bootstrap"[[:space:]]*:[[:space:]]*/, "", boot) }
          L[rs] = ind "\"repo\": { \"bootstrap\": " boot ", \"decision\": " dj ", \"remote\": " rj " }" tail
        } else {
          for (i = rs + 1; i <= n; i++) if (L[i] ~ /^[[:space:]]*\}/) { re = i; break }
          fd = 0; fr = 0
          for (i = rs + 1; i < re; i++) {
            if (match(L[i], /"decision"[[:space:]]*:[[:space:]]*("[^"]*"|null)/)) { L[i] = substr(L[i], 1, RSTART - 1) "\"decision\": " dj substr(L[i], RSTART + RLENGTH); fd = 1 }
            else if (match(L[i], /"remote"[[:space:]]*:[[:space:]]*("[^"]*"|null)/)) { L[i] = substr(L[i], 1, RSTART - 1) "\"remote\": " rj substr(L[i], RSTART + RLENGTH); fr = 1 }
          }
          ins = ""
          if (!fd) ins = ins "    \"decision\": " dj ",\n"
          if (!fr) ins = ins "    \"remote\": " rj ",\n"
          # inserted members end with a comma and precede the existing ones; in an empty block drop it
          if (ins != "") { sub(/\n$/, "", ins); if (re == rs + 1) sub(/,$/, "", ins); L[rs] = L[rs] "\n" ins }
        }
      } else {
        for (i = 1; i <= n; i++) if (L[i] ~ /^[[:space:]]*\{[[:space:]]*$/) { L[i] = L[i] "\n  \"repo\": {\n    \"bootstrap\": \"ask\",\n    \"decision\": " dj ",\n    \"remote\": " rj "\n  },"; break }
      }
      for (i = 1; i <= n; i++) print L[i]
    }
  ' "$SETTINGS_FILE" >"$tmp"
  if [[ $crlf -eq 1 ]]; then awk '{ printf "%s\r\n", $0 }' "$tmp" >"$tmp.crlf"; mv "$tmp.crlf" "$tmp"; fi
  mv "$tmp" "$SETTINGS_FILE"
  act "recorded repo.decision=$dec repo.remote=${rem:-null} in .KCC/settings.json"
}

# ---------------------------------------------------------------- actions
write_gitignore() {
  local f="$REPO_ROOT/.gitignore"
  if [[ -f "$f" ]]; then act "kept existing .gitignore"; return 0; fi
  if [[ $DRY_RUN -eq 1 ]]; then act "would write KCC .gitignore"; return 0; fi
  cat >"$f" <<'EOF'
# KCC generated cell outputs and local runtime artifacts.
.claude/
.codex/
.opencode/
.agents/
ollama/

Traces/Session-*/
ideation/IDEA-*/
specs/IDEA-*-Specs/
solution/*/
migrations/IMPORT-*/
src/
dashboard/

coordination/backchannel.jsonl
coordination/backchannel-*.jsonl

.tmp/
.tmp-*
.test-tmp/
.test-tmp
*.tmp-edge-profile-*
.tmp-edge-profile-*/
.tmp-chromium-profile-*/
*.playwright-profile-*/
__pycache__/
*.py[cod]

*.db
*.db-journal
*.sqlite
*.sqlite3

.DS_Store
Thumbs.db
desktop.ini
EOF
  act "wrote KCC .gitignore"
}

install_one_hook() { # hook-name -> 0 ok, 1 failed
  local hn="$1" marker src dir dst
  marker="$(hook_marker "$hn")"
  src="$HOOK_SRC_DIR/$hn"
  if [[ ! -f "$src" ]]; then add_v RB-HOOK-SRC error human "$src" "hook source .KCC/tools/hooks/$hn not found"; return 1; fi
  dir="$HOOKS_DIR"
  [[ -n "$dir" ]] || dir="$REPO_ROOT/.git/hooks"
  dst="$dir/$hn"
  if [[ -f "$dst" ]] && grep -q "$marker" "$dst" 2>/dev/null; then
    if cmp -s "$src" "$dst"; then act "KCC $hn hook already installed"; return 0; fi
    if [[ $DRY_RUN -eq 1 ]]; then act "would update KCC $hn hook"; return 0; fi
    cp "$src" "$dst"; chmod +x "$dst" 2>/dev/null || true; act "updated KCC $hn hook"; return 0
  fi
  if [[ -f "$dst" ]]; then
    if [[ -e "$dir/$hn.local" ]]; then
      add_v RB-HOOK-CONFLICT error human "$dst" "a foreign $hn hook and $hn.local both exist; merge them by hand"
      return 1
    fi
    if [[ $DRY_RUN -eq 1 ]]; then act "would preserve existing $hn hook as $hn.local (chained)"
    else mv "$dst" "$dir/$hn.local"; act "preserved existing $hn hook as $hn.local (chained)"; fi
  fi
  if [[ $DRY_RUN -eq 1 ]]; then act "would install KCC $hn hook"; return 0; fi
  mkdir -p "$dir"
  cp "$src" "$dst"; chmod +x "$dst" 2>/dev/null || true
  [[ "$hn" == "pre-commit" ]] && HOOKS=kcc-pre-commit
  act "installed KCC $hn hook"
  return 0
}

install_hook() { # all KCC hooks -> 0 ok, 1 when any failed
  if [[ "$GIT_STATE" != "repo" && $DRY_RUN -eq 0 ]]; then add_v RB-HOOK-NOREPO error human "." "not a git repository; run --apply init-local first"; return 1; fi
  local hn rc=0
  for hn in $HOOK_NAMES; do install_one_hook "$hn" || rc=1; done
  return $rc
}

initial_commit() {
  if [[ "$COMMITS" -gt 0 ]]; then act "repository already has $COMMITS commit(s); no bootstrap commit"; return 0; fi
  local name email
  name="$(g config user.name 2>/dev/null || true)"; email="$(g config user.email 2>/dev/null || true)"
  if [[ $DRY_RUN -eq 1 ]]; then
    act "would commit 'chore: KCC workspace bootstrap' (git add -A)"
    [[ -n "$name" && -n "$email" ]] || add_v RB-IDENTITY warning human "." "git identity not configured; the commit would fail. Run: git config --global user.name \"Your Name\"; git config --global user.email you@example.com"
    return 0
  fi
  if [[ -z "$name" || -z "$email" ]]; then
    add_v RB-IDENTITY error human "." "git identity not configured (not set by KCC). Run: git config --global user.name \"Your Name\"; git config --global user.email you@example.com; then re-run"
    return 1
  fi
  g add -A
  local rc=0
  g commit -q -m "chore: KCC workspace bootstrap" || rc=$?
  if [[ $rc -ne 0 ]]; then
    add_v RB-COMMIT error human "." "bootstrap commit failed (exit $rc); if the KCC pre-commit hook blocked it, fix the reported findings"
    return 1
  fi
  act "committed 'chore: KCC workspace bootstrap'"
}

do_init_local() {
  if [[ "$GIT_CLI" != "present" ]]; then
    echo "error: git is not installed. Approve it via: bash .KCC/tools/toolchain-preflight.sh git" >&2
    exit 2
  fi
  if [[ "$GIT_STATE" == "absent" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then act "would run git init"
    else
      g init -q
      # Older git names the first branch 'master', which the git-workflow defaults do not allow.
      if [[ "$(g symbolic-ref --short HEAD 2>/dev/null || true)" == "master" ]]; then g symbolic-ref HEAD refs/heads/main; fi
      act "git init"; detect
    fi
  else
    act "git repository already present"
  fi
  write_gitignore
  install_hook || true
  # Record before committing so the bootstrap commit carries the decision.
  record_decision "$PENDING_DEC" "$PENDING_REM"; RECORDED=1
  initial_commit || true
}

do_connect_remote() {
  if [[ -z "$REMOTE_URL" ]]; then
    echo "error: --remote-url is required for connect-remote (ask the human for the URL; never a token)" >&2
    exit 2
  fi
  if url_has_credentials "$REMOTE_URL"; then
    echo "error: remote URL rejected: it embeds credentials or a token. Use a plain URL and authenticate with a credential helper, 'gh auth login', or an SSH agent." >&2
    exit 2
  fi
  if ! url_is_plausible "$REMOTE_URL"; then die_usage "remote URL is not a recognised git URL"; fi
  do_init_local
  local red; red="$(redact_url "$REMOTE_URL")"
  if [[ "$GIT_STATE" == "repo" ]]; then
    local cur; cur="$(g remote get-url origin 2>/dev/null || true)"
    if [[ -n "$cur" && "$cur" != "$REMOTE_URL" ]]; then
      add_v RB-REMOTE-EXISTS error human "." "origin already points to $(redact_url "$cur"); change it by hand (git remote set-url origin <url>) if intended"
    elif [[ -n "$cur" ]]; then act "origin already set to $red"
    elif [[ $DRY_RUN -eq 1 ]]; then act "would add remote origin $red"
    else g remote add origin "$REMOTE_URL"; act "added remote origin $red"; fi
  else
    act "would add remote origin $red"
  fi
  if [[ "$AUTH" == "none" ]]; then
    add_v RB-AUTH-NONE warning human "." "no git authentication detected. Human runs ONE of: 'gh auth login' | 'git config --global credential.helper manager' (Windows) / 'osxkeychain' (macOS) / 'libsecret' (Linux) | 'ssh-add ~/.ssh/id_ed25519' - then re-run detect"
  fi
  act "push not performed (KCC never pushes; human runs: git push -u origin ${BRANCH:-main})"
}

emit_decision() { # decision remote
  [[ $EMIT -eq 1 && $DRY_RUN -eq 0 ]] || return 0
  local payload="{\"decision\":\"$1\",\"remote\":$(jstr "$2"),\"git\":\"$GIT_STATE\",\"commits\":$COMMITS,\"hooks\":\"$HOOKS\",\"auth\":\"$AUTH\"}"
  bash "$SCRIPT_DIR/backchannel-append.sh" --kind repo-bootstrap-decision --from repo-bootstrap --payload "$payload" --repo-root "$REPO_ROOT" >/dev/null 2>&1 || echo "warning: backchannel emit failed" >&2
}

# ---------------------------------------------------------------- main
detect
MODE=detect
PENDING_DEC="$APPLY"; PENDING_REM=""; RECORDED=0
[[ "$APPLY" == "init-local" && "$REMOTE" != "none" ]] && PENDING_REM="$REMOTE"
[[ "$APPLY" == "connect-remote" && -n "$REMOTE_URL" ]] && PENDING_REM="$(redact_url "$REMOTE_URL")"
if [[ -n "$APPLY" ]]; then
  MODE="apply:$APPLY"
  case "$APPLY" in
    init-local) do_init_local; emit_decision init-local "$PENDING_REM" ;;
    connect-remote) do_connect_remote; emit_decision connect-remote "$PENDING_REM" ;;
    skip) act "git-dependent features degrade: restore points -> coordination/checkpoints/ file snapshots; wave-scope -> file hashes"; record_decision skip ""; emit_decision skip "" ;;
  esac
elif [[ $INSTALL_HOOK -eq 1 ]]; then
  MODE="install-hook"
  install_hook || true
fi
[[ $DRY_RUN -eq 1 ]] || detect

# Standing findings (detect).
if [[ -n "$REMOTE_RAW" ]] && url_has_credentials "$REMOTE_RAW"; then
  add_v RB-REMOTE-CRED error human ".git/config" "remote '$REMOTE_NAME' URL embeds credentials ($REMOTE); remove them: git remote set-url $REMOTE_NAME <plain-url>, then use a credential helper / gh / ssh-agent"
fi
if [[ "$GIT_STATE" == "repo" && -n "$HOOKS_MISSING" && "$MODE" == "detect" ]]; then
  add_v RB-HOOK-MISSING warning human ".git/hooks" "KCC hook(s) not installed: ${HOOKS_MISSING//,/, } (run: repo-bootstrap --install-hook)"
fi
GATE="$(gate_required)"

ERRORS=0; WARNINGS=0
for i in "${!V_ID[@]}"; do case "${V_SEV[$i]}" in error) ERRORS=$((ERRORS + 1));; warning) WARNINGS=$((WARNINGS + 1));; esac; done
STATUS=pass; EXIT=0
if [[ $ERRORS -gt 0 ]]; then STATUS=fail; EXIT=1; fi

if [[ $JSON -eq 1 ]]; then
  printf '{"tool":"repo-bootstrap","version":"%s","scope":"%s","dry_run":%s,' "$VERSION" "$MODE" "$([[ $DRY_RUN -eq 1 ]] && echo true || echo false)"
  printf '"git_cli":"%s","git":"%s","toplevel":%s,"commits":%s,"branch":%s,"remote":%s,' "$GIT_CLI" "$GIT_STATE" "$(jstr "$([[ -n "$TOPLEVEL" ]] && { [[ "$TOPLEVEL" == "$REPO_ROOT" ]] && echo . || echo "$TOPLEVEL"; } || true)")" "$COMMITS" "$(jstr "$BRANCH")" "$(jstr "$REMOTE")"
  printf '"auth":"%s","auth_detected":[' "$AUTH"
  first=1; for a in ${AUTH_LIST//,/ }; do [[ $first -eq 1 ]] || printf ','; first=0; printf '"%s"' "$a"; done
  printf '],"hooks":"%s","hooks_installed":[' "$HOOKS"
  first=1; for a in ${HOOKS_INSTALLED//,/ }; do [[ $first -eq 1 ]] || printf ','; first=0; printf '"%s"' "$a"; done
  printf '],"dirty":%s,"decision":%s,"gate_required":%s,' "$DIRTY" "$(jstr "$DECISION")" "$GATE"
  printf '"choices":["init-local","connect-remote","skip"],"actions":['
  first=1; for a in ${ACTIONS[@]+"${ACTIONS[@]}"}; do [[ $first -eq 1 ]] || printf ','; first=0; printf '%s' "$(jstr "$a")"; done
  printf '],"errors":%d,"warnings":%d,"status":"%s","violations":[' "$ERRORS" "$WARNINGS" "$STATUS"
  first=1
  for i in "${!V_ID[@]}"; do
    [[ $first -eq 1 ]] || printf ','; first=0
    printf '{"id":%s,"severity":%s,"fix_owner":%s,"file":%s,"message":%s}' "$(jstr "${V_ID[$i]}")" "$(jstr "${V_SEV[$i]}")" "$(jstr "${V_OWNER[$i]}")" "$(jstr "${V_FILE[$i]}")" "$(jstr "${V_MSG[$i]}")"
  done
  printf ']}\n'
else
  echo "git: $GIT_STATE (cli $GIT_CLI)  commits: $COMMITS  branch: ${BRANCH:--}"
  echo "remote: $REMOTE"
  echo "auth: $AUTH${AUTH_LIST:+ (detected: $AUTH_LIST)}"
  echo "hooks: $HOOKS (installed: ${HOOKS_INSTALLED:-none})  dirty: $DIRTY  decision: ${DECISION:-none}"
  for a in ${ACTIONS[@]+"${ACTIONS[@]}"}; do echo "action: $a"; done
  for i in "${!V_ID[@]}"; do echo "${V_SEV[$i]}: ${V_ID[$i]} ${V_MSG[$i]}"; done
  if [[ "$GATE" == "true" ]]; then echo "Gate: required -> ask the human once: init-local | connect-remote | skip"; fi
  echo "Errors: $ERRORS  Warnings: $WARNINGS"
fi
exit $EXIT
