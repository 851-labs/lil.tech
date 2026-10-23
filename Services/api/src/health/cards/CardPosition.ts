import { codePointCount } from "./CardJson.ts";
import type { CardSpecError } from "./CardSpecValidator.ts";

// Summary's order of cards: fractional indexing, David Greenspan's "Implementing Fractional
// Indexing" as the `fractional-indexing` package (3.4) implements it, with its base-62 digits
// (`docs/decisions/cards.md`, The `health_card` sync entity › Order). A port of the Swift
// `CardPosition`, checked by the shared cases in `validation-cases.json`, with its two fixes to the
// package: a key with a character that isn't a base-62 digit throws (the package computes with it
// as -1), and `count` keys between bounds given the wrong way round still ascend (the package's
// descend).
//
// A position is a string ordered by its bytes (ascending, ties by ID), and there's always one
// between two others, so a move writes the moved card alone.

/** The base-62 digits, in byte order. */
const digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const zero = "0";
const lastDigit = "z";

/** The longest position the store keeps. */
export const maxCardPositionLength = 200;

export class InvalidCardPosition extends Error {}

const fail = (message: string) => new InvalidCardPosition(message);

const isDigits = (key: string) => /^[0-9A-Za-z]*$/.test(key);

const index = (digit: string | undefined) =>
  digit === undefined ? 0 : Math.max(digits.indexOf(digit), 0);

const integerLength = (head: string): number => {
  if (head >= "a" && head <= "z") return head.charCodeAt(0) - 97 + 2;
  if (head >= "A" && head <= "Z") return 90 - head.charCodeAt(0) + 2;
  throw fail("invalid order key head");
};

const integerPart = (key: string): string => {
  if (key === "") throw fail("invalid order key");
  const length = integerLength(key[0]!);
  if (length > key.length) throw fail(`invalid order key: ${key}`);
  return key.slice(0, length);
};

const smallestInteger = `A${zero.repeat(26)}`;

const validate = (key: string) => {
  if (key === smallestInteger) throw fail(`invalid order key: ${key}`);
  const integer = integerPart(key);
  if (key.length > integer.length && key.endsWith(zero)) throw fail(`invalid order key: ${key}`);
};

const validateInteger = (integer: string) => {
  if (integer === "" || integer.length !== integerLength(integer[0]!)) {
    throw fail(`invalid integer part of order key: ${integer}`);
  }
};

const incrementInteger = (x: string): string | undefined => {
  validateInteger(x);
  const head = x[0]!;
  let trailing = "";
  for (let i = x.length - 1; i >= 1; i -= 1) {
    const d = index(x[i]) + 1;
    if (d === digits.length) {
      trailing = zero + trailing;
    } else {
      return head + x.slice(1, i) + digits[d] + trailing;
    }
  }
  if (head === "Z") return `a${zero}`;
  if (head === "z") return undefined;
  const h = String.fromCharCode(head.charCodeAt(0) + 1);
  return h + (h > "a" ? trailing + zero : trailing.slice(1));
};

const decrementInteger = (x: string): string | undefined => {
  validateInteger(x);
  const head = x[0]!;
  let trailing = "";
  for (let i = x.length - 1; i >= 1; i -= 1) {
    const d = index(x[i]) - 1;
    if (d === -1) {
      trailing = lastDigit + trailing;
    } else {
      return head + x.slice(1, i) + digits[d] + trailing;
    }
  }
  if (head === "a") return `Z${lastDigit}`;
  if (head === "A") return undefined;
  const h = String.fromCharCode(head.charCodeAt(0) - 1);
  return h + (h < "Z" ? trailing + lastDigit : trailing.slice(1));
};

