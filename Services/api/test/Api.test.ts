import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { assert, describe, it } from "@effect/vitest";
import * as Alchemy from "alchemy";
import { Clock, ConfigProvider, Effect, Exit, Layer, Redacted, Schema } from "effect";
import { HttpRouter } from "effect/http";
import { TestClock } from "effect/testing";
import { HttpApi, HttpApiEndpoint, HttpApiGroup } from "effect/http-api";
import { Deployment, environmentForStage } from "../src/Deployment.ts";
import { Auth } from "../src/auth/Auth.ts";
import { ingestHealthBatch } from "../src/health/HealthIngestion.ts";
import { maxDevUsers } from "../src/auth/DevSignIn.ts";
import { AccessTokens } from "../src/auth/Tokens.ts";
import { Devices } from "../src/core/Devices.ts";
import { Identities } from "../src/core/Identities.ts";
import type { UserId } from "../src/core/Ids.ts";
import { Users } from "../src/core/Users.ts";
import { entities } from "../src/store/Registry.ts";
import { snapshotPolicy, writeSnapshotStep } from "../src/store/Snapshots.ts";
import { UserStores } from "../src/store/UserStores.ts";
import { PartUrls } from "../src/sync/SnapshotParts.ts";
import { WorkerHttpLayer } from "../src/Http.ts";
import { makeOpenApiSpec } from "../src/OpenApiSpec.ts";
import { makeApiWorkerProps } from "../src/Worker.ts";
import { appleIdentityToken, TestAppleKeys } from "./auth/TestApple.ts";
import { googleIdToken, TestGoogleClients, TestGoogleKeys } from "./auth/TestGoogle.ts";
import { TestAuth } from "./auth/TestAuth.ts";
import { batchFile, TestHealthIngestion, TestHealthOutbox } from "./health/TestHealthIngestion.ts";
import { TestStores, TestUserStores, testNote } from "./store/TestUserStores.ts";

const committedSpec = readFileSync(new URL("../openapi.json", import.meta.url), "utf8");

type Handler = (request: Request) => Promise<Response>;

/**
 * Runs `use` with a handler for the same layer the Worker serves, driven with real Requests. The
 * handler and `use` share one test database, so `use` can seed it.
 */
const withApi = <A, E>(
  use: (handler: Handler) => Effect.Effect<A, E, Layer.Success<typeof TestServices>>,
  deployment: Deployment["Service"] = { environment: "staging", version: "45aa829" },
) =>
  Effect.gen(function* () {
    const services = Layer.mergeAll(TestServices, Layer.succeed(Deployment, deployment));
    const memoMap = yield* Layer.makeMemoMap;
    const context = yield* Layer.buildWithMemoMap(services, memoMap, yield* Effect.scope);
    const { handler, dispose } = HttpRouter.toWebHandler(
      WorkerHttpLayer.pipe(Layer.provide(services)),
      { memoMap },
    );
    yield* Effect.addFinalizer(() => Effect.promise(() => dispose()));
    return yield* use((request) => handler(request, context)).pipe(Effect.provide(context));
  }).pipe(Effect.scoped);

const TestServices = Layer.mergeAll(
  TestAuth,
  TestAppleKeys,
  TestGoogleKeys,
  TestGoogleClients,
  TestUserStores,
  TestHealthIngestion,
);

const send = (handler: Handler, request: Request) =>
  Effect.promise(async () => {
    const response = await handler(request);
    const text = await response.text();
    return {
      status: response.status,
      body: text === "" ? undefined : (JSON.parse(text) as unknown),
    };
  });

const bearer = (token: string) => ({ authorization: `Bearer ${token}` });

const signIn = Effect.gen(function* () {
  const user = yield* (yield* Users).create({ displayName: "Ada" });
  yield* (yield* Identities).create({
    userId: user.id,
    provider: "apple",
    subject: crypto.randomUUID(),
    email: "ada@privaterelay.appleid.com",
    emailVerified: true,
  });
  const device = yield* (yield* Devices).create({
    userId: user.id,
    app: "health-ios",
    platform: "ios",
    name: null,
  });
  const tokens = yield* (yield* Auth).issueSession(user.id, device.id);
  return { user, tokens };
});

