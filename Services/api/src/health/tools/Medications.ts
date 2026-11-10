import { Clock, type DateTime, Effect, Option, Schema } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import {
  type DoseCursor,
  type DoseRow,
  doseLog,
  doseTaken,
  dosesSince,
  lastTaken,
  type MedicationRow,
  medicationRows,
} from "./HealthQueries.ts";
import {
  HealthMedicationCoding,
  medicationDosesDefaultLimit,
  medicationDosesLimit,
  HealthToolError,
  type HealthToolkit,
} from "./HealthToolkit.ts";
import { RecordedZones } from "./RecordedTimes.ts";
import { localTime, startOfDay, type ToolRange, toolPeriod, toolTimeZone } from "./ToolTime.ts";
import { compareNames } from "./ToolTypes.ts";

type MedicationsResult = (typeof HealthToolkit.tools.medications.successSchema)["Type"];
type DosesResult = (typeof HealthToolkit.tools.medication_doses.successSchema)["Type"];

/** `HKMedicationDoseEvent.ScheduleType.schedule`'s raw value. */
const scheduledDose = 2;

/** A medication with the name it shows: the person's nickname for it, else Health's name. */
export interface NamedMedication extends MedicationRow {
  readonly displayName: string;
}

/**
 * Every shared medication, current ones then archived ones, each by the name it shows, as the
 * Mac's `HealthDatabase.medications` lists them.
 */
export const sortedMedications = (sql: StoreSql): ReadonlyArray<NamedMedication> =>
  medicationRows(sql)
    .map((medication) => ({
      ...medication,
      displayName:
        medication.nickname !== null && medication.nickname.trim() !== ""
          ? medication.nickname
          : medication.name,
    }))
    .sort((a, b) =>
      a.isArchived !== b.isArchived
        ? a.isArchived
          ? 1
          : -1
        : compareNames(a.displayName, b.displayName) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
    );

/**
 * A medication's adherence over the last `days` days as of `now` (today and the days before):
 * the scheduled doses that were due, how many of them were taken, and the doses taken as needed.
 * A dose counts on its scheduled day, or the day it was logged if it wasn't scheduled. Each
 * scheduled time counts once: should Health have several events for it (snoozed, then taken),
 * the latest logged one says what happened. As the Mac's `MedicationAdherence`.
 */
const adherence = (
  doses: ReadonlyArray<DoseRow>,
  days: number,
  now: number,
  zone: DateTime.TimeZone,
) => {
  const start = startOfDay(now, zone, -(days - 1));
  const end = startOfDay(now, zone, 1);
  const slots = new Map<number, DoseRow>();
  let asNeeded = 0;
  for (const dose of doses) {
    const day = dose.scheduledDate ?? dose.startDate;
    if (day < start || day >= end) continue;
    if (dose.scheduleType !== scheduledDose || dose.scheduledDate === null) {
      if (dose.logStatus === doseTaken) asNeeded += 1;
      continue;
    }
    const other = slots.get(dose.scheduledDate);
    const isLater =
      other === undefined ||
      dose.startDate > other.startDate ||
      (dose.startDate === other.startDate && dose.id >= other.id);
    if (isLater) slots.set(dose.scheduledDate, dose);
  }
  const scheduled = [...slots.values()];
  return {
    scheduled: scheduled.length,
    taken: scheduled.filter((dose) => dose.logStatus === doseTaken).length,
    asNeeded,
  };
};

const decodeCodings = Schema.decodeUnknownOption(
  Schema.fromJsonString(Schema.Array(HealthMedicationCoding)),
);

/**
 * A medication's codings, in the order stored, or none if they can't be read, as the Mac's
 * `HealthMedication.decodedCodings`.
 */
const codings = (json: string) => Option.getOrElse(decodeCodings(json), () => []);

/**
 * The `medications` tool from the user's store: every shared medication, current ones then
 * archived ones, by name, with its adherence over the last 7 and 30 days, when a dose was last
 * taken and its codings.
 */
export const healthMedications = Effect.fn("healthMedications")(function* (
  sql: StoreSql,
  input: { readonly timeZone?: string | undefined },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const now = yield* Clock.currentTimeMillis;
  const windowStart = startOfDay(now, zone, -29);
  const medications = sortedMedications(sql).map((medication) => {
    const doses = dosesSince(sql, medication.id, windowStart);
    const taken = lastTaken(sql, medication.id);
    return {
      id: medication.id,
      name: medication.displayName,
      healthName: medication.name,
      form: medication.generalForm,
      archived: medication.isArchived,
      scheduled: medication.hasSchedule,
      last7Days: adherence(doses, 7, now, zone),
      last30Days: adherence(doses, 30, now, zone),
      lastTaken: taken === null ? null : localTime(taken, zone),
      codings: codings(medication.codings),
    };
  });
  const result: MedicationsResult = { timeZone: name, medications };
  return result;
});