const midpoint = (a: string, b: string | undefined): string => {
  if (b !== undefined && !(a < b)) throw fail(`${a} >= ${b}`);
  if (a.endsWith(zero) || b?.endsWith(zero) === true) throw fail("trailing zero");
  if (b !== undefined && b !== "") {
    let n = 0;
    while (n < b.length && (a[n] ?? zero) === b[n]) n += 1;
    if (n > 0) return b.slice(0, n) + midpoint(a.slice(n), b.slice(n));
  }
  const digitA = index(a[0]);
  const digitB = b === undefined ? digits.length : index(b[0]);
  if (digitB - digitA > 1) {
    // Math.round(0.5 * (digitA + digitB)), which rounds halves up.
    return digits[Math.floor((digitA + digitB + 1) / 2)]!;
  }
  if (b !== undefined && b.length > 1) return b[0]!;
  return digits[digitA]! + midpoint(a.slice(1), undefined);
};

const keyBetween = (a: string | undefined, b: string | undefined): string => {
  if (a === undefined) {
    if (b === undefined) return `a${zero}`;
    const ib = integerPart(b);
    const fb = b.slice(ib.length);
    if (ib === smallestInteger) return ib + midpoint("", fb);
    if (ib.length < b.length) return ib;
    const result = decrementInteger(ib);
    if (result === undefined) throw fail("cannot decrement any more");
    return result;
  }
  if (b === undefined) {
    const ia = integerPart(a);
    const fa = a.slice(ia.length);
    return incrementInteger(ia) ?? ia + midpoint(fa, undefined);
  }
  const ia = integerPart(a);
  const fa = a.slice(ia.length);
  const ib = integerPart(b);
  const fb = b.slice(ib.length);
  if (ia === ib) return ia + midpoint(fa, fb);
  const next = incrementInteger(ia);
  if (next === undefined) throw fail("cannot increment any more");
  if (next < b) return next;
  return ia + midpoint(fa, undefined);
};

/**
 * A position between `a` and `b`, either of which may be null for the start or the end:
 * `cardPositionBetween(null, null)` is `a0`, the first card's. `a` and `b` are swapped if they're
 * in the wrong order. Throws `InvalidCardPosition` if either isn't a valid position, or they're
 * equal.
 */
export const cardPositionBetween = (a: string | null, b: string | null): string => {
  for (const key of [a, b]) {
    if (key === null) continue;
    if (!isDigits(key)) throw fail(`invalid order key: ${key}`);
    validate(key);
  }
  if (a !== null && b !== null && a > b) return keyBetween(b, a);
  return keyBetween(a ?? undefined, b ?? undefined);
};

/** `count` positions between `a` and `b`, ascending, whichever way round they're given. */
export const cardPositionsBetween = (
  a: string | null,
  b: string | null,
  count: number,
): Array<string> => {
  if (a !== null && b !== null && b < a) return cardPositionsBetween(b, a, count);
  if (count <= 0) return [];
  if (count === 1) return [cardPositionBetween(a, b)];
  if (b === null) {
    let key = cardPositionBetween(a, b);
    const keys = [key];
    for (let i = 1; i < count; i += 1) {
      key = cardPositionBetween(key, b);
      keys.push(key);
    }
    return keys;
  }
  if (a === null) {
    let key = cardPositionBetween(a, b);
    const keys = [key];
    for (let i = 1; i < count; i += 1) {
      key = cardPositionBetween(a, key);
      keys.push(key);
    }
    return keys.reverse();
  }
  const middle = Math.floor(count / 2);
  const key = cardPositionBetween(a, b);
  return [
    ...cardPositionsBetween(a, key, middle),
    key,
    ...cardPositionsBetween(key, b, count - middle - 1),
  ];
};

/**
 * Why a stored position is wrong, or undefined when it's fine: 1 to 200 characters, base-62
 * digits, and a key the algorithm can place others around.
 */
export const cardPositionError = (position: string): CardSpecError | undefined => {
  const length = codePointCount(position);
  if (length < 1 || length > maxCardPositionLength) {
    return {
      path: "position",
      code: "positionLength",
      message: "position must be 1 to 200 characters.",
    };
  }
  try {
    if (!isDigits(position)) throw fail("");
    validate(position);
    return undefined;
  } catch {
    return {
      path: "position",
      code: "invalidPosition",
      message:
        `position ${JSON.stringify(position)} isn't a fractional index: base-62 digits, ` +
        "starting with a letter that gives the length of its integer part.",
    };
  }
};
