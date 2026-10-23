import type { Schema } from "effect";

// Card specs as JSON values, written and compared as the Swift `CardJSON` writes and compares them
// (`docs/decisions/cards.md`, Versioning and the canonical form), so the server's messages and
// sizes are the apps' word for word and byte for byte.

export type Json = Schema.Json;
export type JsonObject = { readonly [key: string]: Json };

/** Whether a value is a JSON object (not an array or null). */
export const isJsonObject = (value: Json | undefined): value is JsonObject =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** An object's own member, or undefined: never one of `Object.prototype`'s. */
export const member = (object: JsonObject, key: string): Json | undefined =>
  Object.hasOwn(object, key) ? object[key] : undefined;

/** A string as JSON, as messages quote values: `"crimson"`. */
export const quoted = (text: string) => JSON.stringify(text);

/**
 * A value as compact JSON, for messages that show what was given (`(it's 12)`). Object keys are
 * sorted by UTF-16 code units, as Swift has them after parsing.
 */
export const jsonText = (value: Json): string =>
  JSON.stringify(value, (_, nested: unknown) =>
    nested !== null && typeof nested === "object" && !Array.isArray(nested)
      ? Object.fromEntries(Object.entries(nested).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
      : nested,
  );

/** The size of a value's compact JSON in bytes of UTF-8, as a spec's size is measured. */
export const jsonBytes = (value: Json) => new TextEncoder().encode(JSON.stringify(value)).length;

/**
 * Whether two values mean the same JSON: objects by their members, whatever their keys' order,
 * and numbers by value, as the store compares a spec with its canonical form.
 */
export const sameJson = (a: Json, b: Json): boolean => {
  if (a === b) return true;
  if (Array.isArray(a)) {
    return (
      Array.isArray(b) &&
      a.length === b.length &&
      a.every((value, index) => sameJson(value, b[index]!))
    );
  }
  if (isJsonObject(a) && isJsonObject(b)) {
    const keys = Object.keys(a);
    return (
      keys.length === Object.keys(b).length &&
      keys.every((key) => Object.hasOwn(b, key) && sameJson(a[key]!, b[key]!))
    );
  }
  return false;
};

/**
 * A string's Unicode code points, as names', labels' and filter values' lengths count them: not
 * grapheme clusters or UTF-16 units, which Swift and JavaScript would count differently.
 */
export const codePoints = (text: string): Array<string> => Array.from(text);

/** How many Unicode code points a string has. */
export const codePointCount = (text: string) => codePoints(text).length;
