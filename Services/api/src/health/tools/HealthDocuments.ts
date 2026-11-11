import { Clock, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import {
  HealthToolError,
  type HealthToolkit,
  healthDocumentPageLimit,
  healthDocumentsLimit,
} from "./HealthToolkit.ts";
import { RecordedZones } from "./RecordedTimes.ts";
import { jsonObject } from "./SampleDetails.ts";
import { localTime, type ToolRange, toolPeriod, toolTimeZone } from "./ToolTime.ts";
import { cursorIndex, type HealthBlobReader } from "./WorkoutRoutes.ts";

// The Health Documents tools (851-4163): `health_documents` lists documents from their rows, in
// the words of the Mac's Health Documents page (`HealthDocumentsView.swift`), and
// `health_document` reads one document's CDA XML from its blob, a page of characters at a time,
// as the privacy policy says (851-4157). The Mac's `HealthTools` does the same
// (`HealthDocuments.swift`), rule for rule.

type DocumentsResult = (typeof HealthToolkit.tools.health_documents.successSchema)["Type"];
type DocumentResult = (typeof HealthToolkit.tools.health_document.successSchema)["Type"];

/** A document as stored (`health_document`). */
interface DocumentRow {
  readonly id: string;
  readonly startDate: number;
  readonly endDate: number;
  readonly title: string;
  readonly patientName: string;
  readonly authorName: string;
  readonly custodianName: string;
  /** The XML blob's SHA-256. */
  readonly xml: string;
  readonly sourceName: string;
  readonly metadata: string | null;
}

const documentColumns = `id, start_date, end_date, title, patient_name, author_name,
  custodian_name, xml, source_name, metadata`;

const documentRow = (row: Record<string, unknown>): DocumentRow => ({
  id: row["id"] as string,
  startDate: Number(row["start_date"]),
  endDate: Number(row["end_date"]),
  title: row["title"] as string,
  patientName: row["patient_name"] as string,
  authorName: row["author_name"] as string,
  custodianName: row["custodian_name"] as string,
  xml: row["xml"] as string,
  sourceName: row["source_name"] as string,
  metadata: (row["metadata"] as string | null) ?? null,
});

/**
 * Foundation's `whitespacesAndNewlines`, which the Mac's page trims names with, every scalar of it:
 * Unicode's spaces (Zs), tab, the newlines (U+000A to U+000D, U+0085, U+2028, U+2029) and U+200B.
 * Not JavaScript's `trim`, which also trims U+FEFF, and leaves U+0085 and U+200B.
 */
const whitespace =
  "\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200b\\u2028\\u2029\\u202f\\u205f\\u3000";
const edges = new RegExp(`^[${whitespace}]+|[${whitespace}]+$`, "g");

/** A name without the whitespace around it, or null if that's all it is, as the page shows it. */
const shownName = (name: string): string | null => {
  const trimmed = name.replace(edges, "");
  return trimmed === "" ? null : trimmed;
};

/** Its title, or Health Document without one, as the Mac's `HealthDocument.displayTitle`. */
const displayTitle = (document: DocumentRow) => shownName(document.title) ?? "Health Document";

/**
 * The `health_documents` tool from the user's store: the documents that start in the period,
 * newest first, at most `healthDocumentsLimit`, with how many there are, counted only when they
 * don't all fit.
 */
export const healthDocuments = Effect.fn("healthDocuments")(function* (
  sql: StoreSql,
  input: {
    readonly range: ToolRange;
    readonly date?: string | undefined;
    readonly timeZone?: string | undefined;
  },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const now = yield* Clock.currentTimeMillis;
  const period = yield* toolPeriod(input.range, input.date, now, zone);
  const where = "start_date >= ? AND start_date < ?";
  const documents = sql
    .exec(
      `SELECT ${documentColumns} FROM health_document WHERE ${where}
      ORDER BY start_date DESC, id DESC LIMIT ?`,
      period.start,
      period.end,
      healthDocumentsLimit,
    )
    .map(documentRow);
  const count =
    documents.length < healthDocumentsLimit
      ? documents.length
      : Number(
          sql.exec(
            `SELECT count(*) AS count FROM health_document WHERE ${where}`,
            period.start,
            period.end,
          )[0]?.["count"] ?? 0,
        );
  const zones = new RecordedZones();
  const result: DocumentsResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    count,
    documents: documents.map((document) => ({
      id: document.id,
      title: displayTitle(document),
      patient: shownName(document.patientName),
      author: shownName(document.authorName),
      custodian: shownName(document.custodianName),
      start: localTime(document.startDate, zone),
      end: localTime(document.endDate, zone),
      ...zones.times(jsonObject(document.metadata), document.startDate, document.endDate),
      source: document.sourceName,
    })),
  };
  return result;
});

