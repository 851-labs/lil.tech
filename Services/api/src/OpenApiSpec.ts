import { type HttpApi, type HttpApiGroup, OpenApi } from "effect/http-api";
import { Api } from "./Api.ts";

/**
 * Generates the API's OpenAPI spec, which `scripts/openapi.ts` commits as `openapi.json`.
 *
 * Schemas are named by the last segment of their identifier, without Effect's `Encoded` suffix
 * (`lil/api/Status` becomes `Status`), so generated clients get clean type names. Two schemas
 * that would get the same name fail generation instead of being renamed silently, because
 * renaming would change generated client types.
 */
export const makeOpenApiSpec = <Id extends string, Groups extends HttpApiGroup.Constraint>(
  api: HttpApi.HttpApi<Id, Groups> = Api as unknown as HttpApi.HttpApi<Id, Groups>,
) => {
  const owners = new Map<string, string>();
  return OpenApi.fromApi(api, {
    referencePolicy: ({ identifier }) => {
      if (identifier === undefined) return undefined;
      const source = identifier.replace(/Encoded$/, "");
      const name = source.split("/").at(-1) ?? source;
      const owner = owners.get(name);
      if (owner !== undefined && owner !== source) {
        throw new Error(`OpenAPI schema name "${name}" is used by both ${owner} and ${source}`);
      }
      owners.set(name, source);
      return name;
    },
  });
};
