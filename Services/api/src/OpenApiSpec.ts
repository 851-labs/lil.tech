import { OpenApi } from "effect/http-api";
import { Api } from "./Api.ts";

/**
 * The API's OpenAPI spec, served at `/v1/openapi.json` and committed as `openapi.json`.
 *
 * Schemas are named by the last segment of their identifier, without Effect's `Encoded` suffix
 * (`lil/api/Status` becomes `Status`), so generated clients get clean type names.
 */
export const openApiSpec = OpenApi.fromApi(Api, {
  referencePolicy: ({ identifier }) =>
    identifier
      ?.split("/")
      .at(-1)
      ?.replace(/Encoded$/, ""),
});
