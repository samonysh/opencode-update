#!/usr/bin/env bash
# update-opencode.sh — plan + apply updates for STALE opencode-family installs.
# Compatible with: Linux, macOS, WSL, Git Bash on Windows.
#
# Usage:
#   bash scripts/update-opencode.sh              # dry-run: print plan, no mutations
#   bash scripts/update-opencode.sh --apply      # execute the plan
#   bash scripts/update-opencode.sh --apply --yes # skip confirmation prompt
#
# Strategy:
#   - Reuse detect-opencode.sh's logic (sourced) to enumerate STALE installs.
#   - For each STALE install, emit the env-native update command.
#   - --apply executes them; verify at the end by re-running detect.
set -euo pipefail
IFS=$'\n\t'

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT_SCRIPT="$SCRIPT_DIR/detect-opencode.sh"

# ---- arg parsing ----
APPLY=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --help|-h)
      sed -n '2,16p' "$0"; echo; echo "Version: $VERSION"; exit 0 ;;
    --version|-v) echo "update-opencode.sh version $VERSION"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ---- helpers ----
have() { command -v "$1" >/dev/null 2>&1; }

json_get() {
  local f="$1" key="$2"
  [ -r "$f" ] || { echo "MISSING"; return; }
  awk -v k="$key" -F'"' '{ for (i=1;i<=NF;i++) if ($i==k) {print $(i+2); exit} }' "$f" 2>/dev/null | head -n1
}
pkgjson_version() { json_get "$1" "version"; }
pkgjson_dep()     { json_get "$1" "$2"; }

registry_latest() {
  local pkg="$1" url="https://registry.npmjs.org/${1}/latest" body=""
  if have curl; then body="$(curl -fsSL --max-time 10 "$url" 2>/dev/null)" || true
  elif have wget; then body="$(wget -qO- --timeout=10 "$url" 2>/dev/null)" || true
  else echo "NO_HTTP_TOOL"; return; fi
  [ -n "$body" ] || { echo "FETCH_FAILED"; return; }
  printf '%s' "$body" | awk -F'"' '{ for (i=1;i<=NF;i++) if ($i=="version") {print $(i+2); exit} }'
}

