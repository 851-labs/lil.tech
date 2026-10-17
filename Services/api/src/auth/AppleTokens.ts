import { Clock, Context, Effect, Option, Redacted, Schema } from "effect";
import { decodeJwt, importPKCS8, SignJWT } from "jose";
import { type AppleTokenRevocation, AppleTokenRevocations } from "../core/AppleTokenRevocations.ts";

// Apple requires apps that use Sign in with Apple to revoke the person's tokens when their account
// is deleted (851-2612). Revoking needs Apple's refresh token, which an authorization code from
// sign-in is exchanged for, and both calls need a client secret: a short JWT signed with the
// team's Sign in with Apple key. Refresh tokens are stored encrypted.

/** The team that owns the apps, and its Sign in with Apple key's ID. Neither is secret. */
export const appleTeamId = "WH4QW9ND3J";
export const appleSignInKeyId = "J59CSK4YXA";

/** Where Apple's token endpoints are. */
const appleAuthOrigin = "https://appleid.apple.com";

/** How long a call to Apple may take: sign-in and deletion wait for it. */
const appleTimeout = "5 seconds";

export class AppleTokenRequestFailed extends Schema.TaggedError<AppleTokenRequestFailed>()(
  "AppleTokenRequestFailed",
  {
    message: Schema.String,
    /** Apple's `error`, if it answered with one, e.g. `invalid_grant`. */
    appleError: Schema.optionalKey(Schema.String),
  },
) {}

/** POSTs a form to one of Apple's endpoints: `fetch`, swapped in tests. */
export type ApplePost = (
  path: "/auth/token" | "/auth/revoke",
  form: Readonly<Record<string, string>>,
) => Promise<{ readonly status: number; readonly body: string }>;

const fetchPost: ApplePost = async (path, form) => {
  const response = await fetch(`${appleAuthOrigin}${path}`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form).toString(),
  });
  return { status: response.status, body: await response.text() };
};

/** The Sign in with Apple key, imported. */
type SigningKey = Awaited<ReturnType<typeof importPKCS8>>;

/**
 * The client secret for `clientId`, valid for five minutes: a JWT signed (ES256) with the team's
 * Sign in with Apple key (a PKCS #8 PEM).
 */
export const appleClientSecret = (
  signingKey: string | SigningKey,
  clientId: string,
  nowSeconds: number,
) =>
  Effect.tryPromise({
    try: async () =>
      new SignJWT({})
        .setProtectedHeader({ alg: "ES256", kid: appleSignInKeyId })
        .setIssuer(appleTeamId)
        .setIssuedAt(nowSeconds)
        .setExpirationTime(nowSeconds + 300)
        .setAudience(appleAuthOrigin)
        .setSubject(clientId)
        .sign(typeof signingKey === "string" ? await importPKCS8(signingKey, "ES256") : signingKey),
    catch: (error) =>
      new AppleTokenRequestFailed({ message: `Signing Apple's client secret: ${String(error)}` }),
  });

/** AES-GCM with a key derived from `secret` (any string): the IV, then the ciphertext, base64. */
const cipher = (secret: Redacted.Redacted<string>) => {
  const key = crypto.subtle
    .digest("SHA-256", new TextEncoder().encode(Redacted.value(secret)))
    .then((bytes) =>
      crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]),
    );
  return {
    encrypt: async (plain: string) => {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const sealed = new Uint8Array(
        await crypto.subtle.encrypt(
          { name: "AES-GCM", iv },
          await key,
          new TextEncoder().encode(plain),
        ),
      );
      const bytes = new Uint8Array(iv.length + sealed.length);
      bytes.set(iv);
      bytes.set(sealed, iv.length);
      return btoa(String.fromCharCode(...bytes));
    },
    decrypt: async (encrypted: string) => {
      const bytes = Uint8Array.from(atob(encrypted), (char) => char.charCodeAt(0));
      const plain = await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: bytes.slice(0, 12) },
        await key,
        bytes.slice(12),
      );
      return new TextDecoder().decode(plain);
    },
  };
};