// -------------------------------------------------------------------------------------------------
// The XML as text
// -------------------------------------------------------------------------------------------------

const isHighSurrogate = (unit: number) => unit >= 0xd800 && unit <= 0xdbff;
const isLowSurrogate = (unit: number) => unit >= 0xdc00 && unit <= 0xdfff;

/** windows-1252's characters for 0x80 to 0x9F, WHATWG's: the five it leaves out are C1 controls. */
const windows1252 = [
  0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, 0x2c6, 0x2030, 0x160, 0x2039, 0x152,
  0x8d, 0x17d, 0x8f, 0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x2dc, 0x2122,
  0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178,
];

/** ISO-8859-1's names (IANA's, with its aliases), and US-ASCII's, read as ISO-8859-1. */
const latin1Names = new Set([
  "iso-8859-1",
  "iso_8859-1",
  "iso_8859-1:1987",
  "iso-ir-100",
  "latin1",
  "l1",
  "ibm819",
  "cp819",
  "csisolatin1",
  "us-ascii",
  "ascii",
  "iso646-us",
  "us",
  "csascii",
]);
const windows1252Names = new Set(["windows-1252", "cp1252", "cswindows1252"]);

type DocumentEncoding = "utf-8" | "utf-16le" | "utf-16be" | "latin1" | "windows-1252";

/**
 * The single-byte encoding an XML declaration names (`<?xml version="1.0"
 * encoding="ISO-8859-1"?>`) in the XML's first 200 bytes, or UTF-8 for any other, or none. Read
 * from the bytes, each a character (the declaration is ASCII), as the Mac reads it.
 */
