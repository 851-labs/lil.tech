import { Clock, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import {
  heartbeatBeatsDefaultLimit,
  heartbeatSeriesLimit,
  HealthToolError,
  type HealthToolkit,
} from "./HealthToolkit.ts";
import { RecordedZones } from "./RecordedTimes.ts";
import { jsonObject } from "./SampleDetails.ts";
import { localTime, type ToolRange, toolPeriod, toolTimeZone } from "./ToolTime.ts";
import { cursorIndex, roundTo } from "./WorkoutRoutes.ts";

// The heartbeat series tools (851-4162): `heartbeat_series` lists Apple Watch's beat-to-beat
// measurements from their rows, with the average heart rate and HRV the Mac's Beat-to-Beat
// Measurements page works out (`HeartbeatAnalysis`, `HeartQueries.swift`), and
// `heartbeat_series_beats` gives one series' beats, a page at a time, as the privacy policy says
// (851-4157). Beats are JSON in the row (`HealthHeartbeatSeries`), not a blob. The Mac's
// `HealthTools` does the same (`HeartbeatSeries.swift`), rule for rule.

type SeriesResult = (typeof HealthToolkit.tools.heartbeat_series.successSchema)["Type"];
type BeatsResult = (typeof HealthToolkit.tools.heartbeat_series_beats.successSchema)["Type"];

/** A heartbeat series as stored (`health_heartbeat_series`). */
interface SeriesRow {
  readonly id: string;
  readonly startDate: number;
  readonly endDate: number;
  /** Each beat's time, in seconds since `startDate`, as JSON. */
  readonly beats: string;
  /** The indices of the beats preceded by a gap, as JSON. */
  readonly gaps: string;
  readonly sourceName: string;
  readonly metadata: string | null;
}

const seriesColumns = "id, start_date, end_date, beats, gaps, source_name, metadata";

const seriesRow = (row: Record<string, unknown>): SeriesRow => ({
  id: row["id"] as string,
  startDate: Number(row["start_date"]),
  endDate: Number(row["end_date"]),
  beats: row["beats"] as string,
  gaps: row["gaps"] as string,
  sourceName: row["source_name"] as string,
  metadata: (row["metadata"] as string | null) ?? null,
});

const parse = (json: string): unknown => {
  try {
    return JSON.parse(json);
  } catch {
    return undefined;
  }
};

/**
 * A series' beats' times and the beats preceded by a gap, as the Mac's
 * `HealthHeartbeatSeries.analysis` reads them: beats that can't be read are none, and gaps that
 * can't be read make every beat follow one, so no interval is made up across them. (Ingestion
 * checks both, so neither happens on the server.)
 */
export const seriesBeats = (series: { readonly beats: string; readonly gaps: string }) => {
  const parsedBeats = parse(series.beats);
  const times =
    Array.isArray(parsedBeats) && parsedBeats.every((beat) => typeof beat === "number")
      ? (parsedBeats as ReadonlyArray<number>)
      : [];
  const parsedGaps = parse(series.gaps);
  const gaps =
    Array.isArray(parsedGaps) && parsedGaps.every((gap) => Number.isInteger(gap))
      ? new Set(parsedGaps as ReadonlyArray<number>)
      : new Set(times.keys());
  return { times, gaps };
};

/**
 * What a series says, as the Mac's `HeartbeatAnalysis`: its intervals (each beat's time less the
 * one before's), none to a beat preceded by a gap and none that isn't positive, and from them the
 * average heart rate, SDNN (the sample standard deviation, in ms) and RMSSD (the root mean square
 * of the differences between intervals in a row, in ms; a gap starts a new row).
 */
export const heartbeatAnalysis = (times: ReadonlyArray<number>, gaps: ReadonlySet<number>) => {
  const intervals: Array<number> = [];
  const successive: Array<number> = [];
  let previous: number | null = null;
  for (let index = 1; index < times.length; index++) {
    if (gaps.has(index)) {
      previous = null;
      continue;
    }
    const interval = times[index]! - times[index - 1]!;
    if (!(interval > 0)) continue;
    intervals.push(interval);
    if (previous !== null) successive.push(interval - previous);
    previous = interval;
  }
  let averageHeartRate: number | null = null;
  let sdnn: number | null = null;
  if (intervals.length > 0) {
    let sum = 0;
    for (const interval of intervals) sum += interval;
    const mean = sum / intervals.length;
    averageHeartRate = 60 / mean;
    if (intervals.length > 1) {
      let squares = 0;
      for (const interval of intervals) squares += (interval - mean) * (interval - mean);
      sdnn = Math.sqrt(squares / (intervals.length - 1)) * 1000;
    }
  }
  let rmssd: number | null = null;
  if (successive.length > 0) {
    let squares = 0;
    for (const difference of successive) squares += difference * difference;
    rmssd = Math.sqrt(squares / successive.length) * 1000;
  }
  return {
    beatCount: times.length,
    duration: times.length === 0 ? 0 : times[times.length - 1]! - times[0]!,
    intervalCount: intervals.length,
    averageHeartRate,
    sdnn,
    rmssd,
  };
};

const rounded = (value: number | null) => (value === null ? null : roundTo(value, 2));

/**
 * The `heartbeat_series` tool from the user's store: the series that start in the period, newest
 * first, at most `heartbeatSeriesLimit`, with how many there are, counted only when they don't
 * all fit.
 */
export const healthHeartbeatSeries = Effect.fn("healthHeartbeatSeries")(function* (
  sql: StoreSql,
  input: {
    readonly range: ToolRange;
    readonly date?: string | undefined;
    readonly timeZone?: string | undefined;
  },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const now = yield* Clock.currentTimeMillis;
  const period = yield* toolPeriod(input.range, input.date, now, zone);
  const where = "start_date >= ? AND start_date < ?";
  const rows = sql
    .exec(
      `SELECT ${seriesColumns} FROM health_heartbeat_series WHERE ${where}
      ORDER BY start_date DESC, id DESC LIMIT ?`,
      period.start,
      period.end,
      heartbeatSeriesLimit,
    )
    .map(seriesRow);
  const count =
    rows.length < heartbeatSeriesLimit
      ? rows.length
      : Number(
          sql.exec(
            `SELECT count(*) AS count FROM health_heartbeat_series WHERE ${where}`,
            period.start,
            period.end,
          )[0]?.["count"] ?? 0,
        );
  const zones = new RecordedZones();
  const result: SeriesResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    count,
    series: rows.map((series) => {
      const { times, gaps } = seriesBeats(series);
      const analysis = heartbeatAnalysis(times, gaps);
      return {
        id: series.id,
        start: localTime(series.startDate, zone),
        end: localTime(series.endDate, zone),
        ...zones.times(jsonObject(series.metadata), series.startDate, series.endDate),
        beatCount: analysis.beatCount,
        duration: roundTo(analysis.duration, 4),
        gapCount: times.reduce((gapCount, _, index) => gapCount + (gaps.has(index) ? 1 : 0), 0),
        intervalCount: analysis.intervalCount,
        averageHeartRate: rounded(analysis.averageHeartRate),
        sdnn: rounded(analysis.sdnn),
        rmssd: rounded(analysis.rmssd),
        source: series.sourceName,
      };
    }),
  };
  return result;
});

