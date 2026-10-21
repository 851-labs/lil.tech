import { Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { healthCatalogTypes, healthCategoryName } from "../HealthCatalog.ts";
import { typeDates } from "./HealthQueries.ts";
import type { HealthToolkit } from "./HealthToolkit.ts";
import { localTime, toolTimeZone } from "./ToolTime.ts";
import { byCategoryThenName } from "./ToolTypes.ts";

type TypesResult = (typeof HealthToolkit.tools.list_types.successSchema)["Type"];

/**
 * The `list_types` tool from the user's store: every catalog type with data, by category (in
 * Browse's order), then name, with when its earliest and latest records start.
 */
export const healthListTypes = Effect.fn("healthListTypes")(function* (
  sql: StoreSql,
  input: { readonly timeZone?: string | undefined },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const types = healthCatalogTypes
    .flatMap((type) => {
      const dates = typeDates(sql, type, zone);
      return dates === null ? [] : [{ type, dates }];
    })
    .sort((a, b) => byCategoryThenName(a.type, b.type))
    .map(({ type, dates }) => ({
      type: type.id,
      name: type.name,
      category: type.category === null ? null : healthCategoryName(type.category),
      kind: type.kind,
      unit: type.kind === "quantity" ? type.unit : null,
      cumulative: type.aggregation === "cumulative",
      first: localTime(dates.first, zone),
      last: localTime(dates.last, zone),
    }));
  const result: TypesResult = { timeZone: name, types };
  return result;
});
