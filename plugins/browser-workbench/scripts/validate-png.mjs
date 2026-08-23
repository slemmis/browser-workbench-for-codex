#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";

export const MAX_PNG_BYTES = 25 * 1024 * 1024;
export const MAX_PNG_DIMENSION = 20_000;
export const MAX_PNG_PIXELS = 25_000_000;
export const MAX_DECODED_BYTES = 128 * 1024 * 1024;

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

export function validatePng(filePath) {
  const absolutePath = path.resolve(filePath);
  let descriptor;
  try {
    descriptor = fs.openSync(absolutePath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  } catch {
    fail("file does not exist, is a symlink, or is not readable");
  }

  let stat;
  let bytes;
  try {
    stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) {
      fail("file is not a regular file");
    }
    if (stat.size > MAX_PNG_BYTES) {
      fail(`PNG exceeds the ${MAX_PNG_BYTES} byte limit`);
    }
    bytes = fs.readFileSync(descriptor);
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
  let idatEnded = false;
  const idatChunks = [];
  const knownCriticalChunks = new Set(["IHDR", "PLTE", "IDAT", "IEND"]);

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
    } else if (typeName === "IEND") {
      if (chunkLength !== 0 || sawIend) {
        fail("PNG contains an invalid IEND");
      }
      sawIend = true;
      if (chunkEnd !== bytes.length) {
        fail("PNG contains data after IEND");
      }
    } else if (sawIdat) {
      idatEnded = true;
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
  let decoded;
  try {
    decoded = zlib.inflateSync(Buffer.concat(idatChunks), { maxOutputLength: expectedDecodedBytes + 1 });
  } catch {
    fail("PNG contains an invalid or oversized image data stream");
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
  const json = argumentsList[0] === "--json";
  if (json) {
    argumentsList.shift();
  }
  if (argumentsList.length !== 1 || !argumentsList[0]) {
    throw new Error("usage: validate-png.mjs [--json] <png-path>");
  }
  const result = validatePng(argumentsList[0]);
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
