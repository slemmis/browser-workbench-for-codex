#!/usr/bin/env bash

# Shared runtime policy. Callers must set BW_SCRIPT_DIR and BW_PLUGIN_DIR first.
[[ -n "${BW_SCRIPT_DIR:-}" && -n "${BW_PLUGIN_DIR:-}" ]] || {
  printf 'browser-workbench: runtime/common.sh requires BW_SCRIPT_DIR and BW_PLUGIN_DIR\n' >&2
  return 1 2>/dev/null || exit 1
}
# shellcheck source=versions.env
source "$BW_SCRIPT_DIR/runtime/versions.env"

bw_resolve_override_path() {
  local candidate="$1"
  if [[ "$candidate" == /* ]]; then
    printf '%s\n' "$candidate"
  else
    printf '%s/%s\n' "$BW_PLUGIN_DIR" "$candidate"
  fi
}

bw_set_runtime_derived_paths() {
  BW_RUNTIME_ACTIVE_DIR="$BW_RUNTIME_DIR"
  BW_RUNTIME_POINTER_ERROR=""
  if [[ "$BW_RUNTIME_CUSTOM" == 0 && -L "$BW_RUNTIME_DIR" ]]; then
    BW_RUNTIME_POINTER_ERROR="owned runtime root must not be a symlink"
    return 1
  fi
  if [[ "$BW_RUNTIME_CUSTOM" == 0 && -d "$BW_RUNTIME_DIR" ]] && ! bw_private_dir_status "$BW_RUNTIME_DIR"; then
    BW_RUNTIME_POINTER_ERROR="owned runtime root must be an owned private directory"
    return 1
  fi
  if [[ -L "$BW_RUNTIME_DIR/.generations" ]]; then
    BW_RUNTIME_POINTER_ERROR="runtime generation root must not be a symlink"
    return 1
  fi
  if [[ -L "$BW_RUNTIME_DIR/current" ]]; then
    local generation_root pointer_target generation_path resolved_active
    generation_root="$BW_RUNTIME_DIR/.generations"
    [[ -d "$generation_root" ]] || { BW_RUNTIME_POINTER_ERROR="runtime generation root is missing"; return 1; }
    if [[ "$BW_RUNTIME_CUSTOM" == 0 ]] && ! bw_private_dir_status "$generation_root"; then
      BW_RUNTIME_POINTER_ERROR="runtime generation root must be an owned private directory"
      return 1
    fi
    pointer_target="$(readlink -- "$BW_RUNTIME_DIR/current")" || { BW_RUNTIME_POINTER_ERROR="runtime current pointer is unreadable"; return 1; }
    [[ "$pointer_target" =~ ^\.generations/runtime\.[[:alnum:]]+$ ]] || {
      BW_RUNTIME_POINTER_ERROR="runtime current pointer has an unexpected target"
      return 1
    }
    generation_path="$BW_RUNTIME_DIR/$pointer_target"
    [[ ! -L "$generation_path" && -d "$generation_path" ]] || { BW_RUNTIME_POINTER_ERROR="runtime generation must be a real directory"; return 1; }
    if [[ "$BW_RUNTIME_CUSTOM" == 0 ]] && ! bw_private_dir_status "$generation_path"; then
      BW_RUNTIME_POINTER_ERROR="runtime generation must be an owned private directory"
      return 1
    fi
    resolved_active="$(realpath -e -- "$generation_path" 2>/dev/null)" || {
      BW_RUNTIME_POINTER_ERROR="runtime current pointer is dangling"
      return 1
    }
    BW_RUNTIME_ACTIVE_DIR="$resolved_active"
  elif [[ -e "$BW_RUNTIME_DIR/current" ]]; then
    BW_RUNTIME_POINTER_ERROR="runtime current pointer is not a symlink"
    return 1
  elif [[ "$BW_RUNTIME_CUSTOM" == 0 && "${BW_ALLOW_LEGACY_LAYOUT:-0}" != 1 ]]; then
    BW_RUNTIME_POINTER_ERROR="owned runtime current pointer is missing; legacy cache migration is required"
    return 1
  fi
  BW_MCP_CLI="$BW_RUNTIME_ACTIVE_DIR/node_modules/@playwright/mcp/cli.js"
  BW_MCP_PACKAGE_JSON="$BW_RUNTIME_ACTIVE_DIR/node_modules/@playwright/mcp/package.json"
  BW_PLAYWRIGHT_PACKAGE="$BW_RUNTIME_ACTIVE_DIR/node_modules/playwright"
  BW_PLAYWRIGHT_PACKAGE_JSON="$BW_PLAYWRIGHT_PACKAGE/package.json"
  BW_PLAYWRIGHT_CORE_PACKAGE_JSON="$BW_RUNTIME_ACTIVE_DIR/node_modules/playwright-core/package.json"
  BW_RUNTIME_PACKAGE_JSON="$BW_RUNTIME_ACTIVE_DIR/package.json"
  BW_RUNTIME_LOCK_FILE="$BW_RUNTIME_ACTIVE_DIR/package-lock.json"
}

bw_set_browser_active_path() {
  BW_BROWSERS_PATH="$BW_BROWSERS_ROOT"
  BW_BROWSER_POINTER_ERROR=""
  if [[ "$BW_BROWSERS_CUSTOM" == 0 && -L "$BW_BROWSERS_ROOT" ]]; then
    BW_BROWSER_POINTER_ERROR="owned browser root must not be a symlink"
    return 1
  fi
  if [[ "$BW_BROWSERS_CUSTOM" == 0 && -d "$BW_BROWSERS_ROOT" ]] && ! bw_private_dir_status "$BW_BROWSERS_ROOT"; then
    BW_BROWSER_POINTER_ERROR="owned browser root must be an owned private directory"
    return 1
  fi
  if [[ "$BW_BROWSERS_CUSTOM" == 0 && -L "$BW_BROWSERS_ROOT/.generations" ]]; then
    BW_BROWSER_POINTER_ERROR="browser generation root must not be a symlink"
    return 1
  fi
  if [[ "$BW_BROWSERS_CUSTOM" == 0 && -L "$BW_BROWSERS_ROOT/current" ]]; then
    local generation_root pointer_target generation_path resolved_active
    generation_root="$BW_BROWSERS_ROOT/.generations"
    [[ -d "$generation_root" ]] || { BW_BROWSER_POINTER_ERROR="browser generation root is missing"; return 1; }
    bw_private_dir_status "$generation_root" || { BW_BROWSER_POINTER_ERROR="browser generation root must be an owned private directory"; return 1; }
    pointer_target="$(readlink -- "$BW_BROWSERS_ROOT/current")" || { BW_BROWSER_POINTER_ERROR="browser current pointer is unreadable"; return 1; }
    [[ "$pointer_target" =~ ^\.generations/browser\.[[:alnum:]]+$ ]] || {
      BW_BROWSER_POINTER_ERROR="browser current pointer has an unexpected target"
      return 1
    }
    generation_path="$BW_BROWSERS_ROOT/$pointer_target"
    [[ ! -L "$generation_path" && -d "$generation_path" ]] || { BW_BROWSER_POINTER_ERROR="browser generation must be a real directory"; return 1; }
    bw_private_dir_status "$generation_path" || { BW_BROWSER_POINTER_ERROR="browser generation must be an owned private directory"; return 1; }
    resolved_active="$(realpath -e -- "$generation_path" 2>/dev/null)" || {
      BW_BROWSER_POINTER_ERROR="browser current pointer is dangling"
      return 1
    }
    BW_BROWSERS_PATH="$resolved_active"
  elif [[ "$BW_BROWSERS_CUSTOM" == 0 && -e "$BW_BROWSERS_ROOT/current" ]]; then
    BW_BROWSER_POINTER_ERROR="browser current pointer is not a symlink"
    return 1
  elif [[ "$BW_BROWSERS_CUSTOM" == 0 && "${BW_ALLOW_LEGACY_LAYOUT:-0}" != 1 ]]; then
    BW_BROWSER_POINTER_ERROR="owned browser current pointer is missing; legacy cache migration is required"
    return 1
  fi
}

bw_init_paths() {
  BW_HOME_DIR="${HOME:-}"
  BW_PATH_ERROR=""
  [[ -n "$BW_HOME_DIR" ]] || { BW_PATH_ERROR="HOME is required to locate the browser-workbench cache"; return 1; }
  [[ "$BW_HOME_DIR" == /* ]] || { BW_PATH_ERROR="HOME must be an absolute path"; return 1; }

  # XDG base directories must be absolute. A relative XDG_CACHE_HOME is ignored.
  if [[ "${XDG_CACHE_HOME:-}" == /* ]]; then
    BW_CACHE_HOME="$XDG_CACHE_HOME"
    BW_XDG_CACHE_IGNORED=0
  else
    BW_CACHE_HOME="$BW_HOME_DIR/.cache"
    BW_XDG_CACHE_IGNORED=$([[ -n "${XDG_CACHE_HOME:-}" ]] && printf 1 || printf 0)
  fi
  BW_CACHE_ROOT="$BW_CACHE_HOME/browser-workbench"
  BW_LOCK_FILE="$BW_CACHE_ROOT/setup.lock"

  BW_RUNTIME_CUSTOM=$([[ -n "${BROWSER_WORKBENCH_RUNTIME_DIR:-}" ]] && printf 1 || printf 0)
  BW_BROWSERS_CUSTOM=$([[ -n "${BROWSER_WORKBENCH_BROWSERS_PATH:-}" ]] && printf 1 || printf 0)
  BW_TMP_CUSTOM=$([[ -n "${BROWSER_WORKBENCH_TMPDIR:-}" ]] && printf 1 || printf 0)
  BW_OUTPUT_CUSTOM=$([[ -n "${BROWSER_WORKBENCH_OUTPUT_DIR:-}" ]] && printf 1 || printf 0)
  BW_PROFILE_CUSTOM=$([[ -n "${BROWSER_WORKBENCH_USER_DATA_DIR:-}" ]] && printf 1 || printf 0)

  BW_RUNTIME_DIR="$(bw_resolve_override_path "${BROWSER_WORKBENCH_RUNTIME_DIR:-$BW_CACHE_ROOT/runtime}")"
  BW_BROWSERS_ROOT="$(bw_resolve_override_path "${BROWSER_WORKBENCH_BROWSERS_PATH:-$BW_CACHE_ROOT/browsers}")"
  BW_TMP_DIR="$(bw_resolve_override_path "${BROWSER_WORKBENCH_TMPDIR:-$BW_CACHE_ROOT/tmp}")"
  BW_OUTPUT_DIR="$(bw_resolve_override_path "${BROWSER_WORKBENCH_OUTPUT_DIR:-$BW_CACHE_ROOT/output}")"
  BW_RUNTIME_DIR="$(realpath -ms -- "$BW_RUNTIME_DIR")" || return 1
  BW_BROWSERS_ROOT="$(realpath -ms -- "$BW_BROWSERS_ROOT")" || return 1
  BW_TMP_DIR="$(realpath -ms -- "$BW_TMP_DIR")" || return 1
  BW_OUTPUT_DIR="$(realpath -ms -- "$BW_OUTPUT_DIR")" || return 1
  bw_set_runtime_derived_paths || true
  bw_set_browser_active_path || true
}

bw_find_node() {
  BW_NODE="$(command -v node 2>/dev/null || true)"
  [[ -n "$BW_NODE" ]] || return 1
  BW_NODE_VERSION="$($BW_NODE -p 'process.versions.node' 2>/dev/null)" || return 1
  BW_NODE_MAJOR="${BW_NODE_VERSION%%.*}"
  [[ "$BW_NODE_MAJOR" =~ ^[0-9]+$ && "$BW_NODE_MAJOR" -ge 20 ]]
}

bw_read_package_field() {
  local file="$1" expression="$2"
  "$BW_NODE" -e '
    const fs = require("node:fs");
    const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const value = Function("data", `return ${process.argv[2]}`)(data);
    process.stdout.write(typeof value === "string" ? value : "");
  ' "$file" "$expression" 2>/dev/null
}

bw_validate_installed_graph() {
  local runtime_dir="$1"
  "$BW_NODE" "$BW_SCRIPT_DIR/runtime/validate-graph.mjs" \
    "$BW_SCRIPT_DIR/runtime/package-lock.json" "$runtime_dir" "$BW_MCP_VERSION" "$BW_PLAYWRIGHT_VERSION" \
    >/dev/null 2>&1
}

bw_validate_runtime() {
  BW_RUNTIME_ERROR=""
  bw_set_runtime_derived_paths || { BW_RUNTIME_ERROR="${BW_RUNTIME_POINTER_ERROR:-runtime generation cannot be resolved}"; return 1; }
  cmp -s -- "$BW_SCRIPT_DIR/runtime/package.json" "$BW_RUNTIME_PACKAGE_JSON" || { BW_RUNTIME_ERROR="runtime package manifest does not match the committed pin"; return 1; }
  cmp -s -- "$BW_SCRIPT_DIR/runtime/package-lock.json" "$BW_RUNTIME_LOCK_FILE" || { BW_RUNTIME_ERROR="runtime lockfile does not match the committed dependency graph"; return 1; }
  [[ ! -L "$BW_MCP_CLI" && -f "$BW_MCP_CLI" ]] || { BW_RUNTIME_ERROR="MCP CLI must be a regular non-symlink file"; return 1; }
  [[ -f "$BW_MCP_PACKAGE_JSON" ]] || { BW_RUNTIME_ERROR="MCP package metadata is missing"; return 1; }
  [[ -f "$BW_PLAYWRIGHT_PACKAGE_JSON" ]] || { BW_RUNTIME_ERROR="Playwright package metadata is missing"; return 1; }
  [[ -f "$BW_PLAYWRIGHT_CORE_PACKAGE_JSON" ]] || { BW_RUNTIME_ERROR="Playwright Core package metadata is missing"; return 1; }
  bw_find_node || { BW_RUNTIME_ERROR="Node.js 20 or newer is unavailable"; return 1; }

  local mcp_version declared_playwright installed_playwright installed_playwright_core
  mcp_version="$(bw_read_package_field "$BW_MCP_PACKAGE_JSON" 'data.version')" || true
  declared_playwright="$(bw_read_package_field "$BW_MCP_PACKAGE_JSON" 'data.dependencies && data.dependencies.playwright')" || true
  installed_playwright="$(bw_read_package_field "$BW_PLAYWRIGHT_PACKAGE_JSON" 'data.version')" || true
  installed_playwright_core="$(bw_read_package_field "$BW_PLAYWRIGHT_CORE_PACKAGE_JSON" 'data.version')" || true
  [[ "$mcp_version" == "$BW_MCP_VERSION" ]] || { BW_RUNTIME_ERROR="expected @playwright/mcp@$BW_MCP_VERSION but found ${mcp_version:-an unreadable version}"; return 1; }
  [[ "$declared_playwright" == "$BW_PLAYWRIGHT_VERSION" ]] || { BW_RUNTIME_ERROR="MCP declares unexpected Playwright ${declared_playwright:-version}"; return 1; }
  [[ "$installed_playwright" == "$BW_PLAYWRIGHT_VERSION" ]] || { BW_RUNTIME_ERROR="expected Playwright $BW_PLAYWRIGHT_VERSION but found ${installed_playwright:-an unreadable version}"; return 1; }
  [[ "$installed_playwright_core" == "$BW_PLAYWRIGHT_VERSION" ]] || { BW_RUNTIME_ERROR="expected Playwright Core $BW_PLAYWRIGHT_VERSION but found ${installed_playwright_core:-an unreadable version}"; return 1; }
  bw_validate_installed_graph "$BW_RUNTIME_ACTIVE_DIR" || { BW_RUNTIME_ERROR="installed packages do not match the locked package graph"; return 1; }
}

bw_chromium_executable() {
  BW_BROWSER_ERROR=""
  bw_validate_runtime || return 1
  bw_set_browser_active_path || { BW_BROWSER_ERROR="${BW_BROWSER_POINTER_ERROR:-browser generation cannot be resolved}"; return 1; }
  PLAYWRIGHT_BROWSERS_PATH="$BW_BROWSERS_PATH" "$BW_NODE" -e '
    const { chromium } = require(process.argv[1]);
    process.stdout.write(chromium.executablePath());
  ' "$BW_PLAYWRIGHT_PACKAGE" 2>/dev/null || { BW_BROWSER_ERROR="Chromium executable path could not be resolved"; return 1; }
}

bw_chromium_ready() {
  local executable
  BW_BROWSER_ERROR=""
  bw_validate_runtime || return 1
  bw_set_browser_active_path || { BW_BROWSER_ERROR="${BW_BROWSER_POINTER_ERROR:-browser generation cannot be resolved}"; return 1; }
  executable="$(PLAYWRIGHT_BROWSERS_PATH="$BW_BROWSERS_PATH" "$BW_NODE" -e '
    const { chromium } = require(process.argv[1]);
    process.stdout.write(chromium.executablePath());
  ' "$BW_PLAYWRIGHT_PACKAGE" 2>/dev/null)" || { BW_BROWSER_ERROR="Chromium executable path could not be resolved"; return 1; }
  [[ -n "$executable" && -x "$executable" ]] || { BW_BROWSER_ERROR="resolved Chromium executable is missing"; return 1; }
}

bw_channel_ready() {
  case "$1" in
    chrome) command -v google-chrome-stable >/dev/null 2>&1 || command -v google-chrome >/dev/null 2>&1 ;;
    msedge) command -v microsoft-edge-stable >/dev/null 2>&1 || command -v microsoft-edge >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

bw_secure_owned_dir() {
  local path="$1"
  [[ ! -L "$path" ]] || return 2
  if [[ -e "$path" && ! -d "$path" ]]; then return 3; fi
  mkdir -p -- "$path" || return 1
  [[ -O "$path" ]] || return 4
  chmod 0700 -- "$path"
}

bw_private_dir_status() {
  local path="$1" mode mode_value
  [[ ! -e "$path" ]] && return 0
  [[ ! -L "$path" && -d "$path" && -O "$path" ]] || return 1
  mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1
  mode_value=$((8#$mode))
  (( (mode_value & 077) == 0 ))
}

bw_sanitize_node_environment() {
  local env_name
  while IFS= read -r env_name; do
    case "$env_name" in
      PWDEBUG|NODE_OPTIONS|NODE_PATH|NODE_DEBUG|NODE_DEBUG_NATIVE|DEBUG|DEBUG_COLORS|FORCE_COLOR)
        unset "$env_name"
        ;;
    esac
  done < <(compgen -e)
}

bw_sanitize_mcp_environment() {
  local env_name
  bw_sanitize_node_environment
  while IFS= read -r env_name; do
    case "$env_name" in
      PLAYWRIGHT_MCP_*|PLAYWRIGHT_*) unset "$env_name" ;;
    esac
  done < <(compgen -e)
}

bw_collect_config_errors() {
  BW_CONFIG_ERRORS=()
  BW_MODE="${BROWSER_WORKBENCH_MODE:-isolated}"
  case "$BW_MODE" in isolated|persistent|extension|cdp) ;; *) BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_MODE must be isolated, persistent, extension, or cdp") ;; esac

  case "${BROWSER_WORKBENCH_HEADED:-0}" in
    1|true) BW_HEADED=1 ;;
    0|false|'') BW_HEADED=0 ;;
    *) BW_HEADED=0; BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_HEADED must be 0, 1, false, or true") ;;
  esac

  BW_BROWSER="${BROWSER_WORKBENCH_BROWSER:-}"
  case "$BW_BROWSER" in ''|chrome|msedge) ;; firefox|webkit) BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_BROWSER=$BW_BROWSER is not provisioned; use the pinned Chromium default") ;; *) BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_BROWSER must be chrome or msedge, or unset for pinned Chromium") ;; esac
  if [[ "$BW_MODE" == cdp && -n "$BW_BROWSER" ]]; then BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_BROWSER is not valid in cdp mode"); fi
  if [[ "$BW_MODE" == extension && -n "$BW_BROWSER" && "$BW_BROWSER" != chrome && "$BW_BROWSER" != msedge ]]; then BW_CONFIG_ERRORS+=("extension mode supports only chrome or msedge"); fi

  BW_CAPS="${BROWSER_WORKBENCH_CAPS:-}"
  if [[ -n "$BW_CAPS" ]]; then
    if [[ "$BW_CAPS" == *[[:space:]]* || "$BW_CAPS" == ,* || "$BW_CAPS" == *, || "$BW_CAPS" == *,,* ]]; then
      BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_CAPS must be a non-empty comma-separated list without whitespace")
    else
      local cap seen
      IFS=',' read -r -a _bw_caps <<< "$BW_CAPS"
      seen=","
      for cap in "${_bw_caps[@]}"; do
        case "$cap" in vision|pdf|devtools) ;; *) BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_CAPS supports only vision, pdf, and devtools");; esac
        if [[ "$seen" == *",$cap,"* ]]; then BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_CAPS contains duplicate '$cap'"); fi
        seen+="$cap,"
      done
    fi
  fi

  BW_CDP_ENDPOINT="${BROWSER_WORKBENCH_CDP_ENDPOINT:-}"
  if [[ "$BW_MODE" == cdp && -z "$BW_CDP_ENDPOINT" ]]; then
    BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_CDP_ENDPOINT is required for cdp mode")
  elif [[ "$BW_MODE" == cdp && -n "$BW_CDP_ENDPOINT" ]]; then
    if ! bw_find_node || [[ "$BW_CDP_ENDPOINT" == *[[:space:]]* ]] || ! "$BW_NODE" -e '
      let u; try { u = new URL(process.argv[1]); } catch { process.exit(1); }
      if (!["http:","https:","ws:","wss:"].includes(u.protocol) || !u.hostname || u.hostname === "0.0.0.0" || u.username || u.password) process.exit(1);
    ' "$BW_CDP_ENDPOINT" 2>/dev/null; then
      BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_CDP_ENDPOINT must be credential-free http(s)/ws(s), with a safe host")
    fi
  elif [[ -n "$BW_CDP_ENDPOINT" ]]; then
    BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_CDP_ENDPOINT is only valid in cdp mode")
  fi

  BW_USER_DATA_DIR="${BROWSER_WORKBENCH_USER_DATA_DIR:-}"
  if [[ -n "$BW_USER_DATA_DIR" && "$BW_MODE" != persistent ]]; then BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_USER_DATA_DIR is only valid in persistent mode"); fi
  if [[ "$BW_MODE" == persistent && -z "$BW_USER_DATA_DIR" ]]; then BW_USER_DATA_DIR="$BW_CACHE_ROOT/profiles/default"; fi
  if [[ -n "$BW_USER_DATA_DIR" ]]; then BW_USER_DATA_DIR="$(bw_resolve_override_path "$BW_USER_DATA_DIR")"; fi

  BW_OUTPUT_MAX_SIZE="${BROWSER_WORKBENCH_OUTPUT_MAX_SIZE:-$BW_DEFAULT_OUTPUT_MAX_SIZE}"
  if [[ ! "$BW_OUTPUT_MAX_SIZE" =~ ^[1-9][0-9]*$ || ${#BW_OUTPUT_MAX_SIZE} -gt 11 || "$BW_OUTPUT_MAX_SIZE" -gt 10737418240 ]]; then
    BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_OUTPUT_MAX_SIZE must be an integer from 1 to 10737418240 bytes")
  fi

  case "${BROWSER_WORKBENCH_DRY_RUN:-0}" in 0|'') BW_DRY_RUN=0 ;; 1) BW_DRY_RUN=1 ;; *) BW_DRY_RUN=0; BW_CONFIG_ERRORS+=("BROWSER_WORKBENCH_DRY_RUN must be 0 or 1") ;; esac
}
