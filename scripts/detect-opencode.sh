#!/usr/bin/env bash
# detect-opencode.sh — read-only detection of opencode-family installs + Node managers.
# Compatible with: Linux, macOS, WSL, Git Bash on Windows.
# Output: 4 tables (registry latest / installed copies / node managers / CLI resolution).
# Exits: 0 if all known copies fresh AND CLI points to latest, else 1.
#
# Usage:
#   bash scripts/detect-opencode.sh
set -euo pipefail
IFS=$'\n\t'

VERSION="1.0.0"

# ---- help ----
show_help() {
  sed -n '/^# detect/,/^#$/ {s/^# \?//p}' "$0"
  echo
  echo "Version: $VERSION"
  echo "Usage: $0 [--help | --version]"
}

for arg in "$@"; do
  case "$arg" in
    --help|-h) show_help; exit 0 ;;
    --version|-v) echo "detect-opencode.sh version $VERSION"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ---- constants ----
PKG_NAMES=("opencode-ai" "oh-my-opencode" "@opencode-ai/plugin")
REGISTRY_BASE="https://registry.npmjs.org"

# ---- helpers ----
have() { command -v "$1" >/dev/null 2>&1; }

# Robust JSON value extractor (no jq). Finds first "key" : "value" pair at any depth.
json_get() {
  local f="$1" key="$2"
  [ -r "$f" ] || { echo "MISSING"; return; }
  awk -v k="$key" -F'"' '{
    for (i=1; i<=NF; i++) {
      if ($i == k) { print $(i+2); exit }
    }
  }' "$f" 2>/dev/null | head -n1
}

pkgjson_version() { json_get "$1" "version"; }
pkgjson_dep()     { json_get "$1" "$2"; }

# Fetch latest version from npm registry.
registry_latest() {
  local pkg="$1" url="${REGISTRY_BASE}/${pkg}/latest" body=""
  if have curl; then
    body="$(curl -fsSL --max-time 10 "$url" 2>/dev/null)" || true
  elif have wget; then
    body="$(wget -qO- --timeout=10 "$url" 2>/dev/null)" || true
  else
    echo "NO_HTTP_TOOL"; return
  fi
  [ -n "$body" ] || { echo "FETCH_FAILED"; return; }
  printf '%s' "$body" | awk -F'"' '{
    for (i=1; i<=NF; i++) {
      if ($i == "version") { print $(i+2); exit }
    }
  }'
}

# Compare two semver-ish strings (x.y.z). Echoes: GT | LT | EQ | UNKNOWN
ver_cmp() {
  local a="$1" b="$2"
  [[ "$a" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "UNKNOWN"; return; }
  [[ "$b" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "UNKNOWN"; return; }
  local IFS=. i a_parts b_parts
  a_parts=($a)
  b_parts=($b)
  local n=$(( ${#a_parts[@]} > ${#b_parts[@]} ? ${#a_parts[@]} : ${#b_parts[@]} ))
  for (( i=0; i<n; i++ )); do
    local ai="${a_parts[i]:-0}" bi="${b_parts[i]:-0}"
    if (( 10#$ai > 10#$bi )); then echo "GT"; return; fi
    if (( 10#$ai < 10#$bi )); then echo "LT"; return; fi
  done
  echo "EQ"
}

status_for() {
  local installed="$1" latest="$2"
  [ "$installed" = "MISSING" ] && { echo "MISSING"; return; }
  [ "$installed" = "UNKNOWN" ] && { echo "UNKNOWN"; return; }
  [ -z "$installed" ] && { echo "UNKNOWN"; return; }
  case "$(ver_cmp "$installed" "$latest")" in
    EQ) echo "FRESH" ;;
    LT) echo "STALE" ;;
    GT) echo "AHEAD" ;;
    *)  echo "UNKNOWN" ;;
  esac
}

extract_version() {
  local raw="$1"
  printf '%s' "$raw" | tr -d 'v' | awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\./) {print $i; exit}}'
}

# ---- OS detect ----
os_detect() {
  case "$(uname -s 2>/dev/null)" in
    Linux*)  echo "linux" ;;
    Darwin*) echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows-gitbash" ;;
    *) echo "unknown" ;;
  esac
}
OS="$(os_detect)"

