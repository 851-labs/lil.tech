import { Clock, type DateTime, Effect } from "effect";
import type { SqlValue, StoreSql } from "../../store/StoreSql.ts";
import {
  HealthToolError,
  type HealthToolkit,
  routePointsDefaultLimit,
  routeShapeLimit,
  routeShapeTolerance,
  workoutRoutesLimit,
} from "./HealthToolkit.ts";
import { RecordedZones, recordedZoneSql } from "./RecordedTimes.ts";
import { localTime, type ToolRange, toolPeriod, toolTimeZone } from "./ToolTime.ts";

// The route tools (851-4164): `workout_routes` lists routes from their rows, and `workout_route`
// and `workout_route_points` read one route's locations from its blob, as the Mac's do
// (`HealthTools` on the Mac, from the blob the app downloads). Routes are precise locations, so
// `workout_route` gives a summary and a simplified shape, and every point only comes a page at a
// time from `workout_route_points`, as the privacy policy says (851-4157).

type RoutesResult = (typeof HealthToolkit.tools.workout_routes.successSchema)["Type"];
type RouteResult = (typeof HealthToolkit.tools.workout_route.successSchema)["Type"];
type PointsResult = (typeof HealthToolkit.tools.workout_route_points.successSchema)["Type"];

/**
 * A health blob's bytes by its SHA-256, from the user's blobs in R2, or null if it isn't there.
 * The store reads them (`UserStore.ts`); a failed read is the tool's error, which names `what` it
 * was reading (e.g. "the route's points").
 */
export type HealthBlobReader = (
  sha256: string,
  what: string,
) => Effect.Effect<Uint8Array | null, HealthToolError>;

/** No blobs: tools built without the store's bucket (tests that don't read routes). */
export const noHealthBlobs: HealthBlobReader = () => Effect.succeed(null);

export interface RouteRow {
  readonly id: string;
  readonly workout: string | null;
  readonly startDate: number;
  readonly endDate: number;
  readonly locationCount: number;
  /** The locations blob's SHA-256, or null without locations. */
  readonly locations: string | null;
  readonly sourceName: string;
  /** Its `HKTimeZone`, if it's a string (`recordedZoneSql`). */
  readonly recordedTimeZone: unknown;
}

const routeColumns = `id, workout, start_date, end_date, location_count, locations, source_name,
  ${recordedZoneSql} AS recorded_time_zone`;

const routeRow = (row: Record<string, unknown>): RouteRow => ({
  id: row["id"] as string,
  workout: (row["workout"] as string | null) ?? null,
  startDate: Number(row["start_date"]),
  endDate: Number(row["end_date"]),
  locationCount: Number(row["location_count"]),
  locations: (row["locations"] as string | null) ?? null,
  sourceName: row["source_name"] as string,
  recordedTimeZone: row["recorded_time_zone"],
});

/**
 * The route `id` names, as the Mac finds it (`HealthTools.route(id:)`): the route with that ID,
 * if it has locations; else the route of the workout with that ID (`HealthDatabase.route(of:)`):
 * the one HealthKit linked to it with the most locations (then the first by ID), or else such a
 * one linked to no workout that was recorded during it.
 */
const findRoute = (sql: StoreSql, id: string) =>
  Effect.gen(function* () {
    const first = (query: string, ...bindings: ReadonlyArray<SqlValue>) =>
      sql.exec(query, ...bindings).map(routeRow)[0];
    const route = first(
      `SELECT ${routeColumns} FROM health_workout_route WHERE id = ? AND locations IS NOT NULL`,
      id,
    );
    if (route !== undefined) return route;
    const workout = sql.exec("SELECT start_date, end_date FROM health_workout WHERE id = ?", id)[0];
    if (workout === undefined) {
      return yield* new HealthToolError({
        message:
          `No workout or route with ID ${id}. workouts and workout_routes list them, with ` +
          "their IDs.",
      });
    }
    const found =
      first(
        `SELECT ${routeColumns} FROM health_workout_route
        WHERE workout = ? AND locations IS NOT NULL ORDER BY location_count DESC, id LIMIT 1`,
        id,
      ) ??
      first(
        `SELECT ${routeColumns} FROM health_workout_route
        WHERE workout IS NULL AND locations IS NOT NULL AND start_date < ? AND end_date > ?
        ORDER BY location_count DESC, id LIMIT 1`,
        Number(workout["end_date"]),
        Number(workout["start_date"]),
      );
    if (found === undefined) {
      return yield* new HealthToolError({
        message: `The workout ${id} has no route: it was recorded without GPS (hasRoute is false).`,
      });
    }
    return found;
  });

