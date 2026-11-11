import { Clock, Effect, Option, Schema } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { audiogramsLimit, type HealthToolkit } from "./HealthToolkit.ts";
import { RecordedZones } from "./RecordedTimes.ts";
import { jsonObject } from "./SampleDetails.ts";
import { localTime, type ToolRange, toolPeriod, toolTimeZone } from "./ToolTime.ts";

// The `audiograms` tool (851-4161): audiograms in a period, in the words of the Mac's Audiogram
// page (`AudiogramsView.swift`): each ear's hearing level and what it means, and every frequency's
// tests. Points are read as the Mac's `HealthAudiogram.decodedFrequencies` reads them, and the
// Mac's `HealthTools` gives the same (`Audiograms.swift`), rule for rule.

type AudiogramsResult = (typeof HealthToolkit.tools.audiograms.successSchema)["Type"];
type EarResult = AudiogramsResult["audiograms"][number]["leftEar"];
type TestResult = AudiogramsResult["audiograms"][number]["points"][number]["left"][number];

/**
 * A whole number Swift's `Int` holds (64 bits), as the Mac decodes a test's side and conduction
 * type: one past it fails the test there, so it does here.
 */
const Int64 = Schema.Int.check(
  Schema.makeFilter((value) => value >= -(2 ** 63) && value < 2 ** 63),
);

/** A key that may be missing or null, as Swift decodes an optional. */
const nullable = <S extends Schema.Top>(schema: S) => Schema.optionalKey(Schema.NullOr(schema));

/** A test as stored (`HealthAudiogram`'s `points`), with the keys the Mac reads. */
const StoredTest = Schema.Struct({
  side: Int64,
  type: nullable(Int64),
  masked: nullable(Schema.Boolean),
  sensitivity: Schema.Number,
  clampingLower: nullable(Schema.Number),
  clampingUpper: nullable(Schema.Number),
});
type StoredTest = (typeof StoredTest)["Type"];

const StoredPoint = Schema.Struct({
  frequency: Schema.Number,
  tests: Schema.Array(Schema.Unknown),
});

const decodePoints = Schema.decodeUnknownOption(
  Schema.fromJsonString(Schema.Array(Schema.Unknown)),
);
const decodePoint = Schema.decodeUnknownOption(StoredPoint);
const decodeTest = Schema.decodeUnknownOption(StoredTest);

/** A frequency's tests, those that can be read, each on its own. */
interface Frequency {
  readonly frequency: number;
  readonly tests: ReadonlyArray<StoredTest>;
}

/**
 * An audiogram's frequencies, as recorded, leaving out points and tests that can't be read, each on
 * its own, as the Mac's `decodedFrequencies`. None if the JSON isn't an array.
 */
export const audiogramFrequencies = (json: string): Array<Frequency> =>
  Option.getOrElse(decodePoints(json), () => []).flatMap((value) =>
    Option.match(decodePoint(value), {
      onNone: () => [],
      onSome: (point) => [
        {
          frequency: point.frequency,
          tests: point.tests.flatMap((test) => Option.toArray(decodeTest(test))),
        },
      ],
    }),
  );

/**
 * An ear's tests (`side` 0 is the left, 1 the right): the one the page charts first (air
 * conduction, unmasked before masked, else the first), then the others as recorded.
 */
/** Air conduction, as a test without a type is (the Mac's `isAirConduction`). */
const isAir = (test: StoredTest) => (test.type ?? 0) === 0;

export const earTests = (tests: ReadonlyArray<StoredTest>, side: 0 | 1): Array<StoredTest> => {
  const ear = tests.filter((test) => test.side === side);
  const air = ear.filter(isAir);
  const charted = air.find((test) => test.masked !== true) ?? air[0] ?? ear[0];
  return charted === undefined ? [] : [charted, ...ear.filter((test) => test !== charted)];
};

/** `value`, never `-0`, as the Mac gives it. */
const plain = (value: number) => value + 0;

const testResult = (test: StoredTest): TestResult => ({
  sensitivity: plain(test.sensitivity),
  conduction: isAir(test) ? "Air" : "Unknown",
  masked: test.masked === true,
  clamped: test.clampingLower != null || test.clampingUpper != null,
  ...(test.clampingLower == null ? {} : { clampingLower: plain(test.clampingLower) }),
  ...(test.clampingUpper == null ? {} : { clampingUpper: plain(test.clampingUpper) }),
});

