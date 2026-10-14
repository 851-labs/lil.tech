import { Schema } from "effect";
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema } from "effect/http-api";
import { Authorization } from "../auth/AuthApi.ts";
import { UserStoreUnavailable } from "../store/UserStores.ts";
import {
  HealthBatch,
  HealthBatchId,
  HealthBatchNotFound,
  HealthBatchTooLarge,
} from "./HealthBatches.ts";

// The health part of the API definition. Like `Api.ts`, it holds no server code.

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
      error: [HealthBatchTooLarge, UserStoreUnavailable],
    }),
  )
  .add(
    HttpApiEndpoint.get("batch", "/v1/health/batches/:id", {
      params: { id: HealthBatchId },
      success: HealthBatch,
      error: [HealthBatchNotFound, UserStoreUnavailable],
    }),
  )
  .middleware(Authorization) {}
