import { Effect, Option, Schema, Stream } from "effect";
import { HttpServerRequest } from "effect/http";

// Reading the agents' authorization server's requests: where they came to, and their forms.

/** The request's origin, as the client used it. */
export const requestOrigin = (request: HttpServerRequest.HttpServerRequest) => {
  try {
    return new URL(request.originalUrl).origin;
  } catch {
    return `https://${request.headers["host"] ?? "api.lil.tech"}`;
  }
};

/** A URL's query, without the `?`: everything after the first, since a query may hold more. */
export const queryOf = (url: string) => {
  const start = url.indexOf("?");
  return start === -1 ? "" : (url.slice(start + 1).split("#", 1)[0] ?? "");
};

/** The request's path, without its query. */
export const requestPath = (request: HttpServerRequest.HttpServerRequest) =>
  request.url.split("?", 1)[0] ?? "/";

/**
 * Reads a body of at most `limit` bytes, stopping as soon as it's longer, so a chunked body without
 * a `Content-Length` can't make us hold all of it. `None` if it's too long.
 */
export const readAtMost = <E>(body: Stream.Stream<Uint8Array, E>, limit: number) =>
  Effect.gen(function* () {
    const chunks: Array<Uint8Array> = [];
    let size = 0;
    yield* Stream.runForEachWhile(body, (chunk) =>
      Effect.sync(() => {
        size += chunk.byteLength;
        if (size > limit) return false;
        chunks.push(chunk);
        return true;
      }),
    );
    if (size > limit) return Option.none();
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return Option.some(new TextDecoder().decode(bytes));
  });

/** A form a request couldn't be read as. */
export class InvalidForm extends Schema.TaggedError<InvalidForm>()("InvalidForm", {
  description: Schema.String,
}) {}

/**
 * Parameters from a query or form (RFC 6749 §3.1, §3.2): a parameter without a value counts as
 * absent, and one sent twice is refused.
 */
export const readParams = (
  encoded: string,
): Effect.Effect<ReadonlyMap<string, string>, InvalidForm> => {
  const params = new Map<string, string>();
  const seen = new Set<string>();
  for (const [name, value] of new URLSearchParams(encoded)) {
    if (seen.has(name)) {
      return Effect.fail(new InvalidForm({ description: `${name} is given more than once` }));
    }
    seen.add(name);
    if (value !== "") params.set(name, value);
  }
  return Effect.succeed(params);
};

/**
 * The request's `application/x-www-form-urlencoded` parameters, from a body of at most `limit`
 * bytes, read as `readParams` does.
 */
export const readForm = (limit: number) =>
  Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest;
    const contentType = (request.headers["content-type"] ?? "").split(";", 1)[0]?.trim();
    if (contentType?.toLowerCase() !== "application/x-www-form-urlencoded") {
      return yield* new InvalidForm({
        description: "The request must be application/x-www-form-urlencoded",
      });
    }
    const tooLarge = new InvalidForm({ description: `The request is larger than ${limit} bytes` });
    if (Number(request.headers["content-length"] ?? 0) > limit) return yield* tooLarge;
    const body = yield* readAtMost(request.stream, limit).pipe(
      Effect.mapError(() => new InvalidForm({ description: "The request couldn't be read" })),
    );
    if (Option.isNone(body)) return yield* tooLarge;
    return yield* readParams(body.value);
  });
