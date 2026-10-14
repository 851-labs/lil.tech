import { Schema } from "effect";
import { OpenApi } from "effect/http-api";

/**
 * Documents an endpoint's query parameters by their decoded schemas. HttpApi describes query
 * parameters by their string encoding (e.g. a numeric pattern for an integer), which generated
 * clients would take as strings. A test checks that no query parameter is left that way.
 */
export const documentQuery = (query: Record<string, Schema.Top>) => {
  const schemas = new Map(
    Object.entries(query).map(([name, schema]) => [
      name,
      Schema.toJsonSchemaDocument(Schema.toType(schema)).schema,
    ]),
  );
  return OpenApi.annotations({
    transform: (operation) => ({
      ...operation,
      parameters: ((operation["parameters"] ?? []) as Array<Record<string, unknown>>).map(
        (parameter) => {
          const schema =
            parameter["in"] === "query" ? schemas.get(parameter["name"] as string) : undefined;
          return schema === undefined ? parameter : { ...parameter, schema };
        },
      ),
    }),
  });
};