const refresh = (handler: Handler, refreshToken: string) =>
  send(
    handler,
    new Request("https://api.lil.tech/v1/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken }),
    }),
  );

describe("WorkerHttpLayer", () => {
  it.live("GET /v1/status returns the deployment's environment and version", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const response = yield* send(
          handler,
          new Request("https://api.staging.lil.tech/v1/status"),
        );
        assert.deepStrictEqual(response, {
          status: 200,
          body: { environment: "staging", version: "45aa829" },
        });
      }),
    ),
  );

  it.live("GET /v1/openapi.json serves the committed spec", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const response = yield* send(
            handler,
            new Request("https://api.lil.tech/v1/openapi.json"),
          );
          assert.deepStrictEqual(response, { status: 200, body: JSON.parse(committedSpec) });
        }),
      { environment: "prod", version: "1" },
    ),
  );

  it.live("unknown paths return 404", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const response = yield* send(handler, new Request("https://api.lil.tech/v1/nope"));
        assert.strictEqual(response.status, 404);
      }),
    ),
  );

  it.live("GET /v1/me returns the signed-in user and their identities", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(tokens.accessToken) }),
        );
        assert.deepStrictEqual(response, {
          status: 200,
          body: {
            id: user.id,
            displayName: "Ada",
            identities: [{ provider: "apple", email: "ada@privaterelay.appleid.com" }],
          },
        });
      }),
    ),
  );

  it.live("GET /v1/me rejects missing, invalid and expired access tokens", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const accessTokens = yield* AccessTokens;
        // Signed under a test clock at 1970, so it expired long ago.
        const expired = yield* accessTokens
          .sign(yield* accessTokens.verify(tokens.accessToken))
          .pipe(Effect.provide(TestClock.layer()));
        const requests = [
          new Request("https://api.lil.tech/v1/me", { headers: bearer(expired.token) }),
          new Request("https://api.lil.tech/v1/me"),
          new Request("https://api.lil.tech/v1/me", { headers: bearer("nope") }),
          new Request("https://api.lil.tech/v1/me", { headers: bearer(`${tokens.accessToken}x`) }),
          // A refresh token isn't an access token.
          new Request("https://api.lil.tech/v1/me", { headers: bearer(tokens.refreshToken) }),
        ];
        for (const request of requests) {
          const response = yield* send(handler, request);
          assert.strictEqual(response.status, 401);
          assert.propertyVal(response.body, "_tag", "Unauthorized");
        }
      }),
    ),
  );

  it.live("GET /v1/me rejects an access token whose user was deleted", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        yield* (yield* Users).delete(user.id);
        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(tokens.accessToken) }),
        );
        assert.strictEqual(response.status, 401);
      }),
    ),
  );

  it.live("POST /v1/auth/refresh rotates the refresh token", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const first = yield* refresh(handler, tokens.refreshToken);
        assert.strictEqual(first.status, 200);
        const pair = first.body as { accessToken: string; refreshToken: string };
        assert.notStrictEqual(pair.refreshToken, tokens.refreshToken);

        const me = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(pair.accessToken) }),
        );
        assert.strictEqual(me.status, 200);

        const reused = yield* refresh(handler, tokens.refreshToken);
        assert.strictEqual(reused.status, 401);
        assert.propertyVal(reused.body, "_tag", "InvalidRefreshToken");
        assert.strictEqual((yield* refresh(handler, pair.refreshToken)).status, 401);
      }),
    ),
  );

  it.live("POST /v1/auth/refresh rejects a malformed body", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/auth/refresh", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ token: "lrt_x" }),
          }),
        );
        assert.strictEqual(response.status, 400);
      }),
    ),
  );

  it.live("POST /v1/auth/sign-out ends the session", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const unauthenticated = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/auth/sign-out", { method: "POST" }),
        );
        assert.strictEqual(unauthenticated.status, 401);

        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/auth/sign-out", {
            method: "POST",
            headers: bearer(tokens.accessToken),
          }),
        );
        assert.strictEqual(response.status, 204);
        assert.strictEqual((yield* refresh(handler, tokens.refreshToken)).status, 401);
      }),
    ),
  );
});