# ---- HOME / USERPROFILE resolution ----
if [ "$OS" = "windows-gitbash" ] && [ -n "${USERPROFILE:-}" ]; then
  HOME_DIR="$(cygpath -u "$USERPROFILE" 2>/dev/null || echo "$HOME")"
else
  HOME_DIR="$HOME"
fi

# ---- print helpers ----
print_table_header() {
  printf '\n=== %s ===\n' "$1"
  printf '%-16s %-50s %-22s %-10s\n' "$2" "$3" "$4" "$5"
  printf '%.0s-' {1..100}; echo
}

# We collect installed rows as tab-separated: ENV \t PATH \t VERSION \t LATEST_REF
declare -a INSTALLED_ROWS=()
declare -A SEEN_ROWS=()

add_row() {
  local env="$1" path="$2" ver="$3" latest_ref="$4"
  [ "$ver" = "MISSING" ] && return
  [ -z "$ver" ] && return
  local key="${env}|${path}"
  [ -n "${SEEN_ROWS[$key]:-}" ] && return
  SEEN_ROWS[$key]=1
  INSTALLED_ROWS+=("$(printf '%s\t%s\t%s\t%s' "$env" "$path" "$ver" "$latest_ref")")
}

# ---- A. Registry latest ----
print_table_header "A. Registry latest (npm)" "package" "latest" "" ""
declare -A REG_LATEST=()
for pkg in "${PKG_NAMES[@]}"; do
  v="$(registry_latest "$pkg")"
  REG_LATEST["$pkg"]="$v"
  printf '%-16s %-50s\n' "$pkg" "$v"
done

# ---- B. Installed copies ----
print_table_header "B. Installed copies" "env" "path" "version" "status"

# 1) Downloaded binary at ~/.opencode/bin/opencode
BIN_PATH="$HOME_DIR/.opencode/bin/opencode"
if [ -x "$BIN_PATH" ]; then
  raw_v="$("$BIN_PATH" --version 2>/dev/null || true)"
  v="$(extract_version "$raw_v")"
  [ -n "$v" ] || v="UNKNOWN"
  add_row "binary" "$BIN_PATH" "$v" "${REG_LATEST[opencode-ai]}"
fi

# 1b) Plugin tree under ~/.opencode/package.json
PLUG_PKG="$HOME_DIR/.opencode/package.json"
if [ -r "$PLUG_PKG" ]; then
  dep_v="$(pkgjson_dep "$PLUG_PKG" "@opencode-ai/plugin")"
  inst_v="$(pkgjson_version "$HOME_DIR/.opencode/node_modules/@opencode-ai/plugin/package.json")"
  add_row "opencode-plugins" "$PLUG_PKG" "declared=${dep_v} installed=${inst_v}" "${REG_LATEST[@opencode-ai/plugin]}"
fi

# 2) npm global (skip if vite-plus shim)
if have npm; then
  NPM_GLOBAL_ROOT="$(npm root -g 2>/dev/null)"
  if [ -n "$NPM_GLOBAL_ROOT" ] && [ -d "$NPM_GLOBAL_ROOT" ] \
     && [[ "$NPM_GLOBAL_ROOT" != *".vite-plus"* ]]; then
    for pkg in opencode-ai oh-my-opencode; do
      pj="$NPM_GLOBAL_ROOT/$pkg/package.json"
      v="$(pkgjson_version "$pj")"
      add_row "npm-global" "$pj" "$v" "${REG_LATEST[$pkg]}"
    done
  fi
fi

