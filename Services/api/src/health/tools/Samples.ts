import { Clock, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { type SampleCursor, samplePage } from "./HealthQueries.ts";
import { HealthToolError, type HealthToolkit, samplesLimit } from "./HealthToolkit.ts";
import { localTime, type ToolRange, toolPeriod, toolTimeZone } from "./ToolTime.ts";
import { resolveHealthType } from "./ToolTypes.ts";

type SamplesResult = (typeof HealthToolkit.tools.samples.successSchema)["Type"];

/** How many samples a page has unless a call says. */
export const samplesDefaultLimit = 100;

/** A page's cursor: where its last sample starts, and its ID, which breaks ties. */
const cursorAfter = (sample: SampleCursor) => `${sample.startDate}_${sample.id}`;

const parseCursor = (text: string) => {
  const separator = text.indexOf("_");
  const start = text.slice(0, separator);
  return separator === -1 || !/^[+-]?\d+$/.test(start)
    ? Effect.fail(
        new HealthToolError({
          message: `Invalid cursor: ${text}. Pass the previous page's nextCursor.`,
        }),
      )
    : Effect.succeed<SampleCursor>({ startDate: Number(start), id: text.slice(separator + 1) });
};

/**
 * The `samples` tool from the user's store: a quantity or category type's samples that start in
 * the period, newest first, a page at a time.
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
  if (type.kind !== "quantity" && type.kind !== "category") {
    return yield* new HealthToolError({
      message:
        `${type.name} (${type.id}) isn't a quantity or category type, so it has no samples. ` +
        "Use the tool for its kind (workouts, medications, health_details).",
    });
  }
  const limit = input.limit ?? samplesDefaultLimit;
  if (!Number.isInteger(limit) || limit < 1 || limit > samplesLimit) {
    return yield* new HealthToolError({
      message: `The limit must be from 1 to ${samplesLimit}.`,
    });
  }
  const now = yield* Clock.currentTimeMillis;
  const period = toolPeriod(input.range, input.date, now, zone);
  const after = input.cursor === undefined ? null : yield* parseCursor(input.cursor);
  // One more than asked for, to know whether there's another page.
  const page = samplePage(sql, type.id, { from: period.start, to: period.end }, after, limit + 1);
  const samples = page.slice(0, limit);
  const last = samples.at(-1);
  const result: SamplesResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    type: type.id,
    samples: samples.map((sample) => ({
      id: sample.id,
      start: localTime(sample.startDate, zone),
      end: localTime(sample.endDate, zone),
      value: sample.value,
      unit: sample.unit,
      categoryValue: sample.categoryValue,
      source: sample.sourceName,
    })),
    nextCursor: page.length > limit && last !== undefined ? cursorAfter(last) : null,
  };
  return result;
});