describe("POST /v1/auth/apple", () => {
  const appleSignIn = (handler: Handler, body: unknown) =>
    send(
      handler,
      new Request("https://api.lil.tech/v1/auth/apple", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      }),
    );
  const device = { app: "health-mac", platform: "macos" };

  it.live("signs in with an Apple identity token", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const nonce = crypto.randomUUID();
        const identityToken = yield* appleIdentityToken({ sub: "000123.http.0001", nonce });
        const response = yield* appleSignIn(handler, {
          identityToken,
          nonce,
          fullName: { givenName: "Ada", familyName: null },
          device,
        });
        assert.strictEqual(response.status, 200);
        const { accessToken } = response.body as { accessToken: string };
        const me = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(accessToken) }),
        );
        assert.deepInclude(me.body, {
          displayName: "Ada",
          identities: [{ provider: "apple", email: "x7y2@privaterelay.appleid.com" }],
        });
      }),
    ),
  );

  it.live("rejects a token that doesn't verify", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const response = yield* appleSignIn(handler, { identityToken: "nope", nonce: "n", device });
        assert.strictEqual(response.status, 401);
        assert.propertyVal(response.body, "_tag", "InvalidIdentityToken");
        const malformed = yield* appleSignIn(handler, { identityToken: "nope", device });
        assert.strictEqual(malformed.status, 400);
      }),
    ),
  );
});

describe("POST /v1/auth/google", () => {
  it.live("signs in with a Google ID token", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const nonce = crypto.randomUUID();
        const idToken = yield* googleIdToken({ sub: "100000000000000000001", nonce });
        const response = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/auth/google", {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({
              idToken,
              nonce,
              device: { app: "health-mac", platform: "macos" },
            }),
          }),
        );
        assert.strictEqual(response.status, 200);
        const { accessToken } = response.body as { accessToken: string };
        const me = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/me", { headers: bearer(accessToken) }),
        );
        assert.deepInclude(me.body, {
          identities: [{ provider: "google", email: "ada@example.com" }],
        });
      }),
    ),
  );
});

describe("POST /v1/auth/dev", () => {
  const devSignIn = (handler: Handler, body: unknown = { displayName: "Dev" }) =>
    send(
      handler,
      new Request("https://api.lil.tech/v1/auth/dev", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      }),
    );

  for (const environment of ["preview", "local"] as const) {
    it.live(`signs in as a new synthetic user in ${environment}`, () =>
      withApi(
        (handler) =>
          Effect.gen(function* () {
            const response = yield* devSignIn(handler);
            assert.strictEqual(response.status, 200);
            const { accessToken } = response.body as { accessToken: string };
            const me = yield* send(
              handler,
              new Request("https://api.lil.tech/v1/me", { headers: bearer(accessToken) }),
            );
            assert.deepInclude(me.body, { displayName: "Dev", identities: [] });
            assert.strictEqual((yield* devSignIn(handler, { platform: "android" })).status, 400);
            // The body is optional, but must be JSON if there is one.
            const empty = yield* send(
              handler,
              new Request("https://api.lil.tech/v1/auth/dev", { method: "POST" }),
            );
            assert.strictEqual(empty.status, 200);
            const malformed = yield* send(
              handler,
              new Request("https://api.lil.tech/v1/auth/dev", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: "{displayName:",
              }),
            );
            assert.strictEqual(malformed.status, 400);
            assert.propertyVal(malformed.body, "_tag", "BadRequest");
          }),
        { environment, version: "1" },
      ),
    );
  }

  for (const environment of ["staging", "prod"] as const) {
    it.live(`doesn't exist in ${environment}`, () =>
      withApi(
        (handler) =>
          Effect.gen(function* () {
            assert.strictEqual((yield* devSignIn(handler)).status, 404);
          }),
        { environment, version: "1" },
      ),
    );
  }

  it.live("refuses once the stage has too many users", () =>
    withApi(
      (handler) =>
        Effect.gen(function* () {
          const users = yield* Users;
          yield* Effect.forEach(
            Array.from({ length: maxDevUsers }),
            () => users.create({ displayName: null }),
            { discard: true },
          );
          const response = yield* devSignIn(handler);
          assert.strictEqual(response.status, 429);
          assert.strictEqual(yield* users.count, maxDevUsers);
        }),
      { environment: "preview", version: "1" },
    ),
  );

  it("isn't in the OpenAPI spec", () => {
    assert.notProperty(makeOpenApiSpec().paths, "/v1/auth/dev");
  });
});