/** One point of a route, as its blob has it. Accuracies, speed and course are negative if unknown. */
export interface RoutePoint {
  /** Unix seconds. */
  readonly time: number;
  readonly latitude: number;
  readonly longitude: number;
  readonly altitude: number;
  readonly horizontalAccuracy: number;
  readonly verticalAccuracy: number;
  readonly speed: number;
  readonly course: number;
}

/** Bytes per location in a route's blob (`HealthWorkoutRoute`). */
const locationBytes = 44;

/** The times a point can have, in Unix seconds: from 2000 to 2999, the tools' years (`toolDate`). */
const firstTime = 946_684_800;
const pastLastTime = 32_503_680_000;

/**
 * A route blob's locations (`HealthWorkoutRoute`): 44 little-endian bytes each, the time, latitude
 * and longitude as 64-bit floats, then altitude, horizontal and vertical accuracy, speed and
 * course as 32-bit ones. A trailing partial record is left out, as on the Mac, and so is a point
 * whose coordinates aren't valid (a negative horizontal accuracy, as Core Location marks them, or
 * not finite numbers) or whose time is outside 2000 to 2999.
 */
export const routePoints = (bytes: Uint8Array): ReadonlyArray<RoutePoint> => {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const points: Array<RoutePoint> = [];
  for (let offset = 0; offset + locationBytes <= bytes.byteLength; offset += locationBytes) {
    const point = {
      time: view.getFloat64(offset, true),
      latitude: view.getFloat64(offset + 8, true),
      longitude: view.getFloat64(offset + 16, true),
      altitude: view.getFloat32(offset + 24, true),
      horizontalAccuracy: view.getFloat32(offset + 28, true),
      verticalAccuracy: view.getFloat32(offset + 32, true),
      speed: view.getFloat32(offset + 36, true),
      course: view.getFloat32(offset + 40, true),
    };
    const isValid =
      point.horizontalAccuracy >= 0 &&
      Number.isFinite(point.latitude) &&
      Number.isFinite(point.longitude) &&
      point.time >= firstTime &&
      point.time < pastLastTime;
    if (isValid) points.push(point);
  }
  return points;
};

/**
 * `value` to `digits` decimal places, halves away from zero, as Swift's `rounded()`, and never
 * `-0`, so both servers write the same number.
 */
export const roundTo = (value: number, digits: 2 | 3 | 5): number => {
  const factor = digits === 2 ? 100 : digits === 3 ? 1000 : 100_000;
  const rounded = Math.round(Math.abs(value) * factor) / factor;
  return (value < 0 ? -rounded : rounded) + 0;
};

/** A 32-bit float a device may not have known (negative, or not a number), to 2 places, or null. */
const known = (value: number) => (Number.isFinite(value) && value >= 0 ? roundTo(value, 2) : null);

/** A point's altitude, or null when its vertical accuracy says it's unknown (Core Location's rule). */
const altitude = (point: RoutePoint) =>
  point.verticalAccuracy >= 0 && Number.isFinite(point.altitude)
    ? roundTo(point.altitude, 2)
    : null;

const earthRadius = 6_371_000;
const radians = (degrees: number) => (degrees * Math.PI) / 180;

/** Meters between two points along the Earth's surface (`HealthDatabase.distance` on the Mac). */
const distance = (a: RoutePoint, b: RoutePoint) => {
  const lat1 = radians(a.latitude);
  const lat2 = radians(b.latitude);
  const dLat = lat2 - lat1;
  const dLon = radians(b.longitude - a.longitude);
  const h =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  return 2 * earthRadius * Math.asin(Math.min(1, Math.sqrt(h)));
};

/** Meters climbed and descended between the points with a known altitude, or nulls without two. */
const elevation = (points: ReadonlyArray<RoutePoint>) => {
  let gain = 0;
  let loss = 0;
  let previous: number | null = null;
  let count = 0;
  for (const point of points) {
    if (!(point.verticalAccuracy >= 0 && Number.isFinite(point.altitude))) continue;
    if (previous !== null) {
      const change = point.altitude - previous;
      if (change > 0) gain += change;
      else loss -= change;
    }
    previous = point.altitude;
    count += 1;
  }
  return count < 2
    ? { elevationGain: null, elevationLoss: null }
    : { elevationGain: roundTo(gain, 2), elevationLoss: roundTo(loss, 2) };
};

