#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
BRIDGE="$SCRIPT_DIR/windows-image-bridge.sh"
VALIDATOR="$SCRIPT_DIR/validate-png.mjs"
FIXTURE_GENERATOR="$SCRIPT_DIR/test-fixtures/generate-png.mjs"
FAKE_POWERSHELL="$SCRIPT_DIR/test-fixtures/fake-powershell.js"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/browser-workbench-windows-image-test.XXXXXX")"
ORIGINAL_PATH="$PATH"
if command -v powershell.exe >/dev/null 2>&1; then
  REAL_POWERSHELL_AVAILABLE=1
else
  REAL_POWERSHELL_AVAILABLE=0
fi
REAL_WINDOWS_FILE=""
REAL_WINDOWS_DIR=""
trap 'if [[ -n "$REAL_WINDOWS_FILE" && -e "$REAL_WINDOWS_FILE" ]]; then rm -f -- "$REAL_WINDOWS_FILE"; fi; if [[ -n "$REAL_WINDOWS_DIR" && -d "$REAL_WINDOWS_DIR" ]]; then rmdir -- "$REAL_WINDOWS_DIR" 2>/dev/null || true; fi; rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  printf 'windows image bridge test: %s\n' "$*" >&2
  exit 1
}

is_wsl() {
  [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version
}

expect_failure() {
  local description="$1"
  shift
  if "$@" >"$TEST_ROOT/expected-failure.stdout" 2>"$TEST_ROOT/expected-failure.stderr"; then
    fail "$description unexpectedly succeeded"
  fi
}

json_field() {
  local field="$1"
  node -e '
const field = process.argv[1];
const value = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
process.stdout.write(`${value[field]}\n`);
' "$field"
}

assert_json_list() {
  local expected_count="$1"
  node -e '
const expected = Number(process.argv[1]);
const input = require("node:fs").readFileSync(0, "utf8");
const result = JSON.parse(input);
if (!Array.isArray(result.files) || result.files.length !== expected) {
  throw new Error(`unexpected bridge list: ${input}`);
}
for (const entry of result.files) {
  if (!entry.path.startsWith("/") || entry.mime !== "image/png" || !Number.isInteger(entry.width) || !Number.isInteger(entry.height) || !Number.isInteger(entry.bytes)) {
    throw new Error(`unsafe bridge metadata: ${JSON.stringify(entry)}`);
  }
}
' "$expected_count"
}

export XDG_CACHE_HOME="$TEST_ROOT/cache"
mkdir -p "$TEST_ROOT/fake-bin"
printf '#!/usr/bin/env bash\nexec node %q "$@"\n' "$FAKE_POWERSHELL" > "$TEST_ROOT/fake-bin/powershell.exe"
chmod 700 -- "$TEST_ROOT/fake-bin/powershell.exe"
export PATH="$TEST_ROOT/fake-bin:$PATH"
export BROWSER_WORKBENCH_BRIDGE_TESTING=1
export BROWSER_WORKBENCH_BRIDGE_TEST_ROOT="$TEST_ROOT"
export FAKE_POWERSHELL_LOG="$TEST_ROOT/fake-powershell.log"
export FAKE_POWERSHELL_BEHAVIOR=success
export FAKE_POWERSHELL_FIXTURE="$TEST_ROOT/good.png"

mkdir -p "$TEST_ROOT/cache"
node "$FIXTURE_GENERATOR" "$TEST_ROOT/good.png" 8 6
bridge_root="$XDG_CACHE_HOME/browser-workbench/windows-images"

ln -s -- "$TEST_ROOT/cache" "$TEST_ROOT/cache-link"
expect_failure "symlinked XDG cache parent" env XDG_CACHE_HOME="$TEST_ROOT/cache-link" "$BRIDGE" clipboard --dry-run

node - "$TEST_ROOT/good.png" "$TEST_ROOT" <<'NODE'
const fs = require("node:fs");
const zlib = require("node:zlib");

const [inputPath, outputDirectory] = process.argv.slice(2);
const input = fs.readFileSync(inputPath);
const signature = input.subarray(0, 8);
const chunks = [];
let offset = 8;
while (offset < input.length) {
  const length = input.readUInt32BE(offset);
  const end = offset + 12 + length;
  chunks.push({
    type: input.subarray(offset + 4, offset + 8).toString("ascii"),
    data: input.subarray(offset + 8, offset + 8 + length),
    raw: input.subarray(offset, end),
  });
  offset = end;
}

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc & 1) === 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function makeChunk(type, data) {
  const typeBytes = Buffer.isBuffer(type) ? type : Buffer.from(type, "ascii");
  const result = Buffer.alloc(12 + data.length);
  result.writeUInt32BE(data.length, 0);
  typeBytes.copy(result, 4);
  data.copy(result, 8);
  result.writeUInt32BE(crc32(Buffer.concat([typeBytes, data])), 8 + data.length);
  return result;
}