describe("GET /v1/sync/changes", () => {
  const note = (id: string, title = "Note") => ({
    entity: "test_note",
    op: "upsert" as const,
    id,
    row: { title, pinned: false, score: null, tags: [], createdAt: 1 },
  });
  const pull = (handler: Handler, token: string, query = "") =>
    send(
      handler,
      new Request(`https://api.lil.tech/v1/sync/changes${query}`, { headers: bearer(token) }),
    );

  it.live("pages through the signed-in user's change log", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const store = (yield* UserStores).forUser(user.id);
        yield* store.applyMutations([note("n1"), note("n2"), note("n3")]);

        const first = yield* pull(handler, tokens.accessToken, "?limit=2");
        assert.strictEqual(first.status, 200);
        assert.deepInclude(first.body, { epoch: 1, next: 2, head: 3, hasMore: true });
        const changes = (first.body as { changes: Array<Record<string, unknown>> }).changes;
        assert.deepStrictEqual(
          changes.map((change) => [change["seq"], change["id"], change["op"]]),
          [
            [1, "n1", "upsert"],
            [2, "n2", "upsert"],
          ],
        );
        assert.deepStrictEqual(changes[0]?.["row"], { id: "n1", ...note("n1").row });

        const rest = yield* pull(handler, tokens.accessToken, "?after=2&limit=2");
        assert.deepInclude(rest.body, { next: 3, head: 3, hasMore: false });

        // A cursor at the head gets an empty page.
        const atHead = yield* pull(handler, tokens.accessToken, "?after=3");
        assert.deepStrictEqual(atHead.body, {
          epoch: 1,
          changes: [],
          next: 3,
          head: 3,
          hasMore: false,
        });
      }),
    ),
  );

  it.live("returns an empty log for a new user", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const response = yield* pull(handler, tokens.accessToken);
        assert.deepStrictEqual(response, {
          status: 200,
          body: { epoch: 1, changes: [], next: 0, head: 0, hasMore: false },
        });
      }),
    ),
  );

  it.live("answers 410 for a cursor older than the compaction horizon", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const store = (yield* UserStores).forUser(user.id);
        yield* store.applyMutations([note("n1"), note("n2")]);
        // Compaction deleted the first change.
        const sql = (yield* TestStores).sqlFor(user.id);
        sql?.exec("DELETE FROM changes WHERE seq <= 1");
        sql?.exec("INSERT INTO meta (key, value) VALUES ('horizon', 1)");
        const response = yield* pull(handler, tokens.accessToken, "?after=0");
        assert.strictEqual(response.status, 410);
        assert.deepInclude(response.body, { _tag: "ChangesCompacted", reason: "compacted" });
        assert.strictEqual((yield* pull(handler, tokens.accessToken, "?after=1")).status, 200);
      }),
    ),
  );

  it.live("never returns another user's changes", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const ada = yield* signIn;
        const bob = yield* signIn;
        yield* (yield* UserStores).forUser(ada.user.id).applyMutations([note("ada")]);
        const response = yield* pull(handler, bob.tokens.accessToken);
        assert.deepInclude(response.body, { changes: [], head: 0 });
      }),
    ),
  );

  it.live("requires a session and a valid cursor and limit", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const unauthenticated = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/sync/changes"),
        );
        assert.strictEqual(unauthenticated.status, 401);
        for (const query of ["?after=-1", "?after=x", "?limit=0", "?limit=5001", "?limit=1.5"]) {
          assert.strictEqual((yield* pull(handler, tokens.accessToken, query)).status, 400, query);
        }
        assert.strictEqual((yield* pull(handler, tokens.accessToken, "?limit=5000")).status, 200);
      }),
    ),
  );
});

