import { HttpApi, HttpApiEndpoint, HttpApiGroup, OpenApi } from "effect/http-api";
import { Status } from "./Status.ts";

// The API definition is shared by the server and generated clients, so it holds no server code.

export class SystemApi extends HttpApiGroup.make("system", { topLevel: true }).add(
  HttpApiEndpoint.get("status", "/v1/status", { success: Status }),
) {}

export class Api extends HttpApi.make("lil-api")
  .add(SystemApi)
  .annotateMerge(OpenApi.annotations({ title: "lil API" })) {}