/** `HKMedicationDoseEvent.LogStatus`'s names, by raw value from 1, as the Mac's page says them. */
const doseStatuses = [
  "Not Logged",
  "Reminder Not Sent",
  "Snoozed",
  "Taken",
  "Skipped",
  "Not Logged",
];

/** `HKMedicationDoseEvent.ScheduleType`'s names, by raw value from 1. */
const doseSchedules = ["As Needed", "Scheduled"];

const invalidCursor = (text: string) =>
  new HealthToolError({ message: `Invalid cursor: ${text}. Pass the previous page's nextCursor.` });

/** A page's cursor: its last dose's day, logged time and ID, `<day>_<start>_<id>`. */
const doseCursorAt = (dose: DoseCursor) => `${dose.day}_${dose.startDate}_${dose.id}`;

/**
 * A cursor's day, logged time and ID, all there (`1_2_` isn't one), as the Mac reads them: each
 * time at most 15 digits, so it's exact here and fits the Mac's `Int` (milliseconds have 13).
 */
const parseDoseCursor = (text: string) => {
  const match = /^([+-]?\d{1,15})_([+-]?\d{1,15})_([^_]+)$/.exec(text);
  return match === null
    ? Effect.fail(invalidCursor(text))
    : Effect.succeed<DoseCursor>({
        day: Number(match[1]),
        startDate: Number(match[2]),
        id: match[3]!,
      });
};

/**
 * The `medication_doses` tool from the user's store: the doses of the shared medications (or of
 * one) whose day, when they were due or else logged, is in the period, newest first, a page at a
 * time, with the period's count, in the words of the Mac's dose log, as the Mac's
 * `HealthTools.medicationDoses`.
 */
export const healthMedicationDoses = Effect.fn("healthMedicationDoses")(function* (
  sql: StoreSql,
  input: {
    readonly range: ToolRange;
    readonly date?: string | undefined;
    readonly timeZone?: string | undefined;
    readonly medication?: string | undefined;
    readonly cursor?: string | undefined;
    readonly limit?: number | undefined;
  },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const now = yield* Clock.currentTimeMillis;
  const period = yield* toolPeriod(input.range, input.date, now, zone);
  const limit = input.limit ?? medicationDosesDefaultLimit;
  if (!Number.isInteger(limit) || limit < 1 || limit > medicationDosesLimit) {
    return yield* new HealthToolError({
      message: `The limit must be from 1 to ${medicationDosesLimit}.`,
    });
  }
  const after = input.cursor === undefined ? null : yield* parseDoseCursor(input.cursor);
  const names = new Map(
    sortedMedications(sql).map((medication) => [medication.id, medication.displayName]),
  );
  if (input.medication !== undefined && !names.has(input.medication)) {
    return yield* new HealthToolError({
      message: `No medication with ID ${input.medication}. medications lists them, with their IDs.`,
    });
  }
  const medications = input.medication === undefined ? [...names.keys()] : [input.medication];
  // One more than asked for, to know whether there's another page.
  const { count, doses } = doseLog(sql, medications, period.start, period.end, after, limit + 1);
  const page = doses.slice(0, limit);
  const last = page.at(-1);
  const zones = new RecordedZones();
  const result: DosesResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    count,
    doses: page.map((dose) => {
      const recorded = zones.namedAt(dose.recordedTimeZone, dose.startDate);
      const scheduled =
        dose.scheduledDate === null ? {} : zones.namedAt(dose.recordedTimeZone, dose.scheduledDate);
      return {
        medicationId: dose.medication,
        medication: names.get(dose.medication) ?? dose.medication,
        status: doseStatuses[dose.logStatus - 1] ?? "Unknown",
        schedule: doseSchedules[dose.scheduleType - 1] ?? "Unknown",
        time: localTime(dose.startDate, zone),
        scheduledTime: dose.scheduledDate === null ? null : localTime(dose.scheduledDate, zone),
        ...recorded,
        ...(scheduled.recordedTime === undefined
          ? {}
          : { recordedScheduledTime: scheduled.recordedTime }),
        amount: dose.doseQuantity,
        scheduledAmount: dose.scheduledDoseQuantity,
        unit: dose.unit,
        source: dose.sourceName,
      };
    }),
    nextCursor: doses.length > limit && last !== undefined ? doseCursorAt(last) : null,
  };
  return result;
});