const ihdrIndex = chunks.findIndex((chunk) => chunk.type === "IHDR");
const idatIndex = chunks.findIndex((chunk) => chunk.type === "IDAT");
if (ihdrIndex !== 0 || idatIndex < 0) {
  throw new Error("generated fixture did not contain the expected PNG chunks");
}

function writeFixture(name, replacements, extraAfterIhdr) {
  const output = [];
  for (let index = 0; index < chunks.length; index += 1) {
    output.push(chunks[index].raw);
    if (index === ihdrIndex && extraAfterIhdr) {
      output.push(extraAfterIhdr);
    }
  }
  for (const [index, replacement] of replacements) {
    output[index] = replacement;
  }
  fs.writeFileSync(`${outputDirectory}/${name}.png`, Buffer.concat([signature, ...output]), { mode: 0o600 });
}

writeFixture("malformed-critical", [], makeChunk("ABCD", Buffer.alloc(0)));
writeFixture("malformed-chunk", [], makeChunk(Buffer.from([0xc1, 0x44, 0x41, 0x54]), Buffer.alloc(0)));
writeFixture("malformed-zlib", [[idatIndex, makeChunk("IDAT", Buffer.from([0x78, 0x9c, 0x00]))]]);

const decoded = zlib.inflateSync(chunks[idatIndex].data);
decoded[0] = 5;
writeFixture("malformed-filter", [[idatIndex, makeChunk("IDAT", zlib.deflateSync(decoded))]]);
NODE
for malformed in critical chunk zlib filter; do
  expect_failure "malformed $malformed PNG" node "$VALIDATOR" --json "$TEST_ROOT/malformed-$malformed.png"
done

doctor_output="$($BRIDGE doctor)"
[[ "$doctor_output" == *"read-only"* ]] || fail "doctor output did not identify read-only mode"
[[ ! -e "$FAKE_POWERSHELL_LOG" ]] || fail "doctor invoked the PowerShell seam"
dry_run_output="$($BRIDGE clipboard --dry-run)"
[[ "$dry_run_output" == *'"dry_run":true'* ]] || fail "clipboard dry-run did not report dry_run"
[[ ! -e "$FAKE_POWERSHELL_LOG" ]] || fail "dry-run touched the PowerShell seam"
mkdir -p "$TEST_ROOT/declared-seam-root"
expect_failure "PowerShell seam executable outside declared test root" env BROWSER_WORKBENCH_BRIDGE_TEST_ROOT="$TEST_ROOT/declared-seam-root" "$BRIDGE" clipboard
[[ ! -e "$FAKE_POWERSHELL_LOG" ]] || fail "PowerShell seam was invoked outside its declared test root"
expect_failure "invalid dry-run file path" "$BRIDGE" file '../relative.png' --dry-run
for unsafe_path in 'https://example.invalid/image.png' '\\server\share\image.png' '\\?\C:\image.png' 'C:\image.png:stream'; do
  expect_failure "unsafe dry-run file path $unsafe_path" "$BRIDGE" file "$unsafe_path" --dry-run
done

clipboard_output="$($BRIDGE clipboard)"
clipboard_path="$(printf '%s' "$clipboard_output" | json_field path)"
[[ -f "$clipboard_path" && ! -L "$clipboard_path" ]] || fail "clipboard output was not a regular file"
node "$VALIDATOR" --json "$clipboard_path" >/dev/null
[[ "$(stat -c '%a' "$bridge_root")" == 700 ]] || fail "bridge root is not mode 0700"
[[ "$(stat -c '%a' "$clipboard_path")" == 600 ]] || fail "bridge file is not mode 0600"

weird_path='C:\Users\Public\image with spaces;$(whoami)''[*.png'
file_output="$($BRIDGE file "$weird_path")"
file_path="$(printf '%s' "$file_output" | json_field path)"
[[ -f "$file_path" ]] || fail "file mode did not publish an image"
node - "$FAKE_POWERSHELL_LOG" "$weird_path" <<'NODE'
const fs = require("node:fs");
const [logPath, expectedPath] = process.argv.slice(2);
const lines = fs.readFileSync(logPath, "utf8").trim().split(/\n/);
const last = JSON.parse(lines.at(-1));
if (last.mode !== "file" || last.input_path !== expectedPath) {
  throw new Error(`PowerShell argument was changed: ${JSON.stringify(last)}`);
}
NODE

before_count="$(find -P "$bridge_root" -mindepth 1 -maxdepth 1 -type f -name 'windows-image-*.png' | wc -l)"
export FAKE_POWERSHELL_BEHAVIOR=text
expect_failure "clipboard text refusal" "$BRIDGE" clipboard
after_count="$(find -P "$bridge_root" -mindepth 1 -maxdepth 1 -type f -name 'windows-image-*.png' | wc -l)"
[[ "$before_count" == "$after_count" ]] || fail "text refusal left a published file"
for behavior in malformed truncated non-png; do
  export FAKE_POWERSHELL_BEHAVIOR="$behavior"
  expect_failure "$behavior output" "$BRIDGE" clipboard
