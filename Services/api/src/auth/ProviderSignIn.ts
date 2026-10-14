import { Effect, Option } from "effect";
import { Devices, type DevicePlatform } from "../core/Devices.ts";
import { Identities, type IdentityProvider } from "../core/Identities.ts";
import type { UserId } from "../core/Ids.ts";
import { Users } from "../core/Users.ts";
import { Auth } from "./Auth.ts";

/** Who a provider says signed in, from a verified ID token. */
export interface VerifiedIdentity {
  readonly provider: IdentityProvider;
  /** The provider's stable user ID (`sub`). */
  readonly subject: string;
  readonly email: string | null;
  readonly emailVerified: boolean;
  /** A name for a new user. Apple only sends it on the first sign-in. */
  readonly displayName: string | null;
}

export interface DeviceDetails {
  readonly app: string;
  readonly platform: DevicePlatform;
  readonly name: string | null;
}

/**
 * The user an identity belongs to, creating both on first sign-in. Never links by email: a new
 * identity is always a new user (`docs/DECISIONS.md`).
 */
const findOrCreateUser = Effect.fnUntraced(function* (identity: VerifiedIdentity) {
  const users = yield* Users;
  const identities = yield* Identities;
  const existing = yield* identities.find(identity.provider, identity.subject);
  if (Option.isSome(existing)) return existing.value.userId;

  const user = yield* users.create({ displayName: identity.displayName });
  const created = yield* identities
    .create({
      userId: user.id,
      provider: identity.provider,
      subject: identity.subject,
      email: identity.email,
      emailVerified: identity.emailVerified,
    })
    .pipe(Effect.result);
  if (created._tag === "Success") return user.id;

  // A concurrent first sign-in won the (provider, subject) uniqueness race: use its user.
  yield* users.delete(user.id);
  const winner = yield* identities.find(identity.provider, identity.subject);
  if (Option.isSome(winner)) return winner.value.userId;
  return yield* created.failure;
});

/** Signs a verified identity in on a new device and starts its session. */
export const signInWithIdentity = Effect.fn("signInWithIdentity")(function* (
  identity: VerifiedIdentity,
  device: DeviceDetails,
) {
  const userId: UserId = yield* findOrCreateUser(identity);
  const { id: deviceId } = yield* (yield* Devices).create({ userId, ...device });
  return yield* (yield* Auth).issueSession(userId, deviceId);
});
