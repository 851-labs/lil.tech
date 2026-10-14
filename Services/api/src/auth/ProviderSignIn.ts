import { Context, Effect, Layer, Option, type Schema } from "effect";
import type { SqlError } from "effect/sql";
import { Devices, type DevicePlatform } from "../core/Devices.ts";
import { Identities, type IdentityProvider } from "../core/Identities.ts";
import type { UserId } from "../core/Ids.ts";
import { Users } from "../core/Users.ts";
import { Auth } from "./Auth.ts";
import type { TokenPair } from "./AuthApi.ts";

/** Who a provider says signed in, from a verified ID token. */
export interface VerifiedIdentity {
  readonly provider: IdentityProvider;
  /** The provider's stable user ID (`sub`). */
  readonly subject: string;
  readonly email: string | null;
  readonly emailVerified: boolean;
  /** The person's name, if the provider sent one. Apple only sends it on the first sign-in. */
  readonly displayName: string | null;
}

export interface DeviceDetails {
  readonly app: string;
  readonly platform: DevicePlatform;
  readonly name: string | null;
}

/** Signing in with a verified provider identity, shared by every provider. */
export class ProviderSignIn extends Context.Service<
  ProviderSignIn,
  {
    /**
     * Signs the identity in on a new device and starts its session. The identity's user is
     * created on first sign-in; accounts are never linked by email (`docs/DECISIONS.md`).
     */
    readonly signIn: (
      identity: VerifiedIdentity,
      device: DeviceDetails,
    ) => Effect.Effect<TokenPair, SqlError.SqlError | Schema.SchemaError>;
  }
>()("lil/api/auth/ProviderSignIn") {
  static readonly layer = Layer.effect(
    ProviderSignIn,
    Effect.gen(function* () {
      const users = yield* Users;
      const identities = yield* Identities;
      const devices = yield* Devices;
      const auth = yield* Auth;

      const findOrCreateUser = Effect.fnUntraced(function* (identity: VerifiedIdentity) {
        const existing = yield* identities.find(identity.provider, identity.subject);
        if (Option.isSome(existing)) {
          // E.g. the first sign-in's request failed after Apple sent the name.
          if (identity.displayName !== null) {
            yield* users.setDisplayNameIfMissing(existing.value.userId, identity.displayName);
          }
          return existing.value.userId;
        }

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

        // Most likely a concurrent first sign-in won the (provider, subject) uniqueness race.
        // Either way the new user has no identity, so it goes.
        const winner = yield* identities
          .find(identity.provider, identity.subject)
          .pipe(Effect.ensuring(users.delete(user.id).pipe(Effect.ignore({ log: true }))));
        if (Option.isSome(winner)) return winner.value.userId;
        return yield* created.failure;
      });

      return ProviderSignIn.of({
        signIn: Effect.fn("ProviderSignIn.signIn")(function* (identity, device) {
          const userId: UserId = yield* findOrCreateUser(identity);
          const { id: deviceId } = yield* devices.create({ userId, ...device });
          return yield* auth.issueSession(userId, deviceId);
        }),
      });
    }),
  );
}
