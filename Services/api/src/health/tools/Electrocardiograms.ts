import { Clock, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { metadataValue } from "../MetadataValues.ts";
import {
  electrocardiogramsLimit,
  HealthToolError,
  type HealthToolkit,
  voltagesDefaultSeconds,
  voltagesValueLimit,
} from "./HealthToolkit.ts";
import { RecordedZones } from "./RecordedTimes.ts";
import { jsonObject } from "./SampleDetails.ts";
import { localTime, type ToolRange, toolPeriod, toolTimeZone } from "./ToolTime.ts";
import { cursorIndex, type HealthBlobReader, roundTo } from "./WorkoutRoutes.ts";

// The ECG tools (851-4159): `electrocardiograms` lists recordings from their rows, in the words of
// the Mac's ECG page (`ElectrocardiogramsView.swift`), and `electrocardiogram_voltages` reads one
// recording's voltages from its blob, a page of seconds at a time, as the privacy policy says
// (851-4157). The Mac's `HealthTools` does the same (`Electrocardiograms.swift`), rule for rule.

type RecordingsResult = (typeof HealthToolkit.tools.electrocardiograms.successSchema)["Type"];
type VoltagesResult = (typeof HealthToolkit.tools.electrocardiogram_voltages.successSchema)["Type"];

/** `HKElectrocardiogram.Classification`'s names, as the Mac's `ECGClassification` names them. */
const classifications: ReadonlyMap<number, string> = new Map([
  [1, "Sinus Rhythm"],
  [2, "Atrial Fibrillation"],
  [3, "Low Heart Rate"],
  [4, "High Heart Rate"],
  [5, "Poor Recording"],
  [6, "Inconclusive"],
  [100, "Unrecognized"],
]);

/** A classification's name; not set, or one a later iOS adds, is Not Classified, as on the page. */
const classificationName = (raw: number) => classifications.get(raw) ?? "Not Classified";

/** `HKElectrocardiogram.SymptomsStatus` as the page says it (`HealthElectrocardiogram.symptomsName`). */
const symptomsName = (raw: number) =>
  raw === 1 ? "No Symptoms" : raw === 2 ? "Symptoms Logged" : "Not Logged";

/** An ECG as stored (`health_electrocardiogram`). */
interface RecordingRow {
  readonly id: string;
  readonly startDate: number;
  readonly endDate: number;
  readonly classification: number;
  readonly symptomsStatus: number;
  readonly averageHeartRate: number | null;
  readonly samplingFrequency: number | null;
  readonly voltageCount: number;
  /** The voltages blob's SHA-256, or null without measurements. */
  readonly voltages: string | null;
  readonly sourceName: string;
  readonly metadata: string | null;
}

const recordingColumns = `id, start_date, end_date, classification, symptoms_status,
  average_heart_rate, sampling_frequency, voltage_count, voltages, source_name, metadata`;

const nullableNumber = (value: unknown) => (value === null ? null : Number(value));

const recordingRow = (row: Record<string, unknown>): RecordingRow => ({
  id: row["id"] as string,
  startDate: Number(row["start_date"]),
  endDate: Number(row["end_date"]),
  classification: Number(row["classification"]),
  symptomsStatus: Number(row["symptoms_status"]),
  averageHeartRate: nullableNumber(row["average_heart_rate"]),
  samplingFrequency: nullableNumber(row["sampling_frequency"]),
  voltageCount: Number(row["voltage_count"]),
  voltages: (row["voltages"] as string | null) ?? null,
  sourceName: row["source_name"] as string,
  metadata: (row["metadata"] as string | null) ?? null,
});

/**
 * The `electrocardiograms` tool from the user's store: the recordings that start in the period,
 * newest first, at most `electrocardiogramsLimit`, with how many there are, counted only when
 * they don't all fit.
 */
export const healthElectrocardiograms = Effect.fn("healthElectrocardiograms")(function* (
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
  const recordings = sql
    .exec(
      `SELECT ${recordingColumns} FROM health_electrocardiogram WHERE ${where}
      ORDER BY start_date DESC, id DESC LIMIT ?`,
      period.start,
      period.end,
      electrocardiogramsLimit,
    )
    .map(recordingRow);
  const count =
    recordings.length < electrocardiogramsLimit
      ? recordings.length
      : Number(
          sql.exec(
            `SELECT count(*) AS count FROM health_electrocardiogram WHERE ${where}`,
            period.start,
            period.end,
          )[0]?.["count"] ?? 0,
        );
  const zones = new RecordedZones();
  const result: RecordingsResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    count,
    recordings: recordings.map((recording) => {
      const metadata = jsonObject(recording.metadata);
      const algorithmVersion = metadataValue(metadata, "HKMetadataKeyAppleECGAlgorithmVersion");
      return {
        id: recording.id,
        start: localTime(recording.startDate, zone),
        end: localTime(recording.endDate, zone),
        ...zones.times(metadata, recording.startDate, recording.endDate),
        duration: (recording.endDate - recording.startDate) / 1000,
        classification: classificationName(recording.classification),
        averageHeartRate: recording.averageHeartRate,
        samplingFrequency: recording.samplingFrequency,
        voltageCount: recording.voltageCount,
        symptoms: symptomsName(recording.symptomsStatus),
        ...(algorithmVersion === null ? {} : { algorithmVersion }),
        source: recording.sourceName,
      };
    }),
  };
  return result;
});

