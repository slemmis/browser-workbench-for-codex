import fs from 'node:fs';
import path from 'node:path';

const [lockPath, runtimeDir, mcpVersion, playwrightVersion] = process.argv.slice(2);
if (!lockPath || !runtimeDir || !mcpVersion || !playwrightVersion) process.exit(2);

const fail = () => process.exit(1);
const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const canonical = value => {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  return value;
};
const sameRecord = (actual, expected) => JSON.stringify(canonical(actual || {})) === JSON.stringify(canonical(expected));

let lock;
try { lock = readJson(lockPath); } catch { fail(); }
const packages = lock.packages || {};
const expectedKeys = [
  '',
  'node_modules/@playwright/mcp',
  'node_modules/fsevents',
  'node_modules/playwright',
  'node_modules/playwright-core',
];
if (JSON.stringify(Object.keys(packages).sort()) !== JSON.stringify(expectedKeys.sort())) fail();

const expectedLock = {
  'node_modules/@playwright/mcp': {
    version: mcpVersion,
    resolved: 'https://registry.npmjs.org/@playwright/mcp/-/mcp-0.0.79.tgz',
    integrity: 'sha512-VpqD4a3vFyGQMY9sh3UJiO6wjcurggkljKfAyCHL0QWGY5m6Ehr3MNsAAHPDHO//n13g0PCjpHatAOiulrqdZQ==',
    dependencies: { playwright: playwrightVersion, 'playwright-core': playwrightVersion },
  },
  'node_modules/fsevents': {
    version: '2.3.2',
    resolved: 'https://registry.npmjs.org/fsevents/-/fsevents-2.3.2.tgz',
    integrity: 'sha512-xiqMQR4xAeHTuB9uWm+fFRcIOgKBMiOBP+eXiyT7jsgVCq1bkVygt00oASowB7EdtpOHaaPgKt812P9ab+DDKA==',
    dependencies: {},
  },
  'node_modules/playwright': {
    version: playwrightVersion,
    resolved: 'https://registry.npmjs.org/playwright/-/playwright-1.63.0-alpha-2026-08-05.tgz',
    integrity: 'sha512-zbGZUK+JYkoDV3cUgfvh2czTBJL34Gmz5gHVI25xiIpvYSR17Q1M7TS8hnwECUe+IkKaeXbKrSyJTyogm2DVWw==',
    dependencies: { 'playwright-core': playwrightVersion },
    optionalDependencies: { fsevents: '2.3.2' },
  },
  'node_modules/playwright-core': {
    version: playwrightVersion,
    resolved: 'https://registry.npmjs.org/playwright-core/-/playwright-core-1.63.0-alpha-2026-08-05.tgz',
    integrity: 'sha512-YussvUybTfBtyYbGXWh43f+5kNP03wg98M6mu4DphYET7PSbNVajsdLGjWE1xrsjqOw32i2wFlRP7U5mcOpMZg==',
    dependencies: {},
  },
};

if (!sameRecord(packages[''].dependencies, { '@playwright/mcp': mcpVersion })) fail();
for (const [key, expected] of Object.entries(expectedLock)) {
  const actual = packages[key] || {};
  for (const field of ['version', 'resolved', 'integrity']) if (actual[field] !== expected[field]) fail();
  if (!sameRecord(actual.dependencies, expected.dependencies)) fail();
  if (expected.optionalDependencies && !sameRecord(actual.optionalDependencies, expected.optionalDependencies)) fail();
}
if (packages['node_modules/fsevents'].optional !== true || !sameRecord(packages['node_modules/fsevents'].os, ['darwin'])) fail();

const installed = new Map();
let visitedPackageEntries = 0;
const scanNodeModules = (nodeModulesDir, relativePrefix = 'node_modules', depth = 0) => {
  if (depth > 4) fail();
  if (!fs.existsSync(nodeModulesDir)) fail();
  for (const entry of fs.readdirSync(nodeModulesDir)) {
    if (entry === '.bin' || entry === '.package-lock.json') continue;
    const entryPath = path.join(nodeModulesDir, entry);
    const stat = fs.lstatSync(entryPath);
    if (stat.isSymbolicLink()) fail();
    if (!stat.isDirectory()) fail();
    if (entry.startsWith('@')) {
      for (const scopedEntry of fs.readdirSync(entryPath)) {
        const packagePath = path.join(entryPath, scopedEntry);
        collectPackage(packagePath, `${relativePrefix}/${entry}/${scopedEntry}`);
      }
    } else {
      collectPackage(entryPath, `${relativePrefix}/${entry}`);
    }
  }
};
const collectPackage = (packageDir, key) => {
  if (++visitedPackageEntries > 16) fail();
  const dirStat = fs.lstatSync(packageDir);
  if (dirStat.isSymbolicLink() || !dirStat.isDirectory()) fail();
  const metadataPath = path.join(packageDir, 'package.json');
  const metadataStat = fs.lstatSync(metadataPath);
  if (metadataStat.isSymbolicLink() || !metadataStat.isFile()) fail();
  installed.set(key, readJson(metadataPath));
  const nested = path.join(packageDir, 'node_modules');
  if (fs.existsSync(nested)) scanNodeModules(nested, `${key}/node_modules`, key.split('/node_modules/').length);
};

try { scanNodeModules(path.join(runtimeDir, 'node_modules')); } catch { fail(); }
const requiredInstalled = [
  'node_modules/@playwright/mcp',
  'node_modules/playwright',
  'node_modules/playwright-core',
];
if (JSON.stringify([...installed.keys()].sort()) !== JSON.stringify(requiredInstalled.sort())) fail();

const expectedInstalled = {
  'node_modules/@playwright/mcp': { name: '@playwright/mcp', version: mcpVersion, dependencies: { playwright: playwrightVersion, 'playwright-core': playwrightVersion }, optionalDependencies: {} },
  'node_modules/playwright': { name: 'playwright', version: playwrightVersion, dependencies: { 'playwright-core': playwrightVersion }, optionalDependencies: { fsevents: '2.3.2' } },
  'node_modules/playwright-core': { name: 'playwright-core', version: playwrightVersion, dependencies: {}, optionalDependencies: {} },
};
for (const [key, expected] of Object.entries(expectedInstalled)) {
  const actual = installed.get(key);
  if (!actual || actual.name !== expected.name || actual.version !== expected.version) fail();
  if (!sameRecord(actual.dependencies, expected.dependencies)) fail();
  if (!sameRecord(actual.optionalDependencies, expected.optionalDependencies)) fail();
}

const cliPath = path.join(runtimeDir, 'node_modules/@playwright/mcp/cli.js');
let cliStat;
try { cliStat = fs.lstatSync(cliPath); } catch { fail(); }
if (cliStat.isSymbolicLink() || !cliStat.isFile()) fail();
