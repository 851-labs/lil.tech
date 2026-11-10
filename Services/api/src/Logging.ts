import * as Alchemy from "alchemy";
import {
  Cause,
  Console,
  Context,
  Formatter,
  type LogLevel,
  Logger,
  Predicate,
  Redacted,
  References,
  Schema,
  SchemaIssue,
} from "effect";

/** Workers Logs' level for each of Effect's, which is also the console method that logs it. */
const workersLevels = {
  All: "debug",
  Trace: "debug",
  Debug: "debug",
  Info: "info",
  Warn: "warn",
  Error: "error",
  Fatal: "error",
  None: "info",
} as const satisfies Record<LogLevel.LogLevel, keyof Console.Console>;

/** The fields a line sets itself, which no annotation replaces. */
const ownFields = new Set(["message", "level", "details", "cause", "spans"]);

/**
 * The fields of an error a line keeps as they are (851-4054): codes and flags of ours, Cloudflare's
 * and Effect's (an HttpApi decode error's `kind`, such as `Payload`), which hold no one's data. Every other field shows its type only (`"<string>"`), and
 * `cause` and `reason` are errors of their own.
 */
const keptErrorFields = new Set([
  "_tag",
  "appleError",
  "googleError",
  "unavailable",
  "index",
  "status",
  "retryable",
  "overloaded",
  "remote",
  "durableObjectReset",
  "kind",
]);

/** How deep `redacted` follows causes. */
const maxDepth = 6;

/**
 * An error message without the values some messages carry (851-4054): D1 names a value it couldn't
 * bind (`D1_TYPE_ERROR: Type 'object' not supported for value '…'`), and V8 quotes the text that
 * isn't JSON (`Unexpected token 'a', "…" is not valid JSON`).
 */
const redactedMessage = (message: string): string =>
  message
    .replace(/(D1_TYPE_ERROR\b[\s\S]*?\bvalue)\b[\s\S]*/g, "$1 <redacted>")
    .replace(/Unexpected token '[\s\S]{1,2}', /gu, "Unexpected token, ")
    .replace(/(?:\.\.\.)?"[\s\S]*"(?:\.\.\.)? is not valid JSON/g, "<redacted> is not valid JSON");

/** A Schema issue without the input it reports, when decoding asked for it (`reportInput`). */
const withoutInput = (issue: SchemaIssue.Issue): SchemaIssue.Issue => {
  const copy = Object.create(Object.getPrototypeOf(issue) as object) as Record<string, unknown>;
  for (const [key, value] of Object.entries(issue)) {
    if (key === "input") continue;
    copy[key] =
      key === "issue" && SchemaIssue.isIssue(value)
        ? withoutInput(value)
        : key === "issues" && Array.isArray(value)
          ? value.map((inner: SchemaIssue.Issue) => withoutInput(inner))
          : value;
  }
  return copy as unknown as SchemaIssue.Issue;
};

const formatIssue = SchemaIssue.makeFormatterDefault();

/** The type a value is shown as, in place of the value. */
const typeOf = (value: unknown): string =>
  `<${value === null ? "null" : Array.isArray(value) ? "array" : typeof value}>`;

/** An object or array by its shape: its keys, with their values' types. */
const shapeOf = (value: object): unknown =>
  Array.isArray(value)
    ? value.map(typeOf)
    : Object.fromEntries(Object.entries(value).map(([key, field]) => [key, typeOf(field)]));

/** Frames of an error's stack, without its first line, the message, which can hold values. */
const stackFrames = (error: object, header: string): ReadonlyArray<string> => {
  if (!Predicate.hasProperty(error, "stack") || !Predicate.isString(error.stack)) return [];
  const stack = error.stack.startsWith(header) ? error.stack.slice(header.length) : error.stack;
  return stack.split("\n").filter((line) => /^\s+at \S.*(?:\d+:\d+\)?|\(native\))$/.test(line));
};

/**
 * An error as a line may show it (851-4054): its type (`_tag`, `name`), its message without values
 * (`redactedMessage`), the paths and expected types of a Schema error but never what it got, a
 * failed Drizzle query's SQL but not its parameters, its `cause` and `reason` likewise, the fields
 * of `keptErrorFields`, and every other field's type only. Something that isn't an error is shown
 * by its shape: an object's keys with their types, a string or number as it is.
 */
const redactedError = (value: object, depth: number, seen: Map<unknown, unknown>): Error => {
  const name =
    Predicate.hasProperty(value, "name") && Predicate.isString(value.name)
      ? value.name
      : Predicate.hasProperty(value, "_tag") && Predicate.isString(value._tag)
        ? value._tag
        : "Error";
  const message = Schema.isSchemaError(value)
    ? formatIssue(withoutInput(value.issue))
    : Predicate.hasProperty(value, "query") &&
        Predicate.isString(value.query) &&
        Predicate.hasProperty(value, "params")
      ? `Failed query: ${value.query}`
      : Predicate.hasProperty(value, "message") && Predicate.isString(value.message)
        ? redactedMessage(value.message)
        : value instanceof Error
          ? ""
          : JSON.stringify(shapeOf(value));
  const original =
    Predicate.hasProperty(value, "message") && Predicate.isString(value.message)
      ? value.message
      : "";
  const error = new Error(message);
  // On the error, as on the prototype it replaces: not a field of its own in `details`.
  Object.defineProperty(error, "name", { value: name, configurable: true, writable: true });
  seen.set(value, error);
  // Assigned, not given to the constructor, so it's enumerable, and `details` show it too.
  if (Predicate.hasProperty(value, "cause") && value.cause !== undefined) {
    error.cause = redacted(value.cause, depth + 1, seen, true);
  }
  error.stack = [`${name}: ${message}`, ...stackFrames(value, `${name}: ${original}`)].join("\n");
  for (const [key, field] of Object.entries(value)) {
    if (key === "name" || key === "message" || key === "stack" || key === "cause") continue;
    if (key.startsWith("~")) continue;
    (error as unknown as Record<string, unknown>)[key] =
      key === "reason"
        ? redacted(field, depth + 1, seen, true)
        : keptErrorFields.has(key) && !Predicate.isObject(field)
          ? field
          : typeOf(field);
  }
  return error;
};

