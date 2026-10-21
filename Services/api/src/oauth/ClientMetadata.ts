import { Clock, Context, Effect, Option, Schema } from "effect";
import { isNativeRedirectUri, maxRedirectUris, redirectUriProblem } from "./RedirectUris.ts";

// What OAuth clients say about themselves, from a Client ID Metadata Document (CIMD, fetched from
// the URL that is their `client_id`) or a dynamic registration (RFC 7591), checked the same way.
// Public clients only: none has a secret (851-2845).

/**
 * A client that can't be used, with its OAuth error code: `invalid_client` for a client ID that
 * isn't one (unknown, or a document that can't be fetched), and RFC 7591's codes for metadata
 * that isn't acceptable.
 */
export class InvalidClient extends Schema.TaggedError<InvalidClient>()("InvalidClient", {
  error: Schema.Literals(["invalid_client", "invalid_client_metadata", "invalid_redirect_uri"]),
  description: Schema.String,
}) {}

/** The longest `client_name` a client may have. */
export const maxClientNameLength = 100;

/** The longest client ID URL (CIMD) or `client_uri`. */
export const maxClientUrlLength = 2000;

/** The most a Client ID Metadata Document may be. */
export const maxClientMetadataBytes = 16 * 1024;

/** How long fetching a Client ID Metadata Document may take. */
export const clientMetadataTimeout = "5 seconds";

/** How long a Client ID Metadata Document is cached, whatever its `Cache-Control` says. */
export const minClientMetadataAge = 5 * 60 * 1000;
export const maxClientMetadataAge = 24 * 60 * 60 * 1000;

/** The grant types a client may use. */
export const supportedGrantTypes = ["authorization_code", "refresh_token"] as const;

export type ApplicationType = "web" | "native";

/** A client's metadata, once checked. */
export interface ClientMetadata {
  readonly name: string | null;
  readonly clientUri: string | null;
  readonly redirectUris: ReadonlyArray<string>;
  readonly applicationType: ApplicationType;
  readonly grantTypes: ReadonlyArray<(typeof supportedGrantTypes)[number]>;
}

/**
 * The client metadata fields we read (RFC 7591 §2, and OpenID's `application_type`). Others, such
 * as `logo_uri`, are ignored, as RFC 7591 asks.
 */
const ClientMetadataFields = Schema.Struct({
  client_id: Schema.optionalKey(Schema.String),
  client_name: Schema.optionalKey(Schema.String),
  client_uri: Schema.optionalKey(Schema.String),
  redirect_uris: Schema.Array(Schema.String),
  token_endpoint_auth_method: Schema.optionalKey(Schema.String),
  grant_types: Schema.optionalKey(Schema.Array(Schema.String)),
  response_types: Schema.optionalKey(Schema.Array(Schema.String)),
  application_type: Schema.optionalKey(Schema.String),
});
type ClientMetadataFields = typeof ClientMetadataFields.Type;

const decodeFields = Schema.decodeUnknownEffect(Schema.fromJsonString(ClientMetadataFields));

const invalidMetadata = (description: string) =>
  new InvalidClient({ error: "invalid_client_metadata", description });

/**
 * Checks a client's metadata. Both kinds of client need one to ten acceptable redirect URIs, and
 * no client authentication but `none`. A metadata document must also name the client; a
 * registration may leave the name out, and must ask only for the code flow.
 */
