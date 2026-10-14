import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Effect } from "effect";
import { CoreDatabase } from "./src/core/CoreDatabase.ts";
import ApiWorker from "./src/Worker.ts";

export default Alchemy.Stack(
  "lil-api",
  { providers: Cloudflare.providers(), state: Cloudflare.state() },
  Effect.gen(function* () {
    const core = yield* CoreDatabase;
    const worker = yield* ApiWorker;
    return { url: worker.url, coreDatabase: core.databaseName };
  }),
);