/**
 * The tolerance below which Ramer-Douglas-Peucker keeps each point, in meters: at a tolerance, it
 * keeps the first and last points, and every point further than it from the segment between the
 * points kept around it. Which point splits a span (the furthest, the first of points as far)
 * doesn't depend on the tolerance, only whether it splits, so one pass finds them all: a point is
 * kept below its distance from its span's segment, and below its span's own split point's.
 * Distances are on a flat projection around the first point (meters east and north).
 */
const keptBelow = (points: ReadonlyArray<RoutePoint>): Float64Array => {
  const kept = new Float64Array(points.length).fill(Infinity);
  if (points.length <= 2) return kept;
  const origin = points[0]!;
  const east = radians(1) * earthRadius * Math.cos(radians(origin.latitude));
  const north = radians(1) * earthRadius;
  const x = points.map((point) => (point.longitude - origin.longitude) * east);
  const y = points.map((point) => (point.latitude - origin.latitude) * north);
  const fromSegment = (index: number, start: number, end: number) => {
    const dx = x[end]! - x[start]!;
    const dy = y[end]! - y[start]!;
    const length = dx * dx + dy * dy;
    const along =
      length === 0
        ? 0
        : Math.min(
            1,
            Math.max(0, ((x[index]! - x[start]!) * dx + (y[index]! - y[start]!) * dy) / length),
          );
    const ex = x[start]! + along * dx - x[index]!;
    const ey = y[start]! + along * dy - y[index]!;
    return Math.sqrt(ex * ex + ey * ey);
  };
  const spans: Array<readonly [number, number, number]> = [[0, points.length - 1, Infinity]];
  while (spans.length > 0) {
    const [start, end, below] = spans.pop()!;
    let furthest = -1;
    let furthestDistance = -1;
    for (let index = start + 1; index < end; index++) {
      const away = fromSegment(index, start, end);
      if (away > furthestDistance) {
        furthest = index;
        furthestDistance = away;
      }
    }
    if (furthest === -1) continue;
    const keptBelowIt = Math.min(furthestDistance, below);
    kept[furthest] = keptBelowIt;
    spans.push([start, furthest, keptBelowIt], [furthest, end, keptBelowIt]);
  }
  return kept;
};

/**
 * The simplified shape: at `routeShapeTolerance`, doubled until it keeps `routeShapeLimit` or
 * fewer.
 */
const shape = (points: ReadonlyArray<RoutePoint>, zone: DateTime.TimeZone) => {
  const kept = keptBelow(points);
  const keptAt = (tolerance: number) => kept.filter((below) => below > tolerance).length;
  let tolerance = routeShapeTolerance;
  while (keptAt(tolerance) > routeShapeLimit) tolerance *= 2;
  const shown = points.filter((_, index) => kept[index]! > tolerance);
  return {
    tolerance,
    pointCount: shown.length,
    points: shown.map((point) => ({
      time: pointTime(point, zone),
      latitude: roundTo(point.latitude, 5),
      longitude: roundTo(point.longitude, 5),
      altitude: altitude(point),
    })),
  };
};

/** A point's time, to the second, rounded down, as every tool's times are. */
const pointTime = (point: RoutePoint, zone: DateTime.TimeZone) =>
  localTime(Math.floor(point.time) * 1000, zone);

/** The box `points` fit in, or null without any. A loop rather than `Math.min(...)`: a route can have more points than a call takes arguments. */
const bounds = (points: ReadonlyArray<RoutePoint>) => {
  if (points.length === 0) return null;
  let [south, west, north, east] = [Infinity, Infinity, -Infinity, -Infinity];
  for (const { latitude, longitude } of points) {
    south = Math.min(south, latitude);
    north = Math.max(north, latitude);
    west = Math.min(west, longitude);
    east = Math.max(east, longitude);
  }
  return {
    south: roundTo(south, 5),
    west: roundTo(west, 5),
    north: roundTo(north, 5),
    east: roundTo(east, 5),
  };
};

/** What both lists say of a route, `zones` looking up the zones routes were recorded in. */
const routeItem = (
  route: RouteRow,
  zone: DateTime.TimeZone,
  zones: RecordedZones,
  pointCount: number,
) => ({
  id: route.id,
  workout: route.workout,
  start: localTime(route.startDate, zone),
  end: localTime(route.endDate, zone),
  ...zones.named(route.recordedTimeZone, route.startDate, route.endDate),
  duration: (route.endDate - route.startDate) / 1000,
  pointCount,
  source: route.sourceName,
});