const checkMetadata = (
  fields: ClientMetadataFields,
  kind: "cimd" | "dcr",
): Effect.Effect<ClientMetadata, InvalidClient> =>
  Effect.gen(function* () {
    const uris = fields.redirect_uris;
    if (uris.length === 0 || uris.length > maxRedirectUris) {
      return yield* new InvalidClient({
        error: "invalid_redirect_uri",
        description: `A client needs between 1 and ${maxRedirectUris} redirect URIs`,
      });
    }
    for (const uri of uris) {
      const problem = redirectUriProblem(uri);
      if (Option.isSome(problem)) {
        return yield* new InvalidClient({
          error: "invalid_redirect_uri",
          description: `The redirect URI ${JSON.stringify(uri.slice(0, 100))} ${problem.value}`,
        });
      }
    }
    const name = fields.client_name?.trim();
    if (name !== undefined && name.length > maxClientNameLength) {
      return yield* invalidMetadata(`client_name is longer than ${maxClientNameLength} characters`);
    }
    if (kind === "cimd" && (name === undefined || name === "")) {
      return yield* invalidMetadata("The document has no client_name");
    }
    const clientUri = fields.client_uri;
    if (clientUri !== undefined && !isHttpsUrl(clientUri)) {
      return yield* invalidMetadata("client_uri must be an HTTPS URL");
    }
    const method = fields.token_endpoint_auth_method;
    if (method !== undefined && method !== "none") {
      return yield* invalidMetadata(
        'Only public clients are supported: token_endpoint_auth_method must be "none"',
      );
    }
    let grantTypes: ClientMetadata["grantTypes"] = supportedGrantTypes;
    if (kind === "dcr") {
      if (fields.grant_types !== undefined) {
        const asked = fields.grant_types;
        if (!asked.includes("authorization_code") || !asked.every(isSupportedGrantType)) {
          return yield* invalidMetadata(
            "grant_types must include authorization_code, and may add only refresh_token",
          );
        }
        grantTypes = supportedGrantTypes.filter((type) => asked.includes(type));
      }
      const responseTypes = fields.response_types;
      if (responseTypes !== undefined && responseTypes.some((type) => type !== "code")) {
        return yield* invalidMetadata('response_types may only be ["code"]');
      }
    }
    const applicationType = fields.application_type;
    if (
      applicationType !== undefined &&
      applicationType !== "web" &&
      applicationType !== "native"
    ) {
      return yield* invalidMetadata('application_type must be "web" or "native"');
    }
    return {
      name: name === undefined || name === "" ? null : name,
      clientUri: clientUri ?? null,
      redirectUris: uris,
      // Unsaid, a client whose redirects all stay on the device is a native app.
      applicationType: applicationType ?? (uris.every(isNativeRedirectUri) ? "native" : "web"),
      grantTypes,
    };
  });

const isSupportedGrantType = (type: string): type is (typeof supportedGrantTypes)[number] =>
  (supportedGrantTypes as ReadonlyArray<string>).includes(type);

const isHttpsUrl = (value: string) =>
  value.length <= maxClientUrlLength &&
  URL.canParse(value) &&
  new URL(value).protocol === "https:" &&
  new URL(value).hostname !== "";

/** A dynamic registration's body (RFC 7591 §3.1), checked. */
export const checkRegistration = (body: string) =>
  decodeFields(body).pipe(
    Effect.mapError(() =>
      invalidMetadata("The body must be a JSON object of client metadata, with redirect_uris"),
    ),
    Effect.flatMap((fields) => checkMetadata(fields, "dcr")),
  );

/** Whether `clientId` is a URL, so a Client ID Metadata Document's, rather than a registered ID. */
export const isClientMetadataUrl = (clientId: string) => clientId.startsWith("https://");

/** Hosts that are ours: a client ID there could make us fetch from ourselves. */
const isOwnHost = (hostname: string) => hostname === "lil.tech" || hostname.endsWith(".lil.tech");

/**
 * Why `clientId` can't be a Client ID Metadata Document's URL, if it can't: it must be HTTPS, in
 * its canonical form (so no dot segments, default port or other spellings of the same URL), with
 * a path, and no fragment or user info. Not an IP address, and not one of our hosts.
 */
export const clientIdUrlProblem = (clientId: string): Option.Option<string> => {
  if (clientId.length > maxClientUrlLength) return Option.some("The client ID is too long");
  if (!URL.canParse(clientId)) return Option.some("The client ID isn't a URL");
  const url = new URL(clientId);
  if (url.protocol !== "https:") return Option.some("The client ID URL must be HTTPS");
  if (url.href !== clientId) return Option.some("The client ID URL isn't in its canonical form");
  if (url.pathname === "/") return Option.some("The client ID URL has no path");
  if (clientId.includes("#")) return Option.some("The client ID URL has a fragment");
  if (url.username !== "" || url.password !== "") {
    return Option.some("The client ID URL has user info");
  }
  if (url.hostname.startsWith("[") || /^\d+\.\d+\.\d+\.\d+$/.test(url.hostname)) {
    return Option.some("The client ID URL's host is an IP address");
  }
  if (isOwnHost(url.hostname)) return Option.some("The client ID URL is on a lil.tech host");
  return Option.none();
};

/**
 * Fetches a URL for a Client ID Metadata Document: `fetch`, swapped in tests. Called with
 * `redirect: "manual"`, so a redirect comes back as a response rather than being followed.
 */