describe("snapshot downloads", () => {
  const note = (id: string) => ({
    entity: "test_note",
    op: "upsert" as const,
    id,
    row: { title: `Note ${id}`, pinned: false, score: null, tags: [], createdAt: 1 },
  });
  const tinyParts = { ...snapshotPolicy, minChanges: 1, partRecords: 2, pageRows: 2 };
  const get = (handler: Handler, path: string, token?: string) =>
    send(
      handler,
      new Request(
        `https://api.lil.tech${path}`,
        token === undefined ? {} : { headers: bearer(token) },
      ),
    );
  /** Writes a snapshot of the user's store, as its alarm would. */
  const writeSnapshot = (userId: UserId) =>
    Effect.gen(function* () {
      const testStores = yield* TestStores;
      const sql = testStores.sqlFor(userId);
      if (sql === undefined) return assert.fail("no store");
      for (let step = 0; step < 100; step++) {
        const now = yield* Clock.currentTimeMillis;
        const result = yield* writeSnapshotStep(
          sql,
          [...entities, testNote],
          testStores.snapshotFiles,
          now,
          tinyParts,
        );
        if (result === "finished") return;
      }
    });

  it.live("returns no snapshot for a new user", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        const response = yield* get(handler, "/v1/sync/snapshot", tokens.accessToken);
        assert.deepStrictEqual(response, { status: 200, body: { epoch: 1 } });
      }),
    ),
  );

  it.live("serves the latest snapshot with part URLs that download it", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        yield* (yield* UserStores).forUser(user.id).applyMutations(["a", "b", "c"].map(note));
        yield* writeSnapshot(user.id);

        const latest = yield* get(handler, "/v1/sync/snapshot", tokens.accessToken);
        const { snapshot } = latest.body as {
          snapshot: {
            id: string;
            seq: number;
            entities: Array<{
              entity: string;
              parts: Array<{ url: string; sha256: string; records: number }>;
            }>;
          };
        };
        assert.strictEqual(snapshot.seq, 3);
        const parts =
          snapshot.entities.find((entity) => entity.entity === "test_note")?.parts ?? [];
        assert.lengthOf(parts, 2);

        const records: Array<unknown> = [];
        for (const part of parts) {
          assert.match(part.url, /^https:\/\/api\.lil\.tech\/v1\/sync\/parts\?token=/);
          // No Authorization header: the URL is the authorization.
          const response = yield* Effect.promise(() => handler(new Request(part.url)));
          assert.strictEqual(response.status, 200);
          assert.strictEqual(response.headers.get("content-type"), "application/gzip");
          const bytes = new Uint8Array(yield* Effect.promise(() => response.arrayBuffer()));
          const digest = yield* Effect.promise(() => crypto.subtle.digest("SHA-256", bytes));
          assert.strictEqual(Buffer.from(digest).toString("hex"), part.sha256);
          records.push(
            ...gunzipSync(bytes)
              .toString()
              .trim()
              .split("\n")
              .map((line) => JSON.parse(line)),
          );
        }
        assert.deepStrictEqual(
          records.map((record) => (record as { id: string }).id),
          ["a", "b", "c"],
        );

        // The same snapshot by ID, with fresh URLs.
        const byId = yield* get(handler, `/v1/sync/snapshots/${snapshot.id}`, tokens.accessToken);
        assert.strictEqual(byId.status, 200);
        assert.propertyVal(byId.body, "id", snapshot.id);
      }),
    ),
  );

  it.live("refuses part URLs that are tampered with or expired", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user } = yield* signIn;
        yield* (yield* UserStores).forUser(user.id).applyMutations([note("a")]);
        yield* writeSnapshot(user.id);
        const snapshot = yield* (yield* UserStores).forUser(user.id).latestSnapshot();
        const key =
          snapshot?.entities.find((entity) => entity.entity === "test_note")?.parts[0]?.key ?? "";

        const partUrls = yield* PartUrls.pipe(Effect.provide(PartUrls.layer));
        const token = yield* partUrls.sign(key);
        const fetchPart = (token: string) =>
          Effect.promise(() =>
            handler(new Request(`https://api.lil.tech/v1/sync/parts?token=${token}`)),
          );
        assert.strictEqual((yield* fetchPart(token)).status, 200);
        assert.strictEqual((yield* fetchPart(`${token}x`)).status, 401);
        // Signed under a test clock at 1970, so it expired long ago.
        const expired = yield* partUrls.sign(key).pipe(Effect.provide(TestClock.layer()));
        assert.strictEqual((yield* fetchPart(expired)).status, 401);
        // An access token isn't a part URL.
        assert.strictEqual((yield* fetchPart((yield* signIn).tokens.accessToken)).status, 401);
      }),
    ),
  );

  it.live("answers 410 for a snapshot that's gone or someone else's", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const ada = yield* signIn;
        const bob = yield* signIn;
        yield* (yield* UserStores).forUser(ada.user.id).applyMutations([note("a")]);
        yield* writeSnapshot(ada.user.id);
        const snapshot = yield* (yield* UserStores).forUser(ada.user.id).latestSnapshot();

        const theirs = yield* get(
          handler,
          `/v1/sync/snapshots/${snapshot?.id}`,
          bob.tokens.accessToken,
        );
        assert.strictEqual(theirs.status, 410);
        assert.propertyVal(theirs.body, "_tag", "SnapshotGone");
        const unknown = yield* get(handler, "/v1/sync/snapshots/snp_nope", ada.tokens.accessToken);
        assert.strictEqual(unknown.status, 410);
        assert.strictEqual((yield* get(handler, "/v1/sync/snapshot")).status, 401);
      }),
    ),
  );
});

