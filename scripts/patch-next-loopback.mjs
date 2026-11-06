import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const standaloneRoot = process.argv[2] ?? "apps/nextjs/.output/standalone";
const checkOnly = process.argv.includes("--check");

const EXPECTED_NEXT_VERSION = "16.4.2";
const TARGET_SUFFIX = join("dist", "server", "lib", "router-utils", "resolve-routes.js");

const ORIGINAL =
  "const initUrl = config.experimental.trustHostHeader ? `https://${req.headers.host || 'localhost'}${req.url}` : opts.port ? `${protocol}://${(0, _formathostname.formatHostname)(opts.hostname || 'localhost')}:${opts.port}${req.url}` : req.url || '';";

// The replacement keeps the Next.js PR #95917 behavior: normalize a loopback
// bind hostname to "localhost" before it is used to build initUrl.
const PATCHED =
  "const initUrl = config.experimental.trustHostHeader ? `https://${req.headers.host || 'localhost'}${req.url}` : opts.port ? `${protocol}://${(0, _formathostname.formatHostname)(/^(?:127(?:\\.(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){3}|\\[::1\\]|::1|localhost)$/i.test(opts.hostname || 'localhost') ? 'localhost' : (opts.hostname || 'localhost'))}:${opts.port}${req.url}` : req.url || '';";

function findResolveRoutes(root) {
  const results = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir)) {
      const full = join(dir, entry);
      const stats = statSync(full);
      if (stats.isDirectory()) walk(full);
      else if (full.endsWith(TARGET_SUFFIX)) results.push(full);
    }
  };
  walk(root);
  return results;
}

const files = findResolveRoutes(standaloneRoot);
if (files.length !== 1) {
  console.error(`Expected exactly one CJS resolve-routes.js under ${standaloneRoot}, found ${files.length}`);
  for (const file of files) console.error(` - ${file}`);
  process.exit(1);
}

const file = files[0];

const nextPackageJsonPath = join(file, "..", "..", "..", "..", "..", "package.json");
let nextPackage;
try {
  nextPackage = JSON.parse(readFileSync(nextPackageJsonPath, "utf8"));
} catch (error) {
  console.error(`Could not read Next.js package.json at ${nextPackageJsonPath}: ${error.message}`);
  process.exit(1);
}
if (nextPackage.name !== "next" || nextPackage.version !== EXPECTED_NEXT_VERSION) {
  console.error(
    `Unsupported Next.js version: expected next@${EXPECTED_NEXT_VERSION}, found ${nextPackage.name}@${nextPackage.version}`,
  );
  process.exit(1);
}

const source = readFileSync(file, "utf8");
const originalCount = source.split(ORIGINAL).length - 1;
const patchedCount = source.split(PATCHED).length - 1;

if (checkOnly) {
  if (patchedCount !== 1 || originalCount !== 0) {
    console.error(`Patch verification failed for ${file}: original=${originalCount}, patched=${patchedCount}`);
    process.exit(1);
  }
  console.log(`Patch verified: ${file}`);
  process.exit(0);
}

if (originalCount !== 1) {
  if (patchedCount === 1) {
    console.log(`Already patched: ${file}`);
    process.exit(0);
  }
  console.error(`Refusing to patch ${file}: expected 1 original snippet, found ${originalCount}; patched=${patchedCount}`);
  process.exit(1);
}

writeFileSync(file, source.replace(ORIGINAL, PATCHED), "utf8");
console.log(`Patched: ${file}`);
