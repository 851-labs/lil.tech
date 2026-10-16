import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import * as SQL from "alchemy/SQL/D1";
import { Config, Effect, Layer, Option, Redacted, Stream } from "effect";
import { HttpRouter } from "effect/http";
import { AppleKeys } from "./auth/Apple.ts";
import { GoogleClients, GoogleKeys } from "./auth/Google.ts";
import { SessionKey } from "./auth/Tokens.ts";
import { CoreDatabase, CoreRepositories } from "./core/CoreDatabase.ts";
import { retireSignedOutDevices } from "./core/DeviceCleanup.ts";
import { Devices } from "./core/Devices.ts";
import { Users } from "./core/Users.ts";
import { Deployment, environmentForStage, stageDomains } from "./Deployment.ts";
import { HealthBatchFiles, HealthBatchQueue } from "./health/HealthIngestion.ts";
import { HealthBlobFiles } from "./health/HealthBlobs.ts";
import { deletePrefix, HealthBlobBucket, HealthIngestionWorker } from "./health/HealthResources.ts";
import { WorkerHttpLayer } from "./Http.ts";
import {
  type RateLimitCounter,
  type RateLimitName,
  rateLimitNamespaceId,
  RateLimits,
  rateLimits,
} from "./RateLimits.ts";
import { objectBody, provideRuntime } from "./Runtime.ts";
import { SnapshotBucket, UserStore, UserStoreLive } from "./store/UserStore.ts";
import { type OpenedPart, type PartRange, SnapshotParts } from "./sync/SnapshotParts.ts";
import { UserStores } from "./store/UserStores.ts";

/** Custom domains per stage. Other stages (PR previews, personal stages) use workers.dev. */

/**
 * The Worker's props. Alchemy also evaluates them inside the running Worker, where there's no
 * `Stage`, so the deploy-time work (picking the domain, checking the environment, binding the
 * session key) only happens when a stage is present. `sessionKey` makes the key at deploy time.
 */
export const makeApiWorkerProps = <Key, E, R>(sessionKey: Effect.Effect<Key, E, R>) =>
  Effect.gen(function* () {
    const main = import.meta.url;
    const stage = yield* Effect.serviceOption(Alchemy.Stage);
    if (Option.isNone(stage)) return { main };
    const { environment } = yield* Deployment.config;
    const expected = environmentForStage(stage.value);
    if (environment !== expected) {
      return yield* Effect.die(
        `LIL_ENVIRONMENT is "${environment}" but stage "${stage.value}" expects "${expected}"`,
      );
    }
    const domain = stageDomains[stage.value]?.api;
    return {
      main,
      ...(domain === undefined ? {} : { domain }),
      env: { LIL_SESSION_KEY: yield* sessionKey },
    };
  });

// Generated once per stage and kept in Alchemy's state, so redeploys don't sign everyone out.
const apiWorkerProps = makeApiWorkerProps(Alchemy.makeRandom("SessionSigningKey"));

/**
 * The key that signs access tokens, bound by `apiWorkerProps`. It's only missing while Alchemy
 * plans a deploy, which runs the Worker's setup but never serves a request, so that gets a
 * throwaway random key. The deployed bundle (where Alchemy sets `__ALCHEMY_RUNTIME__`) refuses to
 * start without the real one.
 */
const readSessionKey = Effect.gen(function* () {
  const key = yield* Config.Redacted("LIL_SESSION_KEY").pipe(Config.option);
  if (Option.isSome(key)) return key.value;
  if (globalThis.__ALCHEMY_RUNTIME__) return yield* Effect.die("LIL_SESSION_KEY is not bound");
  return Redacted.make(crypto.randomUUID());
});

/**
 * Binds a rate limit and counts with it. The namespace ID only matters at deploy time; the running
 * Worker, which has no `Stage`, finds the binding by name.
 */
const bindRateLimit = Effect.fnUntraced(function* (name: string, limit: RateLimitName) {
  const stage = yield* Effect.serviceOption(Alchemy.Stage);
  const binding = yield* Cloudflare.RateLimit(name, {
    namespaceId: rateLimitNamespaceId(
      Option.getOrElse(stage, () => "runtime"),
      limit,
    ),
    simple: { limit: rateLimits[limit].limit, period: rateLimits[limit].periodSeconds },
  });
  // The binding's calls need the request's runtime context. HttpApi middleware can only use
  // services from setup, so the counter reads it from the request it runs in.
  const counter: RateLimitCounter = (key) =>
    Effect.serviceOption(Alchemy.RuntimeContext).pipe(
      Effect.flatMap(
        Option.match({
          onNone: () => Effect.fail(new Error("No runtime context")),
          onSome: (runtime) => provideRuntime(runtime)(binding.limit({ key })),
        }),
      ),
      Effect.map((outcome) => outcome.success),
    );
  return counter;
});

/**
 * Opens an R2 object, or a byte range of it, for a signed download. Built per request: the
 * bucket's calls need the request's runtime context.
 */