/** The speech range's frequencies, which an ear's hearing level averages. */
const speech = new Set([500, 1000, 2000, 4000]);

/**
 * An ear's hearing level in whole dBHL, as the page's `averageHearingLevel`: the average of its
 * charted sensitivities in the speech range, or at every frequency tested if it has none there,
 * halves away from zero; null if the ear wasn't tested.
 */
export const hearingLevel = (
  charted: ReadonlyArray<{ frequency: number; sensitivity: number }>,
) => {
  const inSpeech = charted.filter((point) => speech.has(point.frequency));
  const values = (inSpeech.length === 0 ? charted : inSpeech).map((point) => point.sensitivity);
  if (values.length === 0) return null;
  let sum = 0;
  for (const value of values) sum += value;
  const average = sum / values.length;
  return plain(Math.sign(average) * Math.round(Math.abs(average)));
};

/** What a hearing level means, as the page's `HearingLevel` names it. */
export const hearingLoss = (level: number) =>
  level <= 25
    ? "Little to No Hearing Loss"
    : level <= 40
      ? "Mild Hearing Loss"
      : level <= 60
        ? "Moderate Hearing Loss"
        : level <= 80
          ? "Severe Hearing Loss"
          : "Profound Hearing Loss";

/** An ear's hearing level and what it means, from its charted test at each frequency. */
const earResult = (
  frequencies: ReadonlyArray<{ frequency: number } & Record<"left" | "right", Array<StoredTest>>>,
  ear: "left" | "right",
): EarResult => {
  const level = hearingLevel(
    frequencies.flatMap(({ frequency, [ear]: [charted] }) =>
      charted === undefined ? [] : [{ frequency, sensitivity: charted.sensitivity }],
    ),
  );
  return { hearingLevel: level, hearingLoss: level === null ? null : hearingLoss(level) };
};

/** An audiogram as stored (`health_audiogram`), its points JSON. */
interface AudiogramRow {
  readonly id: string;
  readonly startDate: number;
  readonly endDate: number;
  readonly points: string;
  readonly sourceName: string;
  readonly metadata: string | null;
}

/**
 * The `audiograms` tool from the user's store: the audiograms that start in the period, newest
 * first, at most `audiogramsLimit`, with how many there are, counted only when they don't all fit.
 */
export const healthAudiograms = Effect.fn("healthAudiograms")(function* (
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
  const audiograms = sql
    .exec(
      `SELECT id, start_date, end_date, points, source_name, metadata FROM health_audiogram
      WHERE ${where} ORDER BY start_date DESC, id DESC LIMIT ?`,
      period.start,
      period.end,
      audiogramsLimit,
    )
    .map((row): AudiogramRow => ({
      id: row["id"] as string,
      startDate: Number(row["start_date"]),
      endDate: Number(row["end_date"]),
      points: row["points"] as string,
      sourceName: row["source_name"] as string,
      metadata: (row["metadata"] as string | null) ?? null,
    }));
  const count =
    audiograms.length < audiogramsLimit
      ? audiograms.length
      : Number(
          sql.exec(
            `SELECT count(*) AS count FROM health_audiogram WHERE ${where}`,
            period.start,
            period.end,
          )[0]?.["count"] ?? 0,
        );
  const zones = new RecordedZones();
  const result: AudiogramsResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    count,
    audiograms: audiograms.map((audiogram) => {
      const frequencies = audiogramFrequencies(audiogram.points).map(({ frequency, tests }) => ({
        frequency,
        left: earTests(tests, 0),
        right: earTests(tests, 1),
      }));
      return {
        id: audiogram.id,
        start: localTime(audiogram.startDate, zone),
        end: localTime(audiogram.endDate, zone),
        ...zones.times(jsonObject(audiogram.metadata), audiogram.startDate, audiogram.endDate),
        leftEar: earResult(frequencies, "left"),
        rightEar: earResult(frequencies, "right"),
        points: frequencies.map(({ frequency, left, right }) => ({
          frequency: plain(frequency),
          left: left.map(testResult),
          right: right.map(testResult),
        })),
        source: audiogram.sourceName,
      };
    }),
  };
  return result;
});
