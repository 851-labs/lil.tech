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
 *
 * The Swift generator skips `{ "type": "null" }`, so it would drop a nullable property entirely.
 * Nullable schemas are rewritten from `anyOf: [{ type: X }, { type: "null" }]` to OpenAPI 3.1's
 * `type: [X, "null"]`, which it generates as an optional. Nullable shapes it can't express that
 * way fail generation.
 *
 * Operation IDs of grouped endpoints (`auth.refresh`) become camel case (`authRefresh`), which
 * generated clients use as method names.
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
  return normalize(spec);
};

const isNullSchema = (schema: unknown) =>
  typeof schema === "object" &&
  schema !== null &&
  Object.keys(schema).length === 1 &&
  (schema as { type?: unknown }).type === "null";

const normalize = <A>(value: A): A => {
  if (Array.isArray(value)) return value.map(normalize) as A;
  if (value === null || typeof value !== "object") return value;
  const object = Object.fromEntries(
    Object.entries(value)
      .filter(([key, child]) => !(key === "additionalProperties" && child === false))
      .map(([key, child]) => [key, normalize(child)]),
  );

  const anyOf = object["anyOf"];
  if (Array.isArray(anyOf) && anyOf.some(isNullSchema)) {
    const [schema, ...rest] = anyOf.filter((option) => !isNullSchema(option)) as Array<unknown>;
    const type = (schema as { type?: unknown } | undefined)?.type;
    if (rest.length > 0 || typeof type !== "string") {
      throw new Error(`Unsupported nullable schema: ${JSON.stringify(object)}`);
    }
    const { anyOf: _, ...others } = object;
    return { ...others, ...(schema as object), type: [type, "null"] } as A;
  }

  const operationId = object["operationId"];
  if (typeof operationId === "string" && operationId.includes(".")) {
    object["operationId"] = operationId.replace(/\.(\w)/g, (_, letter: string) =>
      letter.toUpperCase(),
    );
  }
  return object as A;
};
