#!/usr/bin/env node

import fs from "node:fs";

const args = process.argv.slice(2);
const fileArgumentIndex = args.indexOf("-File");
const mode = fileArgumentIndex >= 0 ? args[fileArgumentIndex + 2] : "";
const inputPath = fileArgumentIndex >= 0 ? args[fileArgumentIndex + 3] ?? "" : "";
const limits = fileArgumentIndex >= 0 ? args.slice(fileArgumentIndex + 4, fileArgumentIndex + 7) : [];
if (process.env.FAKE_POWERSHELL_LOG) {
  fs.appendFileSync(
    process.env.FAKE_POWERSHELL_LOG,
    `${JSON.stringify({ args, mode, input_path: inputPath, limits })}\n`,
    { mode: 0o600 },
  );
}

const behavior = process.env.FAKE_POWERSHELL_BEHAVIOR ?? "success";
if (behavior === "timeout") {
  setTimeout(() => {}, 60_000);
} else if (behavior === "text") {
  process.stderr.write("clipboard does not contain an image\n");
  process.exitCode = 1;
} else if (behavior === "malformed") {
  process.stdout.write("not-an-image\n");
} else if (behavior === "truncated") {
  const data = fs.readFileSync(process.env.FAKE_POWERSHELL_FIXTURE);
  process.stdout.write(`${data.subarray(0, Math.max(1, Math.floor(data.length / 2))).toString("base64")}\n`);
} else if (behavior === "non-png") {
  process.stdout.write(`${Buffer.from("not a PNG").toString("base64")}\n`);
} else {
  const data = fs.readFileSync(process.env.FAKE_POWERSHELL_FIXTURE);
  process.stdout.write(`${data.toString("base64")}\n`);
}
