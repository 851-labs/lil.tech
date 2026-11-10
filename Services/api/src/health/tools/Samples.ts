import { Clock, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import type { HealthCatalogType } from "../HealthCatalog.ts";
import { correlatedValues, type SampleCursor, samplePage } from "./HealthQueries.ts";
import { HealthToolError, type HealthToolkit, samplesLimit } from "./HealthToolkit.ts";
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
  activitySummary: null,
  heartbeatSeries: null,
  electrocardiogram: null,
  audiogram: null,
  stateOfMind: null,
  scoredAssessment: null,
  document: null,
};

/** A page's cursor: where its last sample starts, and its ID, which breaks ties. */
const cursorAfter = (sample: SampleCursor) => `${sample.startDate}_${sample.id}`;

/** A cursor's start and ID, both there: `123_` and `_abc` aren't cursors, as on the Mac. */
const parseCursor = (text: string) => {
  const separator = text.indexOf("_");
  const start = text.slice(0, separator);
  const id = text.slice(separator + 1);
  return separator === -1 || !/^[+-]?\d+$/.test(start) || id === ""
    ? Effect.fail(
        new HealthToolError({
          message: `Invalid cursor: ${text}. Pass the previous page's nextCursor.`,
        }),
      )
    : Effect.succeed<SampleCursor>({ startDate: Number(start), id });
};

/**
 * The `samples` tool from the user's store: a quantity, category or correlation type's samples
 * that start in the period, newest first, a page at a time, each with its source, device and
 * metadata (`sampleDetails`), and a correlation with the samples it groups.
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
  // One more than asked for, to know whether there's another page.
  const correlation = type.kind === "correlation";
  const range = { from: period.start, to: period.end };
  const page = samplePage(sql, type.id, range, after, limit + 1, correlation);
  const samples = page.slice(0, limit);
  const last = samples.at(-1);
  const values = Map.groupBy(
    correlation
      ? correlatedValues(
          sql,
          samples.map((sample) => sample.id),
        )
      : [],
    (row) => row.correlationId,
  );
  const sources = new SampleSources();
  const result: SamplesResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    type: type.id,
    samples: samples.map((sample) => {
      const metadata = jsonObject(sample.metadata);
      return {
        id: sample.id,
        start: localTime(sample.startDate, zone),
        end: localTime(sample.endDate, zone),
        value: sample.value,
        unit: sample.unit,
        categoryValue: sample.categoryValue,
        source: sample.sourceName,
        sourceIndex: sources.indexOf(sample, metadata),
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
    nextCursor: page.length > limit && last !== undefined ? cursorAfter(last) : null,
  };
  return result;
});