export const ClientMetadataFetch = Context.Reference<
  (url: string, init: RequestInit) => Promise<Response>
>("lil/api/oauth/ClientMetadataFetch", { defaultValue: () => (url, init) => fetch(url, init) });

/** A Client ID Metadata Document, checked, and until when it may be cached. */
export interface FetchedClientMetadata {
  readonly metadata: ClientMetadata;
  readonly expiresAt: number;
}

/** A failure to fetch a document, before it's checked. */
class Unfetchable extends Error {}

/** Reads `body` as text, failing once it's longer than `limit` bytes. */
const readAtMost = async (body: ReadableStream<Uint8Array> | null, limit: number) => {
  if (body === null) return "";
  const reader = body.getReader();
  const chunks: Array<Uint8Array> = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      throw new Unfetchable(`The client metadata document is larger than ${limit} bytes`);
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
};

/**
 * How long a document may be cached, from its `Cache-Control`: its `max-age`, kept between 5
 * minutes and 24 hours. `no-store`, `no-cache` or no `max-age` get the 5 minutes.
 */
export const clientMetadataAge = (cacheControl: string | null) => {
  const directives = (cacheControl ?? "").toLowerCase().split(",");
  const names = directives.map((directive) => directive.trim().split("=")[0]);
  if (names.includes("no-store") || names.includes("no-cache")) return minClientMetadataAge;
  const maxAge = directives
    .map((directive) => /^\s*max-age\s*=\s*"?(\d+)"?\s*$/.exec(directive)?.[1])
    .find((value) => value !== undefined);
  const age = maxAge === undefined ? 0 : Number(maxAge) * 1000;
  return Math.min(maxClientMetadataAge, Math.max(minClientMetadataAge, age));
};

/**
 * Fetches and checks the Client ID Metadata Document at `clientId`: no redirects, at most 5
 * seconds and 16 KB, and JSON whose `client_id` is exactly that URL. `global_fetch_strictly_public`
 * keeps the fetch on the public internet.
 */
export const fetchClientMetadata = Effect.fn("fetchClientMetadata")(function* (
  clientId: string,
): Effect.fn.Return<FetchedClientMetadata, InvalidClient> {
  const problem = clientIdUrlProblem(clientId);
  if (Option.isSome(problem)) {
    return yield* new InvalidClient({ error: "invalid_client", description: problem.value });
  }
  const fetchUrl = yield* ClientMetadataFetch;
  const { text, cacheControl } = yield* Effect.tryPromise({
    try: async (signal) => {
      const response = await fetchUrl(clientId, {
        redirect: "manual",
        signal,
        headers: { accept: "application/json" },
      });
      if (response.type === "opaqueredirect" || (response.status >= 300 && response.status < 400)) {
        await response.body?.cancel();
        throw new Unfetchable("The client metadata document redirects, which isn't allowed");
      }
      if (!response.ok) {
        await response.body?.cancel();
        throw new Unfetchable(`Fetching the client metadata document got ${response.status}`);
      }
      if (Number(response.headers.get("content-length") ?? 0) > maxClientMetadataBytes) {
        await response.body?.cancel();
        throw new Unfetchable(
          `The client metadata document is larger than ${maxClientMetadataBytes} bytes`,
        );
      }
      return {
        text: await readAtMost(response.body, maxClientMetadataBytes),
        cacheControl: response.headers.get("cache-control"),
      };
    },
    catch: (error) =>
      new InvalidClient({
        error: "invalid_client",
        description:
          error instanceof Unfetchable
            ? error.message
            : "The client metadata document couldn't be fetched",
      }),
  }).pipe(
    Effect.timeoutOrElse({
      duration: clientMetadataTimeout,
      orElse: () =>
        Effect.fail(
          new InvalidClient({
            error: "invalid_client",
            description: "Fetching the client metadata document took too long",
          }),
        ),
    }),
  );
  const fields = yield* decodeFields(text).pipe(
    Effect.mapError(() =>
      invalidMetadata("The client metadata document isn't a JSON object with redirect_uris"),
    ),
  );
  if (fields.client_id !== clientId) {
    return yield* invalidMetadata("The document's client_id isn't the URL it was fetched from");
  }
  const metadata = yield* checkMetadata(fields, "cimd");
  const now = yield* Clock.currentTimeMillis;
  return { metadata, expiresAt: now + clientMetadataAge(cacheControl) };
});
