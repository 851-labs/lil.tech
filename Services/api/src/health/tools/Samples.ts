import { Clock, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import type { HealthCatalogType } from "../HealthCatalog.ts";
import {
  correlatedValues,
  type DetailedSampleRow,
  quantitySeriesOf,
  type SampleCursor,
  samplePage,
  seriesValueInterval,
} from "./HealthQueries.ts";
import { HealthToolError, type HealthToolkit, samplesLimit } from "./HealthToolkit.ts";
import { RecordedZones } from "./RecordedTimes.ts";
import { jsonObject, SampleSources, sampleDetails } from "./SampleDetails.ts";
import { localTime, type ToolRange, toolPeriod, toolTimeZone } from "./ToolTime.ts";
import { resolveHealthType } from "./ToolTypes.ts";

type SamplesResult = (typeof HealthToolkit.tools.samples.successSchema)["Type"];

/** How many samples a page has unless a call says. */
export const samplesDefaultLimit = 100;

/**
 * The kinds `samples` doesn't list, and the tool that reads each instead, or null for those no
 * tool reads yet (their tools come under 851-4156). The Mac's `HealthTools.samplesElsewhere`
 * matches it.
 */
const samplesElsewhere: Readonly<
  Record<Exclude<HealthCatalogType["kind"], "quantity" | "category" | "correlation">, string | null>
> = {
  workout: "workouts",
  workoutRoute: "workout_routes",
  medication: "medications",
  medicationDoseEvent: "medications",
  characteristic: "health_details",
  visionPrescription: "health_details",
  activitySummary: "activity_rings",
  heartbeatSeries: "heartbeat_series",
  electrocardiogram: "electrocardiograms",
  audiogram: null,
  stateOfMind: "state_of_mind",
  scoredAssessment: "assessments",
  document: null,
};

/**
 * A page's cursor: where its last sample starts, and its ID, which breaks ties; and, if it ended
 * inside a series' values (851-4171), the index of the last one listed: `<start>_<id>_<index>`.
 */
const cursorAt = (sample: SampleCursor, index?: number) =>
  `${sample.startDate}_${sample.id}${index === undefined || index === 0 ? "" : `_${index}`}`;

/**
 * A cursor's start and ID, both there (`123_` and `_abc` aren't cursors), and the index of a
 * series' value, a whole number from 1 without a sign or leading zeros, at most 9 digits (a
 * series has at most 20,000 values), as on the Mac.
 */
const parseCursor = (text: string) => {
  const match = /^([+-]?\d+)_([^_]+)(?:_([1-9]\d{0,8}))?$/.exec(text);
  return match === null
    ? Effect.fail(
        new HealthToolError({
          message: `Invalid cursor: ${text}. Pass the previous page's nextCursor.`,
        }),
      )
    : Effect.succeed({
        sample: { startDate: Number(match[1]), id: match[2]! } satisfies SampleCursor,
        index: match[3] === undefined ? null : Number(match[3]),
      });
};

/** One of `samples`' items: a sample, or one of a series' values, with a cursor ending with it. */
interface ListedItem {
  readonly sample: DetailedSampleRow;
  readonly start: number;
  readonly end: number;
  readonly value: number | null;
  readonly series: SampleSeries | undefined;
  readonly cursor: string;
}

type SampleSeries = NonNullable<SamplesResult["samples"][number]["series"]>;

/**
 * The `samples` tool from the user's store: a quantity, category or correlation type's samples
 * that start in the period, newest first, a page at a time, each with its source, device and
 * metadata (`sampleDetails`), a correlation with the samples it groups, and a quantity series
 * (851-4171) with its count and summary. With `seriesValues`, each series whose values were
 * uploaded is its values instead, newest first, in its sample's place, each an item of its own
 * that the limit counts; a page can end inside a series. As the Mac's `HealthTools.samples`.
 */
export const healthSamples = Effect.fn("healthSamples")(function* (
  sql: StoreSql,
  input: {
    readonly type: string;
    readonly range: ToolRange;
    readonly date?: string | undefined;
    readonly timeZone?: string | undefined;
    readonly cursor?: string | undefined;
    readonly limit?: number | undefined;
    readonly seriesValues?: boolean | undefined;
  },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const type = yield* resolveHealthType(input.type);
  if (type.kind !== "quantity" && type.kind !== "category" && type.kind !== "correlation") {
    const tool = samplesElsewhere[type.kind];
    return yield* new HealthToolError({
      message:
        tool === null
          ? `samples doesn't list ${type.name} (${type.id}), and no other tool reads that kind yet.`
          : `samples doesn't list ${type.name} (${type.id}): use ${tool}.`,
    });
  }
  const limit = input.limit ?? samplesDefaultLimit;
  if (!Number.isInteger(limit) || limit < 1 || limit > samplesLimit) {
    return yield* new HealthToolError({
      message: `The limit must be from 1 to ${samplesLimit}.`,
    });
  }
  const now = yield* Clock.currentTimeMillis;
  const period = yield* toolPeriod(input.range, input.date, now, zone);
  const after = input.cursor === undefined ? null : yield* parseCursor(input.cursor);
  const correlation = type.kind === "correlation";
  const listsValues = input.seriesValues === true && type.kind === "quantity";
  // A page that ended inside a series' values goes on with the rest of them.
  const within = listsValues ? (after?.index ?? null) : null;
  const range = { from: period.start, to: period.end };
  // One more than asked for, to know whether there's another page: each sample is at least one
  // item.
  const page = samplePage(
    sql,
    type.id,
    range,
    after?.sample ?? null,
    limit + (within === null ? 1 : 2),
    correlation,
    within !== null,
  );
  const series =
    type.kind === "quantity"
      ? quantitySeriesOf(
          sql,
          page.map((sample) => sample.id),
          listsValues,
        )
      : new Map();
  const listed: Array<ListedItem> = [];
  pages: for (const sample of page) {
    const isCursor = within !== null && sample.id === after?.sample.id;
    const quantitySeries = series.get(sample.id);
    const seriesValues = listsValues ? (quantitySeries?.values ?? null) : null;
    if (quantitySeries !== undefined && seriesValues !== null) {
      const last = Math.min(
        isCursor ? within - 1 : seriesValues.values.length - 1,
        seriesValues.values.length - 1,
      );
      for (let index = last; index >= 0; index--) {
        if (listed.length > limit) break pages;
        listed.push({
          sample,
          ...seriesValueInterval(seriesValues, index, sample.startDate),
          value: seriesValues.values[index]!,
          series: { count: quantitySeries.count, index },
          cursor: cursorAt(sample, index),
        });
      }
    } else if (!isCursor) {
      if (listed.length > limit) break;
      listed.push({
        sample,
        start: sample.startDate,
        end: sample.endDate,
        value: sample.value,
        series:
          quantitySeries === undefined
            ? undefined
            : {
                count: quantitySeries.count,
                ...(quantitySeries.minimum === null ? {} : { minimum: quantitySeries.minimum }),
                ...(quantitySeries.maximum === null ? {} : { maximum: quantitySeries.maximum }),
                ...(quantitySeries.mostRecent === null
                  ? {}
                  : { mostRecent: quantitySeries.mostRecent }),
                ...(quantitySeries.mostRecentStartDate === null
                  ? {}
                  : { mostRecentStart: localTime(quantitySeries.mostRecentStartDate, zone) }),
                ...(quantitySeries.mostRecentEndDate === null
                  ? {}
                  : { mostRecentEnd: localTime(quantitySeries.mostRecentEndDate, zone) }),
              },
        cursor: cursorAt(sample),
      });
    }
  }
  const items = listed.slice(0, limit);
  const last = items.at(-1);
  const values = Map.groupBy(
    correlation
      ? correlatedValues(
          sql,
          items.map((item) => item.sample.id),
        )
      : [],
    (row) => row.correlationId,
  );
  const sources = new SampleSources();
  const zones = new RecordedZones();
  const result: SamplesResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    type: type.id,
    samples: items.map(({ sample, start, end, value, series }) => {
      const metadata = jsonObject(sample.metadata);
      return {
        id: sample.id,
        start: localTime(start, zone),
        end: localTime(end, zone),
        ...zones.times(metadata, start, end),
        value,
        unit: sample.unit,
        categoryValue: sample.categoryValue,
        source: sample.sourceName,
        sourceIndex: sources.indexOf(sample, metadata),
        ...(series === undefined ? {} : { series }),
        ...sampleDetails(metadata, zone),
        ...(correlation
          ? {
              values: (values.get(sample.id) ?? []).map(({ type, value, unit }) => ({
                type,
                value,
                unit,
              })),
            }
          : {}),
      };
    }),
    sources: sources.sources,
    nextCursor: listed.length > limit && last !== undefined ? last.cursor : null,
  };
  return result;
});