/**
 * The `heartbeat_series_beats` tool from the user's store: a page of a series' beats, `limit` of
 * them from the cursor, the index of the page's first beat.
 */
export const healthHeartbeatSeriesBeats = Effect.fn("healthHeartbeatSeriesBeats")(function* (
  sql: StoreSql,
  input: {
    readonly id: string;
    readonly timeZone?: string | undefined;
    readonly cursor?: string | undefined;
    readonly limit?: number | undefined;
  },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const series = sql
    .exec(`SELECT ${seriesColumns} FROM health_heartbeat_series WHERE id = ?`, input.id)
    .map(seriesRow)[0];
  if (series === undefined) {
    return yield* new HealthToolError({
      message: `No heartbeat series with ID ${input.id}. heartbeat_series lists them, with their IDs.`,
    });
  }
  const { times, gaps } = seriesBeats(series);
  const start = input.cursor === undefined ? 0 : cursorIndex(input.cursor);
  if (start === null || start > times.length) {
    return yield* new HealthToolError({
      message: `Invalid cursor: ${input.cursor}. Pass the previous page's nextCursor.`,
    });
  }
  const end = Math.min(start + (input.limit ?? heartbeatBeatsDefaultLimit), times.length);
  const beats: Array<BeatsResult["beats"][number]> = [];
  for (let index = start; index < end; index++) {
    const precededByGap = gaps.has(index);
    beats.push({
      time: roundTo(times[index]!, 4),
      interval:
        index === 0 || precededByGap
          ? null
          : roundTo((times[index]! - times[index - 1]!) * 1000, 1),
      precededByGap,
    });
  }
  const result: BeatsResult = {
    timeZone: name,
    id: series.id,
    start: localTime(series.startDate, zone),
    beatCount: times.length,
    beats,
    nextCursor: end < times.length ? String(end) : null,
  };
  return result;
});
