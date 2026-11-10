import { Predicate, type Schema } from "effect";
import type { Entity } from "../store/Entities.ts";
import { keptDeviceProperties, keptMetadataKeys } from "./HealthCatalog.ts";

// What the server keeps of a Health record's metadata and device (851-4152,
// `docs/decisions/health.md` › Metadata): the metadata keys and device properties the Swift
// `HealthCatalog` keeps, from `health-catalog.json`. The iPhone uploads only those since 851-4152;
// the server drops the rest from what older iPhones upload (`HealthIngestion`) and from the
// records it stored before (`MetadataCleanup`).

/** Metadata with only the keys lil health keeps, or null if none are left. */
export const keptMetadata = (metadata: Schema.Json): Schema.Json => {
  if (!Predicate.isObject(metadata)) return metadata;
  const kept = Object.entries(metadata as Record<string, Schema.Json>).filter(([key]) =>
    keptMetadataKeys.has(key),
  );
  return kept.length === 0 ? null : Object.fromEntries(kept);
};

/** `HKDevice`'s properties without `localIdentifier` and `udiDeviceIdentifier`. */
export const keptDevice = (device: Schema.Json): Schema.Json =>
  Predicate.isObject(device)
    ? Object.fromEntries(
        Object.entries(device as Record<string, Schema.Json>).filter(([property]) =>
          keptDeviceProperties.has(property),
        ),
      )
    : device;

/** A workout's activities or events, each with only the metadata kept. */
const keptInEach = (records: Schema.Json): Schema.Json =>
  Array.isArray(records)
    ? records.map((record) =>
        Predicate.isObject(record) && "metadata" in record
          ? { ...record, metadata: keptMetadata(record["metadata"] as Schema.Json) }
          : record,
      )
    : records;

/** How each field that holds metadata or a device is cleaned. */
const cleaners: Readonly<Record<string, (value: Schema.Json) => Schema.Json>> = {
  metadata: keptMetadata,
  device: keptDevice,
  activities: keptInEach,
  events: keptInEach,
};

/**
 * An entity's fields that hold metadata or an `HKDevice`, as JSON: `metadata`, `device` (not a
 * device-scoped entity's device ID, which is text), and a workout's `activities` and `events`.
 */
export const metadataFields = (entity: Entity): ReadonlyArray<Entity["fields"][number]> =>
  entity.name.startsWith("health_")
    ? entity.fields.filter(({ field, type }) => type.type === "json" && field in cleaners)
    : [];

/** A row's value for `field` (one of `metadataFields`) with only what lil health keeps. */
export const keptValue = (field: string, value: Schema.Json): Schema.Json => {
  const clean = cleaners[field];
  return clean === undefined ? value : clean(value);
};

/** `row` with only the metadata and device properties kept, in the fields it sets. */
export const withKeptMetadata = <Row extends Readonly<Record<string, Schema.Json>>>(
  entity: Entity,
  row: Row,
): Row => {
  let kept: Record<string, Schema.Json> | undefined;
  for (const { field } of metadataFields(entity)) {
    const value = row[field];
    if (value === undefined) continue;
    kept ??= { ...row };
    kept[field] = keptValue(field, value);
  }
  return (kept ?? row) as Row;
};
