#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";

export const MAX_PNG_BYTES = 25 * 1024 * 1024;
export const MAX_PNG_DIMENSION = 20_000;
export const MAX_PNG_PIXELS = 25_000_000;
export const MAX_DECODED_BYTES = 128 * 1024 * 1024;
export const MAX_LIST_FILES = 256;
export const MAX_LIST_SECONDS = 10;

export const SECURITY_LIMITS = Object.freeze({
  maxPngBytes: MAX_PNG_BYTES,
  maxPngDimension: MAX_PNG_DIMENSION,
  maxPngPixels: MAX_PNG_PIXELS,
  maxDecodedBytes: MAX_DECODED_BYTES,
  maxListFiles: MAX_LIST_FILES,
  maxListSeconds: MAX_LIST_SECONDS,
});

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const CRC_TABLE = new Uint32Array(256);

for (let index = 0; index < CRC_TABLE.length; index += 1) {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) {
    value = (value & 1) === 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  }
  CRC_TABLE[index] = value >>> 0;
}

function crc32(type, data) {
  let crc = 0xffffffff;
  for (const byte of type) {
    crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }
  for (const byte of data) {
    crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function fail(message) {
  throw new Error(message);
}

function paethPredictor(left, above, upperLeft) {
  const estimate = left + above - upperLeft;
  const leftDistance = Math.abs(estimate - left);
  const aboveDistance = Math.abs(estimate - above);
  const upperLeftDistance = Math.abs(estimate - upperLeft);
  if (leftDistance <= aboveDistance && leftDistance <= upperLeftDistance) return left;
  if (aboveDistance <= upperLeftDistance) return above;
  return upperLeft;
}

function unfilterRows(decoded, rowBytes, height, bytesPerPixel) {
  const rows = [];
  for (let rowIndex = 0; rowIndex < height; rowIndex += 1) {
    const inputOffset = rowIndex * (rowBytes + 1);
    const filter = decoded[inputOffset];
    const source = decoded.subarray(inputOffset + 1, inputOffset + 1 + rowBytes);
    const row = Buffer.allocUnsafe(rowBytes);
    const above = rows[rowIndex - 1];
    for (let index = 0; index < rowBytes; index += 1) {
      const left = index >= bytesPerPixel ? row[index - bytesPerPixel] : 0;
      const up = above ? above[index] : 0;
      const upperLeft = above && index >= bytesPerPixel ? above[index - bytesPerPixel] : 0;
      let predictor = 0;
      if (filter === 1) predictor = left;
      else if (filter === 2) predictor = up;
      else if (filter === 3) predictor = Math.floor((left + up) / 2);
      else if (filter === 4) predictor = paethPredictor(left, up, upperLeft);
      row[index] = (source[index] + predictor) & 0xff;
    }
    rows.push(row);
  }
  return rows;
}

function readSample(row, sampleIndex, bitDepth) {
  if (bitDepth === 8) return row[sampleIndex];
  if (bitDepth === 16) return row.readUInt16BE(sampleIndex * 2);
  const bitOffset = sampleIndex * bitDepth;
  const shift = 8 - bitDepth - (bitOffset % 8);
  return (row[Math.floor(bitOffset / 8)] >>> shift) & (2 ** bitDepth - 1);
}

function scaleSample(sample, bitDepth) {
  return bitDepth === 8 ? sample : bitDepth === 16 ? Math.round(sample / 257) : Math.round((sample * 255) / (2 ** bitDepth - 1));
}

function pixelRgba(rows, x, y, bitDepth, colorType, palette, transparency) {
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[colorType];
  const first = x * channels;
  const samples = Array.from({ length: channels }, (_, index) => readSample(rows[y], first + index, bitDepth));
  if (colorType === 0) {
    const gray = scaleSample(samples[0], bitDepth);
    const transparent = transparency && samples[0] === transparency.readUInt16BE(0);
    return [gray, gray, gray, transparent ? 0 : 255];
  }
  if (colorType === 2) {
    const transparent = transparency && samples.every((sample, index) => sample === transparency.readUInt16BE(index * 2));
    return [...samples.map((sample) => scaleSample(sample, bitDepth)), transparent ? 0 : 255];
  }
  if (colorType === 3) {
    const paletteOffset = samples[0] * 3;
    return [palette[paletteOffset], palette[paletteOffset + 1], palette[paletteOffset + 2], transparency?.[samples[0]] ?? 255];
  }
  if (colorType === 4) {
    const gray = scaleSample(samples[0], bitDepth);
    return [gray, gray, gray, scaleSample(samples[1], bitDepth)];
  }
  return samples.map((sample) => scaleSample(sample, bitDepth));
}

export function validatePng(filePath, pixelAssertion = null) {
  const absolutePath = path.resolve(filePath);
  let descriptor;
  try {
    descriptor = fs.openSync(absolutePath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  } catch {
    fail("file does not exist, is a symlink, or is not readable");
  }

  let initialStat;
  let bytes;
  try {
    initialStat = fs.fstatSync(descriptor);
    if (!initialStat.isFile()) {
      fail("file is not a regular file");
    }
    if (initialStat.size > MAX_PNG_BYTES) {
      fail(`PNG exceeds the ${MAX_PNG_BYTES} byte limit`);
    }
    const parts = [];
    let total = 0;
    while (total <= MAX_PNG_BYTES) {
      const part = Buffer.allocUnsafe(Math.min(64 * 1024, MAX_PNG_BYTES + 1 - total));
      const count = fs.readSync(descriptor, part, 0, part.length, null);
      if (count === 0) break;
      parts.push(part.subarray(0, count));
      total += count;
    }
    if (total > MAX_PNG_BYTES) {
      fail(`PNG exceeds the ${MAX_PNG_BYTES} byte limit`);
    }
    const finalStat = fs.fstatSync(descriptor);
    if (
      initialStat.dev !== finalStat.dev ||
      initialStat.ino !== finalStat.ino ||
      initialStat.size !== finalStat.size ||
      finalStat.size !== total
    ) {
      fail("PNG changed while it was being read");
    }
    bytes = Buffer.concat(parts, total);
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("PNG ")) {
      throw error;
    }
    fail("file could not be read");
  } finally {
    fs.closeSync(descriptor);
  }
  if (bytes.length < PNG_SIGNATURE.length || !bytes.subarray(0, 8).equals(PNG_SIGNATURE)) {
    fail("file is not a PNG");
  }

  let offset = 8;
  let width;
  let height;
  let bitDepth;
  let colorType;
  let interlaceMethod;
  let sawIdat = false;
  let sawIend = false;
  let chunkCount = 0;
  let sawPlte = false;
  let palette;
  let transparency;
  let idatEnded = false;
  const idatChunks = [];
  const knownCriticalChunks = new Set(["IHDR", "PLTE", "IDAT", "IEND"]);
  // System.Drawing emits only image data plus a small set of uncompressed
  // color/physical metadata chunks. Reject textual profiles and other
  // ancillary payloads rather than giving them a second decompression path.
  const allowedAncillaryChunks = new Set(["cHRM", "gAMA", "sRGB", "pHYs", "tRNS"]);
  const seenAncillaryChunks = new Set();

  while (offset < bytes.length) {
    if (bytes.length - offset < 12) {
      fail("PNG is truncated at a chunk header");
    }
    const chunkLength = bytes.readUInt32BE(offset);
    const type = bytes.subarray(offset + 4, offset + 8);
    if (!/^[A-Za-z]{4}$/.test(type.toString("ascii"))) {
      fail("PNG contains an invalid chunk type");
    }
    if (!type.every((byte) => (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a))) {
      fail("PNG contains an invalid chunk type");
    }
    const chunkEnd = offset + 12 + chunkLength;
    if (!Number.isSafeInteger(chunkEnd) || chunkEnd > bytes.length) {
      fail("PNG is truncated at a chunk payload");
    }
    const data = bytes.subarray(offset + 8, offset + 8 + chunkLength);
    const expectedCrc = bytes.readUInt32BE(offset + 8 + chunkLength);
    if (crc32(type, data) !== expectedCrc) {
      fail("PNG contains an invalid chunk checksum");
    }

    const typeName = type.toString("ascii");
    const isCritical = type[0] >= 0x41 && type[0] <= 0x5a;
    if (isCritical && !knownCriticalChunks.has(typeName)) {
      fail(`PNG contains an unknown critical chunk ${typeName}`);
    }
    if (!isCritical && !allowedAncillaryChunks.has(typeName)) {
      fail(`PNG contains unsupported ancillary chunk ${typeName}`);
    }
    if (type[2] >= 0x61 && type[2] <= 0x7a) {
      // The third chunk-name bit is reserved by the PNG specification and
      // must be uppercase for a valid chunk name.
      fail("PNG contains a chunk with a reserved name bit");
    }
    chunkCount += 1;
    if (chunkCount === 1 && typeName !== "IHDR") {
      fail("PNG does not start with IHDR");
    }
    if (typeName === "IHDR") {
      if (chunkLength !== 13 || width !== undefined) {
        fail("PNG contains an invalid IHDR");
      }
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      if (width < 1 || height < 1 || width > MAX_PNG_DIMENSION || height > MAX_PNG_DIMENSION) {
        fail(`PNG dimensions exceed ${MAX_PNG_DIMENSION}x${MAX_PNG_DIMENSION}`);
      }
      if (width * height > MAX_PNG_PIXELS) {
        fail(`PNG exceeds the ${MAX_PNG_PIXELS} pixel limit`);
      }
      bitDepth = data[8];
      colorType = data[9];
      const compressionMethod = data[10];
      const filterMethod = data[11];
      interlaceMethod = data[12];
      const validBitDepths = {
        0: [1, 2, 4, 8, 16],
        2: [8, 16],
        3: [1, 2, 4, 8],
        4: [8, 16],
        6: [8, 16],
      };
      if (!(colorType in validBitDepths) || !validBitDepths[colorType].includes(bitDepth)) {
        fail("PNG contains an invalid bit depth or color type");
      }
      if (compressionMethod !== 0 || filterMethod !== 0 || interlaceMethod !== 0) {
        fail("PNG contains unsupported IHDR methods");
      }
    } else if (typeName === "IDAT") {
      if (idatEnded) {
        fail("PNG contains non-consecutive IDAT chunks");
      }
      if (colorType === 3 && !sawPlte) {
        fail("indexed PNG is missing its palette before IDAT");
      }
      sawIdat = true;
      idatChunks.push(data);
    } else if (typeName === "PLTE") {
      if (sawPlte || sawIdat || chunkLength === 0 || chunkLength > 768 || chunkLength % 3 !== 0) {
        fail("PNG contains an invalid palette");
      }
      if ([0, 4].includes(colorType)) {
        fail("grayscale PNG must not contain a palette");
      }
      if (colorType === 3 && chunkLength / 3 > 2 ** bitDepth) {
        fail("indexed PNG palette exceeds its bit depth");
      }
      sawPlte = true;
      palette = data;
    } else if (typeName === "IEND") {
      if (chunkLength !== 0 || sawIend) {
        fail("PNG contains an invalid IEND");
      }
      sawIend = true;
      if (chunkEnd !== bytes.length) {
        fail("PNG contains data after IEND");
      }
    } else {
      if (seenAncillaryChunks.has(typeName)) {
        fail(`PNG contains duplicate ${typeName}`);
      }
      seenAncillaryChunks.add(typeName);
      if (sawIdat) {
        fail(`PNG contains ${typeName} after image data`);
      }
      if (typeName === "cHRM" && chunkLength !== 32) {
        fail("PNG contains an invalid cHRM chunk");
      }
      if (typeName === "gAMA" && (chunkLength !== 4 || data.readUInt32BE(0) === 0)) {
        fail("PNG contains an invalid gAMA chunk");
      }
      if (typeName === "sRGB" && (chunkLength !== 1 || data[0] > 3)) {
        fail("PNG contains an invalid sRGB chunk");
      }
      if (typeName === "pHYs" && (chunkLength !== 9 || data[8] > 1)) {
        fail("PNG contains an invalid pHYs chunk");
      }
      if (typeName === "tRNS") {
        if (sawIdat || ![0, 2, 3].includes(colorType)) {
          fail("PNG contains an invalid tRNS chunk");
        }
        const validLength = colorType === 0 ? chunkLength === 2 : colorType === 2 ? chunkLength === 6 : sawPlte && chunkLength >= 1 && chunkLength <= palette.length / 3;
        if (!validLength) fail("PNG contains an invalid tRNS chunk");
        if (colorType === 0 && data.readUInt16BE(0) >= 2 ** bitDepth) {
          fail("PNG grayscale transparency exceeds its bit depth");
        }
        if (colorType === 2 && bitDepth === 8 && [0, 2, 4].some((offset) => data.readUInt16BE(offset) > 255)) {
          fail("PNG RGB transparency exceeds its bit depth");
        }
        transparency = data;
      }
    }

    offset = chunkEnd;
    if (sawIend) {
      break;
    }
  }

  if (width === undefined || height === undefined || !sawIdat || !sawIend || offset !== bytes.length) {
    fail("PNG is incomplete");
  }

  if (colorType === 3 && !sawPlte) {
    fail("indexed PNG is missing its palette");
  }

  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[colorType];
  const rowBytes = Math.ceil((width * channels * bitDepth) / 8);
  const expectedDecodedBytes = (rowBytes + 1) * height;
  if (!Number.isSafeInteger(expectedDecodedBytes) || expectedDecodedBytes > MAX_DECODED_BYTES) {
    fail(`decoded PNG exceeds the ${MAX_DECODED_BYTES} byte limit`);
  }
  let inflateResult;
  const compressed = Buffer.concat(idatChunks);
  try {
    inflateResult = zlib.inflateSync(compressed, { info: true, maxOutputLength: expectedDecodedBytes + 1 });
  } catch {
    fail("PNG contains an invalid or oversized image data stream");
  }
  const decoded = inflateResult.buffer;
  if (inflateResult.engine.bytesWritten !== compressed.length) {
    fail("PNG image data contains bytes after the zlib stream");
  }
  if (decoded.length !== expectedDecodedBytes) {
    fail("PNG image data has an unexpected decoded length");
  }
  for (let row = 0; row < height; row += 1) {
    const filter = decoded[row * (rowBytes + 1)];
    if (filter > 4) {
      fail("PNG contains an invalid scanline filter");
    }
  }

  if (pixelAssertion) {
    const { x, y, rgba } = pixelAssertion;
    if (x >= width || y >= height) fail(`pixel coordinate ${x},${y} is outside the ${width}x${height} PNG`);
    const bytesPerPixel = Math.max(1, Math.ceil((channels * bitDepth) / 8));
    const rows = unfilterRows(decoded, rowBytes, height, bytesPerPixel);
    const actual = pixelRgba(rows, x, y, bitDepth, colorType, palette, transparency);
    if (!actual.every((value, index) => value === rgba[index])) {
      fail(`pixel ${x},${y} is rgba(${actual.join(",")}), expected rgba(${rgba.join(",")})`);
    }
  }

  return {
    path: absolutePath,
    mime: "image/png",
    width,
    height,
    bytes: bytes.length,
  };
}

function main() {
  const argumentsList = process.argv.slice(2);
  if (argumentsList.length === 1 && argumentsList[0] === "--security-limits-json") {
    process.stdout.write(`${JSON.stringify(SECURITY_LIMITS)}\n`);
    return;
  }
  if (argumentsList.length === 1 && argumentsList[0] === "--security-limits-tsv") {
    process.stdout.write(`${Object.values(SECURITY_LIMITS).join("\t")}\n`);
    return;
  }
  let json = false;
  let pixelAssertion = null;
  while (argumentsList[0]?.startsWith("--")) {
    const option = argumentsList.shift();
    if (option === "--json") {
      json = true;
    } else if (option === "--assert-pixel") {
      if (pixelAssertion) throw new Error("--assert-pixel may be specified only once");
      const specification = argumentsList.shift() ?? "";
      const match = /^(0|[1-9][0-9]*),(0|[1-9][0-9]*),(0|[1-9][0-9]*),(0|[1-9][0-9]*),(0|[1-9][0-9]*),(0|[1-9][0-9]*)$/.exec(specification);
      const values = match?.slice(1).map(Number) ?? [];
      if (values.length !== 6 || !values.every(Number.isSafeInteger) || values.slice(2).some((value) => value > 255)) {
        throw new Error("--assert-pixel requires x,y,r,g,b,a with nonnegative integer coordinates and byte RGBA values");
      }
      pixelAssertion = { x: values[0], y: values[1], rgba: values.slice(2) };
    } else {
      throw new Error(`unknown option ${option}`);
    }
  }
  if (argumentsList.length !== 1 || !argumentsList[0]) {
    throw new Error("usage: validate-png.mjs [--json] [--assert-pixel x,y,r,g,b,a] <png-path>");
  }
  const result = validatePng(argumentsList[0], pixelAssertion);
  process.stdout.write(json ? `${JSON.stringify(result)}\n` : `${result.path}\n`);
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    const message = error instanceof Error ? error.message : "PNG validation failed";
    process.stderr.write(`browser-workbench PNG validator: ${message}\n`);
    process.exitCode = 1;
  }
}
