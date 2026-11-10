import { Clock, Effect, Option, Schema } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { healthCatalogType } from "../HealthCatalog.ts";
import { scoredAssessments, stateOfMindLogs } from "./HealthQueries.ts";
import { assessmentsLimit, type HealthToolkit, stateOfMindLimit } from "./HealthToolkit.ts";
import { RecordedZones } from "./RecordedTimes.ts";
import { localTime, type ToolRange, toolPeriod, toolTimeZone } from "./ToolTime.ts";

// The Mental Wellbeing tools (851-4160): State of Mind logs and GAD-7 and PHQ-9 assessments, in
// the words of the Mac's pages (`MentalWellbeingQueries.swift`), which `HealthTools` on the Mac
// uses too.

type StateOfMindResult = (typeof HealthToolkit.tools.state_of_mind.successSchema)["Type"];
type AssessmentsResult = (typeof HealthToolkit.tools.assessments.successSchema)["Type"];

/** `HKStateOfMind.ValenceClassification`'s names, by raw value from 1 (`ValenceClassification`). */
const valenceClassifications = [
  "Very Unpleasant",
  "Unpleasant",
  "Slightly Unpleasant",
  "Neutral",
  "Slightly Pleasant",
  "Pleasant",
  "Very Pleasant",
];

/** `HKStateOfMind.Label`'s names, by raw value from 1 (`StateOfMindVocabulary.labels`). */
const stateOfMindLabels = [
  "Amazed",
  "Amused",
  "Angry",
  "Anxious",
  "Ashamed",
  "Brave",
  "Calm",
  "Content",
  "Disappointed",
  "Discouraged",
  "Disgusted",
  "Embarrassed",
  "Excited",
  "Frustrated",
  "Grateful",
  "Guilty",
  "Happy",
  "Hopeless",
  "Irritated",
  "Jealous",
  "Joyful",
  "Lonely",
  "Passionate",
  "Peaceful",
  "Proud",
  "Relieved",
  "Sad",
  "Scared",
  "Stressed",
  "Surprised",
  "Worried",
  "Annoyed",
  "Confident",
  "Drained",
  "Hopeful",
  "Indifferent",
  "Overwhelmed",
  "Satisfied",
];

/** `HKStateOfMind.Association`'s names, by raw value from 1 (`StateOfMindVocabulary`). */
const stateOfMindAssociations = [
  "Community",
  "Current Events",
  "Dating",
  "Education",
  "Family",
  "Fitness",
  "Friends",
  "Health",
  "Hobbies",
  "Identity",
  "Money",
  "Partner",
  "Self Care",
  "Spirituality",
  "Tasks",
  "Travel",
  "Work",
  "Weather",
];

const decodeRawValues = Schema.decodeUnknownOption(Schema.fromJsonString(Schema.Array(Schema.Int)));

/** A JSON array of HealthKit raw values, or none if it can't be read. */
const rawValues = (json: string): ReadonlyArray<number> =>
  Option.getOrElse(decodeRawValues(json), () => []);

/** `HKStateOfMind.Kind`'s names, by raw value from 1 (`HealthStateOfMind.toolKindName`). */
const stateOfMindKinds = ["Momentary Emotion", "Daily Mood"];

/**
 * The names of a JSON array of raw values numbered from 1, skipping those without one (from a
 * later iOS), or none if it can't be read, as the Mac's `StateOfMindVocabulary.names`.
 */
const names = (json: string, vocabulary: ReadonlyArray<string>): Array<string> =>
  rawValues(json).flatMap((value) => {
    const name = vocabulary[value - 1];
    return name === undefined ? [] : [name];
  });

/**
 * The `state_of_mind` tool from the user's store: the logs that start in the period, newest first,
 * at most `stateOfMindLimit`, with the period's count, as the Mac's `HealthTools.stateOfMind`.
 */
export const healthStateOfMind = Effect.fn("healthStateOfMind")(function* (
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
  const { count, logs } = stateOfMindLogs(sql, period.start, period.end, stateOfMindLimit);
  const zones = new RecordedZones();
  const result: StateOfMindResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    count,
    logs: logs.map((log) => ({
      time: localTime(log.startDate, zone),
      ...zones.namedAt(log.recordedTimeZone, log.startDate),
      kind: stateOfMindKinds[log.kind - 1] ?? "Unknown",
      valence: log.valence,
      classification: valenceClassifications[log.valenceClassification - 1] ?? "Unknown",
      labels: names(log.labels, stateOfMindLabels),
      associations: names(log.associations, stateOfMindAssociations),
      source: log.sourceName,
    })),
  };
  return result;
});

/** Each answer's words, by raw value from 0 (`HKGAD7Assessment.Answer`). */
const frequencies = ["Not at all", "Several days", "More than half the days", "Nearly every day"];

/**
 * The assessments the tool reads, as the Mac's `AssessmentKind`: their highest scores, risks by
 * raw value from 1, and answers by raw value from 0 (PHQ-9's 9th question can be skipped).
 */
const assessmentKinds: ReadonlyMap<
  string,
  {
    readonly maximumScore: number;
    readonly risks: ReadonlyArray<string>;
    readonly answers: ReadonlyArray<string>;
  }
> = new Map([
  [
    "HKScoredAssessmentTypeIdentifierGAD7",
    {
      maximumScore: 21,
      risks: ["None to Minimal", "Mild", "Moderate", "Severe"],
      answers: frequencies,
    },
  ],
  [
    "HKScoredAssessmentTypeIdentifierPHQ9",
    {
      maximumScore: 27,
      risks: ["None to Minimal", "Mild", "Moderate", "Moderately Severe", "Severe"],
      answers: [...frequencies, "Prefer not to answer"],
    },
  ],
]);

/**
 * The `assessments` tool from the user's store: the GAD-7 and PHQ-9 assessments taken in the
 * period, newest first, at most `assessmentsLimit`, with the period's count, as the Mac's
 * `HealthTools.assessments`.
 */
export const healthAssessments = Effect.fn("healthAssessments")(function* (
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
  const { count, assessments } = scoredAssessments(
    sql,
    [...assessmentKinds.keys()],
    period.start,
    period.end,
    assessmentsLimit,
  );
  const zones = new RecordedZones();
  const result: AssessmentsResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    count,
    // Only those of `assessmentKinds` were read.
    assessments: assessments.flatMap((assessment) => {
      const kind = assessmentKinds.get(assessment.type);
      if (kind === undefined) return [];
      return [
        {
          type: assessment.type,
          name: healthCatalogType(assessment.type)?.name ?? assessment.type,
          time: localTime(assessment.startDate, zone),
          ...zones.namedAt(assessment.recordedTimeZone, assessment.startDate),
          score: assessment.score,
          maximumScore: kind.maximumScore,
          risk: kind.risks[assessment.risk - 1] ?? "Unknown",
          answers: rawValues(assessment.answers).map((answer) => kind.answers[answer] ?? "Unknown"),
        },
      ];
    }),
  };
  return result;
});