describe("/v1/health/batches", () => {
  const batchId = "00000000-0000-4000-8000-0000000000b1";
  const lines = [
    {
      entity: "health_sample",
      op: "upsert",
      id: "6f1c2a40-0000-4000-8000-000000000001",
      row: {
        type: "HKQuantityTypeIdentifierStepCount",
        startDate: 1760400000000,
        endDate: 1760400060000,
        value: 12,
        unit: "count",
        sourceName: "Test iPhone",
        sourceBundleId: "com.apple.health.00000000",
      },
    },
  ];
  const upload = (handler: Handler, token: string, id: string, body: Uint8Array) =>
    send(
      handler,
      new Request(`https://api.lil.tech/v1/health/batches/${id}`, {
        method: "PUT",
        headers: { ...bearer(token), "content-type": "application/gzip" },
        body: body as Uint8Array<ArrayBuffer>,
      }),
    );
  const status = (handler: Handler, token: string, id: string) =>
    send(
      handler,
      new Request(`https://api.lil.tech/v1/health/batches/${id}`, { headers: bearer(token) }),
    );

  it.live("queues an upload once, and reports its status until it's applied", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { user, tokens } = yield* signIn;
        const outbox = yield* TestHealthOutbox;

        const first = yield* upload(handler, tokens.accessToken, batchId, batchFile(lines));
        assert.strictEqual(first.status, 202);
        assert.deepInclude(first.body, { id: batchId, status: "queued" });
        assert.deepStrictEqual(outbox.sent, [{ userId: user.id, batchId }]);
        assert.isTrue(outbox.files.has(`health-batches/${user.id}/${batchId}.ndjson.gz`));

        // A retried upload is answered with the batch's status and isn't queued again.
        const retried = yield* upload(handler, tokens.accessToken, batchId, batchFile(lines));
        assert.deepInclude(retried.body, { id: batchId, status: "queued" });
        assert.lengthOf(outbox.sent, 1);

        // The queue consumer applies it.
        const [message] = outbox.sent;
        if (message !== undefined) yield* ingestHealthBatch(message);
        const applied = yield* status(handler, tokens.accessToken, batchId);
        assert.strictEqual(applied.status, 200);
        assert.deepInclude(applied.body, { status: "applied", lines: 1, applied: 1, rejected: 0 });
        const changes = yield* send(
          handler,
          new Request("https://api.lil.tech/v1/sync/changes", {
            headers: bearer(tokens.accessToken),
          }),
        );
        assert.deepInclude(changes.body, { head: 1 });
      }),
    ),
  );

  it.live("keeps each user's batches to themselves", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const ada = yield* signIn;
        const bob = yield* signIn;
        yield* upload(handler, ada.tokens.accessToken, batchId, batchFile(lines));
        const response = yield* status(handler, bob.tokens.accessToken, batchId);
        assert.strictEqual(response.status, 404);
        assert.propertyVal(response.body, "_tag", "HealthBatchNotFound");
      }),
    ),
  );

  it.live("rejects invalid IDs, oversized files and missing sessions", () =>
    withApi((handler) =>
      Effect.gen(function* () {
        const { tokens } = yield* signIn;
        for (const id of ["not-a-uuid", batchId.toUpperCase()]) {
          assert.strictEqual(
            (yield* upload(handler, tokens.accessToken, id, batchFile(lines))).status,
            400,
          );
        }
        const tooLarge = yield* upload(
          handler,
          tokens.accessToken,
          batchId,
          new Uint8Array(16 * 1024 * 1024 + 1),
        );
        assert.strictEqual(tooLarge.status, 413);
        assert.lengthOf((yield* TestHealthOutbox).sent, 0);
        const anonymous = yield* send(
          handler,
          new Request(`https://api.lil.tech/v1/health/batches/${batchId}`, { method: "PUT" }),
        );
        assert.strictEqual(anonymous.status, 401);
      }),
    ),
  );
});

