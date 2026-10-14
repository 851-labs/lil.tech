import { Schema } from "effect";
import type { SqlRow, SqlValue } from "./StoreSql.ts";

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
  /** Any JSON value, stored as text. */
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

const fieldSchemas = {
  text: Schema.String,
  integer: Schema.Int,
  real: Schema.Finite,
  boolean: Schema.Boolean,
  json: Schema.Json,
} as const;

/** A record as it travels in the change log and the API: JSON with `camelCase` fields. */
export type EntityRow = { readonly id: string } & { readonly [field: string]: Schema.Json };

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
  /** The fields besides `id`, in table order. */
  readonly fields: Readonly<Record<string, Column>>;
  /** Decodes a row from the wire. */
  readonly row: Schema.Decoder<EntityRow>;
}

export const defineEntity = (
  name: string,
  options: { readonly clientWritable: boolean; readonly fields: Record<string, Column> },
): Entity => {
  if (!/^[a-z][a-z0-9_]*$/.test(name)) throw new Error(`Invalid entity name: ${name}`);
  return {
    name,
    clientWritable: options.clientWritable,
    fields: options.fields,
    row: Schema.Struct({
      id: Schema.NonEmptyString,
      ...Object.fromEntries(
        Object.entries(options.fields).map(([field, column]) => {
          const schema = fieldSchemas[column.type];
          return [field, column.nullable ? Schema.NullOr(schema) : schema];
        }),
      ),
    }) as unknown as Schema.Decoder<EntityRow>,
  };
};

/** The `CREATE TABLE` statement for an entity's first migration. */
export const createEntityTable = (entity: Entity) => {
  const columns = Object.entries(entity.fields).map(
    ([field, column]) =>
      `${columnName(field)} ${sqlTypes[column.type]}${column.nullable ? "" : " NOT NULL"}`,
  );
  return `CREATE TABLE ${entity.name} (id TEXT PRIMARY KEY, ${columns.join(", ")}) STRICT;`;
};

/** A decoded row's column values, in table order. */
export const toColumns = (entity: Entity, row: EntityRow): Array<SqlValue> =>
  Object.entries(entity.fields).map(([field, column]) => {
    const value = row[field] ?? null;
    if (value === null) return null;
    if (column.type === "boolean") return value === true ? 1 : 0;
    if (column.type === "json") return JSON.stringify(value);
    return value as SqlValue;
  });

/** The row for a table row selected with `id` and every field's column. */
export const fromColumns = (entity: Entity, values: SqlRow): EntityRow => {
  const row: Record<string, Schema.Json> = { id: values["id"] as string };
  for (const [field, column] of Object.entries(entity.fields)) {
    const value = values[columnName(field)] ?? null;
    row[field] =
      value === null
        ? null
        : column.type === "boolean"
          ? value === 1
          : column.type === "json"
            ? (JSON.parse(value as string) as Schema.Json)
            : (value as Schema.Json);
  }
  return row as EntityRow;
};

/**
 * Every entity the store holds. Adding one also needs a store migration that creates its table
 * (`createEntityTable`); a test checks they match.
 */
export const entities: ReadonlyArray<Entity> = [];
