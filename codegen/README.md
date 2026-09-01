# Wavedash Godot SDK — type codegen

Turns the JS SDK's TypeScript declarations into typed GDScript models, so the addon hands
games real types instead of `Dictionary`.

```sh
cd codegen
npm install
npm run generate                          # install the pinned sdk-js, then generate
node generate.mjs [--input <index.d.ts>]  # generate from what is already installed
```

## Steps

1. **Read** `node_modules/@wvdsh/sdk-js/dist/index.d.ts`. `vendor/sdk-js.d.ts` wins when
   present — the escape hatch for generating against an unpublished change. While it
   exists the output matches no version a consumer can install; delete it once the change
   ships.

2. **Parse** — `parse.mjs`, an AST walk over the TypeScript compiler API, no type checker.
   Pulls out models (interfaces and object-shaped types), literal unions with their
   members resolved, each `WavedashSDK` method's parameters and return type, and object
   types whose keys are *all* computed — lookup tables, which drive the event dispatcher.

3. **Write the IR** to `generated/_ir.json`. Gitignored, deliberately dumb JSON, there to
   diff when something looks wrong.

4. **Map types** — `gdscript.mjs`. `string`/`GenericId` → `String`, `boolean` → `bool`,
   `number` → `int` or `float` per `overrides.json`, `Uint8Array` → `PackedByteArray`,
   literal unions → enums, arrays → typed arrays, `Record` and inline objects →
   `Dictionary`, anything unresolved → `Variant` with a note.

5. **Emit** `addons/wavedash/generated/WavedashTypes.gd`, the one generated file that
   ships with the addon: an inner class per model with a `from_dict()` (and a
   `list_from_data()` on each model an async call returns a list of), an enum per literal
   union (with string converters for the ones read off the wire), and `parse_event()`.
   `handwritten_types.gd` is appended.

6. **Check.** A `number` field with no `overrides.json` entry fails the run, and so does an
   entry matching no emitted field. Convex-derived aliases
   (`FunctionReturnType<typeof api.sdk…>`) need `@wvdsh/api` installed to resolve; without
   it they stay `Variant`/`Dictionary` and the run reports how many.

## Files

| File | Role |
|---|---|
| `generate.mjs` | orchestrator: read → parse → IR → emit |
| `parse.mjs` | `.d.ts` → IR, syntactic |
| `gdscript.mjs` | type-mapping rules and the emitter |
| `overrides.json` | int-vs-float per `number` field, exhaustive both ways |
| `handwritten_types.gd` | types with no sdk-js declaration |
