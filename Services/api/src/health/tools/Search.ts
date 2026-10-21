import { Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import {
  type HealthCatalogType,
  healthCatalogTypes,
  healthCategoryName,
} from "../HealthCatalog.ts";
import { characteristicValues, typeDates } from "./HealthQueries.ts";
import { HealthToolError, type HealthToolkit } from "./HealthToolkit.ts";
import { sortedMedications } from "./Medications.ts";
import { defaultToolTimeZone, toolTimeZone } from "./ToolTime.ts";
import { byCategoryThenName, shortTypeId } from "./ToolTypes.ts";

type SearchResult = (typeof HealthToolkit.tools.search.successSchema)["Type"];

/**
 * The `search` tool from the user's store: every catalog type whose name, category or identifier
 * (without its prefix, so `vo2` finds Cardio Fitness) has each of the query's words, those with
 * data first, then by category and name; and the medications whose names have them.
 */
export const healthSearch = Effect.fn("healthSearch")(function* (
  sql: StoreSql,
  input: { readonly query: string },
) {
  const words = input.query
    .toLowerCase()
    .split(/\s+/u)
    .filter((word) => word.length > 0);
  if (words.length === 0) {
    return yield* new HealthToolError({
      message: "The query must be 1 to 100 characters, and not only spaces.",
    });
  }
  const matches = (text: string) => {
    const lowercased = text.toLowerCase();
    return words.every((word) => lowercased.includes(word));
  };
  // Only whether there's data, which doesn't depend on a time zone.
  const { zone } = yield* toolTimeZone(defaultToolTimeZone);
  const medications = sortedMedications(sql);
  // Characteristics have no dates: those that are set count, not Not Set (`null`).
  const characteristics = new Set(
    characteristicValues(sql)
      .filter(([, value]) => value !== "null")
      .map(([id]) => id),
  );
  const hasData = (type: HealthCatalogType) =>
    typeDates(sql, type, zone) !== null ||
    (type.kind === "medication" && medications.length > 0) ||
    characteristics.has(type.id);
  const types = healthCatalogTypes
    .filter((type) =>
      matches(
        `${type.name} ${type.category === null ? "" : healthCategoryName(type.category)} ` +
          shortTypeId(type.id),
      ),
    )
    .map((type) => ({ type, hasData: hasData(type) }))
    .sort((a, b) =>
      a.hasData !== b.hasData ? (a.hasData ? -1 : 1) : byCategoryThenName(a.type, b.type),
    )
    .map(({ type, hasData }) => ({
      type: type.id,
      name: type.name,
      category: type.category === null ? null : healthCategoryName(type.category),
      hasData,
    }));
  const result: SearchResult = {
    types,
    medications: medications
      .filter((medication) => matches(`${medication.displayName} ${medication.name}`))
      .map((medication) => ({ id: medication.id, name: medication.displayName })),
  };
  return result;
});