# 3) pnpm global (skip if vite-plus shim)
if have pnpm; then
  PNPM_GLOBAL_ROOT="$(pnpm root -g 2>/dev/null)"
  if [ -n "$PNPM_GLOBAL_ROOT" ] && [ -d "$PNPM_GLOBAL_ROOT" ] \
     && [[ "$PNPM_GLOBAL_ROOT" != *".vite-plus"* ]]; then
    for pkg in opencode-ai oh-my-opencode; do
      pj="$PNPM_GLOBAL_ROOT/$pkg/package.json"
      v="$(pkgjson_version "$pj")"
      add_row "pnpm-global" "$pj" "$v" "${REG_LATEST[$pkg]}"
    done
  fi
fi

# 3b) Fallback: standard pnpm global dir
PNPM_FALLBACK="$HOME_DIR/.local/share/pnpm"
if [ -d "$PNPM_FALLBACK" ] && [[ "${PNPM_GLOBAL_ROOT:-}" != *"$PNPM_FALLBACK"* ]]; then
  for pkg in opencode-ai oh-my-opencode; do
    for cand in "$PNPM_FALLBACK/.global" "$PNPM_FALLBACK/global" "$PNPM_FALLBACK"; do
      pj="$cand/node_modules/$pkg/package.json"
      if [ -r "$pj" ]; then
        v="$(pkgjson_version "$pj")"
        add_row "pnpm-global" "$pj" "$v" "${REG_LATEST[$pkg]}"
      fi
    done
  done
fi

# 4) Bun global
if have bun; then
  HOME_PKG="$HOME_DIR/package.json"
  if [ -r "$HOME_PKG" ]; then
    for pkg in opencode-ai oh-my-opencode; do
      dep_v="$(pkgjson_dep "$HOME_PKG" "$pkg")"
      inst_v="$(pkgjson_version "$HOME_DIR/node_modules/$pkg/package.json")"
      add_row "bun-global" "${HOME_PKG} [${pkg}]" "declared=${dep_v} installed=${inst_v}" "${REG_LATEST[$pkg]}"
    done
  fi
  BUN_GLOBAL="$HOME_DIR/.bun/install/global"
  if [ -d "$BUN_GLOBAL/node_modules" ]; then
    for pkg in opencode-ai oh-my-opencode; do
      pj="$BUN_GLOBAL/node_modules/$pkg/package.json"
      if [ -r "$pj" ]; then
        v="$(pkgjson_version "$pj")"
        add_row "bun-global" "$pj" "v=${v}" "${REG_LATEST[$pkg]}"
      fi
    done
  fi
fi

# 5) vite-plus packages
VP_DIR="$HOME_DIR/.vite-plus"
if [ -d "$VP_DIR/packages" ]; then
  for pkg in opencode-ai oh-my-opencode; do
    pj="$VP_DIR/packages/$pkg/lib/node_modules/$pkg/package.json"
    v="$(pkgjson_version "$pj")"
    add_row "vite-plus" "$pj" "$v" "${REG_LATEST[$pkg]}"
  done
fi

# 6) Volta
VOLTA_DIR="$HOME_DIR/.volta"
if [ -d "$VOLTA_DIR/tools/image/packages" ]; then
  for pkg in opencode-ai oh-my-opencode; do
    for ver_dir in "$VOLTA_DIR/tools/image/packages/$pkg"/*; do
      [ -d "$ver_dir" ] || continue
      pj="$ver_dir/lib/node_modules/$pkg/package.json"
      [ -r "$pj" ] || pj="$ver_dir/node_modules/$pkg/package.json"
      v="$(pkgjson_version "$pj")"
      add_row "volta" "$pj" "$v" "${REG_LATEST[$pkg]}"
    done
  done
fi

# 7) nvm
NVM_DIR="${NVM_DIR:-$HOME_DIR/.nvm}"
if [ -d "$NVM_DIR/versions/node" ]; then
  for node_dir in "$NVM_DIR"/versions/node/*; do
    [ -d "$node_dir" ] || continue
    for pkg in opencode-ai oh-my-opencode; do
      pj="$node_dir/lib/node_modules/$pkg/package.json"
      v="$(pkgjson_version "$pj")"
      add_row "nvm" "$pj" "$v" "${REG_LATEST[$pkg]}"
    done
  done
fi

# 8) fnm
FNM_DIR="$HOME_DIR/.fnm"
FNM_MAC_DIR="$HOME_DIR/Library/Application Support/fnm/node-versions"
for base in "$FNM_DIR/node-versions" "$FNM_MAC_DIR"; do
  if [ -d "$base" ]; then
    for node_dir in "$base"/*/installation; do
      [ -d "$node_dir" ] || continue
      for pkg in opencode-ai oh-my-opencode; do
        pj="$node_dir/lib/node_modules/$pkg/package.json"
        v="$(pkgjson_version "$pj")"
        add_row "fnm" "$pj" "$v" "${REG_LATEST[$pkg]}"
      done
    done
  fi
