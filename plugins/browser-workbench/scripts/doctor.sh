#!/usr/bin/env bash
set -uo pipefail
umask 077

BW_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BW_PLUGIN_DIR="$(cd -- "$BW_SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=runtime/common.sh
source "$BW_SCRIPT_DIR/runtime/common.sh"

FAILURES=()
WARNINGS=()
fail() { FAILURES+=("$*"); }
warn() { WARNINGS+=("$*"); }

printf 'Browser Workbench for Codex doctor (read-only)\n'
os_name="$(uname -s 2>/dev/null || printf unknown)"
printf 'OS: %s%s\n' "$os_name" "$([[ "$os_name" == Linux ]] && printf ' (supported)' || printf ' (Linux/WSL required)')"
[[ "$os_name" == Linux ]] || fail "run Browser Workbench on Linux or WSL"
if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version; then printf 'WSL: yes\n'; else printf 'WSL: no\n'; fi

if ! bw_init_paths; then
  fail "${BW_PATH_ERROR:-HOME is required to determine the cache root}"
  BW_CACHE_ROOT="" BW_RUNTIME_DIR="" BW_BROWSERS_PATH=""
else
  if [[ "$BW_XDG_CACHE_IGNORED" == 1 ]]; then warn "relative XDG_CACHE_HOME is ignored; using HOME/.cache"; fi
fi

if bw_find_node; then
  printf 'Node: %s (%s)\n' "$BW_NODE" "$BW_NODE_VERSION"
else
  printf 'Node: missing or older than 20\n'
  fail "install Node.js 20 or newer"
fi
if command -v npm >/dev/null 2>&1; then printf 'npm: available\n'; NPM_READY=1; else printf 'npm: missing\n'; NPM_READY=0; fi
if command -v flock >/dev/null 2>&1; then printf 'flock: available\n'; FLOCK_READY=1; else printf 'flock: missing\n'; FLOCK_READY=0; fi

if [[ -n "${BW_CACHE_ROOT:-}" ]]; then
  CACHE_ROOT_SAFE=1
  if ! bw_private_dir_status "$BW_CACHE_ROOT"; then
    CACHE_ROOT_SAFE=0
    fail "owned cache root is a symlink, unowned, or accessible by group/others"
  else
    owned_dirs=()
    [[ "${BW_RUNTIME_CUSTOM:-0}" == 1 ]] || owned_dirs+=("$BW_CACHE_ROOT/runtime")
    [[ "${BW_BROWSERS_CUSTOM:-0}" == 1 ]] || owned_dirs+=("$BW_CACHE_ROOT/browsers")
    [[ "${BW_TMP_CUSTOM:-0}" == 1 ]] || owned_dirs+=("$BW_CACHE_ROOT/tmp")
    [[ "${BW_OUTPUT_CUSTOM:-0}" == 1 ]] || owned_dirs+=("$BW_CACHE_ROOT/output")
    if [[ "${BROWSER_WORKBENCH_MODE:-isolated}" == persistent && "${BW_PROFILE_CUSTOM:-0}" == 0 ]]; then owned_dirs+=("$BW_CACHE_ROOT/profiles"); fi
    for owned_dir in "${owned_dirs[@]}"; do
      if ! bw_private_dir_status "$owned_dir"; then fail "owned sensitive cache directory is a symlink, unowned, or accessible by group/others"; fi
    done
    if [[ -e "$BW_LOCK_FILE" || -L "$BW_LOCK_FILE" ]]; then
      lock_mode="$(stat -c '%a' -- "$BW_LOCK_FILE" 2>/dev/null || true)"
      [[ ! -L "$BW_LOCK_FILE" && -f "$BW_LOCK_FILE" && -O "$BW_LOCK_FILE" && "$lock_mode" == 600 ]] || fail "setup lock must be an owned regular file with mode 0600"
    fi
  fi
fi

CAN_INSPECT_RUNTIME=1
if [[ "${CACHE_ROOT_SAFE:-1}" == 0 && "${BW_RUNTIME_CUSTOM:-0}" == 0 ]]; then CAN_INSPECT_RUNTIME=0; fi
if [[ "$CAN_INSPECT_RUNTIME" == 1 && -n "${BW_RUNTIME_DIR:-}" ]] && bw_validate_runtime; then
  RUNTIME_READY=1
  printf 'Runtime: exact @playwright/mcp %s with Playwright %s\n' "$BW_MCP_VERSION" "$BW_PLAYWRIGHT_VERSION"
