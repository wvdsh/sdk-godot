// Stage 2 + 3: mapType() turns a TS type into a GDScript type; emit() renders
// the IR into WavedashTypes.gd. Godot 4.0 is the floor, so no typed
// Dictionary[K,V] (4.4+). See codegen/README.md for the pipeline.

import fs from "node:fs";

const OVERRIDES = JSON.parse(
  fs.readFileSync(new URL("./overrides.json", import.meta.url), "utf8")
);

// Why this is a total map and not a list of exceptions: overrides.json's $comment.
const NUMBER_KINDS = new Map(Object.entries(OVERRIDES.number ?? {}));

// mapType() renders every `number` as float; classifyNumber() narrows the ones
// overrides.json marks int.
const NUMERIC_FORMS = new Map([
  ["float", { gd: "int", init: "0" }],
  ["Array[float]", { gd: "Array[int]", init: "[]" }],
]);

// The GDScript primitives an array payload's element can be, and the test one must pass
// before it is appended: JSON hands back an untyped Array, and a wrong-typed element is
// a hard error against a typed one. int()/float()/String()/bool() are NOT total — String()
// rejects a float, int() rejects an Array — so an element is tested rather than converted.
const SCALARS = new Map([
  ["String", "item is String"],
  ["int", "item is int or item is float"],
  ["float", "item is int or item is float"],
  ["bool", "item is bool"],
]);

const unclassifiedNumbers = new Map();
const usedNumberKeys = new Set();
const miscastNumberKeys = new Set();

function classifyNumber(key, mapped) {
  const intForm = NUMERIC_FORMS.get(mapped.gd);
  if (!intForm) {
    if (NUMBER_KINDS.has(key)) miscastNumberKeys.add(key);
    return mapped;
  }
  const kind = NUMBER_KINDS.get(key);
  if (kind === undefined) {
    unclassifiedNumbers.set(key, mapped.gd);
    return mapped;
  }
  usedNumberKeys.add(key);
  if (kind === "int") return { ...mapped, ...intForm };
  if (kind === "float") return mapped;
  throw new Error(
    `[codegen] overrides.json: ${key} is "${kind}", expected "int" or "float".`
  );
}

// Call only at the end of emit(): before that, "never applied" cannot be told
// apart from "not yet reached".
function assertNumbersClassified() {
  const stale = [...NUMBER_KINDS.keys()].filter(
    (k) => !usedNumberKeys.has(k) && !miscastNumberKeys.has(k)
  );
  if (!unclassifiedNumbers.size && !stale.length && !miscastNumberKeys.size) return;

  const lines = [];
  if (unclassifiedNumbers.size) {
    lines.push(
      `[codegen] ${unclassifiedNumbers.size} number field(s) have no entry in overrides.json.`,
      "TS `number` does not say int or float and the generator will not guess.",
      'Add each to the "number" map:',
      ""
    );
    for (const [k, gd] of unclassifiedNumbers) {
      lines.push(`    ${JSON.stringify(k)}: "int",${" ".repeat(Math.max(1, 44 - k.length))}// or "float"  (currently ${gd})`);
    }
    lines.push(
      "",
      'Pick "int" for counts, ranks, sizes and ms timestamps; "float" when the value',
      'can legitimately be fractional. Unsure? "float" — a wrong "int" truncates real',
      "data silently, a wrong \"float\" is merely untidy."
    );
  }
  if (stale.length) {
    lines.push("[codegen] overrides.json entries matching no emitted field:");
    for (const k of stale) lines.push(`    ${k}`);
    lines.push("Fix the key or drop it — a stale entry silently controls nothing.");
  }
  if (miscastNumberKeys.size) {
    lines.push("[codegen] overrides.json entries on fields that are not numbers:");
    for (const k of miscastNumberKeys) lines.push(`    ${k}`);
  }
  throw new Error(lines.join("\n"));
}

export function toSnake(name) {
  return name
    .replace(/([a-z])([A-Z])/g, "$1_$2")
    // Split a digit from the next word only where a word really starts, so
    // acronyms with digits survive: P2PPacketDropReason -> p2p_..., not p2_p_...
    .replace(/([0-9])([A-Z][a-z])/g, "$1_$2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2")
    .toLowerCase();
}