done

# 9) nvm-windows
if [ -n "${APPDATA:-}" ] && [ -d "${APPDATA}/nv" ]; then
  for node_dir in "${APPDATA}"/nv/node/*; do
    [ -d "$node_dir" ] || continue
    for pkg in opencode-ai oh-my-opencode; do
      pj="$node_dir/node_modules/$pkg/package.json"
      v="$(pkgjson_version "$pj")"
      add_row "nvm-windows" "$pj" "$v" "${REG_LATEST[$pkg]}"
    done
  done
fi

# Print B rows
exit_code_main=0
if [ "${#INSTALLED_ROWS[@]}" -gt 0 ]; then
  for row in "${INSTALLED_ROWS[@]}"; do
    [ -z "$row" ] && continue
    env="$(printf '%s' "$row" | awk -F'\t' '{print $1}')"
    path="$(printf '%s' "$row" | awk -F'\t' '{print $2}')"
    ver="$(printf '%s' "$row" | awk -F'\t' '{print $3}')"
    latest_ref="$(printf '%s' "$row" | awk -F'\t' '{print $4}')"
    if [[ "$ver" == declared=*installed=* ]]; then
      inst_v="${ver##*installed=}"
      st="$(status_for "$inst_v" "$latest_ref")"
    elif [[ "$ver" == v=* ]]; then
      inst_v="${ver#v=}"
      st="$(status_for "$inst_v" "$latest_ref")"
    else
      st="$(status_for "$ver" "$latest_ref")"
    fi
    printf '%-16s %-50s %-22s %-10s\n' "$env" "$path" "$ver" "$st"
    [ "$st" = "STALE" ] && exit_code_main=1
  done
else
  printf '(no opencode-family installs detected)\n'
fi

# ---- C. Node managers ----
print_table_header "C. Node version managers" "manager" "bin / path" "versions" "current"

# vite-plus
if have vp; then
  vp_bin="$(command -v vp)"
  vp_versions=""
  if [ -d "$HOME_DIR/.vite-plus/js_runtime/node" ]; then
    vp_versions="$(ls "$HOME_DIR/.vite-plus/js_runtime/node" 2>/dev/null | grep -vE '\.lock$|\.json$' | tr '\n' ',' | sed 's/,$//')"
  fi
  cur_link="$HOME_DIR/.vite-plus/current"
  cur_ver="$(basename "$(readlink -f "$cur_link" 2>/dev/null)" 2>/dev/null || true)"
  node_cur="$(node --version 2>/dev/null || true)"
  printf '%-16s %-50s %-22s %-10s\n' "vite-plus" "$vp_bin" "$vp_versions" "vp=$cur_ver node=$node_cur"
fi

# nvm
if [ -d "$NVM_DIR" ] || [ -s "$NVM_DIR/nvm.sh" ]; then
  nvm_bin="$NVM_DIR/nvm.sh"
  nvm_versions="$(ls "$NVM_DIR/versions/node" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
  printf '%-16s %-50s %-22s %-10s\n' "nvm" "$nvm_bin" "$nvm_versions" "(use nvm current)"
fi

# fnm
if have fnm; then
  fnm_bin="$(command -v fnm)"
  fnm_versions="$(fnm list 2>/dev/null | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')"
  fnm_cur="$(fnm current 2>/dev/null)"
  printf '%-16s %-50s %-22s %-10s\n' "fnm" "$fnm_bin" "$fnm_versions" "$fnm_cur"
fi

# volta
if have volta; then
  volta_bin="$(command -v volta)"
  volta_versions="$(volta list all 2>/dev/null | awk '/node@/ {print $1}' | tr '\n' ',' | sed 's/,$//')"
  printf '%-16s %-50s %-22s %-10s\n' "volta" "$volta_bin" "$volta_versions" "(per-project pin)"
fi

# bun runtime
if have bun; then
  bun_bin="$(command -v bun)"
  bun_ver="$(bun --version 2>/dev/null)"
  printf '%-16s %-50s %-22s %-10s\n' "bun-runtime" "$bun_bin" "-" "$bun_ver"
fi

# nvm-windows
if [ -n "${APPDATA:-}" ] && [ -d "${APPDATA}/nv" ]; then
  nvw_versions="$(ls "${APPDATA}/nv/node" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
  printf '%-16s %-50s %-22s %-10s\n' "nvm-windows" "${APPDATA}/nv" "$nvw_versions" "n/a"
fi

# ---- D. CLI resolution ----
print_table_header "D. CLI resolution" "which" "version" "matches latest?" ""

CLI_PATH=""
if have opencode; then
  CLI_PATH="$(command -v opencode)"
elif [ -x "$HOME_DIR/.opencode/bin/opencode" ]; then
  CLI_PATH="$HOME_DIR/.opencode/bin/opencode"
fi

if [ -n "$CLI_PATH" ]; then
  raw_cli_v="$("$CLI_PATH" --version 2>/dev/null || true)"
  cli_v="$(extract_version "$raw_cli_v")"
  [ -n "$cli_v" ] || cli_v="UNKNOWN"
  cmp_res="$(ver_cmp "$cli_v" "${REG_LATEST[opencode-ai]}")"
  case "$cmp_res" in
    EQ) flag="YES (fresh)" ;;
    LT) flag="NO (stale)";  exit_code_main=1 ;;
    GT) flag="AHEAD" ;;
    *)  flag="UNKNOWN";    exit_code_main=1 ;;
  esac
  printf '%-16s %-50s %-22s %-10s\n' "opencode" "$CLI_PATH" "$cli_v" "$flag"
else
  printf '%-16s %-50s %-22s %-10s\n' "opencode" "(not in PATH)" "-" "MISSING"
  exit_code_main=1
fi

# PATH shadow analysis
printf '\nPATH shadow analysis:\n'
have opencode && printf '  first hit            : %s\n' "$(command -v opencode)"
if [ -x "$HOME_DIR/.opencode/bin/opencode" ]; then
  printf '  ~/.opencode/bin/opencode : %s\n' "$("$HOME_DIR/.opencode/bin/opencode" --version 2>/dev/null || true)"
fi
if [ -e "$HOME_DIR/.vite-plus/bin/opencode" ]; then
  printf '  ~/.vite-plus/bin/opencode : shim -> %s\n' "$(readlink -f "$HOME_DIR/.vite-plus/bin/opencode" 2>/dev/null)"
fi
if [ -x "$HOME_DIR/.bun/bin/opencode" ]; then
  printf '  ~/.bun/bin/opencode       : %s\n' "$("$HOME_DIR/.bun/bin/opencode" --version 2>/dev/null || true)"
fi
if [ -x "$HOME_DIR/.local/share/pnpm/opencode" ] || [ -x "$HOME_DIR/.local/share/pnpm/opencode.cmd" ]; then
  printf '  ~/.local/share/pnpm/opencode exists\n'
fi

echo
echo "Exit: ${exit_code_main:-1} (0 = all known copies fresh AND CLI resolves to latest)."
exit "${exit_code_main:-1}"
