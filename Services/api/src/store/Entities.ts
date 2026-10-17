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
 * and one `snake_case` column per field, and its primary key is its key fields' columns, then
 * `id`.
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
   * Fields that lead the table's primary key, before `id`, so records are stored in their order
   * (`docs/SYNC.md`). A record's are set when it's created and never change, so every upsert must
   * include them. Empty for most entities, which are keyed by `id` alone.
   */
  readonly key: ReadonlyArray<string>;
  /** The table's primary key: the key fields' columns, then `id`. */
  readonly keyColumns: ReadonlyArray<string>;
  /** The name of its row schema in OpenAPI (`health_sample` → `HealthSample`). */
  readonly schemaName: string;
  /**
   * A whole record as the change log carries it: `id` and its fields. Nullable fields are
   * optional keys, so rows written before a field was added still decode. Built on demand, since
   * only the OpenAPI generator needs it.
   */
  readonly rowSchema: () => Schema.Top;
  /** Checks a record ID, e.g. that a HealthKit UUID is lowercase. */
  readonly isValidId: (id: string) => boolean;
  /** For records that belong to the device uploading them (`DeviceScoped`). */
  readonly deviceScoped?: DeviceScoped;
  /** The columns that hold a health blob's SHA-256, which keep it from being swept. */
  readonly blobColumns: ReadonlyArray<string>;
  /**
   * Checks a whole record beyond its fields' types, returning why it's invalid. The store runs it
   * on every upsert, with the merged row.
   */
  readonly checkRow?: CheckRow;
  /** Decodes the fields an upsert sets. Any may be missing, since upserts merge. */
  readonly decodeFields: (
    row: unknown,
  ) => Result.Result<Readonly<Record<string, Schema.Json>>, Schema.SchemaError>;
  /**
   * The statements `applyMutations` runs, built once. `select` takes the key fields' values, then
   * the ID, and `delete` the ID (for an entity without key fields).
   */
  readonly statements: {
    readonly select: string;
    readonly upsert: string;
    readonly delete: string;
  };
}

/**
 * Records that belong to the device uploading them. Clients send IDs in the `id` form, and the
 * server stamps them with the device (`stampDevice`) and sets their `device` field.
 */
export interface DeviceScoped {
  readonly id: RegExp;
  /** An integer field the server sets to when it applied the record (Unix milliseconds). */
  readonly stampedAt?: string;
}

export type CheckRow = (
  id: string,
  row: Readonly<Record<string, Schema.Json>>,
) => string | undefined;

/**
 * Defines an entity. Field names are lower camel case (`startDate`, not `HRV`) so that each maps
 * to its own `snake_case` column, and `id` is implicit.
 */
