// Stage 1: TypeScript declaration file -> normalized IR.
//
// Two passes over ONE parse. 1a is the syntactic walk: what this file literally
// says. Convex-derived `FunctionReturnType<typeof api...>` aliases land as
// kind: "unresolved" because nothing local says what they expand to. 1b is
// resolveExternalAliases(), which runs the type checker over exactly those.
//
// Separate because a missing @wvdsh/api must degrade to "unresolved" rather
// than crash. Both read the SAME ts.SourceFile off the Program — parsing twice
// gave two node trees for one input and the walks drifted apart.

import ts from "typescript";
import fs from "node:fs";

/**
 * @typedef {Object} Field
 * @property {string} name        original TS property name (camelCase)
 * @property {string} tsType      the TS type as written, e.g. `GenericId<"users">`
 * @property {boolean} optional   was it declared `foo?:`
 *
 * @typedef {Object} Model
 * @property {string} name        interface name, e.g. `LobbyJoinedPayload`
 * @property {string|null} doc    leading /** *\/ comment, if any
 * @property {string[]} extends   base interfaces (heritage clause)
 * @property {Field[]} fields
 *
 * @typedef {Object} EnumMember
 * @property {string} name          identifier to use, e.g. `QUEUE_FULL`
 * @property {string|number} value  the value that travels on the wire
 *
 * @typedef {Object} Alias        a `type X = ...` we could NOT expand to a shape
 * @property {string} name
 * @property {string} tsType      the right-hand side, verbatim
 * @property {"string-union"|"number-union"|"unresolved"|"other"} kind
 * @property {EnumMember[]} [members]  set on the union kinds: the literal values
 * @property {string|null} [doc]       set on the union kinds: leading comment
 *
 * @typedef {Object} SdkMethod
 * @property {string} name
 * @property {string} returnType  the raw Promise<...> / sync return type
 * @property {string|null} dataType  the T inside Promise<WavedashResponse<T>>, if any
 * @property {boolean} async
 *
 * @typedef {Object} TableEntry
 * @property {string} key        the constant's member name, e.g. `LOBBY_JOINED`
 * @property {string} keyExpr    the key as written, e.g. `WavedashEvents.LOBBY_JOINED`
 * @property {string} valueType  the type it maps to, verbatim, e.g. `LobbyJoinedPayload`
 *
 * @typedef {Object} Table       a type-level lookup table — see computedKeyTable()
 * @property {string} name       alias name, e.g. `WavedashEventMap`
 * @property {string|null} doc   leading /** *\/ comment, if any
 * @property {TableEntry[]} entries
 */

// Shared by both passes. `skipLibCheck` matters: type-checking all of lib.d.ts
// and convex/ would cost seconds and tell us nothing about the shapes we emit.
const PROGRAM_OPTIONS = {
  noEmit: true,
  skipLibCheck: true,
  strict: true,
  moduleResolution: ts.ModuleResolutionKind.Node10,
};

