import { Clock, DateTime, Effect, Option, Schema } from "effect";
import type { StoreSql } from "../../store/StoreSql.ts";
import { characteristicValues, visionPrescriptions } from "./HealthQueries.ts";
import type { HealthToolkit } from "./HealthToolkit.ts";
import { localDate, toolTimeZone } from "./ToolTime.ts";

type DetailsResult = (typeof HealthToolkit.tools.health_details.successSchema)["Type"];

// Characteristics as the iPhone encodes them (`HealthEncoder`), read as the Mac's `HealthDetails`
// reads them: a value that can't be read, or isn't a known case, is Not Set (null).

const BirthDate = Schema.Struct({ year: Schema.Int, month: Schema.Int, day: Schema.Int });
const Sex = Schema.Literals(["female", "male", "other"]);
const bloodTypes = {
  aPositive: "A+",
  aNegative: "A-",
  bPositive: "B+",
  bNegative: "B-",
  abPositive: "AB+",
  abNegative: "AB-",
  oPositive: "O+",
  oNegative: "O-",
} as const;
const BloodType = Schema.Literals(Object.keys(bloodTypes) as Array<keyof typeof bloodTypes>);
const SkinType = Schema.Literals(["I", "II", "III", "IV", "V", "VI"]);
const WheelchairUse = Schema.Literals(["yes", "no"]);

/** A JSON value decoded with `schema`, or none if it isn't JSON or doesn't fit. */
const decodeJson = <S extends Schema.Top & { readonly DecodingServices: never }>(
  schema: S,
  json: string | undefined,
): Option.Option<S["Type"]> =>
  json === undefined
    ? Option.none()
    : Schema.decodeUnknownOption(Schema.fromJsonString(schema))(json);

/**
 * A lens's values as the tool gives them: each a number or null on its own, so a value that
 * can't be read is missing rather than the whole lens. Null when the eye has no lens, or its
 * JSON isn't an object.
 */
const lens = (json: string | null) => {
  if (json === null) return null;
  const value = decodeJson(Schema.Record(Schema.String, Schema.Unknown), json);
  if (Option.isNone(value)) return null;
  const number = (key: string) => {
    const field = value.value[key];
    return typeof field === "number" ? field : null;
  };
  return {
    sphere: number("sphere"),
    cylinder: number("cylinder"),
    axis: number("axis"),
    addPower: number("addPower"),
  };
};

/** A date of birth as `YYYY-MM-DD`, as given. */
const birthDay = ({ year, month, day }: typeof BirthDate.Type) =>
  [
    String(year).padStart(4, "0"),
    String(month).padStart(2, "0"),
    String(day).padStart(2, "0"),
  ].join("-");

/**
 * How old someone born on `birth` is at `now` in `zone`, in whole years, or null if `now` is
 * before it. As Foundation counts years: a birthday on a day the year doesn't have (29 February)
 * falls on its month's last day (28 February).
 */
export const age = (
  birth: { readonly year: number; readonly month: number; readonly day: number },
  now: number,
  zone: DateTime.TimeZone,
) => {
  const today = DateTime.toParts(DateTime.makeZonedUnsafe(now, { timeZone: zone }));
  // The day after the month's last is the next month's first, in UTC (no time zone involved).
  const monthLength = new Date(Date.UTC(today.year, birth.month, 0)).getUTCDate();
  const birthday = Math.min(birth.day, monthLength);
  const hadBirthday =
    today.month > birth.month || (today.month === birth.month && today.day >= birthday);
  const years = today.year - birth.year - (hadBirthday ? 0 : 1);
  return years < 0 ? null : years;
};

/**
 * The `health_details` tool from the user's store: the characteristics Health Details shows, and
 * the vision prescriptions, newest first.
 */
export const healthDetails = Effect.fn("healthDetails")(function* (
  sql: StoreSql,
  input: { readonly timeZone?: string | undefined },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const now = yield* Clock.currentTimeMillis;
  const values = new Map(characteristicValues(sql));
  const characteristic = <S extends Schema.Top & { readonly DecodingServices: never }>(
    id: string,
    schema: S,
  ) => Option.getOrNull(decodeJson(schema, values.get(`HKCharacteristicTypeIdentifier${id}`)));
  const birth = characteristic("DateOfBirth", BirthDate);
  const bloodType = characteristic("BloodType", BloodType);
  const wheelchairUse = characteristic("WheelchairUse", WheelchairUse);
  const result: DetailsResult = {
    timeZone: name,
    dateOfBirth: birth === null ? null : birthDay(birth),
    age: birth === null ? null : age(birth, now, zone),
    sex: characteristic("BiologicalSex", Sex),
    // ASCII signs, rather than the Mac app's minus (A−).
    bloodType: bloodType === null ? null : bloodTypes[bloodType],
    fitzpatrickSkinType: characteristic("FitzpatrickSkinType", SkinType),
    wheelchairUse: wheelchairUse === null ? null : wheelchairUse === "yes",
    visionPrescriptions: visionPrescriptions(sql).map((prescription) => ({
      id: prescription.id,
      kind:
        prescription.prescriptionType === 1
          ? "glasses"
          : prescription.prescriptionType === 2
            ? "contacts"
            : "unknown",
      issued: localDate(prescription.startDate, zone),
      expires:
        prescription.expirationDate === null ? null : localDate(prescription.expirationDate, zone),
      brand: prescription.brand,
      rightEye: lens(prescription.rightEye),
      leftEye: lens(prescription.leftEye),
    })),
  };
  return result;
});
