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
  REAL_POWERSHELL_EXECUTABLE="$(command -v powershell.exe)"
else
  REAL_POWERSHELL_AVAILABLE=0
  REAL_POWERSHELL_EXECUTABLE=""
fi
REAL_WINDOWS_DIR=""
REAL_WINDOWS_TARGET_DIR=""
REAL_WINDOWS_JUNCTION=""
REAL_WINDOWS_FILES=()
trap 'if [[ -n "$REAL_WINDOWS_JUNCTION" && -L "$REAL_WINDOWS_JUNCTION" ]]; then rm -f -- "$REAL_WINDOWS_JUNCTION"; elif [[ -n "$REAL_WINDOWS_JUNCTION" && -d "$REAL_WINDOWS_JUNCTION" ]]; then rmdir -- "$REAL_WINDOWS_JUNCTION" 2>/dev/null || true; fi; for real_file in "${REAL_WINDOWS_FILES[@]}"; do if [[ -e "$real_file" || -L "$real_file" ]]; then rm -f -- "$real_file"; fi; done; if [[ -n "$REAL_WINDOWS_TARGET_DIR" && -d "$REAL_WINDOWS_TARGET_DIR" ]]; then rmdir -- "$REAL_WINDOWS_TARGET_DIR" 2>/dev/null || true; fi; if [[ -n "$REAL_WINDOWS_DIR" && -d "$REAL_WINDOWS_DIR" ]]; then rmdir -- "$REAL_WINDOWS_DIR" 2>/dev/null || true; fi; rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM

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

function writeRaw(name, rawChunks) {
  fs.writeFileSync(`${outputDirectory}/${name}.png`, Buffer.concat([signature, ...rawChunks]), { mode: 0o600 });
}

function imageHeaderData(width, height, bitDepth, colorType) {
  const data = Buffer.alloc(13);
  data.writeUInt32BE(width, 0);
  data.writeUInt32BE(height, 4);
  data[8] = bitDepth;
  data[9] = colorType;
  return data;
}

function imageHeader(width, height, bitDepth, colorType) {
  return makeChunk("IHDR", imageHeaderData(width, height, bitDepth, colorType));
}

writeFixture("malformed-critical", [], makeChunk("ABCD", Buffer.alloc(0)));
writeFixture("malformed-chunk", [], makeChunk(Buffer.from([0xc1, 0x44, 0x41, 0x54]), Buffer.alloc(0)));
writeFixture("malformed-zlib", [[idatIndex, makeChunk("IDAT", Buffer.from([0x78, 0x9c, 0x00]))]]);
writeFixture("malformed-zlib-trailing", [[idatIndex, makeChunk("IDAT", Buffer.concat([chunks[idatIndex].data, Buffer.from([1, 2, 3])]))]]);
writeFixture("malformed-compressed-metadata", [], makeChunk("zTXt", Buffer.from("key\0x")));
writeFixture("malformed-iccp", [], makeChunk("iCCP", Buffer.from("profile\0\0x")));
writeFixture("malformed-itxt", [], makeChunk("iTXt", Buffer.from("key\0\1\0\0\0x")));
writeFixture("malformed-crc", [[idatIndex, Buffer.from(chunks[idatIndex].raw)]]);
const corruptCrc = fs.readFileSync(`${outputDirectory}/malformed-crc.png`);
corruptCrc[corruptCrc.length - 5] ^= 1;
fs.writeFileSync(`${outputDirectory}/malformed-crc.png`, corruptCrc);
fs.writeFileSync(`${outputDirectory}/malformed-truncation.png`, input.subarray(0, input.length - 3));

const compressed = chunks[idatIndex].data;
writeRaw("malformed-ordering", [
  chunks[ihdrIndex].raw,
  makeChunk("IDAT", compressed.subarray(0, Math.ceil(compressed.length / 2))),
  makeChunk("gAMA", Buffer.from([0, 0, 177, 143])),
  makeChunk("IDAT", compressed.subarray(Math.ceil(compressed.length / 2))),
  makeChunk("IEND", Buffer.alloc(0)),
]);