export function parse(dtsPath) {
  const program = ts.createProgram([dtsPath], PROGRAM_OPTIONS);
  // The Program normalizes paths, so this lookup can miss where a bare parse would
  // not. Falling back keeps pass 1a alive, but a checker belongs to the tree its
  // Program parsed, so it is withheld rather than pointed at nodes it never saw.
  const programSf = program.getSourceFile(dtsPath);
  const sf =
    programSf ??
    ts.createSourceFile(dtsPath, fs.readFileSync(dtsPath, "utf8"), ts.ScriptTarget.Latest, true);
  const checker = programSf ? program.getTypeChecker() : null;
  const text = sf.text;

  /** @type {Model[]} */
  const models = [];
  /** @type {Alias[]} */
  const aliases = [];
  /** @type {SdkMethod[]} */
  const methods = [];
  /** @type {Table[]} */
  const tables = [];

  const raw = (node) => node.getText(sf).replace(/\s+/g, " ").trim();

  const leadingDoc = (node) => {
    const ranges = ts.getLeadingCommentRanges(text, node.getFullStart()) || [];
    const block = ranges
      .filter((r) => text.slice(r.pos, r.end).startsWith("/**"))
      // A blank line between the comment and the declaration means it isn't
      // documenting it — it's a section header for what follows.
      // getStart(sf) rather than getStart(): the no-argument form resolves the
      // source file by walking `parent` pointers, which the fallback parse above
      // may not have set.
      .filter((r) => !/\n\s*\n/.test(text.slice(r.end, node.getStart(sf))))
      .map((r) => text.slice(r.pos, r.end))
      .pop();
    if (!block) return null;
    return block
      .replace(/^\/\*\*/, "")
      .replace(/\*\/$/, "")
      .split("\n")
      .map((l) => l.replace(/^\s*\*?\s?/, "").trimEnd())
      .join("\n")
      .trim();
  };

  // The SDK spells its enums as a frozen object of literals plus a lookup type
  // (`declare const R: { readonly A: "A" }` + `type R = (typeof R)[keyof typeof R]`).
  // Collect those objects first so the aliases resolve to real members below —
  // a same-file lookup, so no type checker needed. They turn up in two places:
  //
  //   * `declare const R$1: {...}` — the string ones, declared right here
  //   * a property on the `WavedashSDK` class (`UGCType: { readonly ... }`) — the
  //     SDK re-exposing the object as `sdk.UGCType.SCREENSHOT`. This is the only
  //     place the numeric ones are written out, since their const is imported
  //     from @wvdsh/api and so can't be followed syntactically.
  const literalObjects = new Map();
  const addLiteralObject = (name, typeNode, docNode) => {
    // First writing wins: a local `declare const` is closer to the source of
    // truth than the class mirror.
    if (literalObjects.has(name)) return;
    const parsed = literalObjectMembers(typeNode, sf);
    if (parsed) literalObjects.set(name, { ...parsed, doc: leadingDoc(docNode) });
  };
  for (const node of sf.statements) {
    if (ts.isVariableStatement(node)) {
      for (const decl of node.declarationList.declarations) {
        if (ts.isIdentifier(decl.name) && decl.type) {
          addLiteralObject(decl.name.text, decl.type, node);
        }
      }
    }
    if (ts.isClassDeclaration(node) && node.name?.text === "WavedashSDK") {
      for (const member of node.members) {
        if (ts.isPropertyDeclaration(member) && member.name && member.type) {
          addLiteralObject(member.name.getText(sf), member.type, member);
        }
      }
    }
  }

  for (const node of sf.statements) {
    // interfaces: the fully-resolvable, hand-written shapes
    if (ts.isInterfaceDeclaration(node)) {
      const fields = [];
      for (const member of node.members) {
        // We only care about data properties, not methods (EngineInstance has
        // call signatures we deliberately skip).
        if (ts.isPropertySignature(member) && member.type && member.name) {
          fields.push({
            name: member.name.getText(sf),
            tsType: raw(member.type),
            optional: !!member.questionToken,
          });
        }
      }
      const heritage = (node.heritageClauses ?? [])
        .flatMap((h) => h.types)
        .map((t) => raw(t));
      models.push({
        name: node.name.text,
        doc: leadingDoc(node),
        extends: heritage,
        fields,
      });
    }

    // --- type aliases: either an inline object shape, a string-literal union,
    //     or something we can't expand (the Convex-derived ones) -------------
    if (ts.isTypeAliasDeclaration(node)) {
      const name = node.name.text;

      // A type literal keyed entirely by *computed* names
      // (`[WavedashEvents.LOBBY_JOINED]: LobbyJoinedPayload`) is a lookup table,
      // not a data shape — see computedKeyTable(). It has to be caught before the
      // TypeLiteral branch below, which would otherwise emit a model whose fields
      // are named after constant references.
      const table = computedKeyTable(node.type, sf);
      if (table) {
        tables.push({ name, doc: leadingDoc(node), entries: table });
        continue;
      }

      // `type X = { ... }` behaves just like an interface.
      if (ts.isTypeLiteralNode(node.type)) {
        const fields = [];
        for (const member of node.type.members) {
          if (ts.isPropertySignature(member) && member.type && member.name) {
            fields.push({
              name: member.name.getText(sf),
              tsType: raw(member.type),
              optional: !!member.questionToken,
            });
          }
        }
        models.push({ name, doc: leadingDoc(node), extends: [], fields });
        continue;
      }

      // `type R = (typeof R$1)[keyof typeof R$1]` -> the members of R$1. The
      // referenced const is tried first; when it's imported (UGC_TYPE and the
      // other numeric ones live in @wvdsh/api) we fall back to an object of the
      // same name as the alias, which is how the SDK class mirrors them.
      const lookup = matchConstObjectLookup(raw(node.type));
      const literalObject = lookup
        ? literalObjects.get(lookup) ?? literalObjects.get(name)
        : null;
      if (literalObject) {
        aliases.push({
          name,
          tsType: raw(node.type),
          kind: literalObject.kind,
          doc: leadingDoc(node) ?? literalObject.doc,
          members: literalObject.members,
        });
        continue;
      }

      // `type Direction = "SEND" | "RECEIVE"` (with `| null` allowed) — a union
      // written out literally. The member name is the wire value itself.
      const literals = stringUnionLiterals(node.type);
      if (literals) {
        aliases.push({
          name,
          tsType: raw(node.type),
          kind: "string-union",
          doc: leadingDoc(node),
          members: literals.map((value) => ({ name: value, value })),
        });
        continue;
      }

      // Anything that references another package (FunctionReturnType<...>) lands
      // here. Without the type checker + @wvdsh/api installed we can't expand it.
      const referencesExternal = /FunctionReturnType|FunctionArgs|typeof api\./.test(
        raw(node.type)
      );
      aliases.push({
        name,
        tsType: raw(node.type),
        kind: referencesExternal ? "unresolved" : "other",
      });
      continue;
    }

    // --- the SDK class: gives us each method's return/data type --------------
    if (ts.isClassDeclaration(node) && node.name?.text === "WavedashSDK") {
      for (const member of node.members) {
        if (!ts.isMethodDeclaration(member) || !member.name) continue;
        const mName = member.name.getText(sf);
        if (mName.startsWith("_")) continue;
        const returnType = member.type ? raw(member.type) : "void";
        methods.push({
          name: mName,
          returnType,
          dataType: extractResponseData(returnType),
          async: returnType.startsWith("Promise<"),
          // Params are what a game *passes in*, so they decide whether an enum
          // is part of the addon's surface (nothing else references UGCType).
          params: member.parameters.map((prm) => ({
            name: prm.name.getText(sf),
            tsType: prm.type ? raw(prm.type) : "unknown",
            optional: !!prm.questionToken,
          })),
        });
      }
      continue;
    }
  }

  // `exported` is what the package actually exposes. An alias the SDK keeps to
  // itself is an implementation detail, not addon surface.
  const exported = new Set();
  const declByName = new Map();
  const importByName = new Map();
  for (const node of sf.statements) {
    if (ts.isTypeAliasDeclaration(node)) declByName.set(node.name.text, node);

    if (ts.isExportDeclaration(node) && node.exportClause && ts.isNamedExports(node.exportClause)) {
      for (const el of node.exportClause.elements) exported.add(el.name.text);
    }

    if (ts.isImportDeclaration(node)) {
      const bindings = node.importClause?.namedBindings;
      if (bindings && ts.isNamedImports(bindings)) {
        for (const el of bindings.elements) importByName.set(el.name.text, el);
      }
    }
  }

  // Being named in a public signature makes a shape observable exactly as an
  // export does. `SDKUser` forces the distinction: `getUser()` returns it on every
  // call, yet it is absent from `export { ... }`.
  //
  // From signatures and emitted fields only, never from an alias's right-hand
  // side — that is what keeps a pure intermediate like RawListUGCItemsArgs out.
  const publicRefs = new Set();
  const noteRefs = (tsType) => {
    for (const m of String(tsType ?? "").matchAll(/[A-Za-z_$][A-Za-z0-9_$]*/g)) {
      publicRefs.add(m[0]);
    }
  };
  for (const m of methods) {
    noteRefs(m.returnType);
    noteRefs(m.dataType);
    for (const p of m.params ?? []) noteRefs(p.tsType);
  }
  for (const m of models) for (const f of m.fields) noteRefs(f.tsType);

  // Named imports the public surface mentions. Being imported is not on its own a
  // reason to expand anything — `api`, `ConvexClient` and the enum consts are too —
  // so only the ones a signature names are offered.
  const importedRefs = [...importByName.keys()].filter((n) => publicRefs.has(n));

  return {
    source: dtsPath,
    models,
    aliases,
    methods,
    tables,
    resolved: resolveExternalAliases({
      checker,
      aliases,
      exported,
      publicRefs,
      importedRefs,
      declByName,
      importByName,
    }),
  };
}

