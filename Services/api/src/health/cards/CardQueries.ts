import type { SqlValue, StoreSql } from "../../store/StoreSql.ts";
import { healthCatalogType } from "../HealthCatalog.ts";
import {
  cumulativeTotalsBy,
  latestSample,
  liveSample,
  statisticsDevices,
  statisticsSource,
} from "../tools/HealthQueries.ts";
import {
  type CardCalendar,
  CardBucketer,
  type CardGrain,
  type CardInterval,
} from "./CardCalendar.ts";
import type {
  CardFetch,
  CardFetchResult,
  CardReading,
  CardStretch,
  CardTotal,
  CardWindowFetch,
  CardWindowFetchResult,
  CardWorkout,
} from "./CardEngine.ts";
import { type CardSleepRecord, sleepAnalysisType } from "./CardNights.ts";
import type { CardFilter } from "./CardSpec.ts";

// The server engine's reads of the user's store (851-3197): the Mac's `CardQueries` over the
// store's tables. Totals come from the statistics source's buckets and the samples past them
// (`cumulativeTotalsBy`, as the `metric` tool's), readings from the samples' (type, start) key, as
// arrays of values (851-2906), and sleep windows' readings only from their stretches' ranges of it.
// Deleted samples the store hasn't swept yet are skipped (tombstones).

const placeholders = (count: number) => Array.from({ length: count }, () => "?").join(", ");

/**
 * A cumulative type's de-duplicated totals per bucket of `grain` starting in `range`, as the Mac's
 * `cumulativeTotals`.
 */
export const cardTotals = (
  sql: StoreSql,
  type: string,
  range: CardInterval,
  grain: CardGrain,
  now: number,
  calendar: CardCalendar,
): Array<CardTotal> => {
  const bucketer = new CardBucketer(calendar, grain);
  return cumulativeTotalsBy(sql, type, range, (millis) => bucketer.startOf(millis), now);
};

/**
 * A type's readings starting in `range`, oldest first, that match `filter`: a range of the (type,
 * start) key. A device model is the sample's own device's, or its provenance's (851-2674), and
 * JSON that doesn't parse matches no model, rather than failing the card.
 */
export const cardReadings = (
  sql: StoreSql,
  type: string,
  range: CardInterval,
  filter: CardFilter | null,
  sampleIds: boolean,
): Array<CardReading> => {
  const conditions = ["s.type = ?", "s.start_date >= ?", "s.start_date < ?", "s.value IS NOT NULL"];
  const bindings: Array<SqlValue> = [type, range.start, range.end];
  let join = "";
  if (filter?.sources) {
    conditions.push(`s.source_bundle_id IN (${placeholders(filter.sources.length)})`);
    bindings.push(...filter.sources);
  }
  if (filter?.deviceModels) {
    join = "LEFT JOIN health_provenance p ON p.id = s.provenance";
    const device = "coalesce(s.device, p.device)";
    conditions.push(
      `CASE WHEN json_valid(${device}) THEN json_extract(${device}, '$.model') END ` +
        `IN (${placeholders(filter.deviceModels.length)})`,
    );
    bindings.push(...filter.deviceModels);
  }
  const rows = sql.rows(
    `SELECT s.start_date, s.end_date, s.value, s.source_bundle_id${sampleIds ? ", s.id" : ""}
    FROM health_sample s ${join}
    WHERE ${conditions.join(" AND ")} AND ${liveSample}
    ORDER BY s.start_date, s.id`,
    ...bindings,
  );
  const readings: Array<CardReading> = Array.from({ length: rows.length });
  for (let index = 0; index < rows.length; index++) {
    const row = rows[index]!;
    readings[index] = {
      start: Number(row[0]),
      end: Number(row[1]),
      value: Number(row[2]),
      source: row[3] as string,
      sampleId: sampleIds ? (row[4] as string) : "",
    };
  }
  return readings;
};

/**
 * A type's readings starting in one of `stretches` (in order and apart), oldest first: a range of
 * the key for each. Reading a night's stretches as one range, and dropping the minutes awake
 * between them, was no faster, on the server as on the Mac (851-3196).
 */