/** What `/auth/token` answers that's kept or checked. */
const TokenResponse = Schema.fromJsonString(
  Schema.Struct({ refresh_token: Schema.NonEmptyString, id_token: Schema.String }),
);

/** Apple's `error` in a refusal's body, if it has one. */
const errorCode = (body: string) =>
  Schema.decodeUnknownOption(Schema.fromJsonString(Schema.Struct({ error: Schema.String })))(
    body,
  ).pipe(Option.map((parsed) => parsed.error));

/** Apple's token endpoints, for a deployment that has the signing key. */
export class AppleTokens extends Context.Service<
  AppleTokens,
  {
    /**
     * Exchanges a sign-in's authorization code for Apple's refresh token, returned encrypted,
     * or none if Apple refused it, the token is someone else's than `subject`'s, or there's no
     * signing key. It never fails: signing in doesn't depend on it, and the account just can't
     * have its token revoked.
     */
    readonly exchange: (
      code: string,
      options: {
        readonly clientId: string;
        readonly subject: string;
        /** The sign-in's `redirect_uri`, if it had one (the web sign-in). */
        readonly redirectUri?: string;
      },
    ) => Effect.Effect<Option.Option<string>>;
    /** Revokes a refresh token that `exchange` returned. */
    readonly revoke: (
      encrypted: string,
      clientId: string,
    ) => Effect.Effect<void, AppleTokenRequestFailed>;
  }
>()("lil/api/auth/AppleTokens") {
  /**
   * With the team's Sign in with Apple key (`signingKey`, or none where it isn't configured, such
   * as previews), and the secret that encrypts stored tokens.
   */
  static make(options: {
    readonly signingKey: Option.Option<Redacted.Redacted<string>>;
    readonly tokenSecret: Redacted.Redacted<string>;
    readonly post?: ApplePost;
  }) {
    const post = options.post ?? fetchPost;
    const tokens = cipher(options.tokenSecret);
    // Imported once, on first use.
    const signingKey = Option.map(options.signingKey, (pem) => {
      let imported: Promise<SigningKey> | undefined;
      return () => (imported ??= importPKCS8(Redacted.value(pem), "ES256"));
    });
    const call = (
      path: "/auth/token" | "/auth/revoke",
      clientId: string,
      form: Record<string, string>,
    ) =>
      Effect.gen(function* () {
        if (Option.isNone(signingKey)) {
          return yield* new AppleTokenRequestFailed({ message: "No Sign in with Apple key" });
        }
        const key = yield* Effect.tryPromise({
          try: signingKey.value,
          catch: (error) =>
            new AppleTokenRequestFailed({
              message: `Importing the Sign in with Apple key: ${String(error)}`,
            }),
        });
        const secret = yield* appleClientSecret(
          key,
          clientId,
          Math.floor((yield* Clock.currentTimeMillis) / 1000),
        );
        const response = yield* Effect.tryPromise({
          try: () => post(path, { ...form, client_id: clientId, client_secret: secret }),
          catch: (error) =>
            new AppleTokenRequestFailed({ message: `Apple's ${path}: ${String(error)}` }),
        }).pipe(
          Effect.timeoutOrElse({
            duration: appleTimeout,
            orElse: () =>
              Effect.fail(new AppleTokenRequestFailed({ message: `Apple's ${path} timed out` })),
          }),
        );
        if (response.status !== 200) {
          const appleError = Option.getOrUndefined(errorCode(response.body));
          return yield* new AppleTokenRequestFailed({
            message: `Apple's ${path} answered ${response.status} ${appleError ?? ""}`.trim(),
            ...(appleError === undefined ? {} : { appleError }),
          });
        }
        return response.body;
      });

    return AppleTokens.of({
      exchange: (code, { clientId, subject, redirectUri }) =>
        Effect.gen(function* () {
          // Where there's no key (previews), quietly: there's nothing to warn anyone about.
          if (Option.isNone(signingKey)) return Option.none();
          const body = yield* call("/auth/token", clientId, {
            code,
            grant_type: "authorization_code",
            ...(redirectUri === undefined ? {} : { redirect_uri: redirectUri }),
          });
          const response = yield* Schema.decodeUnknownEffect(TokenResponse)(body).pipe(
            Effect.mapError(
              () => new AppleTokenRequestFailed({ message: "Apple's token response didn't parse" }),
            ),
          );
          // Over TLS from Apple, so not verified again: it only has to say whose token it is.
          // A code from someone else's sign-in isn't kept.
          if (decodeJwt(response.id_token).sub !== subject) {
            return yield* new AppleTokenRequestFailed({
              message: "Apple's token is for someone else",
            });
          }
          const refreshToken = response.refresh_token;
          return Option.some(yield* Effect.promise(() => tokens.encrypt(refreshToken)));
        }).pipe(
          Effect.catchCause((cause) =>
            Effect.logWarning("Exchanging Apple's authorization code failed", cause).pipe(
              Effect.as(Option.none()),
            ),
          ),
        ),
      revoke: (encrypted, clientId) =>
        Effect.gen(function* () {
          const token = yield* Effect.tryPromise({
            try: () => tokens.decrypt(encrypted),
            catch: () =>
              new AppleTokenRequestFailed({ message: "The stored token didn't decrypt" }),
          });
          yield* call("/auth/revoke", clientId, {
            token,
            token_type_hint: "refresh_token",
          });
        }),
    });
  }
}