/**
* Pass 1b: expand the aliases the syntactic walk gave up on.
*
* `@wvdsh/api`'s generated convex_api.d.ts inlines each FunctionReference's
* argument and return types literally, so the checker expands them with no Convex
* deployment and no schema access. Also expands types the SDK imports rather than
* declares, when a public signature names one (`getUser(): SDKUser`).
*
* Shapes returned:
*   object  — expanded to `fields`; emit as a model called `modelName`
*   array   — element expanded to `fields`; alias itself is `modelName[]`
*   opaque  — resolved, but not a record; `resolvedType` says what
*   generic — has type parameters, so no single shape to emit
*   alias   — a re-export of a shape another entry claimed (`aliasOf`)
*   value   — an imported name that is a value, not a type
*   missing — vanished between the two passes; should not happen
*
* Two phases because shapes reference each other: every alias's type is
* registered by name first, so a nested reference renders as `UGCItem[]` rather
* than a re-inlined object literal. The registry is keyed on the `ts.Type` OBJECT,
* not a rendered string — TypeScript interns structurally identical types, which
* makes the match exact rather than a structural guess.
*/
function resolveExternalAliases({
  checker,
  aliases,
  exported = new Set(),
  publicRefs = new Set(),
  importedRefs = [],
  declByName = new Map(),
  importByName = new Map(),
}) {
  // Exported, or named by a public signature — see publicRefs in parse().
  const isPublic = (name) => exported.has(name) || publicRefs.has(name);
  // Offer the checker anything pass 1a could not turn into a shape, not just what
  // looked Convex-derived: `kind: "unresolved"` is a regex over the RHS, so it
  // misses aliases that reach Convex transitively (`ListUGCItemsArgs`). Non-shapes
  // resolve to zero properties and fall out as "opaque" on their own.
  //
  // Ordered so directly-derived shapes go first: when two aliases resolve to the
  // same type object the first claims the model name. `LobbyMessage` should win
  // over `LobbyMessagePayload`, and a locally declared shape over a re-export.
  const pending = [
    ...aliases.filter((a) => a.kind === "unresolved"),
    ...aliases.filter((a) => a.kind === "other"),
    ...importedRefs.map((name) => ({ name, tsType: name, kind: "imported" })),
  ];
  if (!pending.length || !checker) return [];

  // The declared type behind an import specifier: `SDKUser` here is an alias
  // symbol pointing at the real interface in @wvdsh/api, so it has to be
  // followed before asking for the type. Returns null rather than throwing when
  // the import cannot be followed (a missing dependency), so a partial install
  // degrades to Dictionary the same way the rest of pass 1b does.
  const typeOfImport = (spec) => {
    const sym = checker.getSymbolAtLocation(spec.name);
    if (!sym) return null;
    const target = sym.flags & ts.SymbolFlags.Alias ? checker.getAliasedSymbol(sym) : sym;
    if (!target) return null;
    const declared = checker.getDeclaredTypeOfSymbol(target);
    return declared && declared.flags !== ts.TypeFlags.Any ? declared : null;
  };

  // An index signature means the shape is an open map, not a fixed record.
  // `GameLaunchParams` is `{ lobby?: Id<'lobbies'>; [key: string]: string | undefined }`
  // — emitting a class for it would publish `lobby` and silently drop every
  // other key the launcher passes, so it stays a Dictionary.
  const isOpenMap = (t) =>
    typeof checker.getIndexInfoOfType === "function" &&
    !!checker.getIndexInfoOfType(t, ts.IndexKind.String);

  // Can this type be written out as a class with fields?
  //
  // getPropertiesOfType() answers "does it have members", which is not the same
  // question: a *branded primitive* has 22 of them. `GenericId<'users'>` is
  // `string & { __tableName: 'users' }`, so its members are String.prototype and
  // a class built from them would have `charAt` and `slice` as fields. A union
  // fails the same way (that was PushType). Both are recognised by what they are
  // made of rather than by name — an intersection carrying a primitive part, or
  // a union — which leaves genuine intersections of object types
  // (`UpdateUGCItemArgs`, `UpsertedLeaderboardEntry`) correctly emitting.
  const PRIMITIVE_PART =
    ts.TypeFlags.StringLike |
    ts.TypeFlags.NumberLike |
    ts.TypeFlags.BooleanLike |
    ts.TypeFlags.BigIntLike |
    ts.TypeFlags.ESSymbolLike;
  const isRecordShape = (t) => {
    if (!t || t.isUnion?.()) return false;
    if (isOpenMap(t)) return false;
    const parts = t.isIntersection?.() ? t.types : [t];
    return !parts.some((p) => p.flags & PRIMITIVE_PART);
  };

  // Deliberately stricter than isRecordShape, and the difference has bitten once.
  //   canClaimName  — may this shape be REFERRED TO BY NAME from another field?
  //   isRecordShape — may this shape be WRITTEN OUT as a class?
  // A wrong name claim renames unrelated fields across the whole output, so it also
  // demands a plain object type and a name we will actually emit — a field pointing
  // at a class that was never written lands on Variant.
  const canClaimName = (name, t) =>
    !!(t.flags & ts.TypeFlags.Object) &&
    isPublic(name) &&
    isRecordShape(t) &&
    checker.getPropertiesOfType(t).length > 0;

  const isArrayType = (t) =>
    typeof checker.isArrayType === "function" && checker.isArrayType(t);
  // Element-first: getPropertiesOfType() on an array hands back Array's own
  // members (length, push, ...), which is never what we want.
  const elementOf = (t) => (isArrayType(t) ? checker.getTypeArguments(t)[0] : null);

  // A shape's identity, for the structural fallback below: property names plus
  // whether each is optional. Deliberately shallow — it never recurses, so a
  // self-referential type can't hang it — and only ever used to look up one of
  // the handful of aliases we resolved, never to invent a type.
  const shapeKey = (t) => {
    const props = checker.getPropertiesOfType(t);
    if (!props.length) return null;
    return props
      .map((p) => `${p.getName()}${p.flags & ts.SymbolFlags.Optional ? "?" : ""}`)
      .sort()
      .join(",");
  };

  // --- phase 1: resolve every alias's type and claim a name for its shape ----
  const entries = [];
  /** @type {Map<import("typescript").Type, string>} */
  const nameByType = new Map();
  // Reference identity catches a shape TypeScript reused from one declaration
  // (PaginatedUGCItems.page really is the UGCItem type object). It misses
  // shapes declared separately but identically — LobbyUser comes from
  // gameLobby.lobbyUsers while LobbyJoinResponse.users comes from joinLobby, so
  // convex_api.d.ts spells the same object twice and TypeScript never unifies
  // them. This is the fallback for that. A key claimed by two different aliases
  // is dropped rather than guessed at.
  /** @type {Map<string, string|null>} */
  const nameByShape = new Map();
  for (const alias of pending) {
    const spec = declByName.get(alias.name) ? null : importByName.get(alias.name);
    const node = declByName.get(alias.name) ?? spec;
    if (!node) {
      entries.push({ alias, node: null, type: null, shapeType: null, arrayOf: false });
      continue;
    }
    // A generic alias has no single shape to emit — resolving `WavedashResponse<T>`
    // would bake in whatever T happened to default to and quietly shadow the
    // response machinery that owns the envelope. Skipped on the declaration
    // having type parameters, rather than by name.
    if (node.typeParameters?.length) {
      entries.push({
        alias,
        node,
        type: null,
        shapeType: null,
        arrayOf: false,
        modelName: null,
        generic: true,
      });
      continue;
    }

    // An import specifier has no type of its own — `getTypeAtLocation` on one
    // yields the *value* side (or `any`), so the alias symbol has to be followed
    // to the declared type instead.
    const type = spec ? typeOfImport(spec) : checker.getTypeAtLocation(node.name);
    if (!type) {
      // A named import that carries no type: `GAME_ENGINE` is a `declare const`,
      // so a signature mentioning it is referring to the *value*. Distinct from
      // "missing", which really would be a bug in this pass.
      entries.push({ alias, node: null, type: null, shapeType: null, arrayOf: false, notAType: true });
      continue;
    }
    const elem = elementOf(type);
    const shapeType = elem ?? type;
    const arrayOf = !!elem;
    // A pure re-export of a shape another alias already claimed
    // (`LobbyMessagePayload = LobbyMessage`). Emitting a second identical class
    // would double the surface and give the same JSON two model names, so the
    // alias just points at the existing one.
    const claimed = nameByType.get(shapeType);
    if (claimed) {
      entries.push({ alias, node, type, shapeType, arrayOf, modelName: null, aliasOf: claimed });
      continue;
    }
    // An array alias's own name describes the collection, so the element class
    // is named from its singular.
    const modelName = arrayOf ? singularize(alias.name) ?? `${alias.name}Item` : alias.name;
    entries.push({ alias, node, type, shapeType, arrayOf, modelName });

    if (!canClaimName(alias.name, shapeType)) continue;

    nameByType.set(shapeType, modelName);
    const key = shapeKey(shapeType);
    if (key) {
      // null marks "claimed by more than one alias" — ambiguous, so unusable.
      nameByShape.set(key, nameByShape.has(key) ? null : modelName);
    }
  }

  // --- phase 2: render, now that every shape has a name to be referred to by --
  return entries.map(({ alias, node, type, shapeType, arrayOf, modelName, aliasOf, generic, notAType }) => {
    if (notAType) {
      return {
        name: alias.name,
        shape: "value",
        resolvedType: null,
        tsType: alias.tsType,
        modelName: null,
        arrayOf: false,
        exported: isPublic(alias.name),
        fields: [],
      };
    }
    if (generic) {
      return {
        name: alias.name,
        shape: "generic",
        resolvedType: null,
        tsType: alias.tsType,
        modelName: null,
        arrayOf: false,
        exported: isPublic(alias.name),
        fields: [],
      };
    }
    if (aliasOf) {
      return {
        name: alias.name,
        shape: "alias",
        resolvedType: aliasOf,
        tsType: alias.tsType,
        modelName: null,
        arrayOf: false,
        aliasOf,
        exported: isPublic(alias.name),
        fields: [],
      };
    }
    if (!node) {
      return {
        name: alias.name,
        shape: "missing",
        resolvedType: null,
        tsType: alias.tsType,
        modelName: null,
        arrayOf: false,
        exported: isPublic(alias.name),
        fields: [],
      };
    }

    const names = { byType: nameByType, byShape: nameByShape, shapeKey };
    const resolvedType = typeString(checker, type, node, names, isArrayType, elementOf);
    // Deliberately looser than phase 1's `Object`-only gate, which is about
    // claiming a name for the structural lookup. Emitting only needs the type to
    // be a *record*, and `UpdateUGCItemArgs` / `UpsertedLeaderboardEntry` are
    // intersections of two object types — real shapes with real fields that an
    // `Object`-only test would wrongly drop.
    const props = isRecordShape(shapeType) ? checker.getPropertiesOfType(shapeType) : [];
    if (!props.length) {
      return {
        name: alias.name,
        shape: "opaque",
        resolvedType,
        tsType: alias.tsType,
        modelName: null,
        arrayOf: false,
        exported: isPublic(alias.name),
        fields: [],
      };
    }

    return {
      name: alias.name,
      shape: arrayOf ? "array" : "object",
      resolvedType,
      tsType: alias.tsType,
      modelName,
      arrayOf,
      exported: isPublic(alias.name),
      fields: props.map((sym) => {
        const declared = checker.getTypeOfSymbolAtLocation(sym, node);
        return {
          name: sym.getName(),
          // Left as rendered rather than normalized: an explicit
          // `string | undefined` and an optional `foo?: string` are different
          // declarations, and mapType() is where that distinction is resolved.
          tsType: typeString(checker, declared, node, names, isArrayType, elementOf),
          optional: !!(sym.flags & ts.SymbolFlags.Optional),
        };
      }),
    };
  });
}