/** A route's points, from its blob. */
const readPoints = (route: RouteRow, blobs: HealthBlobReader) =>
  Effect.gen(function* () {
    const bytes =
      route.locations === null ? null : yield* blobs(route.locations, "the route's points");
    if (bytes === null) {
      return yield* new HealthToolError({
        message: "The route's points aren't on the server. Try again later.",
      });
    }
    return routePoints(bytes);
  });

/**
 * The `workout_routes` tool from the user's store: the routes with locations that start in the
 * period, newest first, at most `workoutRoutesLimit`, with how many there are.
 */
export const healthWorkoutRoutes = Effect.fn("healthWorkoutRoutes")(function* (
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
  const where = "locations IS NOT NULL AND start_date >= ? AND start_date < ?";
  const count = Number(
    sql.exec(
      `SELECT count(*) AS count FROM health_workout_route WHERE ${where}`,
      period.start,
      period.end,
    )[0]?.["count"] ?? 0,
  );
  const routes = sql
    .exec(
      `SELECT ${routeColumns} FROM health_workout_route WHERE ${where}
      ORDER BY start_date DESC, id DESC LIMIT ?`,
      period.start,
      period.end,
      workoutRoutesLimit,
    )
    .map(routeRow);
  const zones = new RecordedZones();
  const result: RoutesResult = {
    timeZone: name,
    range: input.range,
    start: localTime(period.start, zone),
    end: localTime(period.end, zone),
    count,
    routes: routes.map((route) => routeItem(route, zone, zones, route.locationCount)),
  };
  return result;
});

/** The `workout_route` tool from the user's store: one route in summary, with its shape. */
export const healthWorkoutRoute = Effect.fn("healthWorkoutRoute")(function* (
  sql: StoreSql,
  blobs: HealthBlobReader,
  input: { readonly id: string; readonly timeZone?: string | undefined },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const route = yield* findRoute(sql, input.id);
  const points = yield* readPoints(route, blobs);
  const first = points[0];
  const last = points.at(-1);
  const area = (point: RoutePoint | undefined) =>
    point === undefined
      ? null
      : { latitude: roundTo(point.latitude, 3), longitude: roundTo(point.longitude, 3) };
  const result: RouteResult = {
    timeZone: name,
    route: {
      ...routeItem(route, zone, new RecordedZones(), points.length),
      distance: points
        .slice(1)
        .reduce((total, point, index) => total + distance(points[index]!, point), 0),
      ...elevation(points),
      bounds: bounds(points),
      startArea: area(first),
      endArea: area(last),
      simplified: shape(points, zone),
    },
  };
  return result;
});

/**
 * The `workout_route_points` tool from the user's store: a page of a route's points, in order.
 * The cursor is the index of the page's first point.
 */
export const healthWorkoutRoutePoints = Effect.fn("healthWorkoutRoutePoints")(function* (
  sql: StoreSql,
  blobs: HealthBlobReader,
  input: {
    readonly id: string;
    readonly timeZone?: string | undefined;
    readonly cursor?: string | undefined;
    readonly limit?: number | undefined;
  },
) {
  const { zone, name } = yield* toolTimeZone(input.timeZone);
  const route = yield* findRoute(sql, input.id);
  const points = yield* readPoints(route, blobs);
  const limit = input.limit ?? routePointsDefaultLimit;
  const start = input.cursor === undefined ? 0 : cursorIndex(input.cursor);
  if (start === null || start > points.length) {
    return yield* new HealthToolError({
      message: `Invalid cursor: ${input.cursor}. Pass the previous page's nextCursor.`,
    });
  }
  const end = Math.min(start + limit, points.length);
  const result: PointsResult = {
    timeZone: name,
    id: route.id,
    pointCount: points.length,
    points: points.slice(start, end).map((point) => ({
      time: pointTime(point, zone),
      latitude: point.latitude,
      longitude: point.longitude,
      altitude: altitude(point),
      horizontalAccuracy: known(point.horizontalAccuracy),
      verticalAccuracy: known(point.verticalAccuracy),
      speed: known(point.speed),
      course: known(point.course),
    })),
    nextCursor: end < points.length ? String(end) : null,
  };
  return result;
});

/** A cursor's index: 1 to 9 digits, as the Mac reads it, or null. */
export const cursorIndex = (cursor: string): number | null =>
  /^[0-9]{1,9}$/.test(cursor) ? Number(cursor) : null;
