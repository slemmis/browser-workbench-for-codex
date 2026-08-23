#!/usr/bin/env bash
set -euo pipefail
umask 077

BW_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BW_PLUGIN_DIR="$(cd -- "$BW_SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=runtime/common.sh
source "$BW_SCRIPT_DIR/runtime/common.sh"

die() {
  printf 'browser-workbench: %s\n' "$*" >&2
  exit 1
}

bw_init_paths || die "${BW_PATH_ERROR:-unable to resolve browser-workbench paths}"
bw_sanitize_mcp_environment
bw_collect_config_errors
if ((${#BW_CONFIG_ERRORS[@]})); then
  printf 'browser-workbench: invalid configuration:\n' >&2
  printf '  - %s\n' "${BW_CONFIG_ERRORS[@]}" >&2
  exit 1
fi
bw_find_node || die "Node.js 20 or newer is required"
command -v flock >/dev/null 2>&1 || die "flock is required for safe runtime publication coordination"

# A dry run is deliberately side-effect and network free. It validates config
# but does not inspect, create, or bootstrap the cache.
if [[ "$BW_DRY_RUN" == 1 ]]; then
  printf 'browser-workbench dry run: mode=%s headed=%s browser=%s caps=%s output_max_size=%s\n' \
    "$BW_MODE" "$BW_HEADED" "${BW_BROWSER:-pinned-chromium}" "${BW_CAPS:-none}" "$BW_OUTPUT_MAX_SIZE"
  printf 'would exec pinned @playwright/mcp@%s with:' "$BW_MCP_VERSION"
  printf ' --output-dir %q --output-max-size %q' "$BW_OUTPUT_DIR" "$BW_OUTPUT_MAX_SIZE"
  case "$BW_MODE" in
    isolated) printf ' --isolated' ;;
    extension) printf ' --extension' ;;
    cdp) printf ' --cdp-endpoint [configured]' ;;
  esac
  [[ "$BW_MODE" != isolated && "$BW_MODE" != persistent || "$BW_HEADED" == 1 ]] || printf ' --headless'
  [[ -z "$BW_BROWSER" ]] || printf ' --browser %q' "$BW_BROWSER"
  [[ -z "$BW_CAPS" ]] || printf ' --caps %q' "$BW_CAPS"
  [[ -z "$BW_USER_DATA_DIR" ]] || printf ' --user-data-dir [configured]'
  printf '\n'
  exit 0
fi

secure_default_dir() {
  local label="$1" path="$2"
  bw_secure_owned_dir "$path" || die "unsafe or unusable owned $label directory; refuse to use it"
}
secure_default_dir cache "$BW_CACHE_ROOT"
[[ "$BW_TMP_CUSTOM" == 1 ]] || secure_default_dir temporary "$BW_TMP_DIR"
[[ "$BW_OUTPUT_CUSTOM" == 1 ]] || secure_default_dir output "$BW_OUTPUT_DIR"
if [[ "$BW_RUNTIME_CUSTOM" == 0 && ( -e "$BW_RUNTIME_DIR" || -L "$BW_RUNTIME_DIR" ) ]]; then secure_default_dir runtime "$BW_RUNTIME_DIR"; fi
if [[ "$BW_BROWSERS_CUSTOM" == 0 && ( -e "$BW_BROWSERS_ROOT" || -L "$BW_BROWSERS_ROOT" ) ]]; then secure_default_dir browsers "$BW_BROWSERS_ROOT"; fi
if [[ "$BW_MODE" == persistent && "$BW_PROFILE_CUSTOM" == 0 ]]; then
  secure_default_dir profiles "$BW_CACHE_ROOT/profiles"
  secure_default_dir profile "$BW_USER_DATA_DIR"
fi
[[ "$BW_TMP_CUSTOM" == 0 ]] || mkdir -p -- "$BW_TMP_DIR"
[[ "$BW_OUTPUT_CUSTOM" == 0 ]] || mkdir -p -- "$BW_OUTPUT_DIR"

runtime_ready_for_mode() {
  bw_validate_runtime || return 1
  if [[ -z "$BW_BROWSER" && ( "$BW_MODE" == isolated || "$BW_MODE" == persistent ) ]]; then
    bw_chromium_ready || return 1
  fi
}