// `LeaderboardEntries` -> `LeaderboardEntry`. Conservative on purpose: returns
// null rather than guessing, and the caller falls back to `<Alias>Item`. A wrong
// singular silently names a public class; no singular is loud and mechanical.
// Irregular plurals hit the fallback until one actually shows up.
function singularize(name) {
  // "-ies" -> "-y" (Entries -> Entry, Lobbies -> Lobby)
  if (/[^aeiou]ies$/.test(name)) return name.replace(/ies$/, "y");
  // Already-singular words that merely end in s (Status, Analysis, Address).
  if (/(ss|us|is)$/.test(name)) return null;
  // Plain "-s" (Friends -> Friend, Items -> Item)
  if (/[a-z]s$/.test(name)) return name.replace(/s$/, "");
  return null;
}

// typeToString with truncation off (a silent `...` mid-shape is worse than a long
// line), and named shapes rendered as their name — without that every nested
// reference re-inlines the object literal and mapType() can only make it a
// Dictionary, so `PaginatedUGCItems.page` would be `Array`, not `Array[UGCItem]`.
function typeString(checker, type, node, names, isArrayType, elementOf) {
  const named = names && lookupName(type, names);
  if (named) return named;
  if (names && isArrayType?.(type)) {
    const elem = elementOf(type);
    const elemName = elem && lookupName(elem, names);
    if (elemName) return `${elemName}[]`;
  }
  return checker
    .typeToString(type, node, ts.TypeFormatFlags.NoTruncation)
    .replace(/\s+/g, " ")
    .trim();
}

