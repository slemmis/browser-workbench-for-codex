#!/usr/bin/env node

import fs from "node:fs";
import zlib from "node:zlib";

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

function chunk(type, data) {
  const typeBytes = Buffer.from(type, "ascii");
  const result = Buffer.alloc(12 + data.length);
  result.writeUInt32BE(data.length, 0);
  typeBytes.copy(result, 4);
  data.copy(result, 8);
  result.writeUInt32BE(crc32(Buffer.concat([typeBytes, data])), 8 + data.length);
  return result;
}

const [outputPath, widthText = "8", heightText = "6"] = process.argv.slice(2);
const width = Number(widthText);
const height = Number(heightText);
if (!outputPath || !Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 1 || height < 1) {
  throw new Error("usage: generate-png.mjs <output-path> [width] [height]");
}

const scanlines = Buffer.alloc(height * (1 + width * 4));
for (let y = 0; y < height; y += 1) {
  const row = y * (1 + width * 4);
  scanlines[row] = 0;
  for (let x = 0; x < width; x += 1) {
    const pixel = row + 1 + x * 4;
    scanlines[pixel] = (x * 31 + y * 17) & 0xff;
    scanlines[pixel + 1] = (y * 47 + 19) & 0xff;
    scanlines[pixel + 2] = 0xa5;
    scanlines[pixel + 3] = 0xff;
  }
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(width, 0);
ihdr.writeUInt32BE(height, 4);
ihdr[8] = 8;
ihdr[9] = 6;
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk("IHDR", ihdr),
  chunk("IDAT", zlib.deflateSync(scanlines)),
  chunk("IEND", Buffer.alloc(0)),
]);
fs.writeFileSync(outputPath, png, { mode: 0o600 });
