import { readFileSync } from "node:fs";
import { assert, describe, it } from "@effect/vitest";
import * as Alchemy from "alchemy";
import { ConfigProvider, Effect, Exit, Layer, Redacted, Schema } from "effect";
import { HttpRouter } from "effect/http";
import { TestClock } from "effect/testing";
import { HttpApi, HttpApiEndpoint, HttpApiGroup } from "effect/http-api";
import { Deployment, environmentForStage } from "../src/Deployment.ts";
import { Auth } from "../src/auth/Auth.ts";
import { AccessTokens } from "../src/auth/Tokens.ts";
import { Devices } from "../src/core/Devices.ts";
import { Identities } from "../src/core/Identities.ts";
import { Users } from "../src/core/Users.ts";
import { UserStores } from "../src/store/UserStores.ts";
import { WorkerHttpLayer } from "../src/Http.ts";
import { makeOpenApiSpec } from "../src/OpenApiSpec.ts";
import { makeApiWorkerProps } from "../src/Worker.ts";
import { TestAuth } from "./auth/TestAuth.ts";
import { TestStores, TestUserStores } from "./store/TestUserStores.ts";

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
    return yield* use((request) => handler(request)).pipe(Effect.provide(context));
  }).pipe(Effect.scoped);

const TestServices = Layer.mergeAll(TestAuth, TestUserStores);

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

  it("documents integer query parameters as integers", () => {
    const parameters = makeOpenApiSpec().paths["/v1/sync/changes"]?.get?.parameters;
    assert.deepStrictEqual(
      parameters?.map((parameter) => [parameter.name, parameter.schema]),
      [
        ["after", { type: "integer", minimum: 0 }],
        ["limit", { type: "integer", minimum: 1, maximum: 5000 }],
      ],
    );
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