describe("Deployment.config", () => {
  const withEnv = (env: Record<string, string>) =>
    Effect.provide(ConfigProvider.layer(ConfigProvider.fromEnvRecord(env)));

  it.effect("reads LIL_ENVIRONMENT and LIL_VERSION", () =>
    Effect.gen(function* () {
      const config = yield* Deployment.config.pipe(
        withEnv({ LIL_ENVIRONMENT: "prod", LIL_VERSION: "45aa829" }),
      );
      assert.deepStrictEqual(config, { environment: "prod", version: "45aa829" });
    }),
  );

  it.effect("rejects an unknown environment", () =>
    Effect.gen(function* () {
      const error = yield* Deployment.config.pipe(
        withEnv({ LIL_ENVIRONMENT: "qa", LIL_VERSION: "45aa829" }),
        Effect.flip,
      );
      assert.include(String(error), "LIL_ENVIRONMENT");
    }),
  );

  it.effect("requires a version", () =>
    Effect.gen(function* () {
      const missing = yield* Deployment.config.pipe(
        withEnv({ LIL_ENVIRONMENT: "prod" }),
        Effect.flip,
      );
      assert.include(String(missing), "LIL_VERSION");
      const empty = yield* Deployment.config.pipe(
        withEnv({ LIL_ENVIRONMENT: "prod", LIL_VERSION: "" }),
        Effect.flip,
      );
      assert.include(String(empty), "LIL_VERSION");
    }),
  );
});

describe("environmentForStage", () => {
  it("maps stages to environments", () => {
    assert.strictEqual(environmentForStage("prod"), "prod");
    assert.strictEqual(environmentForStage("staging"), "staging");
    assert.strictEqual(environmentForStage("pr-12"), "preview");
    assert.strictEqual(environmentForStage("live_tuftlord"), "preview");
    assert.strictEqual(environmentForStage("dev_tuftlord"), "local");
  });
});

describe("apiWorkerProps", () => {
  const withEnv = (env: Record<string, string>) =>
    Effect.provide(ConfigProvider.layer(ConfigProvider.fromEnvRecord(env)));
  const apiWorkerProps = makeApiWorkerProps(Effect.succeed(Redacted.make("session-key")));

  it.effect("runs without a Stage, as it does inside the deployed Worker", () =>
    Effect.gen(function* () {
      const props = yield* apiWorkerProps;
      assert.isUndefined((props as { domain?: string }).domain);
    }),
  );

  it.effect("picks the custom domain for the stage at deploy time", () =>
    Effect.gen(function* () {
      const props = yield* apiWorkerProps.pipe(
        Effect.provideService(Alchemy.Stage, "staging"),
        withEnv({ LIL_ENVIRONMENT: "staging", LIL_VERSION: "45aa829" }),
      );
      assert.strictEqual((props as { domain?: string }).domain, "api.staging.lil.tech");
      assert.deepStrictEqual((props as { env?: object }).env, {
        LIL_SESSION_KEY: Redacted.make("session-key"),
      });
    }),
  );

  it.effect("refuses an environment that doesn't match the stage", () =>
    Effect.gen(function* () {
      const exit = yield* apiWorkerProps.pipe(
        Effect.provideService(Alchemy.Stage, "prod"),
        withEnv({ LIL_ENVIRONMENT: "staging", LIL_VERSION: "45aa829" }),
        Effect.exit,
      );
      assert.isTrue(Exit.isFailure(exit));
    }),
  );
});

