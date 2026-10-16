#!/usr/bin/env bash
# KCC framework (c) 2026 Tarek Fawaz, https://tikasway.dev/kcc. Licensed under the terms in LICENSE.
# KCC v0.4 native bash adapter materializer for macOS/Linux.
#
# Mirrors .KCC/tools/sync-adapters.ps1 (the canonical implementation): same
# inputs, same generated files, same content. Keep the two in step.
#
# Speed: each neutral agent/skill file is parsed ONCE by a single awk pass
# (frontmatter, derived one-line/first-sentence/usage/Obsidian fields, body)
# into a cache directory; everything else is bash string handling with no
# per-field subprocesses (Git Bash on Windows forks slowly).
#
# Bash 3.2 compatible (macOS): no associative arrays, no ${var,,}/${var^}.
set -eo pipefail
export LC_COLLATE=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS="all"
INSTALL_CODEX_SKILLS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    claude|codex|opencode|generic|ollama|all)
      HARNESS="$1"; shift ;;
    --harness|-Harness)
      HARNESS="$2"; shift 2 ;;
    --repo-root|-RepoRoot)
      REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --install-codex-skills|-InstallCodexSkills)
      INSTALL_CODEX_SKILLS=1; shift ;;
    --install-codex-prompts|-InstallCodexPrompts)
      echo "warning: -InstallCodexPrompts is deprecated and is a no-op. Use --install-codex-skills for project-local skills." >&2
      shift ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2 ;;
  esac
done

case "$HARNESS" in
  claude|codex|opencode|generic|ollama|all) ;;
  *) echo "error: unsupported harness: $HARNESS" >&2; exit 2 ;;
esac

KERNEL_ROOT="$REPO_ROOT/.KCC/kernel"
CAP_ROOT="$REPO_ROOT/.KCC/capabilities"
AGENTS_DIR="$CAP_ROOT/agents"
SKILLS_DIR="$CAP_ROOT/skills"

[[ -d "$AGENTS_DIR" ]] || { echo "error: agents directory not found: $AGENTS_DIR" >&2; exit 1; }
[[ -d "$SKILLS_DIR" ]] || { echo "error: skills directory not found: $SKILLS_DIR" >&2; exit 1; }

CACHE="$(mktemp -d)"
trap 'rm -rf "$CACHE"' EXIT

NL=$'\n'
SEP=$'\001'      # field separator in the parse cache
LSEP=$'\037'     # list-item separator
NLC=$'\036'      # newline inside a cached scalar

warn() { echo "WARNING: $*" >&2; }

# ---------------------------------------------------------------------------
# Mapping tables (mirror the $ModelClassTo* tables of sync-adapters.ps1)
# ---------------------------------------------------------------------------

model_for() {
  local surface="$1"
  local class="$2"
  case "$surface:$class" in
    claude:strong-reasoning|claude:local-strong) echo "claude-opus-5-5" ;;
    claude:balanced) echo "claude-sonnet-5-5" ;;
    claude:fast-implementation|claude:local-fast) echo "claude-haiku-5-5" ;;
    claude-id:strong-reasoning|claude-id:local-strong) echo "claude-opus-5-5" ;;
    claude-id:balanced) echo "claude-sonnet-5-5" ;;
    claude-id:fast-implementation|claude-id:local-fast) echo "claude-haiku-5-5" ;;
    codex:strong-reasoning|codex:local-strong) echo "gpt-6-astra" ;;
    codex:balanced) echo "gpt-6.1-sol" ;;
    codex:fast-implementation|codex:local-fast) echo "gpt-6-luna" ;;
    opencode:strong-reasoning) echo "anthropic/claude-opus-5-5" ;;
    opencode:balanced) echo "anthropic/claude-sonnet-5-5" ;;
    opencode:fast-implementation) echo "anthropic/claude-haiku-5-5" ;;
    opencode:local-strong) echo "ollama/qwen2.5:72b" ;;
    opencode:local-fast) echo "ollama/qwen2.5:7b" ;;
    ollama:strong-reasoning) echo "qwen2.5:72b" ;;
    ollama:balanced) echo "qwen2.5:32b" ;;
    ollama:fast-implementation) echo "qwen2.5:14b" ;;
    *:local-strong) echo "qwen2.5:72b" ;;
    *:local-fast) echo "qwen2.5:7b" ;;
    claude:*) echo "claude-sonnet-5-5" ;;
    claude-id:*) echo "claude-sonnet-5-5" ;;
    codex:*) echo "gpt-6.1-sol" ;;
    opencode:*) echo "anthropic/claude-sonnet-5-5" ;;
    ollama:*) echo "qwen2.5:32b" ;;
    *) echo "balanced" ;;
  esac
}

CLASSES="strong-reasoning balanced fast-implementation local-strong local-fast"

# Resolve every (surface, class) pair once; per-agent lookups are then fork-free.
for _s in claude claude-id codex opencode ollama; do
  for _c in $CLASSES; do
    printf -v "M_${_s//-/_}_${_c//-/_}" '%s' "$(model_for "$_s" "$_c")"
  done
  printf -v "MD_${_s//-/_}" '%s' "$(model_for "$_s" "")"
done

# mlookup SURFACE CLASS -> R (unknown class falls back to the PS default model)
mlookup() {
  local n
  case "$2" in
    strong-reasoning|balanced|fast-implementation|local-strong|local-fast)
      n="M_${1//-/_}_${2//-/_}" ;;
    *) n="MD_${1//-/_}" ;;
  esac
  R="${!n}"
}

class_known() {
  case "$1" in
    strong-reasoning|balanced|fast-implementation|local-strong|local-fast) return 0 ;;
    *) return 1 ;;
  esac
}

# model-class -> default reasoning effort; an agent's `effort:` overrides it.
class_default_effort() {
  case "$1" in
    strong-reasoning|local-strong) echo "high" ;;
    balanced) echo "medium" ;;
    fast-implementation|local-fast) echo "low" ;;
    *) echo "medium" ;;
  esac
}

class_use() {
  case "$1" in
    strong-reasoning) echo 'Escalations only: hard architecture or failing-review rework (human gate)' ;;
    balanced) echo 'Interrogation, architecture, spec writing, planning, verification, critique, migration' ;;
    fast-implementation) echo 'Executor: implementation per approved plan; meta-agents (butler, token-guard)' ;;
    local-strong) echo 'Local strong reasoning via an Ollama-compatible harness' ;;
    local-fast) echo 'Local low-cost support via an Ollama-compatible harness' ;;
  esac
}

for _c in $CLASSES; do
  printf -v "DE_${_c//-/_}" '%s' "$(class_default_effort "$_c")"
  printf -v "USE_${_c//-/_}" '%s' "$(class_use "$_c")"
done

codex_effort() {
  case "$1" in
    xhigh|max) echo "high" ;;
    *) echo "$1" ;;
  esac
}

# Per-agent exec-scope overrides for Claude (narrow Bash scopes) -> R (US-separated)
exec_scopes() {
  case "$1" in
    idea-interrogator) R='Bash(git log*)' ;;
    spec-writer|architect|planner) R="Bash(git log*)${LSEP}Bash(git diff*)" ;;
    implementer) R='Bash' ;;
    verifier) R="Bash(git diff*)${LSEP}Bash(git log*)" ;;
    *) R='' ;;
  esac
}

# ---------------------------------------------------------------------------
# Small string helpers (no subprocesses)
# ---------------------------------------------------------------------------

# replace_all TEXT FROM TO -> R (literal; safe for '&' and backslashes)
replace_all() {
  local s="$1" from="$2" to="$3" out=""
  if [[ -z "$from" ]]; then R="$s"; return 0; fi
  while [[ "$s" == *"$from"* ]]; do
    out+="${s%%"$from"*}$to"
    s="${s#*"$from"}"
  done
  R="$out$s"
}

# json_str TEXT -> R (a JSON string literal)
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  R="\"$s\""
}

