// Synthetic Health data for the sync throughput benchmark (851-2650, `scripts/bench-sync.ts`):
// batch files in exactly the format the iPhone uploads (`HealthBatchWriter`,
// `LilPackage/Sources/HealthUpload`), made up, never read from anyone's Health.
//
// Like the iPhone's backfill, it goes a type at a time in time order, in pages of 10,000 records
// cut into files of at most 5,000 (and 15 MB before compression). A record's source revision and
// device go once per file as a `health_provenance` record, which the record refers to.
import { createHash } from "node:crypto";

/** The iPhone's backfill reads this many records a page (`docs/SYNC.md`)... */
export const pageRecords = 10_000;
/** ...and writes them to files of at most this many, uploaded at once. */
export const fileRecords = 5_000;
/** `HealthBatchWriter.maxFileBytes`. */
export const maxFileBytes = 15 * 1024 * 1024;

/** A line of a batch file: a mutation in the push format. */
export interface Mutation {
  readonly entity: string;
  readonly op: "upsert";
  readonly id: string;
  readonly row: Readonly<Record<string, unknown>>;
}

/** A batch file before compression. */
export interface BatchFile {
  /** NDJSON, one mutation a line. */
  readonly text: string;
  /** Mutations, not counting the `health_provenance` records. */
  readonly records: number;
  /** The `health_provenance` records in it. */
  readonly provenances: ReadonlyArray<string>;
}

/** What makes up the data: each kind's share of the records. */
interface Kind {
  readonly name: string;
  readonly share: number;
  /** The record at `index` of `count`, oldest first, ending at `end`. */
  readonly make: (index: number, count: number, context: Context) => Mutation;
}

interface Context {
  readonly random: () => number;
  readonly uuid: () => string;
  /** Unix milliseconds the data ends at. */
  readonly end: number;
  readonly watch: Provenance;
  readonly phone: Provenance;
}

/** A source revision and device, as `HealthEncoder.provenance(of:)` has them. */
interface Provenance {
  readonly sourceName: string;
  readonly sourceBundleId: string;
  readonly sourceRevision: Readonly<Record<string, unknown>>;
  readonly device: Readonly<Record<string, unknown>> | null;
}

/** A seeded pseudo-random generator (mulberry32), so a run's data can be made again. */
export const seededRandom = (seed: number) => {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
};

/** A lowercase version 4 UUID, as HealthKit's are once lowercased. */
const uuidFrom = (random: () => number) => () => {
  const hex = (digits: number) => {
    let text = "";
    for (let index = 0; index < digits; index++) text += Math.floor(random() * 16).toString(16);
    return text;
  };
  const variant = (8 + Math.floor(random() * 4)).toString(16);
  return `${hex(8)}-${hex(4)}-4${hex(3)}-${variant}${hex(3)}-${hex(12)}`;
};

