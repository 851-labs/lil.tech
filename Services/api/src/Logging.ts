import * as Alchemy from "alchemy";
import { Cause, Formatter, type LogLevel, Logger, References } from "effect";

/** Workers Logs' level for each of Effect's. */
const workersLevels: Record<LogLevel.LogLevel, string> = {
  All: "debug",
  Trace: "debug",
  Debug: "debug",
  Info: "info",
  Warn: "warn",
  Error: "error",
  Fatal: "error",
  None: "info",
};

/**
 * A log line as one JSON object (851-4050), which Workers Logs indexes field by field: `message`
 * (the first part logged), `level`, the annotations (`Effect.annotateLogs`) as fields of their
 * own, `details` (the other parts, such as an error) and `cause`. Annotations named like those
 * lose to them. It's plain JSON, made with Effect's formatter: `Redacted` values stay redacted,
 * errors keep their name, message and fields, and anything else that can't be JSON is dropped.
 */
export const workersLogger = Logger.withLeveledConsole(
  Logger.make(({ cause, date, fiber, logLevel, message }) => {
    const [first, ...rest] = Array.isArray(message) ? message : [message];
    const spans: Record<string, number> = {};
    for (const [label, startedAt] of fiber.getRef(References.CurrentLogSpans)) {
      spans[label] = date.getTime() - startedAt;
    }
    const entry = {
      ...fiber.getRef(References.CurrentLogAnnotations),
      message: typeof first === "string" ? first : Formatter.format(first),
      level: workersLevels[logLevel],
      ...(rest.length > 0 ? { details: rest } : {}),
      ...(cause.reasons.length > 0 ? { cause: Cause.pretty(cause) } : {}),
      ...(Object.keys(spans).length > 0 ? { spans } : {}),
    };
    return JSON.parse(Formatter.formatJson(entry)) as Record<string, unknown>;
  }),
);

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
