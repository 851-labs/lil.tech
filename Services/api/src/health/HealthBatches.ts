import { Schema } from "effect";

// Health batch uploads' wire types and errors, shared by the API definition, the store and the
// ingestion consumer. Responses only grow, so `status` is a string.

/** A client-generated batch ID: a lowercase UUID. Re-uploading the same ID is a no-op. */
export const HealthBatchId = Schema.String.check(
  Schema.isPattern(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/),
);

export const RejectedLine = Schema.Struct({
  /** 1-based line number in the batch file. */
  line: Schema.Int,
  message: Schema.String,
}).annotate({ identifier: "lil/api/health/RejectedLine" });
export type RejectedLine = typeof RejectedLine.Type;

export const HealthBatch = Schema.Struct({
  id: Schema.String,
  /**
   * `queued`, `applying`, `applied` or `failed`. A failed batch won't be retried: the client
   * re-reads its data and uploads it as a new batch.
   */
  status: Schema.String,
  /** Unix milliseconds. */
  receivedAt: Schema.Int,
  finishedAt: Schema.optionalKey(Schema.Int),
  /** Non-empty lines in the file. */
  lines: Schema.optionalKey(Schema.Int),
  /** Lines applied, including ones that changed nothing. */
  applied: Schema.optionalKey(Schema.Int),
  /** Lines rejected as invalid. They'll never apply; the rest of the batch did. */
  rejected: Schema.optionalKey(Schema.Int),
  /** The first 100 rejected lines and why. */
  rejectedLines: Schema.optionalKey(Schema.Array(RejectedLine)),
  /** Why a failed batch failed. */
  failure: Schema.optionalKey(Schema.String),
}).annotate({ identifier: "lil/api/health/HealthBatch", description: "An uploaded health batch" });
export type HealthBatch = typeof HealthBatch.Type;

export class HealthBatchNotFound extends Schema.TaggedError<HealthBatchNotFound>()(
  "HealthBatchNotFound",
  { id: Schema.String },
  { httpApiStatus: 404 },
) {}

export class HealthBatchTooLarge extends Schema.TaggedError<HealthBatchTooLarge>()(
  "HealthBatchTooLarge",
  { maxBytes: Schema.Int },
  { httpApiStatus: 413 },
) {}

/**
 * Uploading Health data needs the user's consent to the current privacy policy version
 * (`GET /v1/me/consents/health`), which they haven't given.
 */
export class ConsentRequired extends Schema.TaggedError<ConsentRequired>()(
  "ConsentRequired",
  { required: Schema.String },
  { httpApiStatus: 403 },
) {}

/** The largest batch file accepted, compressed. */
export const maxHealthBatchBytes = 16 * 1024 * 1024;
