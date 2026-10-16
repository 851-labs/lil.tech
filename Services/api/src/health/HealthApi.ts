import { Schema } from "effect";
import { HttpApiEndpoint, HttpApiGroup, HttpApiMiddleware, HttpApiSchema } from "effect/http-api";
import { Authorization } from "../auth/AuthApi.ts";
import { StorageFull } from "../store/Changes.ts";
import { UserStoreUnavailable } from "../store/UserStores.ts";
import {
  ConsentRequired,
  HealthBatch,
  HealthBatchId,
  HealthBatchNotFound,
  HealthBatchTooLarge,
} from "./HealthBatches.ts";
import {
  HealthBlob,
  HealthBlobDownload,
  HealthBlobHash,
  HealthBlobHashMismatch,
  HealthBlobNotFound,
} from "./HealthBlobs.ts";

// The health part of the API definition. Like `Api.ts`, it holds no server code.

/**
 * Refuses an upload (a batch or a blob) whose `Content-Length` is over the limit before its body
 * is read. Middleware
 * runs before HttpApi decodes the payload; the handler checks the size again for uploads without
 * a length.
 */
export class UploadSizeLimit extends HttpApiMiddleware.Service<UploadSizeLimit>()(
  "lil/api/health/UploadSizeLimit",
  { error: HealthBatchTooLarge },
) {}

export class HealthApi extends HttpApiGroup.make("health")
  .add(
    // Upload a batch file: gzip-compressed NDJSON, one mutation per line, as in
    // `POST /v1/sync/mutations` but only for health entities. Re-uploading the same batch ID
    // returns its status without queueing it again, so retries (e.g. from a background
    // `URLSession`) are safe.
    HttpApiEndpoint.put("uploadBatch", "/v1/health/batches/:id", {
      params: { id: HealthBatchId },
      payload: Schema.Uint8Array.pipe(
        HttpApiSchema.asUint8Array({ contentType: "application/gzip" }),
      ),
      success: HealthBatch.pipe(HttpApiSchema.status(202)),
      error: [HealthBatchTooLarge, StorageFull, UserStoreUnavailable, ConsentRequired],
    }).middleware(UploadSizeLimit),
  )
  .add(
    HttpApiEndpoint.get("batch", "/v1/health/batches/:id", {
      params: { id: HealthBatchId },
      success: HealthBatch,
      error: [HealthBatchNotFound, UserStoreUnavailable],
    }),
  )
  .add(
    // Upload a blob (\`src/health/HealthBlobs.ts\`), named by the SHA-256 of its bytes, before the
    // rows that refer to it. Uploading one that's stored already changes nothing, so retries are
    // safe. Same size limit as batches, and like them it needs consent and room in the quota.
    HttpApiEndpoint.put("uploadBlob", "/v1/health/blobs/:sha256", {
      params: { sha256: HealthBlobHash },
      payload: Schema.Uint8Array.pipe(
        HttpApiSchema.asUint8Array({ contentType: "application/octet-stream" }),
      ),
      success: HealthBlob,
      error: [
        HealthBatchTooLarge,
        HealthBlobHashMismatch,
        StorageFull,
        UserStoreUnavailable,
        ConsentRequired,
      ],
    }).middleware(UploadSizeLimit),
  )
  .add(
    // A short-lived URL to download one of the user's blobs.
    HttpApiEndpoint.get("blob", "/v1/health/blobs/:sha256", {
      params: { sha256: HealthBlobHash },
      success: HealthBlobDownload,
      error: [HealthBlobNotFound, UserStoreUnavailable],
    }),
  )
  .middleware(Authorization) {}