# json_list LSEP-SEPARATED-ITEMS -> R (compact JSON array of strings)
json_list() {
  local -a items=()
  local out="" it
  if [[ -n "$1" ]]; then IFS="$LSEP" read -r -a items <<< "$1" || true; fi
  local n=${#items[@]} j
  for ((j = 0; j < n; j++)); do
    json_str "${items[j]}"
    [[ -n "$out" ]] && out+=","
    out+="$R"
  done
  R="[$out]"
}

# ---------------------------------------------------------------------------
# Neutral-source parsing: one awk pass per file
# ---------------------------------------------------------------------------

cat > "$CACHE/parse.awk" <<'AWK'
function trim(s) { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s); return s }
function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }
function norm(s) { gsub(/\r?\n/, " ", s); gsub(/[ \t\r\n]+/, " ", s); return trim(s) }
function isw(c) { return c ~ /^[A-Za-z0-9_]$/ }
function rep(s, from, to,   out, p) {
  if (from == "") return s
  out = ""
  while ((p = index(s, from)) > 0) { out = out substr(s, 1, p - 1) to; s = substr(s, p + length(from)) }
  return out s
}
function setv(key, t, v) { if (!(key in T)) K[++nk] = key; T[key] = t; V[key] = v }
function scalar(key) { return (key in T && T[key] == "s") ? V[key] : "" }
# Get-FirstSentence: first sentence (not ending in e.g/i.e/etc), capped at max.
function fsent(s, max,   line, len, p, c, j, nx) {
  line = norm(s)
  sub(/[ ]+Usage:[ ]*\/.*$/, "", line)
  line = trim(line)
  len = length(line)
  for (p = 2; p <= len; p++) {
    c = substr(line, p, 1)
    if (c != "." && c != "!" && c != "?") continue
    if (p >= 4 && substr(line, p - 3, 3) == "e.g" && (p == 4 || !isw(substr(line, p - 4, 1)))) continue
    if (p >= 4 && substr(line, p - 3, 3) == "i.e" && (p == 4 || !isw(substr(line, p - 4, 1)))) continue
    if (p >= 4 && substr(line, p - 3, 3) == "etc" && (p == 4 || !isw(substr(line, p - 4, 1)))) continue
    if (p == len) { line = substr(line, 1, p); break }
    j = p + 1
    if (substr(line, j, 1) !~ /[ \t]/) continue
    while (substr(line, j, 1) ~ /[ \t]/) j++
    nx = substr(line, j, 1)
    if (nx ~ /[A-Z`(]/ || nx == "[") { line = substr(line, 1, p); break }
  }
  if (length(line) > max) line = rtrim(substr(line, 1, max - 3)) "..."
  return line
}
function emit(key, t, v) {
  gsub(/\n/, NLC, v)
  printf "%s%s%s%s%s\n", key, SEP, t, SEP, v > META
}
BEGIN { SEP = sprintf("%c", 1); LSEP = sprintf("%c", 31); NLC = sprintf("%c", 30); n = 0; nk = 0 }
{ sub(/\r$/, ""); L[++n] = $0 }
END {
  if (n < 1 || L[1] != "---") { print "File does not start with YAML frontmatter delimiter." > "/dev/stderr"; exit 3 }
  e = 0
  for (i = 2; i <= n; i++) if (L[i] == "---") { e = i; break }
  if (!e) for (i = 2; i <= n; i++) if (substr(L[i], 1, 3) == "---") { e = i; break }
  if (!e) { print "No closing frontmatter delimiter found." > "/dev/stderr"; exit 3 }

  # Body = text after the closing delimiter, with leading newlines/dashes trimmed (Split-Frontmatter).
  B = ""
  for (i = e + 1; i <= n; i++) B = B L[i] "\n"
  sub(/^[\n-]+/, "", B)
  printf "%s", B > BODY

  # ConvertFrom-MiniYaml over the frontmatter lines.
  m = 0
  for (i = 2; i < e; i++) Y[++m] = L[i]
  i = 1
  while (i <= m) {
    line = Y[i]
    if (line ~ /^[ \t]*$/) { i++; continue }
    if (line ~ /^[ \t]*#/) { i++; continue }
    if (!match(line, /^[A-Za-z0-9_-]+[ \t]*:/)) { i++; continue }
    key = substr(line, 1, RLENGTH); sub(/[ \t]*:$/, "", key)
    val = trim(substr(line, RLENGTH + 1))
    if (val == ">" || val == "|") {
      i++; sb = ""
      while (i <= m && (Y[i] ~ /^[ \t]+[^ \t]/ || Y[i] ~ /^[ \t]*$/)) {
        if (Y[i] ~ /^[ \t]*$/) { if (val == "|") sb = sb "\n"; else sb = sb " " }
        else {
          st = Y[i]; sub(/^[ \t]+/, "", st)
          if (val == ">") { if (length(sb) > 0) sb = sb " "; sb = sb st }
          else sb = sb st "\n"
        }
        i++
      }
      setv(key, "s", trim(sb))
      continue
    }
    if (val == "[]") { setv(key, "l", ""); i++; continue }
    if (val == "") {
      i++; items = ""; cnt = 0
      while (i <= m && match(Y[i], /^[ \t]+-[ \t]*/)) {
        iv = trim(substr(Y[i], RLENGTH + 1)); sub(/[ \t]+#.*$/, "", iv); iv = trim(iv)
        if (iv != "") { items = (cnt > 0) ? items LSEP iv : iv; cnt++ }
        i++
      }
      setv(key, "l", items)
      continue
    }
    lv = length(val)
    if (lv >= 2 && substr(val, 1, 1) == "\"" && substr(val, lv, 1) == "\"") val = substr(val, 2, lv - 2)
    else if (lv >= 2 && substr(val, 1, 1) == "'" && substr(val, lv, 1) == "'") val = substr(val, 2, lv - 2)
    setv(key, "s", val)
    i++
  }

  for (k = 1; k <= nk; k++) emit(K[k], T[K[k]], V[K[k]])

  # Derived fields (what the PS helpers compute from the parsed meta).
  nm = scalar("name"); if (nm == "") { nm = FNAME }
  emit("zzname", "s", nm)
  emit("zzn_role", "s", norm(scalar("role")))
  emit("zzn_modelclass", "s", norm(scalar("model-class")))
  emit("zzeffort", "s", tolower(norm(scalar("effort"))))
  d = scalar("description")
  emit("zzn_description", "s", norm(d))
  split("90 160 200 300", mx, " ")
  for (x = 1; x <= 4; x++) {
    emit("zzf" mx[x] "_description", "s", fsent(d, mx[x] + 0))
    emit("zzf" mx[x] "_inputs", "s", fsent(scalar("inputs"), mx[x] + 0))
    emit("zzf" mx[x] "_outputs", "s", fsent(scalar("outputs"), mx[x] + 0))
  }
  # Get-SkillUsage
  ln = norm(d); p = index(ln, "Usage:")
  if (p > 0) { u = substr(ln, p + 6); sub(/^[ ]+/, "", u); gsub(/`/, "", u); gsub(/[ ]*\|[ ]*/, " ; ", u); u = trim(u) }
  else u = "/" nm
  emit("zzusage", "s", u)
  # codex openai.yaml (display name, short description, default prompt)
  nparts = split(nm, parts, "-"); disp = ""
  for (x = 1; x <= nparts; x++) {
    w = parts[x]
    if (length(w) <= 1) w = toupper(w); else w = toupper(substr(w, 1, 1)) substr(w, 2)
    disp = (x > 1) ? disp " " w : w
  }
  sd = norm(d); sub(/[ ]+Usage:[ ]*\/.*$/, "", sd); sd = trim(sd)
  if (length(sd) > 120) sd = rtrim(substr(sd, 1, 117)) "..."
  oy = "interface:\n  display_name: \"" rep(norm(disp), "\"", "\\\"") "\"\n  short_description: \"" rep(norm(sd), "\"", "\\\"") "\"\n  default_prompt: \"" rep(norm("/" nm " "), "\"", "\\\"") "\""
  emit("zzopenai", "s", oy)
  # Format-ObsidianBlock
  nfld = split("title aliases tags created updated version status copyright homepage license", fld, " ")
  ob = ""; any = 0
  for (x = 1; x <= nfld; x++) {
    kx = fld[x]
    if (!(kx in T)) continue
    if (!any) { ob = "# Obsidian metadata (Obsidian vault + framework provenance)\n"; any = 1 }
    if (T[kx] == "l") {
      ob = ob kx ":\n"
      ni = split(V[kx], its, LSEP)
      for (y = 1; y <= ni; y++) { it = trim(its[y]); if (it != "") ob = ob "  - " it "\n" }
    } else ob = ob kx ": " V[kx] "\n"
  }
  sub(/\n+$/, "", ob)
  emit("zzobs", "s", ob)
}
AWK

cat > "$CACHE/body.awk" <<'AWK'
function rep(s, from, to,   out, p) {
  if (from == "") return s
  out = ""
  while ((p = index(s, from)) > 0) { out = out substr(s, 1, p - 1) to; s = substr(s, p + length(from)) }
  return out s
}
BEGIN { ph = ENVIRON["KPH"]; tok = ENVIRON["KTOK"]; foot = ENVIRON["KFOOT"]; trimend = ENVIRON["KTRIM"]; buf = "" }
{ buf = buf $0 "\n" }
END {
  if (ph != "") buf = rep(buf, ph, tok)
  if (trimend == "1") { sub(/[ \t\r\n]+$/, "", buf); buf = buf foot }
  sub(/^\n+/, "", buf)
  if (buf != "" && substr(buf, length(buf), 1) != "\n") buf = buf "\n"
  printf "%s", buf
}
AWK

# body_emit PREFIX PLACEHOLDER TOKEN TRIMEND(1|0) FOOTER -> stdout
body_emit() {
  KPH="$2" KTOK="$3" KTRIM="$4" KFOOT="$5" awk -f "$CACHE/body.awk" "$CACHE/$1.body"
}

# Cached-meta accessors: PFX is e.g. a3 (agent 3) or s7 (skill 7).
load_meta() { # PFX
  local k t v n
  while IFS="$SEP" read -r k t v; do
    n="${1}_${k//[^A-Za-z0-9]/_}"
    printf -v "$n" '%s' "$v"
    printf -v "${n}__t" '%s' "$t"
  done < "$CACHE/$1.meta"
}
mget() { local n="${1}_${2//[^A-Za-z0-9]/_}"; R="${!n:-}"; }            # scalar/list -> R
mhas() { local n="${1}_${2//[^A-Za-z0-9]/_}__t"; [[ -n "${!n:-}" ]]; }  # key present?
mset() { printf -v "${1}_${2//[^A-Za-z0-9]/_}" '%s' "$3"; printf -v "${1}_${2//[^A-Za-z0-9]/_}__t" '%s' "s"; }

# ---------------------------------------------------------------------------
# Per-workspace model tiers: `.KCC/model-overrides` (user-owned).
# One line per agent: `name = model-class [effort]`. Unknown class: warn, ignore.
# ---------------------------------------------------------------------------
OV_NAME=(); OV_CLS=(); OV_EFF=()
load_overrides() {
  local f="$REPO_ROOT/.KCC/model-overrides" nm cls eff
  [[ -f "$f" ]] || return 0
  while IFS="$SEP" read -r nm cls eff; do
    [[ -n "$nm" ]] || continue
    OV_NAME[${#OV_NAME[@]}]="$nm"; OV_CLS[${#OV_CLS[@]}]="$cls"; OV_EFF[${#OV_EFF[@]}]="$eff"
  done < <(awk -v SEP="$SEP" '
    function trim(s) { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s); return s }
    { line = $0; sub(/\r$/, "", line); sub(/#.*$/, "", line); line = trim(line)
      q = index(line, "="); if (q == 0) next
      nm = substr(line, 1, q - 1); rest = trim(substr(line, q + 1))
      if (nm !~ /^[^ \t=]+[ \t]*$/) next
      nm = trim(nm)
      nw = split(rest, w, /[ \t]+/)
      if (nw < 1 || nw > 2 || w[1] == "") next
      cls = w[1]; eff = (nw == 2) ? w[2] : ""
      if (cls != "strong-reasoning" && cls != "balanced" && cls != "fast-implementation" && cls != "local-strong" && cls != "local-fast") {
        print "WARNING: model-overrides: unknown model-class \047" cls "\047 for " nm "; ignored" > "/dev/stderr"; next
      }
      if (eff != "") {
        le = tolower(eff)
        if (le != "low" && le != "medium" && le != "high" && le != "xhigh" && le != "max") {
          print "WARNING: model-overrides: unknown effort \047" eff "\047 for " nm "; ignored" > "/dev/stderr"; eff = ""
        }
      }
      if (!(nm in O)) ord[++no] = nm
      O[nm] = cls SEP tolower(eff)
    }
    END { for (x = 1; x <= no; x++) print ord[x] SEP O[ord[x]] }' "$f")
}

# ---------------------------------------------------------------------------
# Load the neutral agents / skills
# ---------------------------------------------------------------------------
AG_FILE=(); SK_FILE=(); NA=0; NS=0

load_sources() {
  local f base i j ov_n
  load_overrides
  for f in "$AGENTS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    i=$NA; NA=$((NA + 1)); AG_FILE[i]="$f"
    base="${f##*/}"; base="${base%.md}"
    if ! awk -v META="$CACHE/a$i.meta" -v BODY="$CACHE/a$i.body" -v SEP="$SEP" -v FNAME="$base" -f "$CACHE/parse.awk" "$f"; then
      echo "error: could not parse $f" >&2; exit 1
    fi
    load_meta "a$i"
    # Apply .KCC/model-overrides (last matching line wins).
    mget "a$i" zzname; ov_n="$R"
    for ((j = 0; j < ${#OV_NAME[@]}; j++)); do
      if [[ "${OV_NAME[j]}" == "$ov_n" ]]; then
        mset "a$i" model-class "${OV_CLS[j]}"
        mset "a$i" zzn_modelclass "${OV_CLS[j]}"
        if [[ -n "${OV_EFF[j]}" ]]; then mset "a$i" zzeffort "${OV_EFF[j]}"; fi
      fi
    done
  done
  for f in "$SKILLS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    i=$NS; NS=$((NS + 1)); SK_FILE[i]="$f"
    base="${f##*/}"; base="${base%.md}"
    if ! awk -v META="$CACHE/s$i.meta" -v BODY="$CACHE/s$i.body" -v SEP="$SEP" -v FNAME="$base" -f "$CACHE/parse.awk" "$f"; then
      echo "error: could not parse $f" >&2; exit 1
    fi
    load_meta "s$i"
  done
}

# ---------------------------------------------------------------------------
# Resolved per-agent profile (Get-AgentEffort / Get-AgentSpawnProfile)
# ---------------------------------------------------------------------------
P_NAME=(); P_ROLE=(); P_CLS=(); P_EFF=(); P_CMODEL=(); P_CID=(); P_TOOLS=(); P_TOOLSJ=()
P_SCOPES=(); P_CODEX=(); P_CODEXE=(); P_OC=(); P_OL=()

compute_profiles() {
  local i p name cls eff de ok t clean
  for ((i = 0; i < NA; i++)); do
    p="a$i"
    mget "$p" zzname; name="$R"; P_NAME[i]="$name"
    mget "$p" zzn_role; P_ROLE[i]="$R"
    mget "$p" zzn_modelclass; cls="$R"; P_CLS[i]="$cls"
    # effort: valid frontmatter/override value, else the class default (warn when invalid)
    mget "$p" zzeffort; eff="$R"; ok=0
    if [[ -n "$eff" ]]; then
      case "$eff" in
        low|medium|high|xhigh|max) ok=1 ;;
        *) warn "agent '$name' has invalid effort '$eff' - using the model-class default" ;;
      esac
    fi
    if (( ok == 0 )); then
      if class_known "$cls"; then de="DE_${cls//-/_}"; eff="${!de}"; else eff="medium"; fi
    fi
    P_EFF[i]="$eff"
    if ! class_known "$cls" && [[ "$HARNESS" == "all" || "$HARNESS" == "claude" ]]; then
      warn "[claude] agent '$name' has unknown model-class '$cls' - defaulting to claude-sonnet-5-5"
    fi
    mlookup claude "$cls"; P_CMODEL[i]="$R"
    mlookup claude-id "$cls"; P_CID[i]="$R"
    mlookup codex "$cls"; P_CODEX[i]="$R"
    mlookup opencode "$cls"; P_OC[i]="$R"
    mlookup ollama "$cls"; P_OL[i]="$R"
    case "$eff" in xhigh|max) P_CODEXE[i]="high" ;; *) P_CODEXE[i]="$eff" ;; esac

    # Claude tools: bare names (unique, in order) + narrow Bash scopes published as exec_scope.
    local -a tl=()
    mget "$p" tools_required
    if [[ -n "$R" ]]; then IFS="$LSEP" read -r -a tl <<< "$R" || true; fi
    local bare="" scopes="" sc x entry resolved=""
    local n=${#tl[@]} j
    for ((j = 0; j < n; j++)); do
      clean="${tl[j]}"
      case "$clean" in
        exec)
          exec_scopes "$name"
          if [[ -n "$R" ]]; then resolved+="${resolved:+$LSEP}$R"; else resolved+="${resolved:+$LSEP}Bash"; fi ;;
        read) resolved+="${resolved:+$LSEP}Read" ;;
        search) resolved+="${resolved:+$LSEP}Glob${LSEP}Grep" ;;
        edit) resolved+="${resolved:+$LSEP}Write${LSEP}Edit" ;;
        web) resolved+="${resolved:+$LSEP}WebSearch${LSEP}WebFetch" ;;
      esac
    done
    local -a rl=()
    if [[ -n "$resolved" ]]; then IFS="$LSEP" read -r -a rl <<< "$resolved" || true; fi
    local bare_list="" sc_list=""
    n=${#rl[@]}
    for ((j = 0; j < n; j++)); do
      entry="${rl[j]}"
      x="${entry%%(*}"
      case "$LSEP$bare_list$LSEP" in *"$LSEP$x$LSEP"*) ;; *) bare_list+="${bare_list:+$LSEP}$x" ;; esac
      case "$entry" in Bash\(*) sc_list+="${sc_list:+$LSEP}$entry" ;; esac
    done
    [[ -n "$bare_list" ]] || bare_list="Read"
    P_TOOLS[i]="${bare_list//$LSEP/, }"
    json_list "$bare_list"; P_TOOLSJ[i]="$R"
    P_SCOPES[i]="$sc_list"
  done
}