ver_cmp() {
  local a="$1" b="$2"
  [[ "$a" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "UNKNOWN"; return; }
  [[ "$b" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "UNKNOWN"; return; }
  local IFS=. a_parts b_parts i
  a_parts=($a); b_parts=($b)
  local n=$(( ${#a_parts[@]} > ${#b_parts[@]} ? ${#a_parts[@]} : ${#b_parts[@]} ))
  for (( i=0; i<n; i++ )); do
    local ai="${a_parts[i]:-0}" bi="${b_parts[i]:-0}"
    if (( 10#$ai > 10#$bi )); then echo "GT"; return; fi
    if (( 10#$ai < 10#$bi )); then echo "LT"; return; fi
  done
  echo "EQ"
}

extract_version() {
  local raw="$1"
  printf '%s' "$raw" | tr -d 'v' | awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\./) {print $i; exit}}'
}

# ---- OS / HOME ----
case "$(uname -s 2>/dev/null)" in
  Linux*)  OS="linux" ;;
  Darwin*) OS="macos" ;;
  MINGW*|MSYS*|CYGWIN*) OS="windows-gitbash" ;;
  *) OS="unknown" ;;
esac
if [ "$OS" = "windows-gitbash" ] && [ -n "${USERPROFILE:-}" ]; then
  HOME_DIR="$(cygpath -u "$USERPROFILE" 2>/dev/null || echo "$HOME")"
else
  HOME_DIR="$HOME"
fi

# ---- Best Node selection ----
pick_best_node() {
  local best_ver="" best_mgr="" best_switch="" v

  # vite-plus
  if have vp && [ -d "$HOME_DIR/.vite-plus/js_runtime/node" ]; then
    for d in "$HOME_DIR/.vite-plus/js_runtime/node"/*/; do
      d="${d%/}"; v="$(basename "$d")"; v="${v#v}"
      [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
      if [ -z "$best_ver" ] || [ "$(ver_cmp "$v" "$best_ver")" = "GT" ]; then
        best_ver="$v"; best_mgr="vite-plus"; best_switch="vp env use $v"
      fi
    done
  fi

  # nvm
  local NVM_DIR="${NVM_DIR:-$HOME_DIR/.nvm}"
  if [ -d "$NVM_DIR/versions/node" ]; then
    for d in "$NVM_DIR"/versions/node/*; do
      [ -d "$d" ] || continue
      v="$(basename "$d")"; v="${v#v}"
      [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
      if [ -z "$best_ver" ] || [ "$(ver_cmp "$v" "$best_ver")" = "GT" ]; then
        best_ver="$v"; best_mgr="nvm"; best_switch=". \"$NVM_DIR/nvm.sh\" && nvm use $v"
      fi
    done
  fi

  # fnm
  if have fnm; then
    for base in "$HOME_DIR/.fnm/node-versions" "$HOME_DIR/Library/Application Support/fnm/node-versions"; do
      [ -d "$base" ] || continue
      for d in "$base"/*/installation; do
        [ -d "$d" ] || continue
        v="$(basename "$(dirname "$d")")"; v="${v#v}"
        [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
        if [ -z "$best_ver" ] || [ "$(ver_cmp "$v" "$best_ver")" = "GT" ]; then
          best_ver="$v"; best_mgr="fnm"; best_switch="fnm use $v"
        fi
      done
    done
  fi

  # nvm-windows
  if [ -n "${APPDATA:-}" ] && [ -d "${APPDATA}/nv/node" ]; then
    for d in "${APPDATA}"/nv/node/*; do
      [ -d "$d" ] || continue
      v="$(basename "$d")"; v="${v#v}"
      [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
      if [ -z "$best_ver" ] || [ "$(ver_cmp "$v" "$best_ver")" = "GT" ]; then
        best_ver="$v"; best_mgr="nvm-windows"; best_switch="nvm use $v"
      fi
    done
  fi

  # Volta (no shell switch)
  if have volta; then
    v="$(volta list node 2>/dev/null | awk '/default.*node@/ {print $3}' | tr -d 'v')"
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] || v=""
    if [ -n "$v" ] && { [ -z "$best_ver" ] || [ "$(ver_cmp "$v" "$best_ver")" = "GT" ]; }; then
      best_ver="$v"; best_mgr="volta"; best_switch="(volta pins per-project, no shell switch)"
    fi
  fi

  printf '%s|%s|%s' "$best_ver" "$best_mgr" "$best_switch"
}

# ---- STALE detection ----
# Each plan row: ENV \t PATH \t CURRENT \t LATEST \t UPDATE_CMD
PLAN=()
plan_add() {
  local env="$1" path="$2" cur="$3" latest="$4" cmd="$5"
  PLAN+=("$(printf '%s\t%s\t%s\t%s\t%s' "$env" "$path" "$cur" "$latest" "$cmd")")
}

# Fetch latest versions
declare -A REG
for pkg in opencode-ai oh-my-opencode "@opencode-ai/plugin"; do
  REG["$pkg"]="$(registry_latest "$pkg")"
done

# Binary ELF
BIN_PATH="$HOME_DIR/.opencode/bin/opencode"
if [ -x "$BIN_PATH" ]; then
  raw="$("$BIN_PATH" --version 2>/dev/null || true)"
  v="$(extract_version "$raw")"
  [ "$(ver_cmp "$v" "${REG[opencode-ai]}")" = "LT" ] && plan_add "binary" "$BIN_PATH" "$v" "${REG[opencode-ai]}" "opencode upgrade"
fi

# Plugin tree
PLUG_PKG="$HOME_DIR/.opencode/package.json"
if [ -r "$PLUG_PKG" ]; then
  inst_v="$(pkgjson_version "$HOME_DIR/.opencode/node_modules/@opencode-ai/plugin/package.json")"
  if [ "$(ver_cmp "$inst_v" "${REG[@opencode-ai/plugin]}")" = "LT" ]; then
    plan_add "opencode-plugins" "$PLUG_PKG" "$inst_v" "${REG[@opencode-ai/plugin]}" \
      "cd \"$HOME_DIR/.opencode\" && (have bun && bun install @opencode-ai/plugin@latest || npm install --save @opencode-ai/plugin@latest)"
  fi
fi

# npm global
if have npm; then
  NPM_ROOT="$(npm root -g 2>/dev/null)"
  if [ -n "$NPM_ROOT" ] && [ -d "$NPM_ROOT" ] && [[ "$NPM_ROOT" != *".vite-plus"* ]]; then
    for pkg in opencode-ai oh-my-opencode; do
      v="$(pkgjson_version "$NPM_ROOT/$pkg/package.json")"
      [ "$(ver_cmp "$v" "${REG[$pkg]}")" = "LT" ] && plan_add "npm-global" "$NPM_ROOT/$pkg" "$v" "${REG[$pkg]}" "npm i -g ${pkg}@latest"
    done
  fi
fi

# pnpm global
if have pnpm; then
  PNPM_ROOT="$(pnpm root -g 2>/dev/null)"
  if [ -n "$PNPM_ROOT" ] && [ -d "$PNPM_ROOT" ] && [[ "$PNPM_ROOT" != *".vite-plus"* ]]; then
    for pkg in opencode-ai oh-my-opencode; do
      v="$(pkgjson_version "$PNPM_ROOT/$pkg/package.json")"
      [ "$(ver_cmp "$v" "${REG[$pkg]}")" = "LT" ] && plan_add "pnpm-global" "$PNPM_ROOT/$pkg" "$v" "${REG[$pkg]}" "pnpm add -g ${pkg}@latest"
    done
  fi
fi

# Bun global
if have bun; then
  HOME_PKG="$HOME_DIR/package.json"
  if [ -r "$HOME_PKG" ]; then
    for pkg in opencode-ai oh-my-opencode; do
      inst_v="$(pkgjson_version "$HOME_DIR/node_modules/$pkg/package.json")"
      [ "$(ver_cmp "$inst_v" "${REG[$pkg]}")" = "LT" ] && plan_add "bun-global" "$HOME_PKG [$pkg]" "$inst_v" "${REG[$pkg]}" "bun add -g ${pkg}@latest"
    done
  fi
  BUN_G="$HOME_DIR/.bun/install/global"
  if [ -d "$BUN_G/node_modules" ]; then
    for pkg in opencode-ai oh-my-opencode; do
      pj="$BUN_G/node_modules/$pkg/package.json"
      [ -r "$pj" ] || continue
      v="$(pkgjson_version "$pj")"
      [ "$(ver_cmp "$v" "${REG[$pkg]}")" = "LT" ] && plan_add "bun-global" "$pj" "$v" "${REG[$pkg]}" "cd \"$BUN_G\" && bun install ${pkg}@latest"
    done
  fi
fi

# vite-plus packages
VP_DIR="$HOME_DIR/.vite-plus"
if [ -d "$VP_DIR/packages" ]; then
  for pkg in opencode-ai oh-my-opencode; do
    pj="$VP_DIR/packages/$pkg/lib/node_modules/$pkg/package.json"
    v="$(pkgjson_version "$pj")"
    [ "$(ver_cmp "$v" "${REG[$pkg]}")" = "LT" ] && plan_add "vite-plus" "$pj" "$v" "${REG[$pkg]}" "vp install -g ${pkg}@latest"
  done
fi

# Volta
VOLTA_DIR="$HOME_DIR/.volta"
if [ -d "$VOLTA_DIR/tools/image/packages" ]; then
  for pkg in opencode-ai oh-my-opencode; do
    for vd in "$VOLTA_DIR/tools/image/packages/$pkg"/*; do
      [ -d "$vd" ] || continue
      pj="$vd/lib/node_modules/$pkg/package.json"
      [ -r "$pj" ] || pj="$vd/node_modules/$pkg/package.json"
      v="$(pkgjson_version "$pj")"
      [ "$(ver_cmp "$v" "${REG[$pkg]}")" = "LT" ] && plan_add "volta" "$pj" "$v" "${REG[$pkg]}" "volta install ${pkg}@latest"
    done
  done
fi

# nvm
NVM_DIR="${NVM_DIR:-$HOME_DIR/.nvm}"
if [ -d "$NVM_DIR/versions/node" ]; then
  for nd in "$NVM_DIR"/versions/node/*; do
    [ -d "$nd" ] || continue
    for pkg in opencode-ai oh-my-opencode; do
      pj="$nd/lib/node_modules/$pkg/package.json"
      v="$(pkgjson_version "$pj")"
      [ "$(ver_cmp "$v" "${REG[$pkg]}")" = "LT" ] && plan_add "nvm" "$pj" "$v" "${REG[$pkg]}" "nvm use $(basename "$nd" | tr -d v) && npm i -g ${pkg}@latest"
    done
  done
fi

# fnm
for base in "$HOME_DIR/.fnm/node-versions" "$HOME_DIR/Library/Application Support/fnm/node-versions"; do
  [ -d "$base" ] || continue
  for nd in "$base"/*/installation; do
    [ -d "$nd" ] || continue
    for pkg in opencode-ai oh-my-opencode; do
      pj="$nd/lib/node_modules/$pkg/package.json"
      v="$(pkgjson_version "$pj")"
      [ "$(ver_cmp "$v" "${REG[$pkg]}")" = "LT" ] && plan_add "fnm" "$pj" "$v" "${REG[$pkg]}" "fnm use $(basename "$(dirname "$nd")" | tr -d v) && npm i -g ${pkg}@latest"
    done
  done
done

# nvm-windows
if [ -n "${APPDATA:-}" ] && [ -d "${APPDATA}/nv/node" ]; then
  for nd in "${APPDATA}"/nv/node/*; do
    [ -d "$nd" ] || continue
    for pkg in opencode-ai oh-my-opencode; do
      pj="$nd/node_modules/$pkg/package.json"
      v="$(pkgjson_version "$pj")"
      [ "$(ver_cmp "$v" "${REG[$pkg]}")" = "LT" ] && plan_add "nvm-windows" "$pj" "$v" "${REG[$pkg]}" "nvm use $(basename "$nd" | tr -d v) && npm i -g ${pkg}@latest"
    done
  done
fi

# ---- Print plan ----
echo
echo "=== Update plan ==="
echo "Mode: $([ "$APPLY" = "1" ] && echo "APPLY (will mutate)" || echo "DRY-RUN (no mutations)")"
echo

if [ "${#PLAN[@]}" -eq 0 ]; then
  echo "Nothing to update — all known copies are FRESH."
  echo
  echo "Running full detect for verification:"
  bash "$DETECT_SCRIPT"
  exit $?
fi

printf '%-16s %-50s %-14s %-14s %s\n' "env" "path" "current" "latest" "update_cmd"
printf '%.0s-' {1..120}; echo
for row in "${PLAN[@]}"; do
  env="$(printf '%s' "$row" | awk -F'\t' '{print $1}')"
  path="$(printf '%s' "$row" | awk -F'\t' '{print $2}')"
  cur="$(printf '%s' "$row" | awk -F'\t' '{print $3}')"
  latest="$(printf '%s' "$row" | awk -F'\t' '{print $4}')"
  cmd="$(printf '%s' "$row" | awk -F'\t' '{print $5}')"
  printf '%-16s %-50s %-14s %-14s %s\n' "$env" "$path" "$cur" "$latest" "$cmd"
done

# Best Node info
NODE_INFO="$(pick_best_node)"
BEST_VER="$(printf '%s' "$NODE_INFO" | awk -F'|' '{print $1}')"
BEST_MGR="$(printf '%s' "$NODE_INFO" | awk -F'|' '{print $2}')"
BEST_SWITCH="$(printf '%s' "$NODE_INFO" | awk -F'|' '{print $3}')"
echo
echo "Best Node available: ${BEST_VER:-none} (via ${BEST_MGR:-n/a})"
[ -n "$BEST_SWITCH" ] && [ "$BEST_SWITCH" != "(volta pins per-project, no shell switch)" ] && \
  echo "  Activate with: $BEST_SWITCH"

# Dry-run exit
if [ "$APPLY" != "1" ]; then
  echo
  echo "Dry-run only. To execute, re-run with --apply."
  exit 0
fi

# ---- Apply ----
echo
if [ "$ASSUME_YES" != "1" ]; then
  read -r -p "Proceed with the above updates? [y/N] " ans
  case "${ans,,}" in
    y|yes) ;;
    *) echo "aborted"; exit 1 ;;
  esac
fi

# Activate best Node if applicable
if [ -n "$BEST_SWITCH" ] && [ "$BEST_SWITCH" != "(volta pins per-project, no shell switch)" ]; then
  echo
  echo "[node] activating $BEST_VER via $BEST_MGR ..."
  eval "$BEST_SWITCH" 2>&1 | sed 's/^/  [node] /' || echo "  [node] (switch failed or n/a, continuing)"
fi

# Execute each plan command
echo
for row in "${PLAN[@]}"; do
  env="$(printf '%s' "$row" | awk -F'\t' '{print $1}')"
  path="$(printf '%s' "$row" | awk -F'\t' '{print $2}')"
  cur="$(printf '%s' "$row" | awk -F'\t' '{print $3}')"
  latest="$(printf '%s' "$row" | awk -F'\t' '{print $4}')"
  cmd="$(printf '%s' "$row" | awk -F'\t' '{print $5}')"
  echo
  echo "[$env] $cmd"
  echo "  path: $path ($cur -> $latest)"

  case "$env" in
    binary|opencode-plugins)
      if [ "$env" = "binary" ] && ! have opencode && [ ! -x "$BIN_PATH" ]; then
        echo "  SKIP: opencode binary not in PATH"; continue
      fi ;;
    npm-global|nvm|nvm-windows|fnm) have npm || { echo "  SKIP: npm not in PATH"; continue; } ;;
    pnpm-global) have pnpm || { echo "  SKIP: pnpm not in PATH"; continue; } ;;
    bun-global) have bun || { echo "  SKIP: bun not in PATH"; continue; } ;;
    vite-plus) have vp || { echo "  SKIP: vp not in PATH"; continue; } ;;
    volta) have volta || { echo "  SKIP: volta not in PATH"; continue; } ;;
  esac

  if bash -c "$cmd" 2>&1 | sed 's/^/  /'; then
    echo "  OK"
  else
    echo "  FAILED (exit $?) — see output above"
  fi
done

# ---- Verify ----
echo
echo "=== Verify (re-running detect) ==="
bash "$DETECT_SCRIPT"
verify_exit=$?
echo
if [ "$verify_exit" = "0" ]; then
  echo "[OK] All known copies are FRESH and CLI resolves to latest."
else
  echo "[FAIL] Some copies still STALE or CLI does not resolve to latest. See table above."
  echo "  Common fix: reorder PATH so the desired opencode binary is first, or"
  echo "  remove the stale copy (e.g. rm ~/.opencode/bin/opencode if you prefer bun-global)."
fi
exit "$verify_exit"
