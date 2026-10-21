import { HttpApi, HttpApiEndpoint, HttpApiGroup, OpenApi } from "effect/http-api";
import { AuthApi, MeApi } from "./auth/AuthApi.ts";
import { HealthApi } from "./health/HealthApi.ts";
import { AgentsApi } from "./oauth/AgentsApi.ts";
import { Status } from "./Status.ts";
import { SyncApi } from "./sync/SyncApi.ts";

// The API definition is shared by the server and generated clients, so it holds no server code.

export class SystemApi extends HttpApiGroup.make("system", { topLevel: true }).add(
  HttpApiEndpoint.get("status", "/v1/status", { success: Status }),
) {}

export class Api extends HttpApi.make("lil-api")
  .add(SystemApi)
  .add(AuthApi)
  .add(MeApi)
  .add(SyncApi)
  .add(HealthApi)
  .add(AgentsApi)
  .annotateMerge(OpenApi.annotations({ title: "lil API" })) {}
