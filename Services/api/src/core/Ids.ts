import { Clock, Effect, Schema } from "effect";

// IDs are a type prefix plus 26 lowercase Crockford base32 characters: 10 encode the creation
// time in milliseconds, so IDs sort by creation time, and 16 are random.

const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";

/** The regular expression source for an ID with `prefix`, e.g. `dev_…`. */
export const idPattern = (prefix: string) => `${prefix}_[${alphabet}]{26}`;

const pattern = (prefix: string) => Schema.isPattern(new RegExp(`^${idPattern(prefix)}$`));

export const UserId = Schema.String.pipe(Schema.check(pattern("usr")), Schema.brand("UserId"));
export type UserId = typeof UserId.Type;
export const IdentityId = Schema.String.pipe(
  Schema.check(pattern("idt")),
  Schema.brand("IdentityId"),
);
export type IdentityId = typeof IdentityId.Type;
export const DeviceId = Schema.String.pipe(Schema.check(pattern("dev")), Schema.brand("DeviceId"));
export type DeviceId = typeof DeviceId.Type;
export const SessionId = Schema.String.pipe(
  Schema.check(pattern("ses")),
  Schema.brand("SessionId"),
);
export type SessionId = typeof SessionId.Type;
export const ConnectionId = Schema.String.pipe(
  Schema.check(pattern("con")),
  Schema.brand("ConnectionId"),
);
export type ConnectionId = typeof ConnectionId.Type;
export const OAuthClientId = Schema.String.pipe(
  Schema.check(pattern("ocl")),
  Schema.brand("OAuthClientId"),
);
export type OAuthClientId = typeof OAuthClientId.Type;
export const AgentAuthorizationId = Schema.String.pipe(
  Schema.check(pattern("aau")),
  Schema.brand("AgentAuthorizationId"),
);
export type AgentAuthorizationId = typeof AgentAuthorizationId.Type;
export const AgentGrantId = Schema.String.pipe(
  Schema.check(pattern("agr")),
  Schema.brand("AgentGrantId"),
);
export type AgentGrantId = typeof AgentGrantId.Type;

/** Makes a new ID with the given prefix, using the `Clock` for its time part. */
export const makeId = Effect.fnUntraced(function* (prefix: string) {
  let time = yield* Clock.currentTimeMillis;
  let encodedTime = "";
  for (let i = 0; i < 10; i++) {
    encodedTime = alphabet[time % 32] + encodedTime;
    time = Math.floor(time / 32);
  }
  const random = crypto.getRandomValues(new Uint8Array(16));
  let encodedRandom = "";
  for (const byte of random) encodedRandom += alphabet[byte % 32];
  return `${prefix}_${encodedTime}${encodedRandom}`;
});

export const newUserId = makeId("usr") as Effect.Effect<UserId>;
export const newIdentityId = makeId("idt") as Effect.Effect<IdentityId>;
export const newDeviceId = makeId("dev") as Effect.Effect<DeviceId>;
export const newSessionId = makeId("ses") as Effect.Effect<SessionId>;
export const newConnectionId = makeId("con") as Effect.Effect<ConnectionId>;
export const newOAuthClientId = makeId("ocl") as Effect.Effect<OAuthClientId>;
export const newAgentAuthorizationId = makeId("aau") as Effect.Effect<AgentAuthorizationId>;
export const newAgentGrantId = makeId("agr") as Effect.Effect<AgentGrantId>;
/** A client ID that dynamic client registration issues (`POST /oauth/register`). */
export const newRegisteredClientId = makeId("cli");