// Reference identity first (exact), then the structural key (for shapes spelled
// twice in convex_api.d.ts). An ambiguous key resolves to null and falls through
// to the inline rendering, which is the safe direction: a Dictionary is worse
// than a model but a *wrong* model is worse than both.
function lookupName(type, { byType, byShape, shapeKey }) {
  const direct = byType.get(type);
  if (direct) return direct;
  const key = shapeKey(type);
  return (key && byShape.get(key)) || null;
}

// A type literal whose every member is a computed-key property signature
// (`[CONST.MEMBER]: SomeType`) -> its entries. Returns null for anything else.
//
// Needs its own IR bucket: syntactically these are `type X = { ... }` exactly like
// a model, so left alone they generate a class whose field names are constant
// references. The key's wire value isn't knowable here, so the constant's member
// name is kept and the emitter resolves it against the parsed WavedashEvent union.
//
// Requiring ALL keys to be computed is deliberate: a shape with even one normal
// key is a data model that happens to use a constant as a key.
function computedKeyTable(typeNode, sf) {
  if (!ts.isTypeLiteralNode(typeNode) || typeNode.members.length === 0) return null;
  const entries = [];
  for (const m of typeNode.members) {
    if (!ts.isPropertySignature(m) || !m.name || !m.type) return null;
    if (!ts.isComputedPropertyName(m.name)) return null;
    const keyExpr = m.name.expression.getText(sf).replace(/\s+/g, " ").trim();
    entries.push({
      // `WavedashEvents.LOBBY_JOINED` -> `LOBBY_JOINED`. A key that isn't a
      // property access (a bare `[SOME_CONST]`) keeps its text as-is.
      key: keyExpr.slice(keyExpr.lastIndexOf(".") + 1),
      keyExpr,
      valueType: m.type.getText(sf).replace(/\s+/g, " ").trim(),
    });
  }
  return entries;
}