function toEnumMember(value) {
  let id = toSnake(String(value))
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  if (!id) id = "VALUE";
  if (/^[0-9]/.test(id)) id = `_${id}`;
  return id;
}

function toPascal(name) {
  return name.replace(/^[a-z]/, (c) => c.toUpperCase());
}

// The GDScript type an async payload comes back as: a model bare, a list as a typed
// Array, a scalar bare. Throws rather than inventing a spelling for a shape that has
// never appeared.
function returnTypeFor(t, what) {
  if (t.model) return t.model;
  if (t.gd.startsWith("Array[") || SCALARS.has(t.gd)) return t.gd;
  throw new Error(
    `[codegen] ${what} has payload type ${t.gd}${t.note ? ` (${t.note})` : ""}, which has no\n` +
      `GDScript return type. Add one to returnTypeFor() in gdscript.mjs, or resolve the\n` +
      `type so it maps to a model.`
  );
}

// How one `item` of an array payload is hydrated.
function elementExpr(t) {
  if (t.elementModel) return `${t.elementModel}.from_dict(item)`;
  if (t.elementEnum) return `${t.elementEnum.decode}(item)`;
  return "item";
}

// The page is trusted to send the right shape, but "trusted" is not "checked": an
// element of the wrong type would abort the decode outright, because from_dict()
// takes a typed Dictionary and a String argument is a hard error. Skip what does not
// fit instead, so a bad element costs one entry rather than the whole list.
function elementGuard(t) {
  if (t.elementModel) return "item is Dictionary";
  if (t.elementEnum) return null; // the decoders map anything unknown to UNKNOWN
  const inner = t.gd.slice("Array[".length, -1);
  return SCALARS.get(inner) ?? null;
}

// The typed-Array decoder for a list payload. JSON hands back an untyped Array, and
// Godot rejects that against a typed one, so every element is appended through the
// same guard from_dict() uses.
function listDecoder(name, t, indent) {
  const L = [];
  const p = (s) => L.push(`${indent}${s}`);
  const guard = elementGuard(t);
  p(`static func ${name}(raw: Variant) -> ${t.gd}:`);
  p(`\tvar items: ${t.gd} = []`);
  p("\tif raw is Array:");
  p("\t\tfor item in raw:");
  if (guard) {
    p(`\t\t\tif ${guard}:`);
    p(`\t\t\t\titems.append(${elementExpr(t)})`);
  } else {
    p(`\t\t\titems.append(${elementExpr(t)})`);
  }
  p("\treturn items");
  return L;
}

function buildEnum(name, members, { doc = null, owner = null } = {}) {
  const numeric = members.every((m) => typeof m.value === "number");
  const taken = new Set();
  const resolved = [];
  members.forEach((m, i) => {
    const base = toEnumMember(m.name ?? m.value);
    let id = base;
    for (let n = 2; taken.has(id); n++) id = `${base}_${n}`;
    taken.add(id);
    resolved.push({ id, wire: m.value, value: numeric ? m.value : i });
  });
  // Both the sentinel's name and its value have to dodge a real member.
  let sentinel = "UNKNOWN";
  for (const candidate of ["UNKNOWN_VALUE", "UNSET", "NOT_SET"]) {
    if (!taken.has(sentinel)) break;
    sentinel = candidate;
  }
  const values = resolved.map((m) => m.value);
  const sentinelValue = values.includes(-1) ? Math.min(...values) - 1 : -1;
  const funcBase = toSnake(name);
  // A nested enum is only referenced from inside its own class, where the bare
  // name is in scope; a script-level one is qualified so inner classes can see it.
  const qualify = (id) => (owner ? id : `WavedashTypes.${id}`);
  const typeRef = qualify(name);
  return {
    name,
    members: resolved,
    numeric,
    sentinel,
    sentinelValue,
    doc,
    owner,
    typeRef,
    funcBase,
    initRef: `${typeRef}.${sentinel}`,
    decode: qualify(`${funcBase}_from_${numeric ? "int" : "string"}`),
    encode: numeric ? null : qualify(`${funcBase}_to_string`),
    missing: numeric ? String(sentinelValue) : '""',
  };
}