const openObject =
  (bucket: Pick<Cloudflare.R2.ReadBucketClient, "get" | "head">) =>
  (runtime: Alchemy.RuntimeContext["Service"]) =>
  (key: string, range: PartRange | undefined): Effect.Effect<Option.Option<OpenedPart>> =>
    provideRuntime(runtime)(
      bucket.get(key, range === undefined ? {} : { range }).pipe(
        // R2 may reject a range past the end; answer that with the part's size (a 416).
        Effect.catch((error) =>
          range === undefined
            ? Effect.fail(error)
            : bucket.head(key).pipe(
                Effect.map((head) =>
                  head === null
                    ? null
                    : {
                        ...head,
                        range: { offset: head.size },
                        readable: new ReadableStream<Uint8Array>(),
                        body: Stream.empty,
                      },
                ),
              ),
        ),
      ),
    ).pipe(
      Effect.map((object) => {
        if (object === null) return Option.none();
        const applied = object.range as
          | { offset?: number; length?: number; suffix?: number }
          | undefined;
        const offset =
          applied?.suffix !== undefined
            ? Math.max(0, object.size - applied.suffix)
            : (applied?.offset ?? 0);
        const length = applied?.length ?? object.size - offset;
        return Option.some({
          body: objectBody(object),
          size: object.size,
          etag: object.httpEtag,
          ...(range === undefined || offset >= object.size ? {} : { range: { offset, length } }),
        });
      }),
      Effect.orDie,
    );

// Alchemy's Effect Worker entry imports the module's default export.
export default class ApiWorker extends Cloudflare.Worker<ApiWorker>()(
  "Api",
  apiWorkerProps,
  Effect.gen(function* () {
    const deployment = yield* Deployment.config;
    const key = yield* readSessionKey;
    const core = yield* Cloudflare.D1.QueryDatabase(CoreDatabase);
    const userStores = UserStores.fromNamespace(yield* UserStore);
    const health = yield* HealthIngestionWorker(
      userStores,
      Users.layer.pipe(Layer.provide(SQL.D1Layer(core))),
    );
    // Daily, at a quiet hour for most users.
    yield* Cloudflare.Workers.cron("23 4 * * *", () =>
      retireSignedOutDevices().pipe(
        Effect.tap((retired) => Effect.log(`Retired ${retired} signed-out devices`)),
        Effect.provide(Devices.layer.pipe(Layer.provide(SQL.D1Layer(core)))),
        Effect.provideService(UserStores, userStores),
      ),
    );
    const snapshots = yield* Cloudflare.R2.ReadBucket(yield* SnapshotBucket);
    const limits = RateLimits.make({
      signIn: yield* bindRateLimit("SignInRateLimit", "signIn"),
      user: yield* bindRateLimit("UserRateLimit", "user"),
      refresh: yield* bindRateLimit("RefreshRateLimit", "refresh"),
    });
    const blobs = yield* Cloudflare.R2.ReadWriteBucket(yield* HealthBlobBucket);
    // Per request: the buckets' calls need the request's runtime context.
    const snapshotParts = Effect.map(Alchemy.RuntimeContext, (runtime) =>
      SnapshotParts.of({ open: openObject(snapshots)(runtime) }),
    );
    const blobFiles = Effect.map(Alchemy.RuntimeContext, (runtime) => {
      const inRuntime = provideRuntime(runtime);
      return HealthBlobFiles.of({
        put: (key, bytes) =>
          inRuntime(
            blobs.put(key, bytes, { httpMetadata: { contentType: "application/octet-stream" } }),
          ).pipe(Effect.asVoid, Effect.orDie),
        open: openObject(blobs)(runtime),
        deletePrefix: (prefix) => deletePrefix(blobs, prefix).pipe(inRuntime),
      });
    });
    const fetch = yield* HttpRouter.toHttpEffect(
      WorkerHttpLayer.pipe(
        Layer.provide(Layer.succeed(Deployment, deployment)),
        Layer.provide(Layer.succeed(SessionKey, key)),
        Layer.provide([AppleKeys.layer, GoogleKeys.layer, GoogleClients.layer]),
        Layer.provide(Layer.succeed(UserStores, userStores)),
        Layer.provide(Layer.succeed(RateLimits, limits)),
        Layer.provide(CoreRepositories.pipe(Layer.provideMerge(SQL.D1Layer(core)))),
      ),
    );
    return {
      fetch: fetch.pipe(
        Effect.provideServiceEffect(HealthBatchFiles, health.files),
        Effect.provideServiceEffect(HealthBatchQueue, health.queue),
        Effect.provideServiceEffect(SnapshotParts, snapshotParts),
        Effect.provideServiceEffect(HealthBlobFiles, blobFiles),
      ),
    };
  }).pipe(
    Effect.provide([
      Cloudflare.D1.QueryDatabaseBinding,
      Cloudflare.R2.ReadWriteBucketBinding,
      Cloudflare.R2.ReadBucketBinding,
      Cloudflare.Queues.WriteQueueBinding,
      Cloudflare.Queues.EventSourceLive,
      Cloudflare.RateLimitBinding,
      Cloudflare.Workers.CronEventSourceLive,
      UserStoreLive,
    ]),
  ),
) {}