// An object type of nothing but string literals, or nothing but numeric literals
// -> its members plus which kind it is. Returns null for anything else (a mixed
// object isn't a clean enum, and neither is a shape with real types in it).
function literalObjectMembers(typeNode, sf) {
  if (!ts.isTypeLiteralNode(typeNode) || typeNode.members.length === 0) return null;
  const members = [];
  let kind = null;
  for (const m of typeNode.members) {
    if (!ts.isPropertySignature(m) || !m.name || !m.type || !ts.isLiteralTypeNode(m.type)) {
      return null;
    }
    const literal = m.type.literal;
    // `-1` parses as a unary minus applied to a numeric literal, not a literal.
    const negative =
      ts.isPrefixUnaryExpression(literal) &&
      literal.operator === ts.SyntaxKind.MinusToken &&
      ts.isNumericLiteral(literal.operand);
    let value;
    let memberKind;
    if (ts.isStringLiteral(literal)) {
      value = literal.text;
      memberKind = "string-union";
    } else if (ts.isNumericLiteral(literal)) {
      value = Number(literal.text);
      memberKind = "number-union";
    } else if (negative) {
      value = -Number(literal.operand.text);
      memberKind = "number-union";
    } else {
      return null;
    }
    if (kind && kind !== memberKind) return null;
    kind = memberKind;
    members.push({ name: m.name.getText(sf), value });
  }
  return { members, kind };
}

