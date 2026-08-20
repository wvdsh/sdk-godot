#!/usr/bin/env node
// Orchestrator: index.d.ts  ->  IR (_ir.json)  ->  WavedashTypes.gd
//
// Usage:
//   node generate.mjs [--input <index.d.ts>] [--gd-out <file.gd>]
//                     [--ir-out <file.json>]
//
// The generated GDScript is written INTO the addon (addons/wavedash/generated)
// so it ships with the Asset Library download. The IR is a debug artifact and
// stays under codegen/ (which .gitattributes export-ignores from the download).
// --input defaults to the @wvdsh/sdk-js declarations installed from npm.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parse } from "./parse.mjs";
import { emit } from "./gdscript.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));

function arg(flag, fallback) {
  const i = process.argv.indexOf(flag);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

// Input is the published JS SDK's declarations, pulled in by `npm install`.
const DEFAULT_INPUT = "node_modules/@wvdsh/sdk-js/dist/index.d.ts";
// Escape hatch for generating against an sdk-js change that has not shipped yet:
// drop its `dist/index.d.ts` here and it wins over the installed package, which
// `npm run generate` would otherwise reinstall over on every run. Delete the file
// once the change is published — while it exists the output does NOT correspond to
// any version a consumer can install.
const VENDORED_INPUT = "vendor/sdk-js.d.ts";
const vendored = path.join(here, VENDORED_INPUT);
const defaultInput = fs.existsSync(vendored) ? vendored : path.join(here, DEFAULT_INPUT);
const input = path.resolve(arg("--input", defaultInput));
if (input === path.resolve(vendored)) {
  console.warn(`[codegen] using unpublished ${VENDORED_INPUT}, not the installed package`);
}
// Ships with the addon (included in the Asset Library archive via addons/**).
const GENERATED_DIR = "../addons/wavedash/generated";
const gdPath = path.resolve(arg("--gd-out", path.join(here, GENERATED_DIR, "WavedashTypes.gd")));
// Debug artifact only — stays in codegen/ (export-ignored from the archive).
const irPath = path.resolve(arg("--ir-out", path.join(here, "generated/_ir.json")));

if (!fs.existsSync(input)) {
  console.error(`[codegen] input not found: ${path.relative(here, input)}`);
  console.error(`[codegen] run \`npm install\` in codegen/ first, or pass --input <index.d.ts>`);
  process.exit(1);
}

console.log(`[codegen] parsing ${path.relative(here, input)}`);
const ir = parse(input);
// Store a stable, repo-relative source so the IR does not vary by checkout path
// (absolute paths vary per machine/worktree and cause spurious diffs).
ir.source = path.relative(here, input);
console.log(
  `[codegen]   ${ir.models.length} models, ${ir.aliases.length} aliases ` +
    `(${ir.aliases.filter((a) => a.kind === "unresolved").length} unresolved), ` +
    `${ir.methods.length} methods, ` +
    `${ir.tables.length} lookup tables ` +
    `(${ir.tables.map((t) => `${t.name}: ${t.entries.length}`).join(", ")})`
);

// Stage 1 output — you can read the IR the emitter works from.
fs.mkdirSync(path.dirname(irPath), { recursive: true });
fs.writeFileSync(irPath, JSON.stringify(ir, null, 2) + "\n");
console.log(`[codegen] wrote ${path.relative(here, irPath)}`);

// Stage 2+3 output — the GDScript, written into the addon.
const { types } = emit(ir);
fs.mkdirSync(path.dirname(gdPath), { recursive: true });
fs.writeFileSync(gdPath, types);
console.log(`[codegen] wrote ${path.relative(here, gdPath)}`);

// A small report on the Convex-derived aliases the syntactic pass can't see.
// `kind: "unresolved"` records what pass 1a found; what matters to the output is
// whether pass 1b then expanded it, so report against that, not against the flag.
const external = ir.aliases.filter((a) => a.kind === "unresolved").map((a) => a.name);
if (external.length) {
  const byName = new Map((ir.resolved ?? []).map((r) => [r.name, r]));
  const expanded = external.filter((n) => byName.get(n)?.fields.length);
  const stillOpaque = external.filter((n) => !byName.get(n)?.fields.length);
  console.log(
    `[codegen] Convex-derived types expanded by the checker: ${expanded.length}/${external.length}`
  );
  if (stillOpaque.length) {
    console.log(
      `[codegen]   still Variant/Dictionary: ${stillOpaque.join(", ")}` +
        `\n[codegen]   (is @wvdsh/api installed? without it these cannot resolve)`
    );
  }
}