const declaredEncoding = (bytes: Uint8Array): DocumentEncoding => {
  const head = String.fromCharCode(...bytes.subarray(0, 200));
  const end = head.indexOf("?>");
  if (!head.startsWith("<?xml") || end === -1) return "utf-8";
  const match = /encoding[ \t\r\n]*=[ \t\r\n]*["']([A-Za-z0-9._:-]+)["']/.exec(head.slice(0, end));
  const encoding = match?.[1]?.toLowerCase();
  if (encoding === undefined) return "utf-8";
  if (latin1Names.has(encoding)) return "latin1";
  return windows1252Names.has(encoding) ? "windows-1252" : "utf-8";
};

/** Code units as a string, a chunk at a time: one call per unit is slow, one for all too deep. */
const unitsText = (units: Uint16Array) => {
  let text = "";
  for (let start = 0; start < units.length; start += 8192) {
    text += String.fromCharCode(...units.subarray(start, start + 8192));
  }
  return text;
};

/** UTF-16 code units as text, a lone surrogate (or an odd last byte) as U+FFFD. */
const utf16Text = (bytes: Uint8Array, littleEndian: boolean) => {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const odd = bytes.byteLength % 2;
  const units = new Uint16Array(Math.floor(bytes.byteLength / 2) + odd);
  for (let index = 0; index < units.length - odd; index++) {
    units[index] = view.getUint16(index * 2, littleEndian);
  }
  if (odd === 1) units[units.length - 1] = 0xfffd;
  for (let index = 0; index < units.length; index++) {
    const unit = units[index]!;
    if (isHighSurrogate(unit) && isLowSurrogate(units[index + 1] ?? 0)) {
      index += 1;
    } else if (isHighSurrogate(unit) || isLowSurrogate(unit)) {
      units[index] = 0xfffd;
    }
  }
  return unitsText(units);
};

/** Bytes as single-byte text: ISO-8859-1's (each byte its code point), or windows-1252's. */
const singleByteText = (bytes: Uint8Array, encoding: "latin1" | "windows-1252") =>
  unitsText(
    Uint16Array.from(bytes, (byte) =>
      encoding === "windows-1252" && byte >= 0x80 && byte <= 0x9f
        ? windows1252[byte - 0x80]!
        : byte,
    ),
  );

/**
 * A document's XML as text, as the Mac's `HealthTools.documentText` reads it: by its byte order
 * mark (left out), else as UTF-16 if it starts `<?` in UTF-16, else by its XML declaration
 * (ISO-8859-1 and US-ASCII as ISO-8859-1, and windows-1252), else as UTF-8, bytes UTF-8 can't
 * read as U+FFFD.
 */
export const documentText = (bytes: Uint8Array): string => {
  const startsWith = (...prefix: Array<number>) => prefix.every((byte, i) => bytes[i] === byte);
  if (startsWith(0xef, 0xbb, 0xbf)) {
    return new TextDecoder("utf-8", { ignoreBOM: true }).decode(bytes.subarray(3));
  }
  if (startsWith(0xff, 0xfe)) return utf16Text(bytes.subarray(2), true);
  if (startsWith(0xfe, 0xff)) return utf16Text(bytes.subarray(2), false);
  if (startsWith(0x3c, 0x00, 0x3f, 0x00)) return utf16Text(bytes, true);
  if (startsWith(0x00, 0x3c, 0x00, 0x3f)) return utf16Text(bytes, false);
  const encoding = declaredEncoding(bytes);
  return encoding === "latin1" || encoding === "windows-1252"
    ? singleByteText(bytes, encoding)
    : new TextDecoder("utf-8", { ignoreBOM: true }).decode(bytes);
};

/**
 * Where a page of `limit` characters from `start` ends in `text`: never between a surrogate pair's
 * halves, so before the pair, or after it when the page would otherwise be empty.
 */
export const documentPageEnd = (text: string, start: number, limit: number) => {
  const end = Math.min(start + limit, text.length);
  if (end === text.length || !isLowSurrogate(text.charCodeAt(end))) return end;
  if (!isHighSurrogate(text.charCodeAt(end - 1))) return end;
  return end - 1 > start ? end - 1 : end + 1;
};

/**
 * The `health_document` tool from the user's store: a page of a document's XML, as text, `limit`
 * characters (UTF-16 code units) from the cursor, which is where the page starts.
 */
export const healthDocument = Effect.fn("healthDocument")(function* (
  sql: StoreSql,
  blobs: HealthBlobReader,
  input: {
    readonly id: string;
    readonly timeZone?: string | undefined;
    readonly cursor?: string | undefined;
    readonly limit?: number | undefined;
  },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  // The input schema checks it, as the Mac does for callers that don't go through one.
  const limit = input.limit ?? healthDocumentPageLimit;
  if (!Number.isInteger(limit) || limit < 1 || limit > healthDocumentPageLimit) {
    return yield* new HealthToolError({
      message: `The limit must be from 1 to ${healthDocumentPageLimit}.`,
    });
  }
  const invalidCursor = new HealthToolError({
    message: `Invalid cursor: ${input.cursor}. Pass the previous page's nextCursor.`,
  });
  // Checked before the XML is read, as on the Mac, which may have to download it.
  const start = input.cursor === undefined ? 0 : cursorIndex(input.cursor);
  if (start === null) return yield* invalidCursor;
  const document = sql
    .exec(`SELECT ${documentColumns} FROM health_document WHERE id = ?`, input.id)
    .map(documentRow)[0];
  if (document === undefined) {
    return yield* new HealthToolError({
      message: `No Health Document with ID ${input.id}. health_documents lists them, with their IDs.`,
    });
  }
  const bytes = yield* blobs(document.xml, "the document's XML");
  if (bytes === null) {
    return yield* new HealthToolError({
      message: "The document's XML isn't on the server. Try again later.",
    });
  }
  const text = documentText(bytes);
  // Past the end, or between a surrogate pair's halves, isn't where a page starts.
  if (
    start > text.length ||
    (start > 0 &&
      isLowSurrogate(text.charCodeAt(start)) &&
      isHighSurrogate(text.charCodeAt(start - 1)))
  ) {
    return yield* invalidCursor;
  }
  const end = documentPageEnd(text, start, limit);
  const result: DocumentResult = {
    timeZone: name,
    id: document.id,
    title: displayTitle(document),
    start: localTime(document.startDate, zone),
    length: text.length,
    offset: start,
    xml: text.slice(start, end),
    nextCursor: end < text.length ? String(end) : null,
  };
  return result;
});