/** JSON with sorted keys and no spaces, as the iPhone's `JSONEncoder` writes it. */
export const sortedJson = (value: unknown): string => {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(sortedJson).join(",")}]`;
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, member]) => member !== undefined)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return `{${entries.map(([key, member]) => `${JSON.stringify(key)}:${sortedJson(member)}`).join(",")}}`;
};

/**
 * The `health_provenance` record for a source revision and device: its ID is the first 16 bytes
 * of the SHA-256 of their sorted-key JSON, as hex (`HealthBatchWriter`).
 */
export const provenanceRecord = (provenance: Provenance): Mutation => {
  const pair = { sourceRevision: provenance.sourceRevision, device: provenance.device };
  const id = createHash("sha256").update(sortedJson(pair)).digest("hex").slice(0, 32);
  return { entity: "health_provenance", op: "upsert", id, row: pair };
};

const minute = 60_000;
const bucket = 30 * minute;

/** A sample's row, with its provenance as the iPhone sends it once separated. */
const sampleRow = (
  provenance: Provenance,
  fields: Record<string, unknown>,
): Record<string, unknown> => ({
  ...fields,
  sourceName: provenance.sourceName,
  sourceBundleId: provenance.sourceBundleId,
  sourceRevision: provenance.sourceRevision,
  device: provenance.device,
});

const quantity = (
  name: string,
  share: number,
  unit: string,
  spacing: number,
  value: (random: () => number) => number,
  source: "watch" | "phone" = "watch",
  metadata: Record<string, unknown> | null = null,
): Kind =>
  ({
    name,
    share,
    make: (index, count, context) => {
      const startDate = context.end - (count - index) * spacing;
      return {
        entity: "health_sample",
        op: "upsert",
        id: context.uuid(),
        row: sampleRow(context[source], {
          type: `HKQuantityTypeIdentifier${name}`,
          startDate,
          endDate: startDate + Math.min(spacing, minute),
          value: value(context.random),
          unit,
          categoryValue: null,
          metadata,
        }),
      };
    },
  }) satisfies Kind;

const category = (name: string, share: number, spacing: number, values: number): Kind => ({
  name,
  share,
  make: (index, count, context) => {
    const startDate = context.end - (count - index) * spacing;
    return {
      entity: "health_sample",
      op: "upsert",
      id: context.uuid(),
      row: sampleRow(context.watch, {
        type: `HKCategoryTypeIdentifier${name}`,
        startDate,
        endDate: startDate + spacing / 2,
        value: null,
        unit: null,
        categoryValue: Math.floor(context.random() * values),
        metadata: { HKTimeZone: "Europe/Bucharest" },
      }),
    };
  },
});

/** 30-minute sums, as the iPhone uploads them: keyed by type and bucket, without its device. */
const statistic = (name: string, share: number, unit: string): Kind => ({
  name: `${name} sums`,
  share,
  make: (index, count, context) => {
    const type = `HKQuantityTypeIdentifier${name}`;
    const bucketStart = Math.floor(context.end / bucket) * bucket - (count - index) * bucket;
    return {
      entity: "health_statistic",
      op: "upsert",
      id: `${type}@${bucketStart}`,
      row: { type, bucketStart, sum: Math.round(context.random() * 50_000) / 100, unit },
    };
  },
});

const workouts: Kind = {
  name: "Workouts",
  share: 0.001,
  make: (index, count, context) => {
    const startDate = context.end - (count - index) * 2 * 24 * 60 * minute;
    const duration = 1200 + Math.round(context.random() * 3600);
    const endDate = startDate + duration * 1000;
    const energy = Math.round(duration * 0.15 * 10) / 10;
    return {
      entity: "health_workout",
      op: "upsert",
      id: context.uuid(),
      row: {
        ...sampleRow(context.watch, {
          startDate,
          endDate,
          metadata: { HKIndoorWorkout: false, HKTimeZone: "Europe/Bucharest" },
        }),
        activityType: context.random() < 0.6 ? 52 : 37,
        duration,
        activities: [],
        events: [{ type: 7, startDate, endDate: startDate + 600_000, metadata: null }],
        statistics: {
          HKQuantityTypeIdentifierActiveEnergyBurned: {
            unit: "kcal",
            sum: energy,
            average: null,
            minimum: null,
            maximum: null,
            mostRecent: null,
          },
          HKQuantityTypeIdentifierHeartRate: {
            unit: "count/min",
            sum: null,
            average: 128,
            minimum: 92,
            maximum: 161,
            mostRecent: 140,
          },
        },
      },
    };
  },
};

const round = (digits: number) => (value: number) =>
  Math.round(value * 10 ** digits) / 10 ** digits;

/**
 * The mix, roughly a Watch wearer's Health: mostly heart rate and energy samples, some steps,
 * distance, sleep and stand hours, the iPhone's 30-minute sums, and a few workouts.
 */
export const kinds: ReadonlyArray<Kind> = [
  quantity(
    "HeartRate",
    0.38,
    "count/min",
    5 * minute,
    (random) => 55 + Math.round(random() * 90),
    "watch",
    {
      HKMetadataKeyHeartRateMotionContext: 1,
    },
  ),
  quantity("ActiveEnergyBurned", 0.2, "kcal", minute, (random) => round(3)(random() * 8)),
  quantity("BasalEnergyBurned", 0.14, "kcal", 2 * minute, (random) => round(3)(1 + random() * 2)),
  quantity(
    "DistanceWalkingRunning",
    0.09,
    "m",
    3 * minute,
    (random) => round(2)(random() * 400),
    "phone",
  ),
  quantity("StepCount", 0.08, "count", 3 * minute, (random) => Math.round(random() * 500), "phone"),
  category("SleepAnalysis", 0.025, 20 * minute, 6),
  category("AppleStandHour", 0.02, 60 * minute, 2),
  statistic("StepCount", 0.025, "count"),
  statistic("ActiveEnergyBurned", 0.019, "kcal"),
  workouts,
];

/** How many records of each kind make `total`: their shares, rounded, adding up to `total`. */
export const kindCounts = (total: number): ReadonlyArray<number> => {
  const shares = kinds.reduce((sum, kind) => sum + kind.share, 0);
  const counts = kinds.map((kind) => Math.floor((total * kind.share) / shares));
  // What rounding down left over goes to the largest kind.
  counts[0] = (counts[0] ?? 0) + total - counts.reduce((sum, count) => sum + count, 0);
  return counts;
};

export interface SyntheticOptions {
  /** Records in all, not counting `health_provenance` records. */
  readonly records: number;
  readonly seed: number;
  /** Unix milliseconds the data ends at. */
  readonly end: number;
  /**
   * Makes this run's devices its own, so their `health_provenance` records are new to an account
   * that has some from an earlier run (`HKDevice.localIdentifier`).
   */
  readonly run: string;
  readonly fileRecords?: number;
}

/**
 * The batch files for `options.records` records, in the order the iPhone would upload them.
 * Made one at a time, so a big run doesn't hold them all in memory.
 */
export function* syntheticBatches(options: SyntheticOptions): Generator<BatchFile> {
  const random = seededRandom(options.seed);
  const device = (name: string, model: string, hardware: string): Record<string, unknown> => ({
    name,
    manufacturer: "Apple Inc.",
    model,
    hardwareVersion: hardware,
    softwareVersion: "26.0",
    localIdentifier: `${options.run}-${hardware}`,
  });
  const context: Context = {
    random,
    uuid: uuidFrom(random),
    end: options.end,
    watch: {
      sourceName: "Synthetic Watch",
      sourceBundleId: "com.apple.health.00000000-0000-4000-8000-000000000001",
      sourceRevision: {
        version: "26.0",
        productType: "Watch7,5",
        operatingSystemVersion: "26.0.0",
      },
      device: device("Apple Watch", "Watch", "Watch7,5"),
    },
    phone: {
      sourceName: "Synthetic iPhone",
      sourceBundleId: "com.apple.health.00000000-0000-4000-8000-000000000002",
      sourceRevision: {
        version: "26.0",
        productType: "iPhone18,1",
        operatingSystemVersion: "26.0.0",
      },
      device: device("iPhone", "iPhone", "iPhone18,1"),
    },
  };
  const perFile = options.fileRecords ?? fileRecords;
  const counts = kindCounts(options.records);
  for (const [kindIndex, kind] of kinds.entries()) {
    const count = counts[kindIndex] ?? 0;
    for (let page = 0; page < count; page += pageRecords) {
      const pageEnd = Math.min(page + pageRecords, count);
      let writer = fileWriter();
      for (let index = page; index < pageEnd; index++) {
        const mutation = kind.make(index, count, context);
        const finished = writer.append(mutation, perFile);
        if (finished !== undefined) {
          yield finished;
          writer = fileWriter();
          writer.append(mutation, perFile);
        }
      }
      const last = writer.finish();
      if (last !== undefined) yield last;
    }
  }
}

/**
 * Collects lines into one file as `HealthBatchWriter` does: a record's source revision and
 * device become a `health_provenance` record, written once before the first record that refers
 * to it. `append` returns the file, without the record, once the record doesn't fit; the caller
 * starts a new file with it.
 */
const fileWriter = () => {
  const lines: Array<string> = [];
  const provenances = new Set<string>();
  let bytes = 0;
  let records = 0;
  const finish = (): BatchFile | undefined =>
    records === 0 ? undefined : { text: lines.join("\n"), records, provenances: [...provenances] };
  return {
    finish,
    append: (mutation: Mutation, perFile: number): BatchFile | undefined => {
      const { row } = mutation;
      let line = sortedJson(mutation);
      let provenanceLine: string | undefined;
      let provenanceId: string | undefined;
      if (row["sourceRevision"] !== undefined || row["device"] !== undefined) {
        const record = provenanceRecord(row as unknown as Provenance);
        provenanceId = record.id;
        if (!provenances.has(record.id)) provenanceLine = sortedJson(record);
        line = sortedJson({
          ...mutation,
          row: { ...row, sourceRevision: null, device: null, provenance: record.id },
        });
      }
      const size =
        bytes + (provenanceLine === undefined ? 0 : provenanceLine.length + 1) + line.length + 1;
      if (records >= perFile || (records > 0 && size > maxFileBytes)) return finish();
      if (provenanceLine !== undefined && provenanceId !== undefined) {
        lines.push(provenanceLine);
        provenances.add(provenanceId);
        bytes += provenanceLine.length + 1;
      }
      lines.push(line);
      bytes += line.length + 1;
      records++;
      return undefined;
    },
  };
};