/** How many failed attempts a revocation gets, about two weeks of daily runs. */
export const maxRevocationAttempts = 14;

/** The most revocations one daily run attempts; the next day's run continues. */
export const revocationBatchSize = 100;

/**
 * How long after a failed attempt to try again: an hour, doubling up to 23 hours, so the next
 * daily run always finds it due.
 */
const retryDelay = (attempts: number) => Math.min(2 ** (attempts - 1), 23) * 60 * 60 * 1000;

/**
 * Revokes the given tokens (or, by default, up to `revocationBatchSize` that are due), forgetting
 * each one that's revoked or that Apple says is no good (`invalid_grant`, e.g. already revoked).
 * Other failures are tried again later, up to `maxRevocationAttempts`. One token's failure doesn't
 * stop the others. Returns how many it's done with (revoked or given up on).
 */
export const revokeAppleTokens = Effect.fn("revokeAppleTokens")(function* (
  pending?: ReadonlyArray<AppleTokenRevocation>,
) {
  const tokens = yield* AppleTokens;
  const revocations = yield* AppleTokenRevocations;
  const now = yield* Clock.currentTimeMillis;
  const due = pending ?? (yield* revocations.listDue(now, revocationBatchSize));
  const results = yield* Effect.forEach(
    due,
    (revocation) =>
      tokens.revoke(revocation.refreshToken, revocation.clientId).pipe(
        Effect.as(true),
        Effect.catchTag("AppleTokenRequestFailed", (error) => {
          const attempts = revocation.attempts + 1;
          if (error.appleError === "invalid_grant" || attempts >= maxRevocationAttempts) {
            return Effect.logError(`Gave up revoking Apple token ${revocation.id}`, error).pipe(
              Effect.as(true),
            );
          }
          return Effect.logWarning(`Revoking Apple token ${revocation.id} failed`, error).pipe(
            Effect.andThen(
              revocations.postpone(revocation.id, attempts, now + retryDelay(attempts)),
            ),
            Effect.as(false),
          );
        }),
        Effect.tap((done) => (done ? revocations.remove(revocation.id) : Effect.void)),
        Effect.catchCause((cause) =>
          Effect.logWarning(`Recording Apple token ${revocation.id} failed`, cause).pipe(
            Effect.as(false),
          ),
        ),
      ),
    { concurrency: 10 },
  );
  return results.filter(Boolean).length;
});
