import { assert, describe, it } from "@effect/vitest";
import { Effect } from "effect";
import { TestClock } from "effect/testing";
import {
  documentPageEnd,
  documentText,
  healthDocument,
  healthDocuments,
} from "../../../src/health/tools/HealthDocuments.ts";
import { healthMcpResultCeiling } from "../../../src/health/tools/HealthMcpServer.ts";
import {
  healthDocumentPageLimit,
  healthDocumentsLimit,
} from "../../../src/health/tools/HealthToolkit.ts";
import type { HealthBlobReader } from "../../../src/health/tools/WorkoutRoutes.ts";
import { storeWithBatches } from "../HealthConformance.ts";

// Synthetic data only (AGENTS.md). The conformance cases (`conformance/cases.json`) check what the
// document tools read on both servers; this checks their caps and sizes, which a case would need
// documents of hundreds of kilobytes for, and the XML's decoding at its edges.

const start = Date.parse("2026-09-01T06:00:00Z");
const documentId = (index: number) => `0c0f0000-0000-4000-8000-${String(index).padStart(12, "0")}`;
const sha256 = "d0".repeat(32);

const document = (index: number, startDate = start) => ({
  entity: "health_document",
  op: "upsert",
  id: documentId(index),
  row: {
    startDate,
    endDate: startDate,
    title: "Visit Summary",
    patientName: "Jane Example",
    authorName: "Dr. Sam Placeholder",
    custodianName: "Synthetic Health Clinic",
    xml: sha256,
    sourceName: "Synthetic Clinic",
    sourceBundleId: "com.example.clinic",
  },
});

const batch = (lines: ReadonlyArray<unknown>) => ({
  device: "dev_00000000000000000000000ph1",
  receivedAt: "2026-09-30T12:00:00Z",
  lines,
});

const blobs =
  (bytes: Uint8Array): HealthBlobReader =>
  (hash) =>
    Effect.succeed(hash === sha256 ? bytes : null);

const size = (result: unknown) => new TextEncoder().encode(JSON.stringify(result)).length;

describe("Health Documents", () => {
  it.effect("give a page of characters at their longest as JSON in under the ceiling", () =>
    Effect.gen(function* () {
      // U+0001 is escaped as \u0001, six bytes: XML can't have it, but a document's bytes can.
      const bytes = new TextEncoder().encode("\u0001".repeat(healthDocumentPageLimit * 2 + 10));
      const sql = yield* storeWithBatches([batch([document(1)])]);
      const result = yield* healthDocument(sql, blobs(bytes), { id: documentId(1) });
      assert.strictEqual(result.xml.length, healthDocumentPageLimit);
      assert.strictEqual(result.length, healthDocumentPageLimit * 2 + 10);
      assert.strictEqual(result.nextCursor, String(healthDocumentPageLimit));
      // 235 KB of 256.
      assert.isBelow(size(result), healthMcpResultCeiling);
      const last = yield* healthDocument(sql, blobs(bytes), {
        id: documentId(1),
        cursor: String(healthDocumentPageLimit * 2),
      });
      assert.strictEqual(last.xml.length, 10);
      assert.isNull(last.nextCursor);
    }),
  );

  it.effect("say when a document's XML isn't on the server", () =>
    Effect.gen(function* () {
      const sql = yield* storeWithBatches([batch([document(1)])]);
      const error = yield* Effect.flip(
        healthDocument(sql, () => Effect.succeed(null), { id: documentId(1) }),
      );
      assert.strictEqual(error.message, "The document's XML isn't on the server. Try again later.");
    }),
  );

  it.effect(`list at most ${healthDocumentsLimit} documents, and count them all`, () =>
    Effect.gen(function* () {
      const lines = Array.from({ length: 150 }, (_, index) =>
        document(index + 1, start + index * 3_600_000),
      );
      const sql = yield* storeWithBatches([batch(lines)]);
      yield* TestClock.setTime(Date.parse("2026-09-30T12:00:00Z"));
      const result = yield* healthDocuments(sql, { range: "M" });
      assert.strictEqual(result.count, 150);
      assert.strictEqual(result.documents.length, healthDocumentsLimit);
      assert.strictEqual(result.documents[0]!.id, documentId(150));
      assert.isBelow(size(result), healthMcpResultCeiling / 4);
    }),
  );

  it("never end a page between a surrogate pair's halves", () => {
    const text = "ab😀cd";
    assert.strictEqual(documentPageEnd(text, 0, 3), 2);
    assert.strictEqual(documentPageEnd(text, 2, 1), 4);
    assert.strictEqual(documentPageEnd(text, 0, 4), 4);
    assert.strictEqual(documentPageEnd(text, 4, 10), 6);
  });

  it("decode the XML as its byte order mark or declaration says, else as UTF-8", () => {
    const bytes = (...values: Array<number>) => new Uint8Array(values);
    const ascii = (text: string) => Array.from(new TextEncoder().encode(text));
    // A declaration's name in any case, in double or single quotes.
    const declared = (name: string, ...body: Array<number>) =>
      bytes(...ascii(`<?xml version="1.0" encoding='${name}'?><a>`), ...body);
    assert.strictEqual(
      documentText(declared("Latin1", 0xe9, 0x80)),
      `<?xml version="1.0" encoding='Latin1'?><a>é\u0080`,
    );
    assert.strictEqual(documentText(declared("US-ASCII", 0xe9)).at(-1), "é");
    assert.strictEqual(documentText(declared("CP1252", 0x80, 0x9f, 0x8d)).slice(-3), "€Ÿ\u008d");
    // An encoding it doesn't read is UTF-8.
    assert.strictEqual(documentText(declared("Shift_JIS", 0xe9)).at(-1), "�");
    // UTF-16 without a byte order mark, little-endian.
    assert.strictEqual(documentText(bytes(0x3c, 0x00, 0x3f, 0x00, 0x3d, 0xd8, 0x00, 0xde)), "<?😀");
    // A byte order mark after the first is kept, as text.
    assert.strictEqual(documentText(bytes(0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf, 0x41)), "﻿A");
  });
});
