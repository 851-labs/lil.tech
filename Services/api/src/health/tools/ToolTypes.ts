import { Effect } from "effect";
import {
  type HealthCatalogType,
  healthCatalogType,
  healthCatalogTypes,
  healthCategories,
} from "../HealthCatalog.ts";
import { HealthToolError } from "./HealthToolkit.ts";

// The catalog's types as the Health tools name and order them, as the Mac's `HealthTools` does.

/** An identifier without HealthKit's prefix: `StepCount` for `HKQuantityTypeIdentifierStepCount`. */
export const shortTypeId = (id: string): string => {
  const index = id.indexOf("TypeIdentifier");
  return index === -1 ? id : id.slice(index + "TypeIdentifier".length);
};

/**
 * The type a call names: by its HealthKit identifier, as the toolkit's tools take it, or by the
 * name Health shows (`Steps`, `heart rate`) or the identifier without its prefix (`StepCount`),
 * in any case, as the Mac's commands take it too. Undefined if the catalog has no such type.
 */
export const findHealthType = (name: string): HealthCatalogType | undefined => {
  const exact = healthCatalogType(name);
  if (exact !== undefined) return exact;
  const wanted = name.trim().toLowerCase();
  return (
    healthCatalogTypes.find((type) => type.name.toLowerCase() === wanted) ??
    healthCatalogTypes.find((type) => shortTypeId(type.id).toLowerCase() === wanted)
  );
};

/** `findHealthType`, failing with the tool's error for a type the catalog doesn't have. */
export const resolveHealthType = (
  name: string,
): Effect.Effect<HealthCatalogType, HealthToolError> => {
  const type = findHealthType(name);
  return type === undefined
    ? Effect.fail(
        new HealthToolError({
          message:
            `Unknown type: ${name}. Use a HealthKit identifier, e.g. ` +
            "HKQuantityTypeIdentifierStepCount; search finds them.",
        }),
      )
    : Effect.succeed(type);
};

/** Where a type's category is in Browse's order, with characteristics (no category) last. */
const categoryOrder = (type: HealthCatalogType) =>
  type.category === null ? healthCategories.length : healthCategories.indexOf(type.category);

/**
 * Compares names as Finder and the Mac's `localizedStandardCompare` do: by letters first, then
 * accents and case, with numbers by value.
 */
const names = new Intl.Collator("en-US", { numeric: true });

/** Orders types by their category, in Browse's order (characteristics last), then by name. */
export const byCategoryThenName = (a: HealthCatalogType, b: HealthCatalogType): number =>
  categoryOrder(a) - categoryOrder(b) || names.compare(a.name, b.name);

/** Orders names as `byCategoryThenName` orders types' names. */
export const compareNames = (a: string, b: string): number => names.compare(a, b);