const isErrorLike = (value: unknown): value is object =>
  value instanceof Error ||
  (Predicate.isObject(value) &&
    (Predicate.hasProperty(value, "_tag") || Predicate.hasProperty(value, "message")));

/**
 * What a log line may show of `value` (851-4054): an error as `redactedError` shows it, a string
 * without the values some error messages carry, a `Redacted` value as it is (it formats as
 * `<redacted>`), and another object by its shape (its keys and their types). Numbers, booleans and
 * the rest stay.
 */
const redacted = (
  value: unknown,
  depth = 0,
  seen = new Map<unknown, unknown>(),
  asError = false,
): unknown => {
  if (Predicate.isString(value)) return redactedMessage(value);
  if (!Predicate.isObjectOrArray(value) || Redacted.isRedacted(value)) return value;
  if (seen.has(value)) return seen.get(value);
  if (depth > maxDepth) return typeOf(value);
  // A cycle back to `value` shows its type.
  seen.set(value, typeOf(value));
  if (Cause.isCause(value)) return Cause.pretty(redactedCause(value));
  if (asError || isErrorLike(value)) return redactedError(value, depth, seen);
  return shapeOf(value);
};

/** `cause` with each failure and defect as `redacted` shows it, keeping its stack annotations. */
const redactedCause = <E>(cause: Cause.Cause<E>): Cause.Cause<unknown> =>
  Cause.fromReasons(
    cause.reasons.map((reason) =>
      reason._tag === "Interrupt"
        ? reason
        : (reason._tag === "Fail"
            ? Cause.makeFailReason(redacted(reason.error, 0, new Map(), true))
            : Cause.makeDieReason(redacted(reason.defect, 0, new Map(), true))
          ).annotate(Context.makeUnsafe(reason.annotations)),
    ),
  );

/**
 * A log line as one JSON object (851-4050), which Workers Logs indexes field by field, logged with
 * the console method of its level (`console.info`, `warn`, `error` or `debug`): `message` (the
 * first part logged, or the cause's first line when only a cause was), `level`, the annotations (`Effect.annotateLogs`) as fields of their own,
 * `details` (the other parts, such as an error), `cause` and `spans`. Annotations named like
 * those are left out. The message, details and cause show no values (851-4054, `redacted`): errors
 * keep their type, message (without the values some carry), a Schema error's paths and expected
 * types and a query's SQL, and their other fields' types. It's plain JSON, made with Effect's
 * formatter: `Redacted` values stay redacted, and anything else that can't be JSON is dropped.
 */
export const workersLogger = Logger.make(({ cause, date, fiber, logLevel, message }) => {
  const [first, ...rest] = Array.isArray(message) ? message : [message];
  const annotations = Object.fromEntries(
    Object.entries(fiber.getRef(References.CurrentLogAnnotations)).filter(
      ([key]) => !ownFields.has(key),
    ),
  );
  const spans: Record<string, number> = {};
  for (const [label, startedAt] of fiber.getRef(References.CurrentLogSpans)) {
    spans[label] = date.getTime() - startedAt;
  }
  const level = workersLevels[logLevel];
  const pretty = cause.reasons.length > 0 ? Cause.pretty(redactedCause(cause)) : undefined;
  const entry = {
    ...annotations,
    // A line of a cause only (`Effect.logError(cause)`, as McpServer logs a tool's defect) takes
    // its first line as the message.
    message:
      first === undefined && pretty !== undefined
        ? (pretty.split("\n")[0] ?? "")
        : Predicate.isString(first)
          ? redactedMessage(first)
          : Formatter.format(redacted(first)),
    level,
    ...(rest.length > 0 ? { details: rest.map((part) => redacted(part)) } : {}),
    ...(pretty !== undefined ? { cause: pretty } : {}),
    ...(Object.keys(spans).length > 0 ? { spans } : {}),
  };
  fiber.getRef(Console.Console)[level](JSON.parse(Formatter.formatJson(entry)));
});

/** The loggers `WorkersLogs` gives, for code that provides them as a service. */
export const workersLoggers: ReadonlySet<Logger.Logger<unknown, void>> = new Set([workersLogger]);

/** Logs with `workersLogger` only. */
export const WorkersLogs = Logger.layer([workersLogger]);

/**
 * `WorkersLogs` for every event the Worker and its Durable Objects handle: requests, the queue,
 * cron, RPC calls, alarms and sockets. Alchemy runs each with the isolate's services, whose logger
 * is its own pretty one (a line of text, then each part and annotation on lines of their own), and
 * builds this telemetry layer into each event, over them. The Worker's setup provides it, and
 * `WorkersLogs` around itself, for what captures the setup's services and provides them again
 * inside an event (the API's routes, a store starting), and what runs outside any event (a timer)
 * provides `WorkersLogs` itself.
 */
export const WorkersLogsTelemetry = Alchemy.Telemetry.layer(WorkersLogs);
