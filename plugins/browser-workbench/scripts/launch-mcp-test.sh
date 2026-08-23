#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/browser-workbench-runtime-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM
REAL_NODE="$(command -v node)"

fail() { printf 'browser-workbench runtime test: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" "$2" || fail "expected $2 to contain: $1"; }
assert_empty() { [[ ! -s "$1" ]] || fail "expected empty $1; got $(sed -n '1,5p' "$1")"; }
assert_mode() { [[ "$(stat -c '%a' -- "$1")" == "$2" ]] || fail "expected mode $2 on $1"; }
active_runtime() {
  local runtime_root="$1"
  if [[ -L "$runtime_root/current" ]]; then realpath -e -- "$runtime_root/current"; else printf '%s\n' "$runtime_root"; fi
}
active_browser() {
  local browser_root="$1"
  if [[ -L "$browser_root/current" ]]; then realpath -e -- "$browser_root/current"; else printf '%s\n' "$browser_root"; fi
}
install_faulty_mv() {
  local root="$1"
  cat > "$root/bin/mv" <<'MV'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
destination="${args[${#args[@]}-1]}"
match=0
case "${BROWSER_WORKBENCH_TEST_MV_MATCH:-}" in
  current) [[ "$destination" == */current ]] && match=1 ;;
  browser-current)
    browser_target="${BROWSER_WORKBENCH_BROWSERS_PATH:-${XDG_CACHE_HOME:?}/browser-workbench/browsers}"
    [[ "$destination" == "$browser_target/current" ]] && match=1
    ;;
esac
marker="${BROWSER_WORKBENCH_TEST_MV_MARKER:-}"
if [[ "$match" == 1 && -n "$marker" && ! -e "$marker" ]]; then
  : > "$marker"
  case "${BROWSER_WORKBENCH_TEST_MV_MODE:-}" in
    fail) exit 44 ;;
    signal)
      /usr/bin/mv "$@"
      kill -TERM "$PPID"
      sleep 0.05
      exit 143
      ;;
  esac
fi
exec /usr/bin/mv "$@"
MV
  chmod +x "$root/bin/mv"
}

make_case() {
  local name="$1" root="$TEST_ROOT/$1"
  mkdir -p "$root/plugin/scripts/runtime" "$root/home" "$root/xdg" "$root/bin"
  cp "$SCRIPT_DIR/launch-mcp.sh" "$SCRIPT_DIR/setup.sh" "$SCRIPT_DIR/doctor.sh" "$root/plugin/scripts/"
  cp "$SCRIPT_DIR/runtime/common.sh" "$SCRIPT_DIR/runtime/versions.env" "$SCRIPT_DIR/runtime/package.json" "$SCRIPT_DIR/runtime/package-lock.json" "$SCRIPT_DIR/runtime/validate-graph.mjs" "$root/plugin/scripts/runtime/"
  ln -s "$REAL_NODE" "$root/bin/node"
  cat > "$root/bin/npm" <<'NPM'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == ci ]] || { printf 'unexpected npm invocation\n' >&2; exit 90; }