/**
 * Measurements per second, as the Mac's `HealthElectrocardiogram.measurementsPerSecond`: as
 * recorded, or worked out from the count and the recording's length if that's missing or not
 * positive, or Apple Watch's 512 Hz.
 */
export const measurementsPerSecond = (recording: {
  readonly samplingFrequency: number | null;
  readonly voltageCount: number;
  readonly startDate: number;
  readonly endDate: number;
}) => {
  if (recording.samplingFrequency !== null && recording.samplingFrequency > 0) {
    return recording.samplingFrequency;
  }
  const seconds = (recording.endDate - recording.startDate) / 1000;
  if (recording.voltageCount > 0 && seconds > 0) return recording.voltageCount / seconds;
  return 512;
};

/**
 * An ECG's voltages blob as microvolts: one little-endian 32-bit float per measurement, NaN where
 * one has no value, as the Mac's `HealthDatabase.electrocardiogramMicrovolts`. Bytes past the last
 * whole float are ignored.
 */
export const microvolts = (bytes: Uint8Array): Float32Array => {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const values = new Float32Array(Math.floor(bytes.byteLength / 4));
  for (let index = 0; index < values.length; index++) {
    values[index] = view.getFloat32(index * 4, true);
  }
  return values;
};

/**
 * A page of values from `start` to `end` (exclusive), each the average of `every` measurements in
 * a row (the last of fewer), skipping those without a value, to 2 decimal places, or null where
 * none has one.
 */
const pageValues = (values: Float32Array, start: number, end: number, every: number) => {
  const page: Array<number | null> = [];
  for (let first = start; first < end; first += every) {
    let sum = 0;
    let count = 0;
    for (let index = first; index < Math.min(first + every, end); index++) {
      const value = values[index]!;
      if (Number.isFinite(value)) {
        sum += value;
        count += 1;
      }
    }
    page.push(count === 0 ? null : roundTo(sum / count, 2));
  }
  return page;
};

/**
 * The `electrocardiogram_voltages` tool from the user's store: a page of a recording's voltages,
 * `seconds` of it at its own rate, or downsampled to at most `voltagesValueLimit` values. The
 * cursor is the index of the page's first measurement.
 */
export const healthElectrocardiogramVoltages = Effect.fn("healthElectrocardiogramVoltages")(
  function* (
    sql: StoreSql,
    blobs: HealthBlobReader,
    input: {
      readonly id: string;
      readonly timeZone?: string | undefined;
      readonly cursor?: string | undefined;
      readonly seconds?: number | undefined;
    },
  ) {
    const { zone, name } = yield* toolTimeZone(input.timeZone);
    const invalidCursor = new HealthToolError({
      message: `Invalid cursor: ${input.cursor}. Pass the previous page's nextCursor.`,
    });
    // Checked before the voltages are read, as on the Mac, which may have to download them.
    const start = input.cursor === undefined ? 0 : cursorIndex(input.cursor);
    if (start === null) return yield* invalidCursor;
    const recording = sql
      .exec(`SELECT ${recordingColumns} FROM health_electrocardiogram WHERE id = ?`, input.id)
      .map(recordingRow)[0];
    if (recording === undefined) {
      return yield* new HealthToolError({
        message: `No ECG with ID ${input.id}. electrocardiograms lists them, with their IDs.`,
      });
    }
    if (recording.voltages === null) {
      return yield* new HealthToolError({
        message: `The ECG ${input.id} has no voltage measurements (its voltageCount is 0).`,
      });
    }
    const bytes = yield* blobs(recording.voltages, "the ECG's voltages");
    if (bytes === null) {
      return yield* new HealthToolError({
        message: "The ECG's voltages aren't on the server. Try again later.",
      });
    }
    const values = microvolts(bytes);
    if (start > values.length) return yield* invalidCursor;
    const frequency = measurementsPerSecond(recording);
    const seconds = input.seconds ?? voltagesDefaultSeconds;
    // Measurements a page covers, at least one, and never more than the recording has (a rate
    // that isn't plausible could make it any number).
    const perPage = Math.max(1, Math.min(values.length, Math.round(frequency * seconds)));
    const every = Math.ceil(perPage / voltagesValueLimit);
    const end = Math.min(start + perPage, values.length);
    const result: VoltagesResult = {
      timeZone: name,
      id: recording.id,
      start: localTime(recording.startDate, zone),
      samplingFrequency: frequency,
      voltageCount: values.length,
      offset: start / frequency,
      rate: frequency / every,
      measurementsPerValue: every,
      values: pageValues(values, start, end, every),
      nextCursor: end < values.length ? String(end) : null,
    };
    return result;
  },
);
