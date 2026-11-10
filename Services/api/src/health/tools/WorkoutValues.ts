import { Predicate } from "effect";
import type { Metadata } from "../WorkoutMetadata.ts";

// What the Health tools read of a workout's metadata beyond where it was (851-4165): HealthKit's
// keys for elevation, speeds, METs, the weather, pool length, SWOLF and strokes, on the workout,
// its activities and its events. The Mac reads them alike (`WorkoutValues` in `HealthTools`), so
// the two `workout` tools agree (the conformance cases).
//
// The iPhone writes an `HKQuantity` as its description, a number with 6 significant digits and a
// unit ("4250 cm", `HealthEncoder.json`), until 851-4150 keeps them whole: so these values are
// rounded to that, and a unit not listed here gives null.

/** A number and a unit, as `HKQuantity.description` writes them: "4250 cm", "6.25 kcal/hr·kg". */
const quantityText = /^([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?) (\S+)$/;

/** A quantity's description converted by its unit's function in `units`, else null. */
const quantity = (
  value: unknown,
  units: ReadonlyMap<string, (value: number) => number>,
): number | null => {
  if (!Predicate.isString(value)) return null;
  const match = quantityText.exec(value);
  const convert = match === null ? undefined : units.get(match[2]!);
  if (match === null || convert === undefined) return null;
  const converted = convert(Number(match[1]));
  return Number.isFinite(converted) ? converted : null;
};

/** Each unit's function: multiplying by its factor. */
const scaled = (factors: Record<string, number>): ReadonlyMap<string, (value: number) => number> =>
  new Map(Object.entries(factors).map(([unit, factor]) => [unit, (value) => value * factor]));

/** Meters in each length unit HealthKit writes a quantity in (`HKUnit`'s unit strings). */
const lengths = scaled({
  mm: 0.001,
  cm: 0.01,
  m: 1,
  km: 1000,
  in: 0.0254,
  ft: 0.3048,
  yd: 0.9144,
  mi: 1609.344,
});

/** Meters per second in each speed unit. */
const speeds = scaled({
  "m/s": 1,
  "km/hr": 1000 / 3600,
  "mi/hr": 1609.344 / 3600,
  "ft/s": 0.3048,
});

/** METs: `kcal/hr·kg`, as `HKQuantity.description` writes the unit (with a middle dot). */
const mets = scaled({ "kcal/hr·kg": 1, "kcal/(kg·hr)": 1, "kcal/(hr·kg)": 1 });

/** Degrees Celsius from each temperature unit. */
const temperatures: ReadonlyMap<string, (value: number) => number> = new Map([
  ["degC", (value: number) => value],
  ["degF", (value: number) => ((value - 32) * 5) / 9],
  ["K", (value: number) => value - 273.15],
]);

/**
 * A percent, from 0 to 100. Apple's Workout app writes humidity 100 times too large (a quantity
 * of 72 percent units for 72%, described as "7200 %"), so a value over 100 is divided by 100.
 */
const humidities: ReadonlyMap<string, (value: number) => number> = new Map([
  ["%", (value: number) => (value > 100 ? value / 100 : value)],
]);

/** A JSON number, not a Boolean, as the Mac's `WorkoutMetadata.number` reads one. */
const number = (value: unknown): number | null =>
  Predicate.isNumber(value) && Number.isFinite(value) ? value : null;

/** The name at an enum's raw value, if it's a whole number with one. */
const named = (names: ReadonlyArray<string | null>, value: unknown): string | null => {
  const raw = number(value);
  return raw !== null && Number.isInteger(raw) ? (names[raw] ?? null) : null;
};

/** `HKWeatherCondition`'s cases, by raw value, without their prefix; 0 (none) is null. */
const weatherConditions = [
  null,
  "clear",
  "fair",
  "partlyCloudy",
  "mostlyCloudy",
  "cloudy",
  "foggy",
  "haze",
  "windy",
  "blustery",
  "smoky",
  "dust",
  "snow",
  "hail",
  "sleet",
  "freezingDrizzle",
  "freezingRain",
  "mixedRainAndHail",
  "mixedRainAndSnow",
  "mixedRainAndSleet",
  "mixedSnowAndSleet",
  "drizzle",
  "scatteredShowers",
  "showers",
  "thunderstorms",
  "tropicalStorm",
  "hurricane",
  "tornado",
];

/** `HKSwimmingStrokeStyle`'s cases, by raw value; 0 (unknown) is null. */
const strokeStyles = [
  null,
  "mixed",
  "freestyle",
  "backstroke",
  "breaststroke",
  "butterfly",
  "kickboard",
];

/** `HKMetadataKeyElevationAscended`, in meters. */
export const elevationAscended = (metadata: Metadata | null | undefined): number | null =>
  quantity(metadata?.["HKElevationAscended"], lengths);

/** A pool's length, `HKMetadataKeyLapLength`, in meters. */
const lapLength = (metadata: Metadata | null | undefined): number | null =>
  quantity(metadata?.["HKLapLength"], lengths);

/** Speeds, in meters per second. */
const speedFields = (metadata: Metadata | null | undefined) => ({
  averageSpeed: quantity(metadata?.["HKAverageSpeed"], speeds),
  maximumSpeed: quantity(metadata?.["HKMaximumSpeed"], speeds),
});

/** What a workout's or an activity's metadata says beyond where it was. */
export const workoutMetadataValues = (metadata: Metadata | null | undefined) => ({
  elevationAscended: elevationAscended(metadata),
  elevationDescended: quantity(metadata?.["HKElevationDescended"], lengths),
  ...speedFields(metadata),
  averageMETs: quantity(metadata?.["HKAverageMETs"], mets),
  lapLength: lapLength(metadata),
  swolf: number(metadata?.["HKSWOLFScore"]),
});

/** The weather a workout's metadata gives. */
export const workoutWeather = (metadata: Metadata | null | undefined) => ({
  weatherCondition: named(weatherConditions, metadata?.["HKWeatherCondition"]),
  weatherTemperature: quantity(metadata?.["HKWeatherTemperature"], temperatures),
  weatherHumidity: quantity(metadata?.["HKWeatherHumidity"], humidities),
});

/** What a lap's or segment's metadata says. */
export const intervalValues = (metadata: Metadata | null | undefined) => ({
  strokeStyle: named(strokeStyles, metadata?.["HKSwimmingStrokeStyle"]),
  swolf: number(metadata?.["HKSWOLFScore"]),
  lapLength: lapLength(metadata),
  ...speedFields(metadata),
});