export const defineEntity = (
  name: string,
  options: {
    readonly clientWritable: boolean;
    readonly fields: Record<string, Column>;
    /** The form record IDs must have. Any non-empty string by default. */
    readonly id?: RegExp;
    readonly deviceScoped?: DeviceScoped;
    readonly checkRow?: CheckRow;
    /**
     * Nullable text fields that refer to health blobs by SHA-256 (`src/store/BlobSweep.ts`): a
     * blob no record refers to is deleted after a grace period.
     */
    readonly blobs?: ReadonlyArray<string>;
    /** Non-nullable text or integer fields that lead the primary key (`Entity.key`). */
    readonly key?: ReadonlyArray<string>;
  },
): Entity => {
  const key = options.key ?? [];
  for (const field of key) {
    const type = options.fields[field];
    if (type === undefined || type.nullable || (type.type !== "text" && type.type !== "integer")) {
      throw new Error(`${name}.${field} must be a non-nullable text or integer field to be a key`);
    }
  }
  if (key.length > 0 && options.deviceScoped !== undefined) {
    throw new Error(`Device-scoped entity ${name} can't have key fields`);
  }
  for (const field of options.blobs ?? []) {
    if (options.fields[field]?.type !== "text") {
      throw new Error(`${name}.${field} must be a text field to hold a blob's SHA-256`);
    }
  }
  const { deviceScoped } = options;
  if (deviceScoped !== undefined && options.fields.device?.type !== "text") {
    throw new Error(`Device-scoped entity ${name} needs a text device field`);
  }
  if (
    deviceScoped?.stampedAt !== undefined &&
    options.fields[deviceScoped.stampedAt]?.type !== "integer"
  ) {
    throw new Error(`${name}.${deviceScoped.stampedAt} must be an integer field`);
  }
  if (!/^[a-z][a-z0-9_]*$/.test(name)) throw new Error(`Invalid entity name: ${name}`);
  const fields = Object.entries(options.fields).map(([field, type]) => {
    if (!/^[a-z][a-z0-9]*(?:[A-Z][a-z0-9]+)*$/.test(field) || field === "id") {
      throw new Error(`Invalid field name in ${name}: ${field}`);
    }
    return { field, column: columnName(field), type };
  });
  const columns = fields.map(({ column }) => `"${column}"`);
  const keyColumns = [...key.map(columnName), "id"];
  const quotedKey = keyColumns.map((column) => `"${column}"`);
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
    key,
    keyColumns,
    schemaName: schemaName(name),
    rowSchema: () =>
      Schema.Struct({
        id: Schema.String,
        ...Object.fromEntries(
          fields.map(({ field, type }) => [
            field,
            type.nullable
              ? // `Schema.Json` already includes null, and renders as `{}` like `NonNullJson`.
                Schema.optionalKey(type.type === "json" ? Schema.Json : fieldSchema(type))
              : fieldSchema(type),
          ]),
        ),
      }).annotate({ identifier: `lil/api/sync/${schemaName(name)}` }),
    isValidId: (id) => id !== "" && (options.id?.test(id) ?? true),
    ...(options.deviceScoped === undefined ? {} : { deviceScoped: options.deviceScoped }),
    blobColumns: (options.blobs ?? []).map(columnName),
    ...(options.checkRow === undefined ? {} : { checkRow: options.checkRow }),
    decodeFields: Schema.decodeUnknownResult(fieldsSchema) as Entity["decodeFields"],
    statements: {
      select: `SELECT ${["id", ...columns].join(", ")} FROM "${name}"
        WHERE ${quotedKey.map((column) => `${column} = ?`).join(" AND ")}`,
      upsert: `INSERT INTO "${name}" (${["id", ...columns].join(", ")})
        VALUES (${["?", ...columns.map(() => "?")].join(", ")})
        ON CONFLICT (${quotedKey.join(", ")}) DO UPDATE SET ${columns.map((column) => `${column} = excluded.${column}`).join(", ")}`,
      delete: `DELETE FROM "${name}" WHERE id = ? RETURNING id`,
    },
  };
};

/**
 * A device-scoped record's ID as stored: the device's own record (`self`) is keyed by the device,
 * and anything else by the device and the client's ID (`<device>/<id>`), so two devices' records
 * never collide.
 */
export const stampDevice = (deviceId: string, id: string) =>
  id === "self" ? deviceId : `${deviceId}/${id}`;

/**
 * The `CREATE TABLE` statement for an entity's first migration. With key fields, the table is
 * stored in its primary key's order (`WITHOUT ROWID`), with no other copy of it.
 */
export const createEntityTable = (entity: Entity, name = entity.name) => {
  const columns = entity.fields.map(
    ({ column, type }) => `"${column}" ${sqlTypes[type.type]}${type.nullable ? "" : " NOT NULL"}`,
  );
  if (entity.key.length === 0) {
    return `CREATE TABLE "${name}" (id TEXT PRIMARY KEY, ${columns.join(", ")}) STRICT;`;
  }
  const key = entity.keyColumns.map((column) => `"${column}"`).join(", ");
  return `CREATE TABLE "${name}" (id TEXT NOT NULL, ${columns.join(", ")}, PRIMARY KEY (${key})) STRICT, WITHOUT ROWID;`;
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