// `(typeof NAME)[keyof typeof NAME]` -> NAME (the backreference makes sure both
// halves name the same const). Returns null when the shape doesn't match.
function matchConstObjectLookup(tsType) {
  const m = tsType.match(
    /^\(\s*typeof\s+([A-Za-z_$][\w$]*)\s*\)\s*\[\s*keyof\s+typeof\s+\1\s*\]$/
  );
  return m ? m[1] : null;
}

// The string literals of a union type node, ignoring `null`/`undefined` members.
// Returns null if it isn't a union of string literals.
function stringUnionLiterals(typeNode) {
  if (!ts.isUnionTypeNode(typeNode)) return null;
  const parts = typeNode.types.filter(
    (t) =>
      !(
        t.kind === ts.SyntaxKind.UndefinedKeyword ||
        (ts.isLiteralTypeNode(t) && t.literal.kind === ts.SyntaxKind.NullKeyword)
      )
  );
  if (!parts.length) return null;
  if (!parts.every((t) => ts.isLiteralTypeNode(t) && ts.isStringLiteral(t.literal))) {
    return null;
  }
  return parts.map((t) => t.literal.text);
}

// Pull T out of `Promise<WavedashResponse<T>>`. Returns null for methods that
// don't use the response envelope (e.g. Promise<boolean> fast-path calls).
function extractResponseData(returnType) {
  const m = returnType.match(/^Promise<\s*WavedashResponse<([\s\S]+)>\s*>$/);
  if (!m) return null;
  // Trim the trailing `>` balancing for nested generics like Id<"lobbies">.
  return m[1].trim();
}
