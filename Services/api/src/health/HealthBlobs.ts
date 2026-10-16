import { Context, Effect, type Option, Schema } from "effect";
import type { UserId } from "../core/Ids.ts";
import type { OpenedPart, PartRange } from "../sync/SnapshotParts.ts";
import type { BatchFilesUnavailable } from "./HealthIngestion.ts";

// Health payloads too big for sync rows (ECG voltages, workout routes, heartbeat series) are
// uploaded as blobs, and rows refer to them by their SHA-256 (`docs/SYNC.md`). A blob's key is
// its user and its hash, so blobs are immutable and only their owner can reach them.

/** A blob's SHA-256, as lowercase hex: its name. */
export const HealthBlobHash = Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/));

/** Where a user's blob is in R2. */
export const healthBlobKey = (userId: UserId, sha256: string) =>
  `${healthBlobPrefix(userId)}${sha256}`;

/** Every blob of a user's is under this prefix. */
export const healthBlobPrefix = (userId: UserId) => `health-blobs/${userId}/`;

export const HealthBlob = Schema.Struct({
  sha256: Schema.String,
  size: Schema.Int,
}).annotate({ identifier: "lil/api/health/HealthBlob", description: "A stored health blob" });

export const HealthBlobDownload = Schema.Struct({
  /** Streams the blob without an `Authorization` header, and supports `Range`. */
  url: Schema.String,
  /** Unix milliseconds, after which `url` stops working. */
  expiresAt: Schema.Int,
}).annotate({ identifier: "lil/api/health/HealthBlobDownload" });

export class HealthBlobNotFound extends Schema.TaggedError<HealthBlobNotFound>()(
  "HealthBlobNotFound",
  { sha256: Schema.String },
  { httpApiStatus: 404 },
) {}

/** Blobs are at most as large as batch files (`maxHealthBatchBytes`). */
export class HealthBlobTooLarge extends Schema.TaggedError<HealthBlobTooLarge>()(
  "HealthBlobTooLarge",
  { maxBytes: Schema.Int },
  { httpApiStatus: 413 },
) {}

/** The uploaded bytes don't hash to the blob's name. */
export class HealthBlobHashMismatch extends Schema.TaggedError<HealthBlobHashMismatch>()(
  "HealthBlobHashMismatch",
  { sha256: Schema.String, actual: Schema.String },
  { httpApiStatus: 400 },
) {}

/** Health blobs in R2 (built per request in the Worker). */
export class HealthBlobFiles extends Context.Service<
  HealthBlobFiles,
  {
    readonly put: (key: string, bytes: Uint8Array) => Effect.Effect<void>;
    readonly delete: (key: string) => Effect.Effect<void>;
    readonly open: (
      key: string,
      range: PartRange | undefined,
    ) => Effect.Effect<Option.Option<OpenedPart>>;
    /** Deletes every blob whose key starts with `prefix`, e.g. a deleted user's. */
    readonly deletePrefix: (prefix: string) => Effect.Effect<void, BatchFilesUnavailable>;
  }
>()("lil/api/health/HealthBlobFiles") {}

/** The SHA-256 of `bytes`, as lowercase hex. */
export const sha256Hex = (bytes: Uint8Array) =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>)).pipe(
    Effect.map((digest) =>
      Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join(""),
    ),
  );

/** Where blob download URLs point (`HealthBlobDownloadRoute`). */
export const healthBlobDownloadPath = "/v1/health/blob-downloads";