else
  RUNTIME_READY=0
  printf 'Runtime: not ready%s\n' "$([[ -n "${BW_RUNTIME_ERROR:-}" ]] && printf ' (%s)' "$BW_RUNTIME_ERROR")"
  fail "run scripts/setup.sh to prepare the exact locked runtime"
fi
if [[ "$FLOCK_READY" == 0 ]]; then fail "install flock (util-linux) for safe launch/setup coordination"; fi
if [[ "$NPM_READY" == 0 ]]; then
  if [[ "$RUNTIME_READY" == 0 ]]; then
    fail "install npm for first-use setup"
  else
    warn "npm is unavailable; the ready runtime can launch, but repair/bootstrap cannot run"
  fi
fi

if [[ -n "${BW_CACHE_ROOT:-}" ]]; then
  bw_collect_config_errors
  if ((${#BW_CONFIG_ERRORS[@]})); then
    local_error=""
    for local_error in "${BW_CONFIG_ERRORS[@]}"; do fail "$local_error"; done
  fi
  printf 'Mode: %s\n' "$BW_MODE"
  printf 'Headed: %s\n' "$([[ "$BW_HEADED" == 1 ]] && printf enabled || printf disabled)"
  printf 'Browser: %s\n' "${BW_BROWSER:-pinned Chromium}"
  if [[ "${BW_BROWSERS_CUSTOM:-0}" == 1 ]]; then printf 'Browser cache: custom path (externally managed; setup updates it in place)\n'; else printf 'Browser cache: owned immutable generations\n'; fi
  printf 'Capabilities: %s\n' "${BW_CAPS:-none}"
  printf 'Output quota: %s bytes\n' "$BW_OUTPUT_MAX_SIZE"
  [[ -z "$BW_CDP_ENDPOINT" ]] && printf 'CDP endpoint: not configured\n' || printf 'CDP endpoint: configured (value hidden)\n'
  [[ -z "$BW_USER_DATA_DIR" ]] && printf 'Persistent profile: not configured\n' || printf 'Persistent profile: configured (path hidden)\n'

  if [[ "$BW_MODE" == isolated || "$BW_MODE" == persistent ]]; then
    if [[ -z "$BW_BROWSER" ]]; then
      if [[ "$CAN_INSPECT_RUNTIME" == 0 ]]; then
        printf 'Pinned Chromium: skipped because cache root is unsafe\n'
      elif bw_chromium_ready; then printf 'Pinned Chromium: ready\n'; else printf 'Pinned Chromium: not ready%s\n' "$([[ -n "${BW_BROWSER_ERROR:-}" ]] && printf ' (%s)' "$BW_BROWSER_ERROR")"; fail "run scripts/setup.sh to install pinned Chromium"; fi
    elif bw_channel_ready "$BW_BROWSER"; then
      printf 'Selected browser channel: ready on PATH\n'
    else
      printf 'Selected browser channel: not found on PATH\n'
      fail "install the selected Linux browser channel or unset BROWSER_WORKBENCH_BROWSER"
    fi
  else
    printf 'Browser attachment: live readiness must be checked at connection time\n'
  fi
fi

if [[ -n "${DISPLAY:-}" ]]; then printf 'Display: configured\n'; else printf 'Display: not configured\n'; [[ "${BW_HEADED:-0}" == 1 ]] && fail "configure DISPLAY/WSLg for headed mode"; fi
if [[ -n "${WAYLAND_DISPLAY:-}" || -d /mnt/wslg ]]; then printf 'Wayland/WSLg: detected\n'; else printf 'Wayland/WSLg: not detected\n'; fi
if [[ -x "$BW_SCRIPT_DIR/windows-image-bridge.sh" ]]; then printf 'Windows image bridge: helper present\n'; else warn "Windows image bridge helper is missing"; fi

if ((${#WARNINGS[@]})); then
  printf 'Warnings:\n'
  printf '  - %s\n' "${WARNINGS[@]}"
fi
if ((${#FAILURES[@]})); then
  printf 'Failures:\n' >&2
  printf '  - %s\n' "${FAILURES[@]}" >&2
  exit 1
fi
printf 'Doctor result: ready\n'