writeRaw("valid-grayscale", [imageHeader(1, 1, 8, 0), makeChunk("IDAT", zlib.deflateSync(Buffer.from([0, 127]))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("valid-rgb", [imageHeader(1, 1, 8, 2), makeChunk("IDAT", zlib.deflateSync(Buffer.from([0, 1, 2, 3]))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("valid-indexed", [imageHeader(1, 1, 8, 3), makeChunk("PLTE", Buffer.from([1, 2, 3])), makeChunk("IDAT", zlib.deflateSync(Buffer.from([0, 0]))), makeChunk("IEND", Buffer.alloc(0))]);

const formatMatrix = new Map([
  [0, [1, 2, 4, 8, 16]],
  [2, [8, 16]],
  [3, [1, 2, 4, 8]],
  [4, [8, 16]],
  [6, [8, 16]],
]);
const channelCounts = new Map([[0, 1], [2, 3], [3, 1], [4, 2], [6, 4]]);
for (const [colorType, depths] of formatMatrix) {
  for (const depth of depths) {
    const chunksForImage = [imageHeader(1, 1, depth, colorType)];
    if (colorType === 3) chunksForImage.push(makeChunk("PLTE", Buffer.from([12, 34, 56])));
    const rowBytes = Math.ceil((channelCounts.get(colorType) * depth) / 8);
    chunksForImage.push(makeChunk("IDAT", zlib.deflateSync(Buffer.alloc(rowBytes + 1))));
    chunksForImage.push(makeChunk("IEND", Buffer.alloc(0)));
    writeRaw(`valid-matrix-${colorType}-${depth}`, chunksForImage);
  }
}

writeRaw("valid-trns-gray", [imageHeader(1, 1, 8, 0), makeChunk("tRNS", Buffer.from([0, 0])), makeChunk("IDAT", zlib.deflateSync(Buffer.from([0, 0]))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("valid-trns-rgb", [imageHeader(1, 1, 8, 2), makeChunk("tRNS", Buffer.alloc(6)), makeChunk("IDAT", zlib.deflateSync(Buffer.alloc(4))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("valid-trns-indexed", [imageHeader(1, 1, 8, 3), makeChunk("PLTE", Buffer.from([1, 2, 3])), makeChunk("tRNS", Buffer.from([128])), makeChunk("IDAT", zlib.deflateSync(Buffer.from([0, 0]))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("valid-filter-four", [imageHeader(1, 1, 8, 6), makeChunk("IDAT", zlib.deflateSync(Buffer.from([4, 1, 2, 3, 4]))), makeChunk("IEND", Buffer.alloc(0))]);

function paeth(left, above, upperLeft) {
  const estimate = left + above - upperLeft;
  const distances = [Math.abs(estimate - left), Math.abs(estimate - above), Math.abs(estimate - upperLeft)];
  return distances[0] <= distances[1] && distances[0] <= distances[2] ? left : distances[1] <= distances[2] ? above : upperLeft;
}
function filteredRow(raw, above, filter, bytesPerPixel) {
  const encoded = Buffer.alloc(raw.length + 1);
  encoded[0] = filter;
  for (let index = 0; index < raw.length; index += 1) {
    const left = index >= bytesPerPixel ? raw[index - bytesPerPixel] : 0;
    const up = above?.[index] ?? 0;
    const upperLeft = above && index >= bytesPerPixel ? above[index - bytesPerPixel] : 0;
    const predictor = filter === 1 ? left : filter === 2 ? up : filter === 3 ? Math.floor((left + up) / 2) : filter === 4 ? paeth(left, up, upperLeft) : 0;
    encoded[index + 1] = (raw[index] - predictor) & 0xff;
  }
  return encoded;
}
const rawFilterRows = Array.from({ length: 5 }, (_, y) => Buffer.from([10 + y, 20 + y, 30 + y, 200 + y, 40 + y, 50 + y, 60 + y, 210 + y]));
const encodedFilterRows = rawFilterRows.map((row, index) => filteredRow(row, rawFilterRows[index - 1], index, 4));
writeRaw("valid-filter-matrix", [imageHeader(2, 5, 8, 6), makeChunk("IDAT", zlib.deflateSync(Buffer.concat(encodedFilterRows))), makeChunk("IEND", Buffer.alloc(0))]);

for (const [name, byteOffset, value] of [["compression", 10, 1], ["filter-method", 11, 1], ["interlace", 12, 1]]) {
  const header = imageHeaderData(1, 1, 8, 6);
  header[byteOffset] = value;
  writeRaw(`malformed-ihdr-${name}`, [makeChunk("IHDR", header), makeChunk("IDAT", zlib.deflateSync(Buffer.alloc(5))), makeChunk("IEND", Buffer.alloc(0))]);
}
writeRaw("malformed-ihdr-bit-depth", [imageHeader(1, 1, 4, 2), makeChunk("IDAT", zlib.deflateSync(Buffer.alloc(3))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("malformed-plte-missing", [imageHeader(1, 1, 8, 3), makeChunk("IDAT", zlib.deflateSync(Buffer.from([0, 0]))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("malformed-plte-grayscale", [imageHeader(1, 1, 8, 0), makeChunk("PLTE", Buffer.from([1, 2, 3])), makeChunk("IDAT", zlib.deflateSync(Buffer.from([0, 0]))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("malformed-plte-depth", [imageHeader(1, 1, 1, 3), makeChunk("PLTE", Buffer.alloc(9)), makeChunk("IDAT", zlib.deflateSync(Buffer.from([0, 0]))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("malformed-plte-empty", [imageHeader(1, 1, 8, 3), makeChunk("PLTE", Buffer.alloc(0)), makeChunk("IDAT", zlib.deflateSync(Buffer.from([0, 0]))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("malformed-trns-rgba", [imageHeader(1, 1, 8, 6), makeChunk("tRNS", Buffer.from([0])), makeChunk("IDAT", zlib.deflateSync(Buffer.alloc(5))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("malformed-trns-indexed-length", [imageHeader(1, 1, 8, 3), makeChunk("PLTE", Buffer.from([1, 2, 3])), makeChunk("tRNS", Buffer.from([1, 2])), makeChunk("IDAT", zlib.deflateSync(Buffer.from([0, 0]))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("malformed-trns-gray-range", [imageHeader(1, 1, 1, 0), makeChunk("tRNS", Buffer.from([0, 2])), makeChunk("IDAT", zlib.deflateSync(Buffer.from([0, 0]))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("malformed-trns-rgb-range", [imageHeader(1, 1, 8, 2), makeChunk("tRNS", Buffer.from([1, 0, 0, 0, 0, 0])), makeChunk("IDAT", zlib.deflateSync(Buffer.alloc(4))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("malformed-decoded-short", [imageHeader(1, 1, 8, 6), makeChunk("IDAT", zlib.deflateSync(Buffer.alloc(4))), makeChunk("IEND", Buffer.alloc(0))]);
writeRaw("malformed-decoded-long", [imageHeader(1, 1, 8, 6), makeChunk("IDAT", zlib.deflateSync(Buffer.alloc(6))), makeChunk("IEND", Buffer.alloc(0))]);

const decoded = zlib.inflateSync(chunks[idatIndex].data);
decoded[0] = 5;
writeFixture("malformed-filter", [[idatIndex, makeChunk("IDAT", zlib.deflateSync(decoded))]]);
NODE
for malformed in critical chunk zlib zlib-trailing compressed-metadata iccp itxt crc truncation ordering filter ihdr-compression ihdr-filter-method ihdr-interlace ihdr-bit-depth plte-missing plte-grayscale plte-depth plte-empty trns-rgba trns-indexed-length trns-gray-range trns-rgb-range decoded-short decoded-long; do
  expect_failure "malformed $malformed PNG" node "$VALIDATOR" --json "$TEST_ROOT/malformed-$malformed.png"
done

cp "$TEST_ROOT/good.png" "$TEST_ROOT/growing.png"
node --input-type=module - "$VALIDATOR" "$TEST_ROOT/growing.png" <<'NODE'
import fs from "node:fs";
const [validatorPath, imagePath] = process.argv.slice(2);
const { validatePng } = await import(`file://${validatorPath}`);
const originalRead = fs.readSync;
let changed = false;
fs.readSync = function (...args) {
  const count = originalRead.apply(this, args);
  if (!changed) {
    fs.appendFileSync(imagePath, Buffer.from([0]));
    changed = true;
  }
  return count;
};
try {
  validatePng(imagePath);
  throw new Error("growing source unexpectedly passed validation");
} catch (error) {
  if (!String(error.message).includes("changed while it was being read")) throw error;
} finally {
  fs.readSync = originalRead;
}
NODE
for format in grayscale rgb indexed; do
  node "$VALIDATOR" --json "$TEST_ROOT/valid-$format.png" >/dev/null || fail "representative $format PNG was rejected"
done
for color_type in 0 2 3 4 6; do
  case "$color_type" in
    0) depths='1 2 4 8 16' ;;
    2|4|6) depths='8 16' ;;
    3) depths='1 2 4 8' ;;
  esac
  for depth in $depths; do
    node "$VALIDATOR" --json "$TEST_ROOT/valid-matrix-$color_type-$depth.png" >/dev/null || fail "valid color type $color_type depth $depth PNG was rejected"
  done
done
for valid_boundary in trns-gray trns-rgb trns-indexed filter-four filter-matrix; do
  node "$VALIDATOR" --json "$TEST_ROOT/valid-$valid_boundary.png" >/dev/null || fail "valid $valid_boundary PNG was rejected"
done

node "$VALIDATOR" --assert-pixel 0,0,1,2,3,255 "$TEST_ROOT/valid-rgb.png" >/dev/null || fail "positive RGB pixel assertion failed"
node "$VALIDATOR" --json --assert-pixel 0,0,1,2,3,4 "$TEST_ROOT/valid-filter-four.png" >/dev/null || fail "positive filtered RGBA pixel assertion failed"
for filter_row in 0 1 2 3 4; do
  node "$VALIDATOR" --assert-pixel "1,$filter_row,$((40 + filter_row)),$((50 + filter_row)),$((60 + filter_row)),$((210 + filter_row))" "$TEST_ROOT/valid-filter-matrix.png" >/dev/null || fail "filter $filter_row pixel assertion failed"
done
node "$VALIDATOR" --assert-pixel 0,0,0,0,0,255 "$TEST_ROOT/valid-matrix-0-16.png" >/dev/null || fail "grayscale pixel assertion failed"
node "$VALIDATOR" --assert-pixel 0,0,0,0,0,255 "$TEST_ROOT/valid-matrix-2-16.png" >/dev/null || fail "RGB16 pixel assertion failed"
node "$VALIDATOR" --assert-pixel 0,0,12,34,56,255 "$TEST_ROOT/valid-matrix-3-4.png" >/dev/null || fail "indexed pixel assertion failed"
node "$VALIDATOR" --assert-pixel 0,0,0,0,0,0 "$TEST_ROOT/valid-matrix-4-16.png" >/dev/null || fail "grayscale-alpha pixel assertion failed"
node "$VALIDATOR" --assert-pixel 0,0,0,0,0,0 "$TEST_ROOT/valid-matrix-6-16.png" >/dev/null || fail "RGBA16 pixel assertion failed"
node "$VALIDATOR" --assert-pixel 0,0,1,2,3,128 "$TEST_ROOT/valid-trns-indexed.png" >/dev/null || fail "palette transparency pixel assertion failed"
expect_failure "pixel mismatch" node "$VALIDATOR" --assert-pixel 0,0,255,0,0,255 "$TEST_ROOT/valid-rgb.png"
expect_failure "pixel coordinate bounds" node "$VALIDATOR" --assert-pixel 1,0,0,0,0,255 "$TEST_ROOT/valid-rgb.png"
expect_failure "pixel argument syntax" node "$VALIDATOR" --assert-pixel 0,0,256,0,0,255 "$TEST_ROOT/valid-rgb.png"
expect_failure "pixel empty argument component" node "$VALIDATOR" --assert-pixel 0,0,,0,0,255 "$TEST_ROOT/valid-rgb.png"

limits_json="$(node "$VALIDATOR" --security-limits-json)"
max_list_files="$(printf '%s' "$limits_json" | json_field maxListFiles)"
max_png_bytes="$(printf '%s' "$limits_json" | json_field maxPngBytes)"
max_png_dimension="$(printf '%s' "$limits_json" | json_field maxPngDimension)"
[[ "$max_list_files" =~ ^[1-9][0-9]*$ ]] || fail "canonical security limits were invalid"

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
node - "$FAKE_POWERSHELL_LOG" "$limits_json" <<'NODE'
const fs = require("node:fs");
const [logPath, limitsText] = process.argv.slice(2);
const last = JSON.parse(fs.readFileSync(logPath, "utf8").trim().split(/\n/).at(-1));
const limits = JSON.parse(limitsText);
const expected = [limits.maxPngBytes, limits.maxPngDimension, limits.maxPngPixels].map(String);
if (JSON.stringify(last.limits) !== JSON.stringify(expected)) throw new Error(`PowerShell limits differ: ${JSON.stringify(last)}`);
NODE

before_fs_check="$(wc -l < "$FAKE_POWERSHELL_LOG")"
for unsafe_fs in 9p v9fs; do
  expect_failure "$unsafe_fs cache refusal" env BROWSER_WORKBENCH_BRIDGE_TEST_FS_TYPE="$unsafe_fs" "$BRIDGE" clipboard
done
[[ "$(wc -l < "$FAKE_POWERSHELL_LOG")" == "$before_fs_check" ]] || fail "unsafe cache filesystem check invoked PowerShell"

if [[ -d /mnt/c && "$(stat -f -c '%T' /mnt/c)" == v9fs ]]; then
  host_v9fs_cache="/mnt/c/.browser-workbench-v9fs-probe-${UID}-$$"
  [[ ! -e "$host_v9fs_cache" ]] || fail "host v9fs probe path unexpectedly exists"
  before_host_fs_check="$(wc -l < "$FAKE_POWERSHELL_LOG")"
  expect_failure "actual host v9fs cache refusal" env XDG_CACHE_HOME="$host_v9fs_cache" "$BRIDGE" clipboard
  [[ ! -e "$host_v9fs_cache" ]] || fail "v9fs refusal created a cache directory"
  [[ "$(wc -l < "$FAKE_POWERSHELL_LOG")" == "$before_host_fs_check" ]] || fail "host v9fs check invoked PowerShell"
  host_fs_doctor="$(env XDG_CACHE_HOME="$host_v9fs_cache" "$BRIDGE" doctor)"
  [[ "$host_fs_doctor" == *"unsafe filesystem v9fs"* ]] || fail "doctor did not identify the host's v9fs Windows mount"
fi

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

mkdir -p "$TEST_ROOT/enumeration-bin"
printf '#!/usr/bin/env bash\nexit "${FAKE_FIND_STATUS:-124}"\n' > "$TEST_ROOT/enumeration-bin/find"
chmod 700 -- "$TEST_ROOT/enumeration-bin/find"
expect_failure "list enumeration timeout status" env PATH="$TEST_ROOT/enumeration-bin:$PATH" FAKE_FIND_STATUS=124 "$BRIDGE" list
[[ "$(<"$TEST_ROOT/expected-failure.stderr")" == *"listing enumeration timed out"* ]] || fail "list timeout diagnostic was inaccurate"
expect_failure "list enumeration error status" env PATH="$TEST_ROOT/enumeration-bin:$PATH" FAKE_FIND_STATUS=23 "$BRIDGE" list
[[ "$(<"$TEST_ROOT/expected-failure.stderr")" == *"listing enumeration failed with status 23"* ]] || fail "list error diagnostic was inaccurate"
expect_failure "cleanup enumeration timeout status" env PATH="$TEST_ROOT/enumeration-bin:$PATH" FAKE_FIND_STATUS=124 "$BRIDGE" cleanup --all --dry-run
[[ "$(<"$TEST_ROOT/expected-failure.stderr")" == *"cleanup enumeration timed out"* ]] || fail "cleanup timeout diagnostic was inaccurate"
expect_failure "cleanup enumeration error status" env PATH="$TEST_ROOT/enumeration-bin:$PATH" FAKE_FIND_STATUS=23 "$BRIDGE" cleanup --all --dry-run
[[ "$(<"$TEST_ROOT/expected-failure.stderr")" == *"cleanup enumeration failed with status 23"* ]] || fail "cleanup error diagnostic was inaccurate"

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

mkdir -p "$TEST_ROOT/enumeration-cache/browser-workbench/windows-images"
chmod 700 "$TEST_ROOT/enumeration-cache/browser-workbench/windows-images"
for index in $(seq 1 $((max_list_files + 1))); do
  : > "$TEST_ROOT/enumeration-cache/browser-workbench/windows-images/windows-image-20260101T000000Z-cap${index}.png"
done
expect_failure "large cache enumeration" env XDG_CACHE_HOME="$TEST_ROOT/enumeration-cache" "$BRIDGE" list

concurrent_cache="$TEST_ROOT/concurrent-cache"
for index in 1 2 3 4; do
  env XDG_CACHE_HOME="$concurrent_cache" "$BRIDGE" clipboard >"$TEST_ROOT/concurrent-$index.json" &
done
wait
env XDG_CACHE_HOME="$concurrent_cache" "$BRIDGE" list >"$TEST_ROOT/concurrent-list.json" &
list_pid=$!
env XDG_CACHE_HOME="$concurrent_cache" "$BRIDGE" cleanup --all --dry-run >"$TEST_ROOT/concurrent-cleanup.json" &
cleanup_pid=$!
wait "$list_pid"
wait "$cleanup_pid"
concurrent_list="$(<"$TEST_ROOT/concurrent-list.json")"
printf '%s' "$concurrent_list" | assert_json_list 4
[[ "$(<"$TEST_ROOT/concurrent-cleanup.json")" == *'"removed":4'* ]] || fail "concurrent cleanup preview returned the wrong count"
for index in 1 2; do
  env XDG_CACHE_HOME="$concurrent_cache" "$BRIDGE" cleanup --all >"$TEST_ROOT/concurrent-mutating-cleanup-$index.json" &
done
wait
removed_first="$(json_field removed < "$TEST_ROOT/concurrent-mutating-cleanup-1.json")"
removed_second="$(json_field removed < "$TEST_ROOT/concurrent-mutating-cleanup-2.json")"
[[ $((removed_first + removed_second)) -eq 4 ]] || fail "concurrent cleanup removal counts did not match the files removed"
printf '%s' "$(env XDG_CACHE_HOME="$concurrent_cache" "$BRIDGE" list)" | assert_json_list 0

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

if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version && [[ "$REAL_POWERSHELL_AVAILABLE" -eq 1 ]] && [[ "${BROWSER_WORKBENCH_RUN_WINDOWS_INTEGRATION:-0}" == 1 ]]; then
  REAL_WINDOWS_DIR="/mnt/c/Users/Public/browser-workbench-bridge-test-$(date +%s)-$$"
  mkdir -p -- "$REAL_WINDOWS_DIR"
  real_windows_file="$REAL_WINDOWS_DIR/image with spaces;punctuation.png"
  real_windows_non_image="$REAL_WINDOWS_DIR/not-an-image.bin"
  real_windows_large="$REAL_WINDOWS_DIR/too-large.png"
  real_windows_wide="$REAL_WINDOWS_DIR/too-wide.png"
  REAL_WINDOWS_TARGET_DIR="$REAL_WINDOWS_DIR/junction-target"
  REAL_WINDOWS_JUNCTION="$REAL_WINDOWS_DIR/junction-source"
  mkdir -p -- "$REAL_WINDOWS_TARGET_DIR"
  real_windows_target_file="$REAL_WINDOWS_TARGET_DIR/image.png"
  REAL_WINDOWS_FILES+=("$real_windows_file" "$real_windows_non_image" "$real_windows_large" "$real_windows_wide" "$real_windows_target_file")
  node "$FIXTURE_GENERATOR" "$real_windows_file" 11 7
  node -e 'require("node:fs").writeFileSync(process.argv[1], "not an image")' "$real_windows_non_image"
  truncate -s $((max_png_bytes + 1)) "$real_windows_large"
  node "$FIXTURE_GENERATOR" "$real_windows_wide" $((max_png_dimension + 1)) 1
  cp -- "$real_windows_file" "$real_windows_target_file"
  real_windows_path="$(wslpath -w -- "$real_windows_file")"
  real_windows_non_image_path="$(wslpath -w -- "$real_windows_non_image")"
  real_windows_large_path="$(wslpath -w -- "$real_windows_large")"
  real_windows_wide_path="$(wslpath -w -- "$real_windows_wide")"
  real_windows_target_dir_path="$(wslpath -w -- "$REAL_WINDOWS_TARGET_DIR")"
  real_windows_junction_path="$(wslpath -w -- "$REAL_WINDOWS_JUNCTION")"
  "$REAL_POWERSHELL_EXECUTABLE" -NoLogo -NoProfile -NonInteractive -Command '& { param($junctionPath, $targetPath) $item = New-Item -ItemType Junction -Path $junctionPath -Target $targetPath -ErrorAction Stop; if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "junction capability unavailable" } }' "$real_windows_junction_path" "$real_windows_target_dir_path"
  [[ -d "$REAL_WINDOWS_JUNCTION" ]] || fail "Windows junction capability was not exposed to WSL"
  real_windows_junction_file_path="${real_windows_junction_path}\\image.png"
  (
    unset BROWSER_WORKBENCH_BRIDGE_TESTING BROWSER_WORKBENCH_BRIDGE_TEST_ROOT
    export PATH="$ORIGINAL_PATH"
    export XDG_CACHE_HOME="$TEST_ROOT/real-cache"
    timeout 30s "$BRIDGE" file "$real_windows_path" >/dev/null
    expect_failure "native missing source" "$BRIDGE" file "${real_windows_path%\\*}\\missing.png"
    expect_failure "native non-image source" "$BRIDGE" file "$real_windows_non_image_path"
    expect_failure "native source size limit" "$BRIDGE" file "$real_windows_large_path"
    expect_failure "native dimension limit" "$BRIDGE" file "$real_windows_wide_path"
    expect_failure "native junction source" "$BRIDGE" file "$real_windows_junction_file_path"
    expect_failure "native ADS syntax" powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File "$(wslpath -w -- "$SCRIPT_DIR/windows-image-bridge.ps1")" file "${real_windows_path}:stream" "$max_png_bytes" "$max_png_dimension" "$(printf '%s' "$limits_json" | json_field maxPngPixels)"
    expect_failure "native device syntax" powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File "$(wslpath -w -- "$SCRIPT_DIR/windows-image-bridge.ps1")" file "\\\\?\\$real_windows_path" "$max_png_bytes" "$max_png_dimension" "$(printf '%s' "$limits_json" | json_field maxPngPixels)"
  )
  printf 'Windows image bridge test: native PowerShell 5.1 file/security matrix passed\n'
else
  printf 'Windows image bridge test: real WSL file-mode integration skipped (set BROWSER_WORKBENCH_RUN_WINDOWS_INTEGRATION=1 to opt in)\n'
fi

printf 'Windows image bridge tests passed\n'
