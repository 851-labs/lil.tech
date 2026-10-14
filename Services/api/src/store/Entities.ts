import { Result, Schema } from "effect";
import type { SqlValue } from "./StoreSql.ts";

/** How a field is stored in its entity's table. */
export interface Column {
  readonly type: "text" | "integer" | "real" | "boolean" | "json";
  readonly nullable: boolean;
}

export const Column = {
  text: { type: "text", nullable: false },
  integer: { type: "integer", nullable: false },
  real: { type: "real", nullable: false },
  boolean: { type: "boolean", nullable: false },
  /** Any JSON value, stored as text with sorted keys. */
  json: { type: "json", nullable: false },
  nullable: <C extends Column>(column: C) => ({ ...column, nullable: true }) as const,
} as const;

const sqlTypes = {
  text: "TEXT",
  integer: "INTEGER",
  real: "REAL",
  boolean: "INTEGER",
  json: "TEXT",
} as const;

const NonNullJson = Schema.Json.check(
  Schema.makeFilter((value) => value !== null || "Expected a value other than null"),
);

const fieldSchemas = {
  text: Schema.String,
  integer: Schema.Int,
  real: Schema.Finite,
  boolean: Schema.Boolean,
  json: NonNullJson,
} as const;

/** A record as it travels in the change log: JSON with `id` and `camelCase` fields. */
export type EntityRow = { readonly id: string } & { readonly [field: string]: Schema.Json };

/** `health_sample` → `HealthSample`. */
const schemaName = (entity: string) =>
  entity.replace(/(?:^|_)([a-z0-9])/g, (_, letter: string) => letter.toUpperCase());

/** `startDate` → `start_date`. */
export const columnName = (field: string) =>
  field.replace(/[A-Z]/g, (letter) => `_${letter.toLowerCase()}`);

/**
 * A kind of record with its own table in the store (`docs/SYNC.md`). Its table has an `id` column
 * and one `snake_case` column per field.
 */
export interface Entity {
  readonly name: string;
  /** Whether apps may write it with `POST /v1/sync/mutations`. */
  readonly clientWritable: boolean;
  /** The fields besides `id`, in table order, with their columns' names. */
  readonly fields: ReadonlyArray<{
    readonly field: string;
    readonly column: string;
    readonly type: Column;
  }>;
  /**
   * A whole record as the change log carries it: `id` and every field, `null` where unset.
   * Published in OpenAPI, named after the entity (`health_sample` → `HealthSample`).
   */
  readonly rowSchema: Schema.Top;
  /** Decodes the fields an upsert sets. Any may be missing, since upserts merge. */
  readonly decodeFields: (
    row: unknown,
  ) => Result.Result<Readonly<Record<string, Schema.Json>>, Schema.SchemaError>;
  /** The statements `applyMutations` runs, built once. */
  readonly statements: {
    readonly select: string;
    readonly upsert: string;
    readonly delete: string;
  };
}

/**
 * Defines an entity. Field names are lower camel case (`startDate`, not `HRV`) so that each maps
 * to its own `snake_case` column, and `id` is implicit.
 */
export const defineEntity = (
  name: string,
  options: { readonly clientWritable: boolean; readonly fields: Record<string, Column> },
): Entity => {
  if (!/^[a-z][a-z0-9_]*$/.test(name)) throw new Error(`Invalid entity name: ${name}`);
  const fields = Object.entries(options.fields).map(([field, type]) => {
    if (!/^[a-z][a-z0-9]*(?:[A-Z][a-z0-9]+)*$/.test(field) || field === "id") {
      throw new Error(`Invalid field name in ${name}: ${field}`);
    }
    return { field, column: columnName(field), type };
  });
  const columns = fields.map(({ column }) => `"${column}"`);
  const fieldSchema = (type: Column) => {
    const schema = fieldSchemas[type.type];
    return type.nullable ? Schema.NullOr(schema) : schema;
  };
  const fieldsSchema = Schema.Struct(
    Object.fromEntries(
      fields.map(({ field, type }) => [field, Schema.optionalKey(fieldSchema(type))]),
    ),
  );
  return {
    name,
    clientWritable: options.clientWritable,
    fields,
    rowSchema: Schema.Struct({
      id: Schema.String,
      ...Object.fromEntries(fields.map(({ field, type }) => [field, fieldSchema(type)])),
    }).annotate({ identifier: `lil/api/sync/${schemaName(name)}` }),
    decodeFields: Schema.decodeUnknownResult(fieldsSchema) as Entity["decodeFields"],
    statements: {
      select: `SELECT ${["id", ...columns].join(", ")} FROM "${name}" WHERE id = ?`,
      upsert: `INSERT INTO "${name}" (${["id", ...columns].join(", ")})
        VALUES (${["?", ...columns.map(() => "?")].join(", ")})
        ON CONFLICT (id) DO UPDATE SET ${columns.map((column) => `${column} = excluded.${column}`).join(", ")}`,
      delete: `DELETE FROM "${name}" WHERE id = ? RETURNING id`,
    },
  };
};

/** The `CREATE TABLE` statement for an entity's first migration. */
export const createEntityTable = (entity: Entity) => {
  const columns = entity.fields.map(
    ({ column, type }) => `"${column}" ${sqlTypes[type.type]}${type.nullable ? "" : " NOT NULL"}`,
  );
  return `CREATE TABLE "${entity.name}" (id TEXT PRIMARY KEY, ${columns.join(", ")}) STRICT;`;
};

/** JSON with object keys sorted, so equal values are stored identically. */
const canonicalJson = (value: Schema.Json): string =>
  JSON.stringify(value, (_, nested: unknown) =>
    nested !== null && typeof nested === "object" && !Array.isArray(nested)
      ? Object.fromEntries(Object.entries(nested).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
      : nested,
  );

/** A field's value as stored in its column. */
export const toColumnValue = (type: Column, value: Schema.Json): SqlValue => {
  if (value === null) return null;
  if (type.type === "boolean") return value === true ? 1 : 0;
  if (type.type === "json") return canonicalJson(value);
  return value as SqlValue;
};

/** A column's value as the field's JSON value. */
export const fromColumnValue = (type: Column, value: SqlValue | undefined): Schema.Json => {
  if (value === null || value === undefined) return null;
  if (type.type === "boolean") return value === 1;
  if (type.type === "json") return JSON.parse(value as string) as Schema.Json;
  return value as Schema.Json;
};