export const cardStretchReadings = (
  sql: StoreSql,
  type: string,
  stretches: ReadonlyArray<CardStretch>,
  filter: CardFilter | null,
  sampleIds: boolean,
): Array<CardReading> =>
  stretches.flatMap((stretch) => cardReadings(sql, type, stretch, filter, sampleIds));

/**
 * Sleep analysis records with a value that end after `range` starts and start before it ends, by
 * start: In Bed records can start well before a night.
 */
export const cardSleepRecords = (sql: StoreSql, range: CardInterval): Array<CardSleepRecord> =>
  sql
    .rows(
      `SELECT start_date, end_date, category_value, source_bundle_id FROM health_sample s
      WHERE type = ? AND start_date < ? AND end_date > ? AND category_value IS NOT NULL
        AND ${liveSample}
      ORDER BY start_date, id`,
      sleepAnalysisType,
      range.end,
      range.start,
    )
    .map(([start, end, value, source]) => ({
      start: Number(start),
      end: Number(end),
      value: Number(value),
      source: source as string,
    }));

/** Workouts of every activity that end after `range` starts and start before it ends, from every source. */
export const cardWorkouts = (sql: StoreSql, range: CardInterval): Array<CardWorkout> =>
  sql
    .rows(
      `SELECT start_date, end_date, activity_type FROM health_workout
      WHERE start_date < ? AND end_date > ? ORDER BY start_date, id`,
      range.end,
      range.start,
    )
    .map(([start, end, activityType]) => ({
      start: Number(start),
      end: Number(end),
      activityType: Number(activityType),
    }));

/** What a window fetch asks for, from the store. */
export const fetchCardWindow = (sql: StoreSql, fetch: CardWindowFetch): CardWindowFetchResult =>
  fetch._tag === "sleep"
    ? { _tag: "sleep", records: cardSleepRecords(sql, fetch.range) }
    : { _tag: "workouts", workouts: cardWorkouts(sql, fetch.range) };

/** What a fetch asks for, from the store. `now` picks the statistics source. */
export const fetchCardData = (
  sql: StoreSql,
  fetch: CardFetch,
  now: number,
  calendar: CardCalendar,
): CardFetchResult => {
  const { kind } = fetch;
  switch (kind._tag) {
    case "totals":
      return {
        _tag: "totals",
        totals: cardTotals(sql, fetch.type, kind.range, kind.grain, now, calendar),
      };
    case "readings":
      return {
        _tag: "readings",
        readings: cardReadings(sql, fetch.type, kind.range, kind.filter, kind.needsSampleIds),
      };
    case "stretchReadings":
      return {
        _tag: "readings",
        readings: cardStretchReadings(
          sql,
          fetch.type,
          kind.stretches,
          kind.filter,
          kind.needsSampleIds,
        ),
      };
  }
};

/**
 * When a quantity type's latest data started, of what had started by `now`, as the Mac's
 * `latestPeriodDate` dates it: for a type that adds up, its latest statistics bucket with anything
 * in it or its latest sample, whichever is later (`latestCumulativeStart`); for others, its latest
 * sample. Null without any.
 */
export const latestDataStart = (sql: StoreSql, type: string, now: number): number | null => {
  const sample = latestSample(sql, type, now)?.startDate ?? null;
  if (healthCatalogType(type)?.aggregation !== "cumulative") return sample;
  const source = statisticsSource(statisticsDevices(sql), now);
  // The iPhone sends empty buckets up to a day ahead (to overwrite sums that are gone), so the
  // latest is the latest with anything in it that has started.
  const bucket =
    source === null
      ? undefined
      : sql.rows(
          `SELECT bucket_start FROM health_statistic
          WHERE id >= ? AND id <= ? AND device = ? AND type = ? AND sum > 0 AND bucket_start <= ?
          ORDER BY id DESC LIMIT 1`,
          `${source}/${type}@`,
          `${source}/${type}@${now}`,
          source,
          type,
          now,
        )[0]?.[0];
  const latest = [sample, bucket === undefined ? null : Number(bucket)].filter(
    (start): start is number => start !== null,
  );
  return latest.length === 0 ? null : Math.max(...latest);
};