done
export FAKE_POWERSHELL_BEHAVIOR=success

node "$FIXTURE_GENERATOR" "$TEST_ROOT/too-wide.png" 20001 1
export FAKE_POWERSHELL_FIXTURE="$TEST_ROOT/too-wide.png"
expect_failure "dimension limit" "$BRIDGE" clipboard
truncate -s $((25 * 1024 * 1024 + 1)) "$TEST_ROOT/too-large.png"
expect_failure "encoded size limit" node "$VALIDATOR" --json "$TEST_ROOT/too-large.png"
export FAKE_POWERSHELL_FIXTURE="$TEST_ROOT/good.png"

expect_failure "missing file argument" "$BRIDGE" file
expect_failure "unsupported command" "$BRIDGE" unsupported

second_output="$($BRIDGE clipboard)"
second_path="$(printf '%s' "$second_output" | json_field path)"
[[ "$clipboard_path" != "$second_path" ]] || fail "bridge result names are not unique"
[[ -z "$(find -P "$bridge_root" -mindepth 1 -maxdepth 1 -name '.windows-image.*' -print -quit)" ]] || fail "temporary result remained after publish"

ln -s -- "$clipboard_path" "$bridge_root/windows-image-20260101T000000Z-symlink.png"
cp -- "$clipboard_path" "$bridge_root/windows-image-not-a-normalized-name.png"
list_output="$($BRIDGE list)"
printf '%s' "$list_output" | assert_json_list 3
cleanup_preview="$($BRIDGE cleanup --all --dry-run)"
[[ "$cleanup_preview" == *'"dry_run":true'* && "$cleanup_preview" == *'"removed":3'* ]] || fail "cleanup dry-run did not report the expected files"
[[ -f "$clipboard_path" && -f "$file_path" && -f "$second_path" ]] || fail "cleanup dry-run removed a bridge file"

old_path="$bridge_root/windows-image-20260101T000000Z-oldfixture.png"
cp -- "$clipboard_path" "$old_path"
touch -d '3 days ago' "$old_path"
outside_path="$TEST_ROOT/outside.png"
cp -- "$clipboard_path" "$outside_path"
cleanup_output="$($BRIDGE cleanup --older-than-days 1)"
[[ ! -e "$old_path" ]] || fail "age-bounded cleanup retained an old bridge file"
[[ -e "$outside_path" ]] || fail "cleanup touched a file outside the bridge root"
[[ "$cleanup_output" == *'"removed":1'* ]] || fail "cleanup did not report its removal"

export BROWSER_WORKBENCH_WINDOWS_IMAGE_TIMEOUT_SECONDS=1
export FAKE_POWERSHELL_BEHAVIOR=timeout
expect_failure "PowerShell timeout" timeout 5s "$BRIDGE" clipboard
unset BROWSER_WORKBENCH_WINDOWS_IMAGE_TIMEOUT_SECONDS
export FAKE_POWERSHELL_BEHAVIOR=success

if ! is_wsl 2>/dev/null; then
  unset BROWSER_WORKBENCH_BRIDGE_TESTING BROWSER_WORKBENCH_BRIDGE_TEST_ROOT
  expect_failure "non-WSL refusal" "$BRIDGE" clipboard
  export BROWSER_WORKBENCH_BRIDGE_TESTING=1
  export BROWSER_WORKBENCH_BRIDGE_TEST_ROOT="$TEST_ROOT"
else
  printf 'Windows image bridge test: non-WSL refusal skipped on WSL\n'
fi

if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version && [[ "$REAL_POWERSHELL_AVAILABLE" -eq 1 ]]; then
  REAL_WINDOWS_DIR="/mnt/c/Users/Public/browser-workbench-bridge-test-$(date +%s)-$$"
  mkdir -p -- "$REAL_WINDOWS_DIR"
  REAL_WINDOWS_FILE="$REAL_WINDOWS_DIR/image with spaces;punctuation.png"
  node "$FIXTURE_GENERATOR" "$REAL_WINDOWS_FILE" 11 7
  real_windows_path="$(wslpath -w -- "$REAL_WINDOWS_FILE")"
  (
    unset BROWSER_WORKBENCH_BRIDGE_TESTING BROWSER_WORKBENCH_BRIDGE_TEST_ROOT
    export PATH="$ORIGINAL_PATH"
    export XDG_CACHE_HOME="$TEST_ROOT/real-cache"
    timeout 30s "$BRIDGE" file "$real_windows_path" >/dev/null
  )
  printf 'Windows image bridge test: real WSL file-mode integration passed\n'
else
  printf 'Windows image bridge test: real WSL file-mode integration skipped (not WSL with powershell.exe)\n'
fi

printf 'Windows image bridge tests passed\n'