// `decoded` adds UNKNOWN and the wire converters: needed by anything read out of
// a payload, noise for an enum you only ever pass in.
function emitEnum(e, indent, { decoded = true } = {}) {
  const L = [];
  const p = (s = "") => L.push(s);
  const q = (s) => JSON.stringify(s);
  if (e.doc) L.push(docComment(e.doc, indent).trimEnd());
  if (!e.numeric) {
    p(`${indent}## Wire values: ${e.members.map((m) => q(m.wire)).join(" | ")}`);
  }
  p(`${indent}enum ${e.name} {`);
  const rows = e.members.map((m) => ({ code: `${m.id} = ${m.value}` }));
  if (decoded) {
    rows.unshift({
      code: `${e.sentinel} = ${e.sentinelValue}`,
      comment: "absent, or unknown to this build",
    });
  }
  // The comma has to come before the comment, or it ends up commented out.
  rows.forEach((row, i) => {
    const comma = i === rows.length - 1 ? "" : ",";
    p(`${indent}\t${row.code}${comma}${row.comment ? `  # ${row.comment}` : ""}`);
  });
  p(`${indent}}`);
  p("");
  if (!decoded) return L;

  if (e.numeric) {
    // JSON.parse_string() makes every number a float and `match` is type-strict:
    // 1.0 does NOT match the literal 1. Narrow first, or every decoded enum
    // silently becomes the sentinel.
    p(`${indent}static func ${e.funcBase}_from_int(v) -> ${e.name}:`);
    p(`${indent}\tif not (v is int or v is float):`);
    p(`${indent}\t\treturn ${e.name}.${e.sentinel}`);
    p(`${indent}\tmatch int(v):`);
  } else {
    // `s` is untyped on purpose: a String-typed parameter ABORTS the function when
    // the page sends a number, taking the calling from_dict() with it.
    p(`${indent}static func ${e.funcBase}_from_string(s) -> ${e.name}:`);
    p(`${indent}\tmatch s:`);
  }
  for (const m of e.members) {
    p(`${indent}\t\t${e.numeric ? m.wire : q(m.wire)}: return ${e.name}.${m.id}`);
  }
  p(`${indent}\treturn ${e.name}.${e.sentinel}`);
  p("");
  if (!e.numeric) {
    p(`${indent}static func ${e.funcBase}_to_string(v: ${e.name}) -> String:`);
    p(`${indent}\tmatch v:`);
    for (const m of e.members) p(`${indent}\t\t${e.name}.${m.id}: return ${q(m.wire)}`);
    p(`${indent}\treturn ""`);
    p("");
  }
  return L;
}

function unwrapParens(t) {
  let s = t.trim();
  while (s.startsWith("(") && s.endsWith(")")) s = s.slice(1, -1).trim();
  return s;
}

function unwrapArray(tsType) {
  const t = tsType.trim();
  if (t.endsWith("[]")) return { elem: t.slice(0, -2).trim(), isArray: true };
  const m = t.match(/^Array<([\s\S]+)>$/);
  if (m) return { elem: m[1].trim(), isArray: true };
  return { elem: t, isArray: false };
}

function inlineLiteralUnion(tsType) {
  const parts = splitUnion(unwrapParens(tsType)).map((p) => p.trim());
  const nonNull = parts.filter((p) => p !== "null" && p !== "undefined");
  if (nonNull.length < 2 || !nonNull.every((p) => /^(["']).*\1$/.test(p))) return null;
  return nonNull.map((p) => p.slice(1, -1));
}

// Recover a numeric enum from its values alone — Convex declares these unions
// inline (`0 | 2 | 1`), so the checker strips the name. Exact set match and a
// unique winner only: `0 | 2` fits both LobbyVisibility and UGCVisibility, and a
// wrong enum silently mistypes a public field, so ambiguity stays Variant.
function matchNumericEnum(parts, enums) {
  if (parts.length < 2) return null;
  const values = [];
  for (const p of parts) {
    if (!/^-?\d+$/.test(p.trim())) return null;
    values.push(Number(p));
  }
  const key = (ns) => [...new Set(ns)].sort((a, b) => a - b).join(",");
  const want = key(values);
  const hits = [...enums.values()].filter(
    (e) => e.numeric && key(e.members.map((m) => m.wire)) === want
  );
  return hits.length === 1 ? hits[0] : null;
}

// Split a union type on top-level `|`, respecting <...> nesting.
function splitUnion(t) {
  const parts = [];
  let depth = 0;
  let cur = "";
  for (const ch of t) {
    if (ch === "<") depth++;
    else if (ch === ">") depth--;
    if (ch === "|" && depth === 0) {
      parts.push(cur.trim());
      cur = "";
    } else cur += ch;
  }
  if (cur.trim()) parts.push(cur.trim());
  return parts;
}

// Returns { gd, init, note?, model?, elementModel?, enumRef?, elementEnum? }.
export function mapType(tsType, known, enums = new Map()) {
  const t = unwrapParens(tsType);

  const union = splitUnion(t);
  if (union.length > 1) {
    const nonNull = union.filter((u) => u !== "null" && u !== "undefined");
    if (nonNull.every((u) => /^["'].*["']$/.test(u))) return { gd: "String", init: '""' };
    const byValues = matchNumericEnum(nonNull, enums);
    if (byValues) return { gd: byValues.typeRef, init: byValues.initRef, enumRef: byValues };
    if (nonNull.length === 1) {
      const inner = mapType(nonNull[0], known, enums);
      if (inner.enumRef) return inner; // an int; the sentinel already means "absent"
      // Only Variant or an Object can hold null — `var x: String = null` is a parse
      // error — so anything else keeps its type's default for the absent case.
      const holdsNull = !!inner.model || inner.gd === "Variant";
      return holdsNull ? { ...inner, init: "null" } : inner;
    }
    return { gd: "Variant", init: "null", note: `union: ${t}` };
  }

  const { elem, isArray } = unwrapArray(t);
  if (isArray) {
    const inner = mapType(elem, known, enums);
    if (inner.enumRef) {
      return { gd: "Array[int]", init: "[]", note: `Array[${inner.gd}]`, elementEnum: inner.enumRef };
    }
    if (SCALARS.has(inner.gd)) return { gd: `Array[${inner.gd}]`, init: "[]" };
    // Typed, so indexing keeps the element type and items[0].field autocompletes.
    // Parses on 4.0.4 and 4.7.1.
    if (known.has(elem)) return { gd: `Array[${elem}]`, init: "[]", elementModel: elem };
    return { gd: "Array", init: "[]", note: `Array[${inner.gd}]`, elementModel: null };
  }

  // Compile-time-only modifiers. Partial needs no separate class: every generated
  // field already carries a default, so an absent key leaves it there.
  const modifier = t.match(/^(?:Partial|Readonly)<([\s\S]+)>$/);
  if (modifier) return mapType(modifier[1].trim(), known, enums);

  if (/^Record</.test(t)) return { gd: "Dictionary", init: "{}" };
  if (t.startsWith("{")) return { gd: "Dictionary", init: "{}", note: t };
  if (/^(GenericId|Id)</.test(t)) return { gd: "String", init: '""' };
  if (t === "string") return { gd: "String", init: '""' };
  if (t === "number") return { gd: "float", init: "0.0" };
  if (t === "boolean") return { gd: "bool", init: "false" };
  // Convex hands opaque blobs over as ArrayBuffer; they reach Godot as bytes.
  if (t === "Uint8Array" || t === "ArrayBuffer") {
    return { gd: "PackedByteArray", init: "PackedByteArray()" };
  }
  if (t === "unknown" || t === "any") return { gd: "Variant", init: "null" };

  const en = enums.get(t);
  if (en) return { gd: en.typeRef, init: en.initRef, enumRef: en };
  if (known.has(t)) return { gd: t, init: "null", model: t };
  return { gd: "Variant", init: "null", note: `unresolved: ${t}` };
}

function docComment(doc, indent) {
  if (!doc) return "";
  return doc
    .split("\n")
    .map((l) => `${indent}## ${l}`.trimEnd())
    .join("\n") + "\n";
}

export function emit(ir) {
  // Module-level, so a second emit() in the same process must start clean.
  unclassifiedNumbers.clear();
  usedNumberKeys.clear();
  miscastNumberKeys.clear();

  // Only what the SDK exports: an alias it keeps to itself is an implementation
  // detail. RawListUGCItemsArgs is the live case — it exists only so
  // ListUGCItemsArgs can be derived from it.
  const resolvedModels = (ir.resolved ?? [])
    .filter((r) => r.exported && r.fields.length && !r.aliasOf)
    .map((r) => ({
      name: r.modelName,
      doc: `${r.modelName} — resolved from the Convex API (\`${r.tsType}\`).`,
      extends: [],
      fields: r.fields,
    }));

  // An array-shaped alias names a collection, so it cannot be a model itself:
  // `LeaderboardEntries` must become `LeaderboardEntry[]` before mapType() sees
  // it. A pure alias rewrites to the model it re-exports. Object-shaped aliases
  // need neither — their name is the model name.
  const aliasRewrites = new Map([
    ...(ir.resolved ?? [])
      .filter((r) => r.shape === "array" && r.modelName)
      .map((r) => [r.name, `${r.modelName}[]`]),
    ...(ir.resolved ?? []).filter((r) => r.aliasOf).map((r) => [r.name, r.aliasOf]),
  ]);
  const rewriteAlias = (tsType) => aliasRewrites.get(tsType) ?? tsType;

  const allModels = [...ir.models, ...resolvedModels];
  const known = new Set(allModels.map((m) => m.name));
  const L = [];
  const p = (s = "") => L.push(s);

  // Candidates only. Which ones are emitted is decided after the field/param
  // pass, so a union the SDK uses internally does not become public API.
  const aliasEnums = new Map();
  for (const a of ir.aliases) {
    if (!/-union$/.test(a.kind) || !a.members?.length) continue;
    aliasEnums.set(a.name, buildEnum(a.name, a.members, { doc: a.doc }));
  }

  const models = allModels.filter((model) => {
    if (model.name === "EngineInstance") return false; // host-only, not a payload
    // A method-only interface (Logger) has nothing to model.
    return model.fields.length > 0 || model.extends.length > 0;
  });

  const usedAliasEnums = new Set(); // referenced anywhere -> worth emitting
  const decodedEnums = new Set(); // read out of a payload -> needs a converter
  const nestedEnums = new Map(); // model name -> enums to nest in it

  const noteUse = (t, decoded) => {
    for (const e of [t.enumRef, t.elementEnum]) {
      if (!e || e.owner) continue; // nested enums live and die with their class
      usedAliasEnums.add(e.name);
      if (decoded) decodedEnums.add(e.name);
    }
  };

  const nestedEnumFor = (model, field, values) => {
    const declared = nestedEnums.get(model.name) ?? [];
    let name = toPascal(field.name);
    // Don't shadow a sibling class or a script-level enum from inside the class.
    if (known.has(name) || aliasEnums.has(name) || declared.some((e) => e.name === name)) {
      name = `${name}Enum`;
    }
    const e = buildEnum(
      name,
      values.map((value) => ({ name: value, value })),
      { owner: model.name }
    );
    nestedEnums.set(model.name, [...declared, e]);
    return e;
  };

  // An extending interface carries the parent's fields on the wire, so they belong
  // on the class. Dropping them once cost LobbyUsersUpdatedPayload every field but
  // changeType — a listener knew somebody joined and nothing about who.
  const modelsByName = new Map(allModels.map((m) => [m.name, m]));
  const withInherited = (model) => {
    if (!model.extends.length) return model.fields;
    const own = new Set(model.fields.map((f) => f.name));
    const inherited = [];
    for (const parent of model.extends) {
      for (const f of modelsByName.get(parent)?.fields ?? []) {
        if (!own.has(f.name)) {
          own.add(f.name);
          inherited.push(f);
        }
      }
    }
    return [...inherited, ...model.fields];
  };

  const plans = models.map((model) => ({
    model,
    fields: withInherited(model).map((f) => {
      // An inline `"A" | "B"` has no named alias to hang an enum off, so it gets
      // one nested in this class.
      const { elem, isArray } = unwrapArray(f.tsType);
      const values = inlineLiteralUnion(elem);
      if (values) {
        const e = nestedEnumFor(model, f, values);
        return {
          f,
          t: isArray
            ? { gd: "Array[int]", init: "[]", note: `Array[${e.name}]`, elementEnum: e }
            : { gd: e.name, init: e.initRef, enumRef: e },
        };
      }
      const t = classifyNumber(
        `${model.name}.${f.name}`,
        mapType(rewriteAlias(f.tsType), known, aliasEnums)
      );
      noteUse(t, /* decoded */ true);
      return { f, t };
    }),
  }));

  const methodRows = ir.methods
    .filter((m) => m.dataType)
    .map((m) => {
      const t = classifyNumber(
        `${m.name}() payload`,
        mapType(rewriteAlias(m.dataType), known, aliasEnums)
      );
      noteUse(t, /* decoded */ true);
      return { m, t };
    });

  // Parameters are the only place the number-valued unions (UGCType and friends)
  // appear, and passing one in is exactly what the enum is for.
  for (const m of ir.methods) {
    for (const prm of m.params ?? []) {
      const t = mapType(rewriteAlias(prm.tsType), known, aliasEnums);
      noteUse(t, /* decoded */ false); // the game supplies it; nothing to convert
    }
  }

  p("# AUTO-GENERATED by codegen/generate.mjs from the sdk-js index.d.ts.");
  p("# Do not edit by hand — re-run `npm run generate` in codegen/ instead.");
  p("#");
  p("# The SDK's data models: one inner class per SDK type, each with a from_dict()");
  p("# that hydrates the JSON the JS bridge hands to Godot. Reference as");
  p("# WavedashTypes.<ClassName>.");
  p("#");
  p("# Async calls resolve to one of these, or to a bare String/bool/Array — see the");
  p("# table at the end.");
  p("#");
  p("# Members follow the upstream API's order, not GDScript's section order.");
  p("# gdlint: disable=class-definitions-order");
  p("class_name WavedashTypes");
  p("extends RefCounted");
  p("");

  const scriptEnums = [...aliasEnums.values()].filter((e) => usedAliasEnums.has(e.name));
  if (scriptEnums.length) {
    p("# --------------------------------------------------------------------------");
    p("# The SDK's literal unions, as enums. The number-valued ones hold the value");
    p("# the SDK expects, so pass a member straight in. The string-valued ones are");
    p("# carried as strings on the bridge, so they come with <name>_from_string() /");
    p("# <name>_to_string() — from_dict() below already converts on the way in.");
    p("# --------------------------------------------------------------------------");
    p("");
    for (const e of scriptEnums) {
      const decoded = !e.numeric || decodedEnums.has(e.name);
      for (const line of emitEnum(e, "", { decoded })) p(line);
    }
  }

  // Appended so they share WavedashTypes' namespace instead of adding global class
  // names. A model arriving upstream under one of these names would emit a second
  // inner class of the same name — Godot fails that at load, which is loud but
  // late, so fail the run here instead.
  const hand = fs.readFileSync(new URL("handwritten_types.gd", import.meta.url), "utf8");
  const handNames = [...hand.matchAll(/^class (\w+)/gm)].map((m) => m[1]);
  const clash = handNames.filter((n) => known.has(n) || aliasEnums.has(n));
  if (clash.length) {
    throw new Error(
      `[codegen] handwritten_types.gd declares ${clash.join(", ")}, which the SDK now\n` +
        `also declares. Rename the hand-written class — the generated one tracks upstream.`
    );
  }

  // Which element types come back as a list: every list an async method resolves to,
  // plus LobbyUser, which get_lobby_users() reads out of the local lobby cache and
  // sdk-js declares no async method for.
  const listElements = new Map(); // element name -> { t, methods[] }
  const declareList = (t, method) => {
    if (!t.gd.startsWith("Array[")) return;
    const element = t.elementModel ?? t.elementEnum?.name ?? t.gd.slice("Array[".length, -1);
    const entry = listElements.get(element) ?? { t, methods: [] };
    if (method) entry.methods.push(method);
    listElements.set(element, entry);
  };
  declareList({ gd: "Array[LobbyUser]", init: "[]", elementModel: "LobbyUser" });
  for (const { m, t } of methodRows) declareList(t, m.name);

  // sdk-js spelling, not snake_case: the addon renames some of these (isEntitled ->
  // fetch_entitlement) and skips others, so a GDScript-looking name here would be a
  // call that does not exist.
  const resolvedBy = (methods) =>
    methods.length
      ? `## Resolved by (sdk-js): ${methods.map((n) => `${n}()`).sort().join(", ")}`
      : "## No async call resolves to one; a sync getter reads it off the page.";

  // A model's decoder lives on the model (below). A scalar has no class to hang it on,
  // so its decoder is a static on WavedashTypes itself.
  const scalarLists = [...listElements].filter(([, { t }]) => !t.elementModel);
  if (scalarLists.length) {
    p("# --------------------------------------------------------------------------");
    p("# Typed-Array decoders for the list payloads whose element is not a model.");
    p("# --------------------------------------------------------------------------");
    p("");
    for (const [element, { t, methods }] of scalarLists) {
      p(resolvedBy(methods));
      for (const line of listDecoder(`${toSnake(element)}_list_from_data`, t, "")) p(line);
      p("");
    }
  }

  p("# --------------------------------------------------------------------------");
  p("# Hand-written, from codegen/handwritten_types.gd — types with no sdk-js");
  p("# declaration to generate from. Edit that file, not this one.");
  p("# --------------------------------------------------------------------------");
  p("");
  for (const line of hand.split("\n")) p(line);

  const emittedLists = new Set();
  for (const { model, fields: mapped } of plans) {
    p(docComment(model.doc, "").trimEnd() || `## ${model.name}`);
    p(`class ${model.name} extends RefCounted:`);

    for (const e of nestedEnums.get(model.name) ?? []) {
      for (const line of emitEnum(e, "\t")) p(line);
    }

    if (model.extends.length) {
      const unresolved = model.extends.filter((n) => !modelsByName.has(n));
      p(`\t# Fields inherited from: ${model.extends.join(", ")}`);
      if (unresolved.length) {
        p(`\t# NOT inherited, unresolved: ${unresolved.join(", ")}`);
      }
    }
    for (const { f, t } of mapped) {
      const note = t.note ? `  # ${f.tsType} -> ${t.note}` : `  # ${f.tsType}`;
      p(`\tvar ${toSnake(f.name)}: ${t.gd} = ${t.init}${note}`);
    }
    p("");
    p(`\tstatic func from_dict(d: Dictionary) -> ${model.name}:`);
    p(`\t\tvar o := ${model.name}.new()`);
    for (const { f, t } of mapped) {
      const key = f.name;
      const dst = `o.${toSnake(f.name)}`;
      if (t.gd.startsWith("Array")) {
        // Not a plain assignment: JSON hands back an untyped Array, and Godot rejects
        // that against a typed one. Same element guard as from_data().
        const guard = elementGuard(t);
        p(`\t\tfor item in d.get(${JSON.stringify(key)}, []):`);
        if (guard) {
          p(`\t\t\tif ${guard}:`);
          p(`\t\t\t\t${dst}.append(${elementExpr(t)})`);
        } else {
          p(`\t\t\t${dst}.append(${elementExpr(t)})`);
        }
      } else if (t.enumRef) {
        p(`\t\t${dst} = ${t.enumRef.decode}(d.get(${JSON.stringify(key)}, ${t.enumRef.missing}))`);
      } else if (t.model) {
        p(`\t\t${dst} = ${t.model}.from_dict(d.get(${JSON.stringify(key)}, {}))`);
      } else {
        p(`\t\t${dst} = d.get(${JSON.stringify(key)}, ${t.init})`);
      }
    }
    p("\t\treturn o");
    p("");
    const asList = listElements.get(model.name);
    if (asList) {
      p(`\t${resolvedBy(asList.methods)}`);
      for (const line of listDecoder("list_from_data", asList.t, "\t")) p(line);
      p("");
      emittedLists.add(model.name);
    }


    // An optional field still holding its default is OMITTED, not sent: `foo?:`
    // means the JS side branches on the key being absent, so sending `""` would
    // override a default it meant to apply.
    p(`\tfunc to_dict() -> Dictionary:`);
    p(`\t\tvar d := {}`);
    for (const { f, t } of mapped) {
      const key = JSON.stringify(f.name);
      const src = toSnake(f.name);
      const body = [];
      if (t.elementModel || t.elementEnum) {
        const enc = t.elementEnum?.encode;
        body.push(`var a := []`);
        body.push(`for item in ${src}:`);
        body.push(`\ta.append(${t.elementModel ? "item.to_dict()" : enc ? `${enc}(item)` : "item"})`);
        body.push(`d[${key}] = a`);
      } else if (t.enumRef) {
        body.push(`d[${key}] = ${t.enumRef.encode ? `${t.enumRef.encode}(${src})` : src}`);
      } else if (t.model) {
        body.push(`d[${key}] = ${src}.to_dict()`);
      } else {
        body.push(`d[${key}] = ${src}`);
      }
      if (f.optional) {
        p(`\t\tif ${src} != ${t.init}:`);
        for (const line of body) p(`\t\t\t${line}`);
      } else {
        for (const line of body) p(`\t\t${line}`);
      }
    }
    p(`\t\treturn d`);
    p("");
  }

  // A list element that resolved to a model name the emitter never wrote would leave
  // WavedashSDK.gd calling a list_from_data() that does not exist.
  const missingLists = [...listElements]
    .filter(([n, { t }]) => t.elementModel && !emittedLists.has(n))
    .map(([n]) => n);
  if (missingLists.length) {
    throw new Error(
      `[codegen] ${missingLists.join(", ")} is returned as a list but no model of that\n` +
        `name was emitted, so it has no list_from_data(). Resolve the element type.`
    );
  }

  const eventStrings = new Map(
    (ir.aliases.find((a) => a.name === "WavedashEvent")?.members ?? []).map((m) => [
      m.name,
      m.value,
    ])
  );
  p("# Wire strings for the events the page pushes into _dispatch_js_event().");
  for (const [key, wire] of eventStrings) {
    p(`const JS_EVENT_${key} = ${JSON.stringify(wire)}`);
  }
  p("");

  p("## Turn a raw event payload Dictionary into its typed model.");
  p("## Call this from WavedashSDK._dispatch_js_event before emitting the signal.");
  p("static func parse_event(event_name: String, payload: Dictionary) -> RefCounted:");
  p("\tmatch event_name:");
  // No hand-written fallback table on purpose: a copy of these 18 pairs would go
  // stale on the first upstream rename, and invisibly — a dispatch arm with the
  // wrong string simply never matches.
  const eventEntries =
    ir.tables.find((t) => t.name === "WavedashEventMap")?.entries ?? [];
  for (const e of eventEntries) {
    const payloadName = rewriteAlias(e.valueType);
    if (known.has(payloadName)) {
      const evName = eventStrings.get(e.key);
      if (!evName) {
        throw new Error(
          `[codegen] no wire string for event ${e.key}: it is a key of WavedashEventMap ` +
            `but not a member of the WavedashEvent union. Guessing the string would emit ` +
            `a dispatch arm that never matches.`
        );
      }
      p(`\t\tJS_EVENT_${e.key}: return ${payloadName}.from_dict(payload)`);
    }
  }
  p("\t\t_: return null  # unmapped or dynamic (e.g. LobbyDataUpdated is free-form)");
  p("");

  // WavedashSDK.gd's signatures are hand-written, so this is what to diff them
  // against after a regenerate.
  p("# ---------------------------------------------------------------------------");
  p("# What each async method resolves to. A `Variant`/`Dictionary` data type is");
  p("# Convex-derived and needs the type checker + @wvdsh/api to expand (see");
  p("# codegen/README.md). Resolving one IS a breaking change for callers:");
  p("# unresolved, the payload is raw JSON read as res.value[\"name\"]; resolved, it is");
  p("# a hydrated model read as res.name. Do it inside a major version bump.");
  const pad = Math.max(...methodRows.map(({ m }) => m.name.length + 2));
  for (const { m, t } of methodRows) {
    const ret = returnTypeFor(t, `${m.name}()`);
    p(`#   ${`${m.name}()`.padEnd(pad)} -> ${ret}  (${m.dataType})`);
  }

  assertNumbersClassified();

  return { types: L.join("\n") + "\n" };
}
