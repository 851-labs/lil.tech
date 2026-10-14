import { type HttpApi, type HttpApiGroup, OpenApi } from "effect/http-api";
import { Api } from "./Api.ts";

/**
 * Generates the API's OpenAPI spec, which `scripts/openapi.ts` commits as `openapi.json`.
 *
 * Schemas are named by the last segment of their identifier, without Effect's `Encoded` suffix
 * (`lil/api/Status` becomes `Status`), so generated clients get clean type names. Two schemas
 * that would get the same name fail generation instead of being renamed silently, because
 * renaming would change generated client types.
 *
 * Effect marks objects `additionalProperties: false`, but its decoders ignore unknown properties,
 * so the spec drops that: generated clients then tolerate fields added later, and an additive
 * server change doesn't break apps that are already installed.
 */
export const makeOpenApiSpec = <Id extends string, Groups extends HttpApiGroup.Constraint>(
  api: HttpApi.HttpApi<Id, Groups> = Api as unknown as HttpApi.HttpApi<Id, Groups>,
) => {
  const owners = new Map<string, string>();
  const spec = OpenApi.fromApi(api, {
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
  return allowAdditionalProperties(spec);
};

const allowAdditionalProperties = <A>(value: A): A => {
  if (Array.isArray(value)) return value.map(allowAdditionalProperties) as A;
  if (value === null || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value)
      .filter(([key, child]) => !(key === "additionalProperties" && child === false))
      .map(([key, child]) => [key, allowAdditionalProperties(child)]),
  ) as A;
};