if ! runtime_ready_for_mode; then
  [[ -r "$BW_SCRIPT_DIR/setup.sh" ]] || die "pinned runtime is unavailable and sibling scripts/setup.sh is missing"
  printf 'browser-workbench: preparing the pinned browser runtime (first use only)\n' >&2
  if ! BROWSER_WORKBENCH_SETUP_QUIET_READY=1 bash "$BW_SCRIPT_DIR/setup.sh" >&2; then
    die "automatic setup failed; check Node.js, npm, network access, and cache permissions, then rerun scripts/setup.sh"
  fi
  runtime_ready_for_mode || die "automatic setup completed but the exact pinned runtime/browser is not ready"
fi

if [[ -n "$BW_BROWSER" && ( "$BW_MODE" == isolated || "$BW_MODE" == persistent ) ]] && ! bw_channel_ready "$BW_BROWSER"; then
  die "$BW_BROWSER was selected but its Linux browser channel executable is not on PATH"
fi

# Resolve an immutable runtime generation while setup holds the exclusive
# publication lock. The lock is released before the long-running MCP process;
# published generations are never removed, so the resolved path stays valid.
[[ ! -L "$BW_LOCK_FILE" ]] || die "setup lock must not be a symlink"
exec {BW_LAUNCH_LOCK_FD}>"$BW_LOCK_FILE" || die "cannot open setup coordination lock"
chmod 0600 -- "$BW_LOCK_FILE" || die "cannot secure setup coordination lock"
flock "$BW_LAUNCH_LOCK_FD" || die "cannot acquire setup coordination lock"
runtime_ready_for_mode || die "runtime became unavailable during publication coordination; rerun scripts/setup.sh"
LOCKED_MCP_CLI="$BW_MCP_CLI"
LOCKED_BROWSERS_PATH="$BW_BROWSERS_PATH"
CHROMIUM_EXECUTABLE=""
if [[ -z "$BW_BROWSER" && ( "$BW_MODE" == isolated || "$BW_MODE" == persistent ) ]]; then
  CHROMIUM_EXECUTABLE="$(bw_chromium_executable)" || die "unable to resolve pinned Chromium executable"
  [[ -x "$CHROMIUM_EXECUTABLE" ]] || die "pinned Chromium executable is missing or not executable"
  LOCKED_BROWSERS_PATH="$BW_BROWSERS_PATH"
fi
flock -u "$BW_LAUNCH_LOCK_FD" || die "cannot release setup coordination lock"
exec {BW_LAUNCH_LOCK_FD}>&-

export PLAYWRIGHT_BROWSERS_PATH="$LOCKED_BROWSERS_PATH"
export TMPDIR="$BW_TMP_DIR" TEMP="$BW_TMP_DIR" TMP="$BW_TMP_DIR"

MCP_ARGS=(--output-dir "$BW_OUTPUT_DIR" --output-max-size "$BW_OUTPUT_MAX_SIZE")
case "$BW_MODE" in
  isolated) MCP_ARGS+=(--isolated) ;;
  persistent) ;;
  extension) MCP_ARGS+=(--extension) ;;
  cdp) MCP_ARGS+=(--cdp-endpoint "$BW_CDP_ENDPOINT") ;;
esac
if [[ "$BW_MODE" == isolated || "$BW_MODE" == persistent ]]; then
  [[ "$BW_HEADED" == 1 ]] || MCP_ARGS+=(--headless)
fi
if [[ -z "$BW_BROWSER" && ( "$BW_MODE" == isolated || "$BW_MODE" == persistent ) ]]; then
  MCP_ARGS+=(--executable-path "$CHROMIUM_EXECUTABLE")
fi
[[ -z "$BW_BROWSER" ]] || MCP_ARGS+=(--browser "$BW_BROWSER")
[[ -z "$BW_CAPS" ]] || MCP_ARGS+=(--caps "$BW_CAPS")
[[ -z "$BW_USER_DATA_DIR" ]] || MCP_ARGS+=(--user-data-dir "$BW_USER_DATA_DIR")

# stdout is exclusively the MCP JSON-RPC stream.
exec "$BW_NODE" "$LOCKED_MCP_CLI" "${MCP_ARGS[@]}"