# ---------------------------------------------------------------------------
# Tables for orchestrator.md / AGENTS.md / CLAUDE.md
# ---------------------------------------------------------------------------
backtick_list() { # LSEP-items -> R: `a`, `b`
  local -a it=(); local out="" j n
  if [[ -n "$1" ]]; then IFS="$LSEP" read -r -a it <<< "$1" || true; fi
  n=${#it[@]}
  for ((j = 0; j < n; j++)); do out+="${out:+, }\`${it[j]}\`"; done
  R="$out"
}

build_tables() {
  local i p out line sc_txt x
  # agents
  out="| Agent | Role | Model class | Effort | Purpose |${NL}|-------|------|-------------|--------|---------|"
  for ((i = 0; i < NA; i++)); do
    mget "a$i" zzf160_description
    out+="${NL}| \`${P_NAME[i]}\` | ${P_ROLE[i]} | \`${P_CLS[i]}\` | \`${P_EFF[i]}\` | $R |"
  done
  T_AGENT="$out"
  # spawn
  out="| Agent | Class | Claude model | Effort | Codex model/effort | Tools (Claude) | Inputs -> Outputs |${NL}|-------|-------|--------------|--------|--------------------|----------------|-------------------|"
  for ((i = 0; i < NA; i++)); do
    line="${P_TOOLS[i]}"
    if [[ -n "${P_SCOPES[i]}" ]]; then
      local -a scl=(); local sct=""
      IFS="$LSEP" read -r -a scl <<< "${P_SCOPES[i]}" || true
      for x in "${scl[@]}"; do x="${x#Bash(}"; x="${x%)}"; sct+="${sct:+, }$x"; done
      line+=" (Bash limited to: $sct)"
    fi
    mget "a$i" zzf90_inputs; sc_txt="$R"
    mget "a$i" zzf90_outputs
    sc_txt="$sc_txt -> $R"
    sc_txt="${sc_txt//|//}"
    out+="${NL}| \`${P_NAME[i]}\` | \`${P_CLS[i]}\` | \`${P_CMODEL[i]}\` | \`${P_EFF[i]}\` | \`${P_CODEX[i]}\` / \`${P_CODEXE[i]}\` | $line | $sc_txt |"
  done
  T_SPAWN="$out"
  # skills + routes
  local tsk="| Skill | Usage | Delegates to |${NL}|-------|-------|--------------|"
  local trt="| Trigger | Skill | Agent invoked |${NL}|---------|-------|---------------|"
  for ((i = 0; i < NS; i++)); do
    mget "s$i" zzname; local nm="$R"
    mget "s$i" zzusage; local us="$R"
    mget "s$i" delegates_to
    if [[ -n "$R" ]]; then backtick_list "$R"; tsk+="${NL}| \`$nm\` | \`$us\` | $R |"; trt+="${NL}| \`$us\` | \`$nm\` | $R |"
    else tsk+="${NL}| \`$nm\` | \`$us\` | (direct file read) |"; trt+="${NL}| \`$us\` | \`$nm\` | (none) |"; fi
  done
  T_SKILL="$tsk"; T_ROUTE="$trt"
  T_HARNESS='| Harness | Generated paths |
|---------|-----------------|
| `claude` | `.claude/agents/`, `.claude/skills/`, `CLAUDE.md` if missing |
| `codex` | `.codex/agents/`, `.codex/skills/*/SKILL.md`, `.codex/tools/`, `.codex/config.toml`, `AGENTS.md` if missing |
| `opencode` | `.opencode/agents/`, `.opencode/commands/`, `.opencode/skills/`, `opencode.json`, `AGENTS.md` if missing |
| `generic` | `.agents/agents/`, `.agents/skills/`, `.agents/tools/`, `.agents/config.json`, `.agents/manifest.json` |
| `ollama` | `ollama/agents.json`, `ollama/README.md` |'
  # model classes
  out="| Class | Claude | Default effort | Codex | OpenCode | Ollama | Intended use |${NL}|-------|--------|----------------|-------|----------|--------|--------------|"
  local cls
  for cls in $CLASSES; do
    local k="${cls//-/_}" a b c d e f
    a="M_claude_$k"; b="DE_$k"; c="M_codex_$k"; d="M_opencode_$k"; e="M_ollama_$k"; f="USE_$k"
    out+="${NL}| \`$cls\` | \`${!a}\` | \`${!b}\` | \`${!c}\` | \`${!d}\` | \`${!e}\` | ${!f} |"
  done
  T_MODELCLASS="$out"
}

# expand_template PATH -> R   (Expand-OrchestratorTemplate)
expand_template() {
  local t
  [[ -f "$1" ]] || { echo "error: Orchestrator template not found: $1" >&2; exit 1; }
  t="$(cat "$1"; printf x)"; t="${t%x}"
  replace_all "$t" '{{DATE}}' "$TODAY"; t="$R"
  replace_all "$t" '{{AGENT_TABLE}}' "$T_AGENT"; t="$R"
  replace_all "$t" '{{SPAWN_TABLE}}' "$T_SPAWN"; t="$R"
  replace_all "$t" '{{SKILL_TABLE}}' "$T_SKILL"; t="$R"
  replace_all "$t" '{{ROUTE_TABLE}}' "$T_ROUTE"; t="$R"
  replace_all "$t" '{{HARNESS_OUTPUT_TABLE}}' "$T_HARNESS"; t="$R"
  replace_all "$t" '{{MODEL_CLASS_TABLE}}' "$T_MODELCLASS"; t="$R"
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
GEN_FILES=()
track() { GEN_FILES[${#GEN_FILES[@]}]="$1"; }

# ensure PATH CONTENT  (Ensure-FileIfMissing: content has no added trailing newline)
ensure_file() {
  local path="$1" content="$2"
  if [[ ! -e "$path" ]]; then
    mkdir -p "$(dirname "$path")"
    printf '%s' "$content" > "$path"
    track "$path"
    echo "[init     ] [create] $path"
  fi
}

# Write-time guard: strip disallowed control characters (keeps tab, LF, CR) from
# the files this run wrote. Mirrors the PowerShell Remove-ControlChars guard.
strip_ctrl_files() {
  [[ $# -gt 0 ]] || return 0
  local hits f tmp
  hits="$(LC_ALL=C grep -l $'[\001-\010\013\014\016-\037\177]' "$@" 2>/dev/null || true)"
  [[ -n "$hits" ]] || return 0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    tmp="$(mktemp)"
    LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' < "$f" > "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
  done <<< "$hits"
}

# obs_block PFX -> R ("" or "\n<block>")
obs_block() {
  mget "$1" zzobs
  if [[ -n "$R" ]]; then R="$NL${R//$NLC/$NL}"; else R=""; fi
}

# oneline_raw PFX -> R (description with any newline replaced by a space; PS: -replace "\r?\n", ' ')
desc_raw_oneline() {
  mget "$1" description
  R="${R//$NLC/ }"
}

RUNTIME_FOOT=$'\n\n## Runtime\n\nFollow `.KCC/kernel/contracts/agent-runtime.md`: handover in, lazy reads, `Confidence: NN%` + `ActualTokenUsage`, lean return, output economy (`depthlevel`).\n'
ECONOMY=$'\n\n## Output economy\n\nHonour `depthlevel` (1-5, default 5) from the AutoPolicy per `.KCC/kernel/protocols/depth-levels.md`; write each fact once, tables over prose, stay under the artifact length caps.\n'

# skill_prep: placeholder + footer for each skill
SK_PH=(); SK_FOOT=()
prep_skills() {
  local i
  for ((i = 0; i < NS; i++)); do
    mget "s$i" argument_placeholder
    if mhas "s$i" argument-placeholder && [[ -n "$R" ]]; then SK_PH[i]="$R"; else SK_PH[i]='<ARGS>'; fi
    mget "s$i" delegates_to
    if [[ -n "$R" ]]; then
      backtick_list "$R"
      SK_FOOT[i]=$'\n\n## Spawning\n\nDelegate to '"$R"$' per `coordination/orchestrator.md` -> *Spawn protocol*: fresh subagent per unit, model and effort from its profile (`orchestrator.json` -> `agents[].spawn`), handover packet in, lean return out.\n'"$ECONOMY"
    else
      SK_FOOT[i]="$ECONOMY"
    fi
  done
}

# skill_package I TOKEN COMPAT -> stdout  (New-SkillPackageContent)
skill_package() {
  local i="$1" token="$2" compat="$3" name desc
  mget "s$i" zzname; name="$R"
  mget "s$i" zzn_description; desc="$R"
  obs_block "s$i"
  printf '%s\n\n' "---${NL}name: $name${NL}description: >${NL}  $desc${NL}compatibility: $compat${NL}$R${NL}---"
  body_emit "s$i" "${SK_PH[i]}" "$token" 1 "${SK_FOOT[i]}"
}

# ---------------------------------------------------------------------------
# Framework initialization (Initialize-FrameworkInfrastructure)
# ---------------------------------------------------------------------------
initialize_framework() {
  mkdir -p "$REPO_ROOT/memory" "$REPO_ROOT/coordination" "$REPO_ROOT/Traces/_session-template"

  ensure_file "$REPO_ROOT/.gitignore" "# KCC generated cell outputs and local runtime artifacts.
.claude/
.codex/
.opencode/
.agents/
ollama/

# Ideas, specs, architecture and src/ are the project's deliverables and ARE committed.
Traces/Session-*/
solution/*/
migrations/IMPORT-*/
dashboard/

coordination/backchannel.jsonl
coordination/backchannel-*.jsonl
coordination/run/
coordination/gates/
coordination/checkpoints/
.kcc-lanes/
coordination/lanes.json

node_modules/
dist/
build/
coverage/
.env
.env.*
!.env.example

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
desktop.ini"

  if [[ ! -e "$REPO_ROOT/AGENTS.md" ]]; then
    expand_template "$KERNEL_ROOT/templates/AGENTS.md"
    ensure_file "$REPO_ROOT/AGENTS.md" "$R"
  fi
  if [[ "$HARNESS" == "all" || "$HARNESS" == "claude" ]] && [[ ! -e "$REPO_ROOT/CLAUDE.md" ]]; then
    expand_template "$KERNEL_ROOT/templates/CLAUDE.md"
    ensure_file "$REPO_ROOT/CLAUDE.md" "$R"
  fi

  ensure_file "$REPO_ROOT/memory/index.json" '{
  "entries": [],
  "last_updated": null,
  "schema_version": "1.0"
}'

  ensure_file "$REPO_ROOT/memory/memory.md" "---
title: Memory MOC
tags:
  - memory
  - entrypoint
created: $TODAY
updated: $TODAY
version: 1.0.0
status: active
---

# Memory

Butler-owned institutional memory. Do not edit generated index rows directly."

  # NOTE: backticks are intentionally absent below: the PowerShell tool writes these two
  # MOCs from double-quoted here-strings, where a backtick is an escape and is dropped.
  ensure_file "$REPO_ROOT/memory/schema.md" "---
title: Memory Schema
tags:
  - memory
  - protocol
created: $TODAY
updated: $TODAY
version: 1.0.0
status: active
---

# Memory Schema

Entry types: decision, pattern, incident, preference, glossary.

Each entry should include an ID, title, type, date, summary, evidence, and applicability notes."

  ensure_file "$REPO_ROOT/coordination/coordination.md" "---
title: Coordination MOC
tags:
  - coordination
  - entrypoint
created: $TODAY
updated: $TODAY
version: 1.0.0
status: active
---

# Coordination

- \`backchannel.jsonl\` - append-only meta-agent event log.
- \`orchestrator.md\` - generated skill-to-agent route map.
- \`orchestrator.json\` - generated machine-readable route map.
- \`.KCC/tools/backchannel-append.ps1\` / \`.sh\` - deterministic event append helpers that refresh \`dashboard/index.html\`.
- \`.KCC/tools/show-backchannel.ps1\` / \`.sh\` - read-only human-readable backchannel viewers."

  # orchestrator.md is expanded from the kernel template (always rewritten).
  expand_template "$KERNEL_ROOT/templates/orchestrator.md"
  printf '%s' "$R" > "$REPO_ROOT/coordination/orchestrator.md"
  track "$REPO_ROOT/coordination/orchestrator.md"

  write_orchestrator_json

  ensure_file "$REPO_ROOT/Traces/traces.md" "---
title: Traces MOC
tags:
  - trace
  - entrypoint
created: $TODAY
updated: $TODAY
version: 1.0.0
status: active
---

# Traces

Per-session trace folders live here as Session-{slug}-{datetime}/."

  local tpl
  IFS= read -r -d '' tpl <<'EOF' || true
---
title: "Session: <chat title>"
session-id: Session-<slug>-<datetime>
date: <YYYY-MM-DD>
agent: <primary agent name>
spec: SPEC-XXX | none
status: active
tags:
  - trace
  - session
  - lifecycle/<stage>
created: <YYYY-MM-DD>
updated: <YYYY-MM-DD>
version: 0.1.0
---

# Session: <chat title>

Copy this file to `session-{slug}-{datetime}.md` inside a
`Traces/Session-{slug}-{datetime}/` folder.

## Summary

_One paragraph, filled in at session end._

## Artifacts

- [[Decisions]]
- [[Handovers]]
- [[Actions]]
- [[ToolsUsed]]
- [[HumanActions]]
- [[HumanDecisions]]
- [[TokenUsage]]

## Key decisions

1. _decision title_ - see [[Decisions#1]]
2. _decision title_ - see [[Decisions#2]]
3. _decision title_ - see [[Decisions#3]]

## Outcomes

- Shipped:
- Deferred:
- Follow-up specs created:

## Related

- Spec under work: SPEC-XXX | none
- All traces: [[../traces|Traces MOC]]
- Trace layout protocol: [[../.KCC/kernel/protocols/trace-layout]]
EOF
  tpl="${tpl%$'\n'}"
  local sd="$REPO_ROOT/Traces/_session-template"
  ensure_file "$sd/session-template.md" "$tpl"
  ensure_file "$sd/Actions.md" $'# Actions\n'
  ensure_file "$sd/ToolsUsed.md" $'# Tools Used\n'
  ensure_file "$sd/Decisions.md" $'# Decisions\n'
  ensure_file "$sd/Handovers.md" $'# Handovers\n'
  ensure_file "$sd/HumanActions.md" $'# Human Actions\n'
  ensure_file "$sd/HumanDecisions.md" $'# Human Decisions\n'
  ensure_file "$sd/TokenUsage.md" $'# Token Usage\n'
}

# ---------------------------------------------------------------------------
# coordination/orchestrator.json (New-OrchestratorJson + ConvertTo-CompactJson)
# ---------------------------------------------------------------------------
write_orchestrator_json() {
  local json="$REPO_ROOT/coordination/orchestrator.json"
  local runtime="" generated i cls k first line
  generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Preserve butler-owned runtime keys (active_session*, runtime) from the old file.
  if [[ -f "$json" ]]; then
    runtime="$(awk -v SEP="$SEP" '
      function flush() { if (val != "") print key SEP val; capture = 0; val = "" }
      BEGIN { RS = "\001" }
      { s = $0; n = length(s); mode = 0; instr = 0; esc = 0; capture = 0; vdepth = 0; val = ""; kbuf = ""
        for (i = 1; i <= n; i++) {
          c = substr(s, i, 1)
          if (instr) {
            if (mode == 2) {
              if (esc) { esc = 0; kbuf = kbuf c }
              else if (c == "\\") { esc = 1; kbuf = kbuf c }
              else if (c == "\"") { instr = 0; key = kbuf; mode = 3 }
              else kbuf = kbuf c
              continue
            }
            if (capture) val = val c
            if (esc) esc = 0
            else if (c == "\\") esc = 1
            else if (c == "\"") instr = 0
            continue
          }
          if (c == " " || c == "\t" || c == "\r" || c == "\n") continue
          if (mode == 0) { if (c == "{") mode = 1; continue }
          if (mode == 1) { if (c == "\"") { instr = 1; mode = 2; kbuf = "" } ; continue }
          if (mode == 3) { if (c == ":") { mode = 4; vdepth = 0; val = ""; capture = (key ~ /^active_session/ || key == "runtime") ? 1 : 0 } ; continue }
          if (mode == 4) {
            if (c == "\"") { instr = 1; if (capture) val = val c; continue }
            if (c == "{" || c == "[") { vdepth++; if (capture) val = val c; continue }
            if (c == "}" || c == "]") {
              if (vdepth == 0) { if (capture) flush(); mode = 9; continue }
              vdepth--; if (capture) val = val c; continue
            }
            if (c == "," && vdepth == 0) { if (capture) flush(); mode = 1; continue }
            if (capture) val = val c
          }
        }
      }' "$json" || true)"
  fi

  {
    echo '{'
    echo '  "schema_version": "2.0",'
    printf '  "generated": "%s",\n' "$generated"
    local rules="" r
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      json_str "$line"; rules+="${rules:+,}$R"
    done <<'RULES'
resolve model+effort from agents[].spawn; never inherit the caller model (only exceptions: the complexity rule, an approved deep spawn)
fresh subagent per unit; never fork or resume the caller transcript
handover packet <= 300 words: goal, ids, read (paths only), write, constraints, confidence_threshold, budget, depthlevel (omit at 5)
lazy reads: grep the heading, then read that section; never load .KCC/ wholesale
return <= 150-word summary + artifact paths + Confidence + ActualTokenUsage; no file echoes
fan out independent wave units in one message; barrier before the next wave
retry escalation: effort +1 step; a model-class change needs critical-human-gate or a token-guard re-estimate, except complexity rule: implementer runs on the executor class and may be spawned on balanced for high/extra-high or security-sensitive items or after a FAIL (emit model-escalated)
gates are scripts: done only when the state exit-check tool passes; exit 3 (deferred) is never a pass
continuity: at the soft usage threshold spawn nothing new; the hard threshold writes a restore point and suspends
meta-agents (butler, token-guard) stay on their fast/low profile
deepthinking: only the kernel/models.json deep_tasks may run on the deep tier (xhigh/max), only after the human sees the cost range and approves (events deep-proposed, deep-approved|deep-declined, deep-spawned, deep-completed); never silent; the orchestrator may propose it in auto and fasttrack, and the human can start one anytime with /deep
RULES
    printf '  "spawn_protocol": {"doc":"coordination/orchestrator.md#spawn-protocol","rules":[%s],"effort_levels":["low","medium","high","xhigh","max"]},\n' "$rules"
    echo '  "model_classes": {'
    local sep=""
    for cls in $CLASSES; do
      k="${cls//-/_}"
      local a="M_claude_$k" b="DE_$k" c="M_claude_id_$k" d="M_codex_$k" e="M_opencode_$k" f="M_ollama_$k" u="USE_$k"
      json_str "${!u}"
      printf '%s    "%s": {"default_effort":"%s","claude":"%s","claude_model_id":"%s","codex":"%s","opencode":"%s","ollama":"%s","use":%s}' \
        "$sep" "$cls" "${!b}" "${!a}" "${!c}" "${!d}" "${!e}" "${!f}" "$R"
      sep=$',\n'
    done
    echo
    echo '  },'
    echo '  "agents": ['
    for ((i = 0; i < NA; i++)); do
      local jn jr js ji jo jc jm jid je jx jcx jcxe joc jol
      json_str "${P_NAME[i]}"; jn="$R"
      json_str "${P_ROLE[i]}"; jr="$R"
      mget "a$i" zzf200_description; json_str "$R"; js="$R"
      mget "a$i" zzf200_inputs; json_str "$R"; ji="$R"
      mget "a$i" zzf200_outputs; json_str "$R"; jo="$R"
      json_str "${P_CLS[i]}"; jc="$R"
      json_str "${P_EFF[i]}"; je="$R"
      json_str "${P_CMODEL[i]}"; jm="$R"
      json_str "${P_CID[i]}"; jid="$R"
      json_list "${P_SCOPES[i]}"; jx="$R"
      json_str "${P_CODEX[i]}"; jcx="$R"
      json_str "${P_CODEXE[i]}"; jcxe="$R"
      json_str "${P_OC[i]}"; joc="$R"
      json_str "${P_OL[i]}"; jol="$R"
      json_str ".KCC/capabilities/agents/${P_NAME[i]}.md"
      (( i > 0 )) && echo ','
      printf '    {"name":%s,"role":%s,"summary":%s,"inputs":%s,"outputs":%s,"spawn":{"model_class":%s,"effort":%s,"claude":{"model":%s,"model_id":%s,"effort":%s,"tools":%s,"exec_scope":%s},"codex":{"model":%s,"effort":%s},"opencode":{"model":%s},"ollama":{"model":%s}},"definition":%s}' \
        "$jn" "$jr" "$js" "$ji" "$jo" "$jc" "$je" "$jm" "$jid" "$je" "${P_TOOLSJ[i]}" "$jx" "$jcx" "$jcxe" "$joc" "$jol" "$R"
    done
    (( NA > 0 )) && echo
    echo '  ],'
    # skills (followed by the preserved runtime keys, if any)
    local trailing=","
    [[ -n "$runtime" ]] || trailing=""
    echo '  "skills": ['
    for ((i = 0; i < NS; i++)); do
      local sn su sd sl
      mget "s$i" zzname; json_str "$R"; sn="$R"
      mget "s$i" zzusage; json_str "$R"; su="$R"
      mget "s$i" delegates_to; json_list "$R"; sl="$R"
      mget "s$i" zzf200_description; json_str "$R"; sd="$R"
      (( i > 0 )) && echo ','
      printf '    {"name":%s,"usage":%s,"delegates_to":%s,"summary":%s}' "$sn" "$su" "$sl" "$sd"
    done
    (( NS > 0 )) && echo
    echo "  ]$trailing"
    if [[ -n "$runtime" ]]; then
      local -a RK=() RV=(); local rk rv rn
      while IFS="$SEP" read -r rk rv; do
        [[ -n "$rk" ]] || continue
        RK[${#RK[@]}]="$rk"; RV[${#RV[@]}]="$rv"
      done <<< "$runtime"
      rn=${#RK[@]}
      for ((i = 0; i < rn; i++)); do
        if (( i < rn - 1 )); then printf '  "%s": %s,\n' "${RK[i]}" "${RV[i]}"; else printf '  "%s": %s\n' "${RK[i]}" "${RV[i]}"; fi
      done
    fi
    printf '}'
  } > "$json"
  track "$json"
}

# ---------------------------------------------------------------------------
# Per-harness sync
# ---------------------------------------------------------------------------
sync_claude() {
  local agents_out="$REPO_ROOT/.claude/agents"
  local skills_out="$REPO_ROOT/.claude/skills"
  mkdir -p "$agents_out" "$skills_out"
  local i name desc fm
  for ((i = 0; i < NA; i++)); do
    name="${P_NAME[i]}"
    mget "a$i" zzf300_description; desc="  $R"
    obs_block "a$i"
    fm="---${NL}name: $name${NL}description: >${NL}$desc${NL}model: ${P_CMODEL[i]}${NL}effort: ${P_EFF[i]}${NL}tools: ${P_TOOLS[i]}${NL}$R${NL}---"
    { printf '%s\n\n' "$fm"; body_emit "a$i" "" "" 1 "$RUNTIME_FOOT"; } > "$agents_out/$name.md"
    track "$agents_out/$name.md"
    echo "[claude   ] [agent ] $agents_out/$name.md"
  done
  for ((i = 0; i < NS; i++)); do
    mget "s$i" zzname; name="$R"
    mget "s$i" zzn_description; desc="  $R"
    obs_block "s$i"
    fm="---${NL}name: $name${NL}description: >${NL}$desc${NL}$R${NL}---"
    mkdir -p "$skills_out/$name"
    { printf '%s\n\n' "$fm"; body_emit "s$i" "${SK_PH[i]}" '$ARGUMENTS' 1 "${SK_FOOT[i]}"; } > "$skills_out/$name/SKILL.md"
    track "$skills_out/$name/SKILL.md"
    echo "[claude   ] [skill ] $skills_out/$name/SKILL.md"
  done

  # Seed .claude/settings.json from the kernel template ONLY when absent.
  local claude_settings="$REPO_ROOT/.claude/settings.json"
  local settings_tpl="$REPO_ROOT/.KCC/kernel/templates/claude-settings.json"
  if [[ ! -f "$claude_settings" ]]; then
    if [[ -f "$settings_tpl" ]]; then
      cp "$settings_tpl" "$claude_settings"
      echo "[claude   ] [config] $claude_settings (seeded from template)"
    fi
  else
    echo "[claude   ] [config] $claude_settings is hand-edited and was not touched."
  fi
}

# tools_lines PFX -> R  ("  - x" per line, joined with newline; cleaned of comments)
tools_lines() {
  local -a tl=(); local out="" j n
  mget "$1" tools_required
  if [[ -n "$R" ]]; then IFS="$LSEP" read -r -a tl <<< "$R" || true; fi
  n=${#tl[@]}
  for ((j = 0; j < n; j++)); do out+="${out:+$NL}  - ${tl[j]}"; done
  R="$out"
}

sync_codex() {
  local agents_out="$REPO_ROOT/.codex/agents"
  local skills_out="$REPO_ROOT/.codex/skills"
  local tools_out="$REPO_ROOT/.codex/tools"
  mkdir -p "$agents_out" "$skills_out" "$tools_out"
  local i name role desc tl fm ob
  for ((i = 0; i < NA; i++)); do
    name="${P_NAME[i]}"
    mget "a$i" role; role="$R"
    desc_raw_oneline "a$i"; desc="  $R"
    tools_lines "a$i"; tl="$R"
    obs_block "a$i"; ob="$R"
    fm="---${NL}name: $name${NL}role: $role${NL}model: ${P_CODEX[i]}${NL}model_reasoning_effort: ${P_CODEXE[i]}${NL}model-class: ${P_CLS[i]}${NL}effort: ${P_EFF[i]}${NL}description: >${NL}$desc${NL}tools:${NL}$tl${NL}$ob${NL}---"
    { printf '%s\n\n' "$fm"; body_emit "a$i" "" "" 1 "$RUNTIME_FOOT"; } > "$agents_out/$name.md"
    track "$agents_out/$name.md"
    echo "[codex    ] [agent ] $agents_out/$name.md"
  done
  for ((i = 0; i < NS; i++)); do
    mget "s$i" zzname; name="$R"
    mkdir -p "$skills_out/$name/agents"
    skill_package "$i" '$1' codex > "$skills_out/$name/SKILL.md"
    track "$skills_out/$name/SKILL.md"
    echo "[codex    ] [skill ] $skills_out/$name/SKILL.md"
    mget "s$i" zzopenai
    printf '%s' "${R//$NLC/$NL}" > "$skills_out/$name/agents/openai.yaml"
    track "$skills_out/$name/agents/openai.yaml"
    echo "[codex    ] [skill-ui] $skills_out/$name/agents/openai.yaml"
  done
  printf '%s' '# Codex tools

Codex exposes tools through the active CLI sandbox, approval policy, installed
MCP servers, and enabled plugins. This framework'\''s neutral `tools-required`
metadata is mirrored into each generated agent file for routing context; the
initializer does not grant tools globally or mutate user-level Codex config.

Keep tool wiring local-first. Add global MCP servers, plugins, or meta-agent
tooling through a separate bootstrap pipeline when the project proves it needs
them.' > "$tools_out/README.md"
  track "$tools_out/README.md"
  echo "[codex    ] [tools ] $tools_out/README.md"
  if [[ ! -f "$REPO_ROOT/.codex/config.toml" ]]; then
    printf '%s' '# Project-scoped Codex CLI hints. Generated by .KCC/tools/sync-adapters.ps1.
# Edit freely; this file will NOT be overwritten on subsequent syncs.

[project]
name = "spec-driven-framework"
entrypoint = "AGENTS.md"

[notes]
# Codex CLI reads AGENTS.md at the repo root automatically.
# Per-agent .md files live in .codex/agents/ for human navigation;
# Codex does not auto-load them today but they mirror .claude/agents/.
# Native project-local skill packages live in .codex/skills/{name}/SKILL.md.
# This initializer does not write to ~/.codex/skills or ~/.codex/prompts.' > "$REPO_ROOT/.codex/config.toml"
    track "$REPO_ROOT/.codex/config.toml"
    echo "[codex    ] [config] $REPO_ROOT/.codex/config.toml"
  fi
  # An `&&` list as the last statement would make the function return 1 and end the script under `set -e`.
  if (( INSTALL_CODEX_SKILLS == 1 )); then echo "[codex    ] project-local Codex skills initialized"; fi
}

sync_opencode() {
  local agents_out="$REPO_ROOT/.opencode/agents"
  local commands_out="$REPO_ROOT/.opencode/commands"
  local skills_out="$REPO_ROOT/.opencode/skills"
  mkdir -p "$agents_out" "$commands_out" "$skills_out"
  local i name desc fm ob perm
  for ((i = 0; i < NA; i++)); do
    name="${P_NAME[i]}"
    desc_raw_oneline "a$i"; desc="  $R"
    # Resolve-OpenCodePermissions
    local hr=0 hs=0 he=0 hx=0 hw=0
    local -a tl=()
    mget "a$i" tools_required
    if [[ -n "$R" ]]; then IFS="$LSEP" read -r -a tl <<< "$R" || true; fi
    local n=${#tl[@]} j
    for ((j = 0; j < n; j++)); do
      case "${tl[j]}" in read) hr=1 ;; search) hs=1 ;; edit) he=1 ;; exec) hx=1 ;; web) hw=1 ;; esac
    done
    perm=""
    if (( hr || hs )); then perm+="  read: allow$NL"; fi
    if (( hs )); then perm+="  glob: allow${NL}  grep: allow${NL}  list: allow$NL"; fi
    if (( he )); then perm+="  edit: allow$NL"; else perm+="  edit: deny$NL"; fi
    if (( hx )); then perm+="  bash: allow$NL"; else perm+="  bash: deny$NL"; fi
    if (( hw )); then perm+="  webfetch: allow${NL}  websearch: allow$NL"; fi
    perm+="  skill: allow"
    obs_block "a$i"; ob="$R"
    fm="---${NL}description: >${NL}$desc${NL}mode: subagent${NL}model: ${P_OC[i]}${NL}permission:${NL}$perm${NL}$ob${NL}---"
    { printf '%s\n\n' "$fm"; body_emit "a$i" "" "" 1 "$RUNTIME_FOOT"; } > "$agents_out/$name.md"
    track "$agents_out/$name.md"
    echo "[opencode ] [agent ] $agents_out/$name.md"
  done
  for ((i = 0; i < NS; i++)); do
    mget "s$i" zzname; name="$R"
    mget "s$i" zzn_description; desc="  $R"
    obs_block "s$i"; ob="$R"
    fm="---${NL}description: >${NL}$desc${NL}$ob${NL}---"
    { printf '%s\n\n' "$fm"; body_emit "s$i" "${SK_PH[i]}" '$ARGUMENTS' 0 ""; } > "$commands_out/$name.md"
    track "$commands_out/$name.md"
    echo "[opencode ] [skill ] $commands_out/$name.md"
    mkdir -p "$skills_out/$name"
    skill_package "$i" '$ARGUMENTS' opencode > "$skills_out/$name/SKILL.md"
    track "$skills_out/$name/SKILL.md"
    echo "[opencode ] [skillpkg] $skills_out/$name/SKILL.md"
  done
  if [[ ! -f "$REPO_ROOT/opencode.json" ]]; then
    printf '%s' '{
  "$schema": "https://opencode.ai/config.json",
  "theme": "system",
  "model": "anthropic/claude-sonnet-5-5",
  "autoshare": false,
  "autoupdate": false,
  "permission": {
    "skill": {
      "*": "allow"
    }
  }
}' > "$REPO_ROOT/opencode.json"
    track "$REPO_ROOT/opencode.json"
    echo "[opencode ] [config] $REPO_ROOT/opencode.json"
  fi
}

sync_generic() {
  local base="$REPO_ROOT/.agents"
  local agents_out="$base/agents"
  local skills_out="$base/skills"
  local tools_out="$base/tools"
  mkdir -p "$agents_out" "$skills_out" "$tools_out"
  local i name role mcls desc tl ob fm gen
  local mag="" msk="" cat_a="" cat_s=""
  for ((i = 0; i < NA; i++)); do
    name="${P_NAME[i]}"
    mget "a$i" role; role="$R"
    mget "a$i" model_class; mcls="$R"
    mget "a$i" zzn_description; desc="$R"
    tools_lines "a$i"; tl="$R"; [[ -n "$tl" ]] || tl="  - read"
    obs_block "a$i"; ob="$R"
    fm="---${NL}name: $name${NL}role: $role${NL}model-class: $mcls${NL}effort: ${P_EFF[i]}${NL}description: >${NL}  $desc${NL}tools-required:${NL}$tl${NL}$ob${NL}---"
    { printf '%s\n\n' "$fm"; body_emit "a$i" "" "" 1 "$RUNTIME_FOOT"; } > "$agents_out/$name.md"
    track "$agents_out/$name.md"
    echo "[generic  ] [agent ] $agents_out/$name.md"
    # manifest entry (ConvertTo-Json, PowerShell 7 layout)
    local jn jr jm je jd jt jtools="" tj
    json_str "$name"; jn="$R"
    json_str "$role"; jr="$R"
    json_str "$mcls"; jm="$R"
    json_str "${P_EFF[i]}"; je="$R"
    json_str "$desc"; jd="$R"
    mget "a$i" tools_required
    local -a tla=(); if [[ -n "$R" ]]; then IFS="$LSEP" read -r -a tla <<< "$R" || true; fi
    local n=${#tla[@]} j
    if (( n == 0 )); then jtools="[]"
    else
      jtools="["
      for ((j = 0; j < n; j++)); do json_str "${tla[j]}"; jtools+="${NL}        $R"; (( j < n - 1 )) && jtools+=","; done
      jtools+="${NL}      ]"
    fi
    json_str "agents/$name.md"; jt="$R"
    [[ -n "$mag" ]] && mag+=","
    mag+="${NL}    {${NL}      \"name\": $jn,${NL}      \"role\": $jr,${NL}      \"model_class\": $jm,${NL}      \"effort\": $je,${NL}      \"description\": $jd,${NL}      \"tools_required\": $jtools,${NL}      \"path\": $jt${NL}    }"
    cat_a+="- \`$name\` - $desc$NL"
  done
  for ((i = 0; i < NS; i++)); do
    mget "s$i" zzname; name="$R"
    mget "s$i" zzn_description; desc="$R"
    mkdir -p "$skills_out/$name"
    skill_package "$i" '<ARGS>' generic > "$skills_out/$name/SKILL.md"
    track "$skills_out/$name/SKILL.md"
    echo "[generic  ] [skill ] $skills_out/$name/SKILL.md"
    local sn sdsc sp
    json_str "$name"; sn="$R"
    json_str "$desc"; sdsc="$R"
    json_str "skills/$name/SKILL.md"; sp="$R"
    [[ -n "$msk" ]] && msk+=","
    msk+="${NL}    {${NL}      \"name\": $sn,${NL}      \"description\": $sdsc,${NL}      \"path\": $sp${NL}    }"
    cat_s+="- \`/$name\` - $desc$NL"
  done
  printf '%s' '# Generic tool contract

Generic harnesses should map each agent'\''s `tools-required` values to their
own permission system:

| Neutral tool | Expected capability |
|--------------|---------------------|
| `read`     | Read project files |
| `search`   | Glob, grep, or semantic search over project files |
| `edit`     | Create and modify files in the workspace |
| `exec`     | Run shell commands subject to the harness approval policy |
| `web`      | Fetch or search web documentation when enabled |

This directory is descriptive only. It does not grant permissions by itself.' > "$tools_out/README.md"
  track "$tools_out/README.md"
  echo "[generic  ] [tools ] $tools_out/README.md"
  printf '%s' '{
  "schema": "spec-driven-framework.generic-agents.v1",
  "schema_version": "1.0",
  "entrypoint": "../AGENTS.md",
  "agents_path": "agents",
  "skills_path": "skills",
  "tools_path": "tools",
  "local_only": true
}' > "$base/config.json"
  track "$base/config.json"
  echo "[generic  ] [config] $base/config.json"
  gen="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf '{\n  "schema_version": "1.0",\n  "generated": "%s",\n  "entrypoint": "../AGENTS.md",\n' "$gen"
    if [[ -n "$mag" ]]; then printf '  "agents": [%s\n  ],\n' "$mag"; else printf '  "agents": [],\n'; fi
    if [[ -n "$msk" ]]; then printf '  "skills": [%s\n  ]\n' "$msk"; else printf '  "skills": []\n'; fi
    printf '}'
  } > "$base/manifest.json"
  track "$base/manifest.json"
  echo "[generic  ] [manifest] $base/manifest.json"
  {
    printf '%s\n' '# Generic Agent Bundle'
    printf '\n'
    printf '%s\n' 'This folder is generated from `.KCC/kernel/` and `.KCC/capabilities/` for harnesses that understand the common `.agents` convention.'
    printf '\n## Agents\n\n'
    printf '%s' "$cat_a"
    printf '\n## Skills\n\n'
    printf '%s' "$cat_s"
  } > "$base/AGENTS.md"
  track "$base/AGENTS.md"
  echo "[generic  ] [catalog] $base/AGENTS.md"
}

sync_ollama() {
  local out="$REPO_ROOT/ollama" gen i
  mkdir -p "$out"
  gen="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local ag="" jn jm jo jd cls k v
  for ((i = 0; i < NA; i++)); do
    json_str "${P_NAME[i]}"; jn="$R"
    mget "a$i" model_class; json_str "$R"; jm="$R"
    json_str "${P_OL[i]}"; jo="$R"
    mget "a$i" description; json_str "${R//$NLC/$NL}"; jd="$R"
    [[ -n "$ag" ]] && ag+=","
    ag+="${NL}    {${NL}      \"name\": $jn,${NL}      \"model_class\": $jm,${NL}      \"ollama_model\": $jo,${NL}      \"description\": $jd${NL}    }"
  done
  {
    printf '{\n  "schema_version": "1.0",\n  "generated": "%s",\n  "model_class_map": {\n' "$gen"
    local sep=""
    for cls in $CLASSES; do
      k="M_ollama_${cls//-/_}"
      printf '%s    "%s": "%s"' "$sep" "$cls" "${!k}"
      sep=$',\n'
    done
    printf '\n  },\n'
    if [[ -n "$ag" ]]; then printf '  "agents": [%s\n  ]\n' "$ag"; else printf '  "agents": []\n'; fi
    printf '}'
  } > "$out/agents.json"
  track "$out/agents.json"
  echo "[ollama   ] [manifest] $out/agents.json"
  printf '%s' "---
title: Ollama Bindings
tags:
  - framework/adapter
  - harness/ollama
created: $TODAY
updated: $TODAY
version: 1.0.0
status: active
---

# Ollama bindings

Ollama is a model runner, not an agent harness. This directory holds the
mapping from each neutral agent to a recommended Ollama model, so a harness
that talks to Ollama via an OpenAI-compatible bridge (OpenCode, Continue,
LiteLLM, etc.) can pick sensible defaults per agent.

## Files

- \`agents.json\` - per-agent and per-model-class recommendations. Regenerate
  with \`powershell .KCC/tools/sync-adapters.ps1 -Harness ollama\`.

## Wire-up (OpenCode example)

OpenCode's per-agent \`model:\` field can reference an Ollama bridge. Set
your OpenCode provider to point at \`http://localhost:11434/v1\` and use
the model ids from this manifest.

## Default mapping

| Model class           | Ollama model    |
|-----------------------|-----------------|
| strong-reasoning      | qwen2.5:72b     |
| balanced              | qwen2.5:32b     |
| fast-implementation   | qwen2.5:14b     |
| local-strong          | qwen2.5:72b     |
| local-fast            | qwen2.5:7b      |

Override per-agent by editing \`agents.json\` after sync." > "$out/README.md"
  track "$out/README.md"
  echo "[ollama   ] [readme  ] $out/README.md"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
TODAY="$(date +%F)"

echo
echo "Reading KCC kernel/capabilities from: $REPO_ROOT"
load_sources
echo "  parsed: $NA agents, $NS skills"
compute_profiles
prep_skills
build_tables

echo
echo "Initializing framework infrastructure"
echo
initialize_framework
echo
echo "Generating for harness: $HARNESS"
echo

case "$HARNESS" in
  claude) sync_claude ;;
  codex) sync_codex ;;
  opencode) sync_opencode ;;
  generic) sync_generic ;;
  ollama) sync_ollama ;;
  all)
    sync_claude
    sync_codex
    sync_opencode
    sync_generic
    sync_ollama
    ;;
esac

# Write-time guard sweep over the files written in this run.
strip_ctrl_files "${GEN_FILES[@]}"

echo
echo "Sync complete for harness: $HARNESS"
echo "Source of truth: .KCC/kernel and .KCC/capabilities"
echo "Generated adapter surfaces are local output and should not be committed."