describe("makeOpenApiSpec", () => {
  it("matches the committed openapi.json (run scripts/format to regenerate)", () => {
    assert.strictEqual(committedSpec, `${JSON.stringify(makeOpenApiSpec(), null, 2)}\n`);
  });

  it("lets clients tolerate fields added later", () => {
    assert.notInclude(JSON.stringify(makeOpenApiSpec()), '"additionalProperties":false');
  });

  it("names schemas without namespaces or the Encoded suffix", () => {
    const names = Object.keys(makeOpenApiSpec().components.schemas);
    assert.includeMembers(names, ["Status", "TokenPair", "Me"]);
    for (const name of names) assert.notMatch(name, /\/|Encoded$/);
  });

  it("writes nullable properties as type arrays, which the Swift generator makes optional", () => {
    const spec = makeOpenApiSpec();
    assert.notInclude(JSON.stringify(spec), '{"type":"null"}');
    assert.deepStrictEqual(
      (spec.components.schemas["Me"] as { properties: Record<string, unknown> }).properties[
        "displayName"
      ],
      {
        type: ["string", "null"],
      },
    );

    class Pair extends Schema.Class<Pair>("lil/Pair")({ a: Schema.String }) {}
    const api = HttpApi.make("nullable").add(
      HttpApiGroup.make("g").add(
        HttpApiEndpoint.get("a", "/a", { success: Schema.Struct({ pair: Schema.NullOr(Pair) }) }),
      ),
    );
    assert.throws(() => makeOpenApiSpec(api), /Unsupported nullable schema/);

    const enums = HttpApi.make("enum").add(
      HttpApiGroup.make("g").add(
        HttpApiEndpoint.get("a", "/a", {
          success: Schema.Struct({
            kind: Schema.NullOr(Schema.Literals(["a", "b"])).annotate({ description: "Kind" }),
          }),
        }),
      ),
    );
    const kind = JSON.stringify(makeOpenApiSpec(enums).paths["/a"]?.get?.responses);
    assert.include(kind, '"type":["string","null"]');
    assert.include(kind, '"enum":["a","b",null]');
    assert.include(kind, '"description":"Kind"');
  });

  it("documents query parameters by their decoded schemas", () => {
    const spec = makeOpenApiSpec();
    assert.deepStrictEqual(
      spec.paths["/v1/sync/changes"]?.get?.parameters?.map((parameter) => [
        parameter.name,
        parameter.schema,
      ]),
      [
        ["after", { type: "integer", minimum: 0, maximum: 9007199254740991, default: 0 }],
        ["limit", { type: "integer", minimum: 1, maximum: 5000, default: 1000 }],
      ],
    );
    // Every endpoint with query parameters needs `documentQuery`.
    for (const [path, operations] of Object.entries(spec.paths)) {
      for (const operation of Object.values(operations ?? {})) {
        for (const parameter of (operation as { parameters?: Array<{ schema: object }> })
          .parameters ?? []) {
          assert.notProperty(parameter.schema, "pattern", path);
        }
      }
    }
  });

  it("names grouped operations in camel case", () => {
    const spec = makeOpenApiSpec();
    assert.strictEqual(spec.paths["/v1/auth/refresh"]?.post?.operationId, "authRefresh");
    assert.strictEqual(spec.paths["/v1/me"]?.get?.operationId, "me");
  });

  it("refuses two schemas that would get the same name", () => {
    class A extends Schema.Class<A>("lil/a/Thing")({ a: Schema.String }) {}
    class B extends Schema.Class<B>("lil/b/Thing")({ b: Schema.String }) {}
    const api = HttpApi.make("collide").add(
      HttpApiGroup.make("g")
        .add(HttpApiEndpoint.get("a", "/a", { success: A }))
        .add(HttpApiEndpoint.get("b", "/b", { success: B })),
    );
    assert.throws(() => makeOpenApiSpec(api), /used by both/);
  });
});
