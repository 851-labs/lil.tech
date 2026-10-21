import { Clock, type DateTime, Effect } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import {
  type DoseRow,
  doseTaken,
  dosesSince,
  lastTaken,
  type MedicationRow,
  medicationRows,
} from "./HealthQueries.ts";
import type { HealthToolkit } from "./HealthToolkit.ts";
import { localTime, startOfDay, toolTimeZone } from "./ToolTime.ts";
import { compareNames } from "./ToolTypes.ts";

type MedicationsResult = (typeof HealthToolkit.tools.medications.successSchema)["Type"];

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

/**
 * The `medications` tool from the user's store: every shared medication, current ones then
 * archived ones, by name, with its adherence over the last 7 and 30 days and when a dose was last
 * taken.
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
    };
  });
  const result: MedicationsResult = { timeZone: name, medications };
  return result;
});
