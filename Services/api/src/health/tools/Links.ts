import { Option, Predicate, Schema } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { healthCatalogType } from "../HealthCatalog.ts";
import { liveSample } from "./HealthQueries.ts";

// What HealthKit links to a workout or an ECG (851-4153), as the tools read it (851-4187): a
// workout's effort scores and an ECG's symptoms, from their link records (`health_workout_effort`,
// `health_electrocardiogram_symptoms`) and the samples they name, those that have arrived. The
// Mac's pages and tools read them alike (`LinkQueries.swift` in `HealthDatabase`, 851-4186).

export const workoutEffortScoreType = "HKQuantityTypeIdentifierWorkoutEffortScore";
export const estimatedWorkoutEffortScoreType =
  "HKQuantityTypeIdentifierEstimatedWorkoutEffortScore";

/** A linked sample, as the tools read it. */
interface LinkedSample {
  readonly id: string;
  readonly type: string;
  readonly startDate: number;
  readonly value: number | null;
}

/** The samples with these IDs that have arrived (and aren't deleted), in order of start, then ID. */
const samplesWithIds = (sql: StoreSql, ids: ReadonlyArray<string>): ReadonlyArray<LinkedSample> =>
  ids.length === 0
    ? []
    : sql
        .exec(
          `SELECT s.id, s.type, s.start_date, s.value FROM health_sample s
          WHERE s.id IN (SELECT value FROM json_each(?)) AND ${liveSample}
          ORDER BY s.start_date, s.id`,
          JSON.stringify(ids),
        )
        .map((row) => ({
          id: row["id"] as string,
          type: row["type"] as string,
          startDate: Number(row["start_date"]),
          value: typeof row["value"] === "number" ? row["value"] : null,
        }));

const IDs = Schema.Array(Schema.String);
const decodeIDs = Schema.decodeUnknownOption(Schema.fromJsonString(IDs));
const decodeLegs = Schema.decodeUnknownOption(
  Schema.fromJsonString(
    Schema.Array(
      Schema.Struct({
        activity: Schema.String,
        samples: IDs,
        mostRelevant: Schema.optionalKey(Schema.NullOr(Schema.String)),
      }),
    ),
  ),
);
/** A link record's `samples`: type identifiers to their samples' IDs. */
const decodeLinkedIDs = Schema.decodeUnknownOption(
  Schema.fromJsonString(Schema.Record(Schema.String, IDs)),
);

/** An effort score, as `workout` gives it. */
export interface EffortScore {
  readonly score: number;
  readonly estimated: boolean;
}

/** A workout's effort scores: the whole workout's, and each leg's by its activity's ID. */
export interface WorkoutEffort {
  readonly effort: EffortScore | null;
  readonly legs: ReadonlyMap<string, EffortScore>;
}

/**
 * The score that stands for a workout or a leg among the samples related to it: the one HealthKit
 * finds most relevant, else (it hasn't arrived) the latest the person rated that has, else Apple
 * Watch's latest estimate, as the Mac's `HealthDatabase.effortScore`. Null if none has, or it has
 * no value.
 */
const effortScore = (
  samples: ReadonlyArray<LinkedSample>,
  ids: ReadonlyArray<string>,
  mostRelevant: string | null,
): EffortScore | null => {
  const related = new Set(ids);
  const arrived = samples.filter((sample) => related.has(sample.id));
  const sample =
    arrived.find((each) => each.id === mostRelevant) ??
    arrived.findLast((each) => each.type === workoutEffortScoreType) ??
    arrived.at(-1);
  if (sample === undefined || sample.value === null) return null;
  return { score: sample.value, estimated: sample.type === estimatedWorkoutEffortScoreType };
};

/**
 * The effort scores related to the workout with ID `id`, from its `health_workout_effort` record:
 * none without one (it has no scores, or they haven't synced), and none for a record that can't
 * be read.
 */
export const workoutEffort = (sql: StoreSql, id: string): WorkoutEffort => {
  const none: WorkoutEffort = { effort: null, legs: new Map() };
  const row = sql.exec(
    `SELECT samples, most_relevant, legs FROM health_workout_effort WHERE id = ?`,
    id,
  )[0];
  if (row === undefined) return none;
  const ids = decodeIDs(row["samples"]);
  const legs = decodeLegs(row["legs"]);
  if (Option.isNone(ids) || Option.isNone(legs)) return none;
  const all = [...ids.value, ...legs.value.flatMap((leg) => leg.samples)];
  const samples = samplesWithIds(sql, all);
  const mostRelevant = row["most_relevant"];
  const legScores = new Map<string, EffortScore>();
  for (const leg of legs.value) {
    const score = effortScore(samples, leg.samples, leg.mostRelevant ?? null);
    if (score !== null) legScores.set(leg.activity, score);
  }
  return {
    effort: effortScore(samples, ids.value, Predicate.isString(mostRelevant) ? mostRelevant : null),
    legs: legScores,
  };
};

/**
 * Whether the workout with ID `id` has a `health_workout_samples` record, which every workout an
 * iPhone uploads since 851-4153 has (empty if no samples were added to it): without one, an older
 * lil health uploaded it, or its links haven't synced, so what it links isn't known.
 */
export const workoutLinksRead = (sql: StoreSql, id: string): boolean =>
  sql.exec(`SELECT 1 FROM health_workout_samples WHERE id = ?`, id).length > 0;

/** A symptom logged with an ECG, as `electrocardiograms` gives it. */
export interface LoggedSymptom {
  readonly type: string;
  readonly name: string;
}

/**
 * The symptoms logged with each of the ECGs with these IDs, from their
 * `health_electrocardiogram_symptoms` records: those that have arrived, in order of start, then
 * ID, each by the name Health gives its type. An ECG without a record (an older lil health
 * uploaded it, or its links haven't synced), or whose record lists too many to upload or can't
 * be read, isn't in the map: which symptoms it has isn't known.
 */
export const electrocardiogramSymptoms = (
  sql: StoreSql,
  ids: ReadonlyArray<string>,
): ReadonlyMap<string, ReadonlyArray<LoggedSymptom>> => {
  if (ids.length === 0) return new Map();
  const records = sql
    .exec(
      `SELECT id, samples FROM health_electrocardiogram_symptoms
      WHERE id IN (SELECT value FROM json_each(?))`,
      JSON.stringify(ids),
    )
    .flatMap((row) => {
      const linked = decodeLinkedIDs(row["samples"]);
      return Option.isNone(linked) ? [] : [[row["id"] as string, linked.value] as const];
    });
  const samples = samplesWithIds(
    sql,
    records.flatMap(([, linked]) => Object.values(linked).flat()),
  );
  return new Map(
    records.map(([id, linked]) => {
      const own = new Set(Object.values(linked).flat());
      return [
        id,
        samples
          .filter((sample) => own.has(sample.id))
          .map((sample) => ({
            type: sample.type,
            name: healthCatalogType(sample.type)?.name ?? sample.type,
          })),
      ];
    }),
  );
};