prefix=""
while (($#)); do
  if [[ "$1" == --prefix ]]; then prefix="$2"; shift 2; else shift; fi
done
[[ -n "$prefix" ]] || exit 91
printf 'npm %s\n' "$prefix" >> "${BROWSER_WORKBENCH_TEST_NPM_LOG:?}"
sleep "${BROWSER_WORKBENCH_TEST_NPM_DELAY:-0}"
[[ "${BROWSER_WORKBENCH_TEST_NPM_FAIL:-0}" == 0 ]] || exit 42
mkdir -p "$prefix/node_modules/@playwright/mcp" "$prefix/node_modules/playwright" "$prefix/node_modules/playwright-core"
printf '%s\n' '{"name":"@playwright/mcp","version":"0.0.79","dependencies":{"playwright":"1.63.0-alpha-2026-08-05","playwright-core":"1.63.0-alpha-2026-08-05"}}' > "$prefix/node_modules/@playwright/mcp/package.json"
printf '%s\n' '{"name":"playwright","version":"1.63.0-alpha-2026-08-05","main":"index.js","dependencies":{"playwright-core":"1.63.0-alpha-2026-08-05"},"optionalDependencies":{"fsevents":"2.3.2"}}' > "$prefix/node_modules/playwright/package.json"
printf '%s\n' '{"name":"playwright-core","version":"1.63.0-alpha-2026-08-05"}' > "$prefix/node_modules/playwright-core/package.json"
cat > "$prefix/node_modules/playwright/index.js" <<'NODE'
const path = require('node:path');
exports.chromium = { executablePath() { return path.join(process.env.PLAYWRIGHT_BROWSERS_PATH, process.env.BROWSER_WORKBENCH_TEST_BROWSER_NAME || 'chromium'); } };
NODE
cat > "$prefix/node_modules/playwright/cli.js" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
if (process.argv[2] !== 'install' || process.argv[3] !== 'chromium') process.exit(92);
if (process.env.BROWSER_WORKBENCH_TEST_BROWSER_FAIL === '1') process.exit(43);
fs.mkdirSync(process.env.PLAYWRIGHT_BROWSERS_PATH, { recursive: true, mode: 0o700 });
const executable = path.join(process.env.PLAYWRIGHT_BROWSERS_PATH, process.env.BROWSER_WORKBENCH_TEST_BROWSER_NAME || 'chromium');
fs.writeFileSync(executable, '#!/bin/sh\nexit 0\n', { mode: 0o700 });
NODE
cat > "$prefix/node_modules/@playwright/mcp/cli.js" <<'NODE'
const fs = require('node:fs');
if (process.env.BROWSER_WORKBENCH_TEST_EXEC_LOG) {
  fs.writeFileSync(process.env.BROWSER_WORKBENCH_TEST_EXEC_LOG, JSON.stringify({
    argv: process.argv.slice(2),
    scriptDir: __dirname,
    nodeOptions: process.env.NODE_OPTIONS || '',
    pwdebug: process.env.PWDEBUG || '',
    playwrightFoo: process.env.PLAYWRIGHT_FOO || '',
    browsersPath: process.env.PLAYWRIGHT_BROWSERS_PATH || '',
  }));
}
NODE
NPM
  cat > "$root/bin/npx" <<'NPX'
#!/usr/bin/env bash
printf 'npx must not be used\n' >&2
exit 99
NPX
  chmod +x "$root/bin/npm" "$root/bin/npx" "$root/plugin/scripts/launch-mcp.sh" "$root/plugin/scripts/setup.sh" "$root/plugin/scripts/doctor.sh"
  printf '%s\n' "$root"
}

case_env() {
  local root="$1"
  export HOME="$root/home"
  export XDG_CACHE_HOME="$root/xdg"
  export PATH="$root/bin:/usr/bin:/bin"
  export BROWSER_WORKBENCH_TEST_NPM_LOG="$root/npm.log"
  export BROWSER_WORKBENCH_TEST_EXEC_LOG="$root/exec.json"
  unset BROWSER_WORKBENCH_RUNTIME_DIR BROWSER_WORKBENCH_BROWSERS_PATH BROWSER_WORKBENCH_TMPDIR BROWSER_WORKBENCH_OUTPUT_DIR
  unset BROWSER_WORKBENCH_MODE BROWSER_WORKBENCH_HEADED BROWSER_WORKBENCH_BROWSER BROWSER_WORKBENCH_CAPS
  unset BROWSER_WORKBENCH_CDP_ENDPOINT BROWSER_WORKBENCH_USER_DATA_DIR BROWSER_WORKBENCH_OUTPUT_MAX_SIZE
  unset BROWSER_WORKBENCH_DRY_RUN BROWSER_WORKBENCH_TEST_NPM_FAIL BROWSER_WORKBENCH_TEST_NPM_DELAY
  unset BROWSER_WORKBENCH_TEST_BROWSER_FAIL
  unset BROWSER_WORKBENCH_TEST_BROWSER_NAME
  unset BROWSER_WORKBENCH_TEST_MV_MATCH BROWSER_WORKBENCH_TEST_MV_MODE BROWSER_WORKBENCH_TEST_MV_MARKER
  unset NODE_OPTIONS PWDEBUG PLAYWRIGHT_FOO
}

run_launcher() {
  local root="$1"
  bash "$root/plugin/scripts/launch-mcp.sh" >"$root/stdout" 2>"$root/stderr"
}

first="$(make_case first-use)"; case_env "$first"
run_launcher "$first" || fail "first-use bootstrap failed: $(sed -n '1,12p' "$first/stderr")"
assert_empty "$first/stdout"
assert_contains 'preparing the pinned browser runtime' "$first/stderr"
assert_contains 'Installing the locked runtime' "$first/stderr"
[[ "$(wc -l < "$first/npm.log")" == 1 ]] || fail "first use did not run npm once"
assert_mode "$first/xdg/browser-workbench" 700
assert_mode "$first/xdg/browser-workbench/runtime" 700
assert_mode "$first/xdg/browser-workbench/browsers" 700
assert_mode "$first/xdg/browser-workbench/output" 700
assert_mode "$first/xdg/browser-workbench/tmp" 700
assert_mode "$first/xdg/browser-workbench/setup.lock" 600
assert_contains '"--output-max-size","104857600"' "$first/exec.json"

if ! bash "$first/plugin/scripts/doctor.sh" >"$first/doctor.out" 2>"$first/doctor.err"; then fail "doctor rejected ready hermetic cache: $(sed -n '1,12p' "$first/doctor.err")"; fi
assert_contains 'Doctor result: ready' "$first/doctor.out"
chmod 0755 "$first/xdg/browser-workbench/output"
if bash "$first/plugin/scripts/doctor.sh" >"$first/doctor-bad.out" 2>"$first/doctor-bad.err"; then fail "doctor accepted unsafe permissions"; fi
assert_contains 'owned sensitive cache directory' "$first/doctor-bad.err"
chmod 0700 "$first/xdg/browser-workbench/output"

: > "$first/npm.log"; run_launcher "$first" || fail "ready-cache launch failed"
assert_empty "$first/stdout"
assert_empty "$first/npm.log"

legacy="$(make_case ready-legacy-migration)"; case_env "$legacy"
bash "$legacy/plugin/scripts/setup.sh" >/dev/null
legacy_runtime_root="$legacy/xdg/browser-workbench/runtime"
legacy_browser_root="$legacy/xdg/browser-workbench/browsers"
legacy_runtime_source="$(active_runtime "$legacy_runtime_root")"
legacy_browser_source="$(active_browser "$legacy_browser_root")"
cp -a "$legacy_runtime_source/package.json" "$legacy_runtime_source/package-lock.json" "$legacy_runtime_source/node_modules" "$legacy_runtime_root/"
cp -a "$legacy_browser_source/." "$legacy_browser_root/"
rm -f "$legacy_runtime_root/current" "$legacy_browser_root/current"
legacy_runtime_generation_count="$(find "$legacy_runtime_root/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)"
legacy_browser_generation_count="$(find "$legacy_browser_root/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)"
: > "$legacy/npm.log"
run_launcher "$legacy" & legacy_launcher_one=$!
run_launcher "$legacy" & legacy_launcher_two=$!
wait "$legacy_launcher_one" || fail "first concurrent legacy migration launch failed"
wait "$legacy_launcher_two" || fail "second concurrent legacy migration launch failed"
[[ -L "$legacy_runtime_root/current" && -L "$legacy_browser_root/current" ]] || fail "legacy migration did not publish both current pointers"
[[ "$(find "$legacy_runtime_root/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$((legacy_runtime_generation_count + 1))" ]] || fail "legacy runtime migrated more than once"
[[ "$(find "$legacy_browser_root/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$((legacy_browser_generation_count + 1))" ]] || fail "legacy browser migrated more than once"
assert_empty "$legacy/npm.log"
[[ -f "$legacy_runtime_root/node_modules/@playwright/mcp/cli.js" ]] || fail "legacy migration removed the flat CLI needed by an old client"
[[ -x "$legacy_browser_root/chromium" ]] || fail "legacy migration removed the flat browser needed by an old client"
"$REAL_NODE" "$legacy_runtime_root/node_modules/@playwright/mcp/cli.js" || fail "legacy flat CLI is no longer usable"
"$legacy_browser_root/chromium" || fail "legacy flat browser is no longer usable"
legacy_runtime_count_after="$(find "$legacy_runtime_root/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)"
legacy_browser_count_after="$(find "$legacy_browser_root/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)"
run_launcher "$legacy" || fail "post-migration ready launch failed"
[[ "$(find "$legacy_runtime_root/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$legacy_runtime_count_after" ]] || fail "ready runtime remigrated"
[[ "$(find "$legacy_browser_root/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$legacy_browser_count_after" ]] || fail "ready browser remigrated"
if find "$legacy" -name '*.stage.*' -print -quit | grep -q .; then fail "legacy migration left a partial staging tree"; fi

case_env "$first"
first_browser_active="$(active_browser "$first/xdg/browser-workbench/browsers")"
rm -f "$first_browser_active/chromium"; : > "$first/npm.log"
run_launcher "$first" || fail "missing-browser repair failed"
[[ "$(wc -l < "$first/npm.log")" == 1 ]] || fail "missing browser did not invoke setup exactly once"

first_active="$(active_runtime "$first/xdg/browser-workbench/runtime")"
printf '\n' >> "$first_active/package-lock.json"; : > "$first/npm.log"
run_launcher "$first" || fail "changed runtime lock was not repaired"
[[ "$(wc -l < "$first/npm.log")" == 1 ]] || fail "changed runtime lock did not invoke setup"

first_active="$(active_runtime "$first/xdg/browser-workbench/runtime")"
printf '%s\n' '{"version":"0.0.0-stale"}' > "$first_active/node_modules/playwright-core/package.json"; : > "$first/npm.log"
run_launcher "$first" || fail "stale Playwright Core was not repaired"
[[ "$(wc -l < "$first/npm.log")" == 1 ]] || fail "stale Playwright Core did not invoke setup"
first_active="$(active_runtime "$first/xdg/browser-workbench/runtime")"
assert_contains '"version":"1.63.0-alpha-2026-08-05"' "$first_active/node_modules/playwright-core/package.json"

mkdir -p "$first_active/node_modules/unexpected-package"
printf '%s\n' '{"name":"unexpected-package","version":"1.0.0"}' > "$first_active/node_modules/unexpected-package/package.json"
: > "$first/npm.log"; run_launcher "$first" || fail "extraneous installed package was not repaired"
[[ "$(wc -l < "$first/npm.log")" == 1 ]] || fail "extraneous installed package did not invoke setup"
first_active="$(active_runtime "$first/xdg/browser-workbench/runtime")"
[[ ! -e "$first_active/node_modules/unexpected-package" ]] || fail "extraneous installed package survived repair"

rm -rf "$first_active/node_modules/playwright-core"
: > "$first/npm.log"; run_launcher "$first" || fail "missing locked package was not repaired"
[[ "$(wc -l < "$first/npm.log")" == 1 ]] || fail "missing locked package did not invoke setup"
first_active="$(active_runtime "$first/xdg/browser-workbench/runtime")"
[[ -f "$first_active/node_modules/playwright-core/package.json" ]] || fail "missing locked package was not restored"

printf '%s\n' '{"name":"playwright","version":"1.63.0-alpha-2026-08-05","main":"index.js","dependencies":{"playwright-core":"wrong"},"optionalDependencies":{"fsevents":"2.3.2"}}' > "$first_active/node_modules/playwright/package.json"
: > "$first/npm.log"; run_launcher "$first" || fail "mismatched dependency edge was not repaired"
[[ "$(wc -l < "$first/npm.log")" == 1 ]] || fail "mismatched dependency edge did not invoke setup"
first_active="$(active_runtime "$first/xdg/browser-workbench/runtime")"
assert_contains '"playwright-core":"1.63.0-alpha-2026-08-05"' "$first_active/node_modules/playwright/package.json"

mv "$first_active/node_modules/@playwright/mcp/cli.js" "$first_active/node_modules/@playwright/mcp/cli.real.js"
ln -s cli.real.js "$first_active/node_modules/@playwright/mcp/cli.js"
: > "$first/npm.log"; run_launcher "$first" || fail "symlinked MCP CLI was not repaired"
[[ "$(wc -l < "$first/npm.log")" == 1 ]] || fail "symlinked MCP CLI did not invoke setup"
first_active="$(active_runtime "$first/xdg/browser-workbench/runtime")"
[[ -f "$first_active/node_modules/@playwright/mcp/cli.js" && ! -L "$first_active/node_modules/@playwright/mcp/cli.js" ]] || fail "MCP CLI was not restored as a regular file"

coordination="$(make_case launch-publication-coordination)"; case_env "$coordination"
bash "$coordination/plugin/scripts/setup.sh" >/dev/null
coord_runtime_root="$coordination/xdg/browser-workbench/runtime"
coord_old_active="$(active_runtime "$coord_runtime_root")"
coord_new_active="$(mktemp -d "$coord_runtime_root/.generations/runtime.XXXXXX")"
cp -a "$coord_old_active/." "$coord_new_active/"
exec {coord_lock_fd}>"$coordination/xdg/browser-workbench/setup.lock"
flock "$coord_lock_fd"
run_launcher "$coordination" & coord_launcher_pid=$!
sleep 0.1
coord_pointer_tmp="$(mktemp -d "$coord_runtime_root/.pointer.test.XXXXXX")"
ln -s ".generations/$(basename -- "$coord_new_active")" "$coord_pointer_tmp/current"
mv -Tf "$coord_pointer_tmp/current" "$coord_runtime_root/current"
rmdir "$coord_pointer_tmp"
flock -u "$coord_lock_fd"
exec {coord_lock_fd}>&-
wait "$coord_launcher_pid" || fail "launcher failed across coordinated publication"
assert_contains "$coord_new_active/node_modules/@playwright/mcp" "$coordination/exec.json"
[[ -d "$coord_old_active" ]] || fail "publication removed a generation that an earlier launcher could still use"

browser_generation="$(make_case browser-generation-lifetime)"; case_env "$browser_generation"
bash "$browser_generation/plugin/scripts/setup.sh" >/dev/null
browser_root="$browser_generation/xdg/browser-workbench/browsers"
old_browser_generation="$(active_browser "$browser_root")"
old_browser_executable="$old_browser_generation/chromium"
[[ -x "$old_browser_executable" ]] || fail "initial browser generation executable is missing"
export BROWSER_WORKBENCH_TEST_BROWSER_NAME=chromium-next BROWSER_WORKBENCH_TEST_NPM_DELAY=0.2
: > "$browser_generation/npm.log"
bash "$browser_generation/plugin/scripts/setup.sh" >"$browser_generation/setup-next.out" 2>"$browser_generation/setup-next.err" & browser_setup_pid=$!
for _ in $(seq 1 100); do [[ -s "$browser_generation/npm.log" ]] && break; sleep 0.01; done
run_launcher "$browser_generation" & browser_launcher_pid=$!
wait "$browser_setup_pid" || fail "new browser generation publication failed"
wait "$browser_launcher_pid" || fail "launcher failed while setup published a browser generation"
[[ "$(wc -l < "$browser_generation/npm.log")" == 1 ]] || fail "concurrent setup/launch installed the browser generation more than once"
new_browser_generation="$(active_browser "$browser_root")"
[[ "$new_browser_generation" != "$old_browser_generation" ]] || fail "browser publication did not switch generations"
[[ -x "$new_browser_generation/chromium-next" ]] || fail "new browser generation executable is missing"
[[ ! -e "$new_browser_generation/current" && ! -e "$new_browser_generation/.generations" ]] || fail "Playwright installed pointer scaffolding recursively inside a browser generation"
[[ -x "$old_browser_executable" ]] || fail "browser publication removed executable needed by an existing client"
"$old_browser_executable" || fail "old client could not launch from its retained browser generation"
assert_contains "$new_browser_generation" "$browser_generation/exec.json"

pointer_failure="$(make_case pointer-rename-failure)"; case_env "$pointer_failure"
bash "$pointer_failure/plugin/scripts/setup.sh" >/dev/null
pointer_old_active="$(active_runtime "$pointer_failure/xdg/browser-workbench/runtime")"
printf '%s\n' keep-old > "$pointer_old_active/old-generation-marker"
printf '%s\n' '{"version":"stale-core"}' > "$pointer_old_active/node_modules/playwright-core/package.json"
pointer_generation_count="$(find "$pointer_failure/xdg/browser-workbench/runtime/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)"
install_faulty_mv "$pointer_failure"
export BROWSER_WORKBENCH_TEST_MV_MATCH=current BROWSER_WORKBENCH_TEST_MV_MODE=fail BROWSER_WORKBENCH_TEST_MV_MARKER="$pointer_failure/mv.once"
if bash "$pointer_failure/plugin/scripts/setup.sh" >"$pointer_failure/publish-fail.out" 2>"$pointer_failure/publish-fail.err"; then fail "runtime pointer rename failure returned success"; fi
[[ "$(active_runtime "$pointer_failure/xdg/browser-workbench/runtime")" == "$pointer_old_active" ]] || fail "pointer rename failure changed active runtime"
[[ -f "$pointer_old_active/old-generation-marker" ]] || fail "pointer rename failure lost prior live generation"
[[ "$(find "$pointer_failure/xdg/browser-workbench/runtime/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$pointer_generation_count" ]] || fail "pointer rename failure published or leaked a partial generation"

rm -f "$pointer_failure/mv.once"
export BROWSER_WORKBENCH_TEST_MV_MODE=signal
set +e
bash "$pointer_failure/plugin/scripts/setup.sh" >"$pointer_failure/publish-signal.out" 2>"$pointer_failure/publish-signal.err"
pointer_signal_status=$?
set -e
[[ "$pointer_signal_status" == 143 ]] || fail "TERM publication window returned $pointer_signal_status instead of 143"
[[ "$(active_runtime "$pointer_failure/xdg/browser-workbench/runtime")" == "$pointer_old_active" ]] || fail "TERM publication window did not restore prior runtime pointer"
[[ -f "$pointer_old_active/old-generation-marker" ]] || fail "TERM publication window lost prior live generation"
[[ "$(find "$pointer_failure/xdg/browser-workbench/runtime/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$pointer_generation_count" ]] || fail "TERM publication window left a partial generation"

stale="$(make_case stale-cache)"; case_env "$stale"
mkdir -p "$stale/xdg/browser-workbench/runtime/node_modules/@playwright/mcp" "$stale/xdg/browser-workbench/runtime/node_modules/playwright"
printf '%s\n' '{"version":"0.0.78","dependencies":{"playwright":"old"}}' > "$stale/xdg/browser-workbench/runtime/node_modules/@playwright/mcp/package.json"
printf '%s\n' '// stale' > "$stale/xdg/browser-workbench/runtime/node_modules/@playwright/mcp/cli.js"
printf '%s\n' '{"version":"old"}' > "$stale/xdg/browser-workbench/runtime/node_modules/playwright/package.json"
run_launcher "$stale" || fail "stale cache was not repaired"
stale_active="$(active_runtime "$stale/xdg/browser-workbench/runtime")"
assert_contains '"version":"0.0.79"' "$stale_active/node_modules/@playwright/mcp/package.json"

failure="$(make_case setup-failure)"; case_env "$failure"
mkdir -p "$failure/xdg/browser-workbench/runtime"; printf '%s\n' sentinel > "$failure/xdg/browser-workbench/runtime/sentinel"
export BROWSER_WORKBENCH_TEST_NPM_FAIL=1
if run_launcher "$failure"; then fail "setup failure returned success"; fi
assert_empty "$failure/stdout"
assert_contains 'automatic setup failed' "$failure/stderr"
[[ -f "$failure/xdg/browser-workbench/runtime/sentinel" ]] || fail "failed setup changed live runtime"
if find "$failure/xdg/browser-workbench" -name '*.stage.*' -print -quit | grep -q .; then fail "failed setup left a staging directory"; fi

browser_failure="$(make_case browser-failure)"; case_env "$browser_failure"
bash "$browser_failure/plugin/scripts/setup.sh" >/dev/null
browser_failure_old_generation="$(active_browser "$browser_failure/xdg/browser-workbench/browsers")"
export BROWSER_WORKBENCH_TEST_BROWSER_NAME=chromium-failure
browser_failure_active="$(active_runtime "$browser_failure/xdg/browser-workbench/runtime")"
runtime_before="$(sha256sum "$browser_failure_active/package-lock.json")"
export BROWSER_WORKBENCH_TEST_BROWSER_FAIL=1
if run_launcher "$browser_failure"; then fail "browser installer failure returned success"; fi
assert_empty "$browser_failure/stdout"
[[ "$(sha256sum "$browser_failure_active/package-lock.json")" == "$runtime_before" ]] || fail "browser install failure changed live runtime"
[[ "$(active_browser "$browser_failure/xdg/browser-workbench/browsers")" == "$browser_failure_old_generation" ]] || fail "browser install failure changed active browser generation"
[[ -x "$browser_failure_old_generation/chromium" ]] || fail "browser install failure removed prior executable"

browser_rename_failure="$(make_case browser-rename-failure)"; case_env "$browser_rename_failure"
bash "$browser_rename_failure/plugin/scripts/setup.sh" >/dev/null
browser_rename_old_generation="$(active_browser "$browser_rename_failure/xdg/browser-workbench/browsers")"
printf '%s\n' keep-browser > "$browser_rename_old_generation/old-browser-marker"
browser_generation_count="$(find "$browser_rename_failure/xdg/browser-workbench/browsers/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)"
export BROWSER_WORKBENCH_TEST_BROWSER_NAME=chromium-replacement
install_faulty_mv "$browser_rename_failure"
export BROWSER_WORKBENCH_TEST_MV_MATCH=browser-current BROWSER_WORKBENCH_TEST_MV_MODE=fail BROWSER_WORKBENCH_TEST_MV_MARKER="$browser_rename_failure/mv.once"
if bash "$browser_rename_failure/plugin/scripts/setup.sh" >"$browser_rename_failure/browser-publish.out" 2>"$browser_rename_failure/browser-publish.err"; then fail "browser second rename failure returned success"; fi
[[ "$(active_browser "$browser_rename_failure/xdg/browser-workbench/browsers")" == "$browser_rename_old_generation" ]] || fail "browser pointer rename failure changed active generation"
[[ -f "$browser_rename_old_generation/old-browser-marker" ]] || fail "browser pointer rename failure lost prior live cache"
[[ -x "$browser_rename_old_generation/chromium" ]] || fail "browser pointer rename failure removed prior executable"
[[ "$(find "$browser_rename_failure/xdg/browser-workbench/browsers/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$browser_generation_count" ]] || fail "browser pointer rename failure leaked an unpublished generation"

rm -f "$browser_rename_failure/mv.once"
export BROWSER_WORKBENCH_TEST_MV_MODE=signal
set +e
bash "$browser_rename_failure/plugin/scripts/setup.sh" >"$browser_rename_failure/browser-signal.out" 2>"$browser_rename_failure/browser-signal.err"
browser_signal_status=$?
set -e
[[ "$browser_signal_status" == 143 ]] || fail "browser TERM publication window returned $browser_signal_status instead of 143"
[[ "$(active_browser "$browser_rename_failure/xdg/browser-workbench/browsers")" == "$browser_rename_old_generation" ]] || fail "browser TERM publication window did not restore prior generation"
[[ -x "$browser_rename_old_generation/chromium" ]] || fail "browser TERM publication window removed prior executable"
[[ "$(find "$browser_rename_failure/xdg/browser-workbench/browsers/.generations" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$browser_generation_count" ]] || fail "browser TERM publication window leaked a partial generation"

concurrent="$(make_case concurrent-setup)"; case_env "$concurrent"
export BROWSER_WORKBENCH_TEST_NPM_DELAY=0.2
bash "$concurrent/plugin/scripts/setup.sh" >"$concurrent/setup1.out" 2>"$concurrent/setup1.err" & p1=$!
bash "$concurrent/plugin/scripts/setup.sh" >"$concurrent/setup2.out" 2>"$concurrent/setup2.err" & p2=$!
for _ in $(seq 1 100); do [[ -s "$concurrent/npm.log" ]] && break; sleep 0.01; done
[[ ! -e "$concurrent/xdg/browser-workbench/runtime/node_modules" ]] || fail "setup exposed partial live node_modules"
wait "$p1" || fail "first concurrent setup failed"
wait "$p2" || fail "second concurrent setup failed"
[[ "$(wc -l < "$concurrent/npm.log")" == 1 ]] || fail "concurrent setup ran npm more than once"

overrides="$(make_case setup-overrides)"; case_env "$overrides"
mkdir -p "$overrides/custom-browsers"; chmod 0777 "$overrides/custom-browsers"
export BROWSER_WORKBENCH_RUNTIME_DIR='custom/../custom-runtime'
export BROWSER_WORKBENCH_BROWSERS_PATH="$overrides/custom-browsers"
bash "$overrides/plugin/scripts/setup.sh" >/dev/null || fail "setup with path overrides failed"
overrides_active="$(active_runtime "$overrides/plugin/custom-runtime")"
[[ -f "$overrides_active/node_modules/@playwright/mcp/cli.js" ]] || fail "relative runtime override did not retain plugin-relative semantics"
[[ -x "$overrides/custom-browsers/chromium" ]] || fail "custom browser cache was not provisioned"
[[ ! -e "$overrides/custom-browsers/current" && ! -e "$overrides/custom-browsers/.generations" ]] || fail "custom browser cache received owned-pointer scaffolding"
assert_mode "$overrides/custom-browsers" 777
if ! bash "$overrides/plugin/scripts/doctor.sh" >"$overrides/doctor.out" 2>"$overrides/doctor.err"; then fail "doctor rejected safe custom runtime/browser overrides: $(sed -n '1,10p' "$overrides/doctor.err")"; fi
assert_contains 'Doctor result: ready' "$overrides/doctor.out"
assert_contains 'custom path (externally managed; setup updates it in place)' "$overrides/doctor.out"

sanitize="$(make_case sanitize)"; case_env "$sanitize"
bash "$sanitize/plugin/scripts/setup.sh" >/dev/null
export NODE_OPTIONS='--definitely-invalid-option' PWDEBUG=console PLAYWRIGHT_FOO=bad
run_launcher "$sanitize" || fail "sanitized launch failed"
assert_empty "$sanitize/stdout"
assert_contains '"nodeOptions":""' "$sanitize/exec.json"
assert_contains '"pwdebug":""' "$sanitize/exec.json"
assert_contains '"playwrightFoo":""' "$sanitize/exec.json"

custom="$(make_case custom-paths)"; case_env "$custom"
bash "$custom/plugin/scripts/setup.sh" >/dev/null
mkdir -p "$custom/custom-output" "$custom/custom-tmp"; chmod 0777 "$custom/custom-output" "$custom/custom-tmp"
export BROWSER_WORKBENCH_OUTPUT_DIR="$custom/custom-output" BROWSER_WORKBENCH_TMPDIR="$custom/custom-tmp"
run_launcher "$custom" || fail "custom-path launch failed"
assert_mode "$custom/custom-output" 777
assert_mode "$custom/custom-tmp" 777
mkdir -p "$custom/custom-profile"; chmod 0777 "$custom/custom-profile"
export BROWSER_WORKBENCH_MODE=persistent BROWSER_WORKBENCH_USER_DATA_DIR="$custom/custom-profile"
run_launcher "$custom" || fail "custom-profile launch failed"
assert_mode "$custom/custom-profile" 777
if ! bash "$custom/plugin/scripts/doctor.sh" >"$custom/doctor.out" 2>"$custom/doctor.err"; then fail "doctor treated custom output/tmp/profile permissions as owned defaults"; fi
assert_contains 'Doctor result: ready' "$custom/doctor.out"

symlink_case="$(make_case symlink-refusal)"; case_env "$symlink_case"
mkdir -p "$symlink_case/xdg/browser-workbench" "$symlink_case/outside-output"
chmod 0700 "$symlink_case/xdg/browser-workbench"; chmod 0777 "$symlink_case/outside-output"
ln -s "$symlink_case/outside-output" "$symlink_case/xdg/browser-workbench/output"
if run_launcher "$symlink_case"; then fail "owned output symlink unexpectedly launched"; fi
assert_contains 'unsafe or unusable owned output directory' "$symlink_case/stderr"
assert_mode "$symlink_case/outside-output" 777
[[ ! -e "$symlink_case/npm.log" ]] || fail "symlink refusal invoked setup"

runtime_escape="$(make_case runtime-generation-escape)"; case_env "$runtime_escape"
bash "$runtime_escape/plugin/scripts/setup.sh" >/dev/null
runtime_escape_root="$runtime_escape/xdg/browser-workbench/runtime"
mv "$runtime_escape_root/.generations" "$runtime_escape/outside-runtime-generations"
ln -s "$runtime_escape/outside-runtime-generations" "$runtime_escape_root/.generations"
: > "$runtime_escape/npm.log"
if run_launcher "$runtime_escape"; then fail "runtime generation-root symlink escape unexpectedly launched"; fi
assert_contains 'runtime generation root must not be a symlink' "$runtime_escape/stderr"
assert_empty "$runtime_escape/npm.log"
if bash "$runtime_escape/plugin/scripts/doctor.sh" >"$runtime_escape/doctor.out" 2>"$runtime_escape/doctor.err"; then fail "doctor accepted runtime generation-root symlink escape"; fi
assert_contains 'runtime generation root must not be a symlink' "$runtime_escape/doctor.out"

browser_escape="$(make_case browser-generation-escape)"; case_env "$browser_escape"
bash "$browser_escape/plugin/scripts/setup.sh" >/dev/null
browser_escape_root="$browser_escape/xdg/browser-workbench/browsers"
mv "$browser_escape_root/.generations" "$browser_escape/outside-browser-generations"
ln -s "$browser_escape/outside-browser-generations" "$browser_escape_root/.generations"
: > "$browser_escape/npm.log"
if run_launcher "$browser_escape"; then fail "browser generation-root symlink escape unexpectedly launched"; fi
assert_contains 'browser generation root must not be a symlink' "$browser_escape/stderr"
assert_empty "$browser_escape/npm.log"
if bash "$browser_escape/plugin/scripts/doctor.sh" >"$browser_escape/doctor.out" 2>"$browser_escape/doctor.err"; then fail "doctor accepted browser generation-root symlink escape"; fi
assert_contains 'browser generation root must not be a symlink' "$browser_escape/doctor.out"

unsafe_generation="$(make_case unsafe-generation-mode)"; case_env "$unsafe_generation"
bash "$unsafe_generation/plugin/scripts/setup.sh" >/dev/null
unsafe_runtime_active="$(active_runtime "$unsafe_generation/xdg/browser-workbench/runtime")"
unsafe_browser_active="$(active_browser "$unsafe_generation/xdg/browser-workbench/browsers")"
chmod 0755 "$unsafe_runtime_active"
if run_launcher "$unsafe_generation"; then fail "group-readable runtime generation unexpectedly launched"; fi
assert_contains 'runtime generation must be an owned private directory' "$unsafe_generation/stderr"
if bash "$unsafe_generation/plugin/scripts/doctor.sh" >"$unsafe_generation/doctor-runtime.out" 2>"$unsafe_generation/doctor-runtime.err"; then fail "doctor accepted unsafe runtime generation mode"; fi
assert_contains 'runtime generation must be an owned private directory' "$unsafe_generation/doctor-runtime.out"
chmod 0700 "$unsafe_runtime_active"
chmod 0755 "$unsafe_browser_active"
if run_launcher "$unsafe_generation"; then fail "group-readable browser generation unexpectedly launched"; fi
assert_contains 'browser generation must be an owned private directory' "$unsafe_generation/stderr"
if bash "$unsafe_generation/plugin/scripts/doctor.sh" >"$unsafe_generation/doctor-browser.out" 2>"$unsafe_generation/doctor-browser.err"; then fail "doctor accepted unsafe browser generation mode"; fi
assert_contains 'browser generation must be an owned private directory' "$unsafe_generation/doctor-browser.out"

dry="$(make_case dry-run)"; case_env "$dry"
export BROWSER_WORKBENCH_DRY_RUN=1 XDG_CACHE_HOME=relative-cache
run_launcher "$dry" || fail "empty-cache dry run failed"
assert_contains "$dry/home/.cache/browser-workbench/output" "$dry/stdout"
assert_contains '--output-max-size 104857600' "$dry/stdout"
[[ ! -e "$dry/home/.cache/browser-workbench" ]] || fail "dry run mutated cache"
[[ ! -e "$dry/npm.log" ]] || fail "dry run invoked npm"

case_env "$dry"; export BROWSER_WORKBENCH_DRY_RUN=1 HOME=relative-home
if run_launcher "$dry"; then fail "relative HOME unexpectedly passed path validation"; fi
assert_contains 'HOME must be an absolute path' "$dry/stderr"
if bash "$dry/plugin/scripts/setup.sh" >"$dry/setup-relative-home.out" 2>"$dry/setup-relative-home.err"; then fail "setup accepted a relative HOME"; fi
assert_contains 'HOME must be an absolute path' "$dry/setup-relative-home.err"
if bash "$dry/plugin/scripts/doctor.sh" >"$dry/doctor-relative-home.out" 2>"$dry/doctor-relative-home.err"; then fail "doctor accepted a relative HOME"; fi
assert_contains 'HOME must be an absolute path' "$dry/doctor-relative-home.err"

for mode in isolated persistent extension; do
  case_env "$dry"; export BROWSER_WORKBENCH_DRY_RUN=1 BROWSER_WORKBENCH_MODE="$mode"
  run_launcher "$dry" || fail "$mode dry run failed"
  assert_contains "mode=$mode" "$dry/stdout"
done
case_env "$dry"; export BROWSER_WORKBENCH_DRY_RUN=1 BROWSER_WORKBENCH_MODE=cdp BROWSER_WORKBENCH_CDP_ENDPOINT='ws://127.0.0.1:9222/devtools/browser/secret'
run_launcher "$dry" || fail "cdp dry run failed"
assert_contains '--cdp-endpoint [configured]' "$dry/stdout"
if grep -Fq secret "$dry/stdout"; then fail "dry run disclosed CDP endpoint"; fi

case_env "$first"; export BROWSER_WORKBENCH_MODE=cdp BROWSER_WORKBENCH_CDP_ENDPOINT='ws://127.0.0.1:9222/devtools/browser/doctor-secret'
if ! bash "$first/plugin/scripts/doctor.sh" >"$first/doctor-cdp.out" 2>"$first/doctor-cdp.err"; then fail "doctor rejected valid CDP config"; fi
if grep -Fq doctor-secret "$first/doctor-cdp.out" "$first/doctor-cdp.err"; then fail "doctor disclosed CDP endpoint"; fi

expect_invalid() {
  local label="$1"; shift
  case_env "$dry"; export BROWSER_WORKBENCH_DRY_RUN=1
  if env "$@" bash "$dry/plugin/scripts/launch-mcp.sh" >"$dry/invalid.out" 2>"$dry/invalid.err"; then fail "$label unexpectedly succeeded"; fi
  assert_contains 'invalid configuration' "$dry/invalid.err"
}
expect_invalid bad-mode BROWSER_WORKBENCH_MODE=wat
expect_invalid firefox BROWSER_WORKBENCH_BROWSER=firefox
expect_invalid cdp-browser BROWSER_WORKBENCH_MODE=cdp BROWSER_WORKBENCH_CDP_ENDPOINT=ws://localhost:9222 BROWSER_WORKBENCH_BROWSER=chrome
expect_invalid cdp-outside-mode BROWSER_WORKBENCH_CDP_ENDPOINT=ws://localhost:9222
expect_invalid profile-outside-persistent BROWSER_WORKBENCH_USER_DATA_DIR=profile
expect_invalid bad-caps BROWSER_WORKBENCH_CAPS=vision,vision
expect_invalid bad-quota BROWSER_WORKBENCH_OUTPUT_MAX_SIZE=0
expect_invalid huge-quota BROWSER_WORKBENCH_OUTPUT_MAX_SIZE=10737418241

case_env "$first"; export BROWSER_WORKBENCH_MODE=bad BROWSER_WORKBENCH_OUTPUT_MAX_SIZE=0
if bash "$first/plugin/scripts/doctor.sh" >"$first/doctor-config.out" 2>"$first/doctor-config.err"; then fail "doctor accepted multiple invalid settings"; fi
assert_contains 'BROWSER_WORKBENCH_MODE' "$first/doctor-config.err"
assert_contains 'BROWSER_WORKBENCH_OUTPUT_MAX_SIZE' "$first/doctor-config.err"

case_env "$dry"; export BROWSER_WORKBENCH_DRY_RUN=1 BROWSER_WORKBENCH_OUTPUT_MAX_SIZE=4096
run_launcher "$dry" || fail "quota override failed"
assert_contains '--output-max-size 4096' "$dry/stdout"

printf 'Browser Workbench runtime/bootstrap tests passed\n'
