import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Effect } from "effect";
import { ApiWorker } from "./src/Worker.ts";

export default Alchemy.Stack(
  "lil-api",
  { providers: Cloudflare.providers(), state: Cloudflare.state() },
  Effect.gen(function* () {
    const worker = yield* ApiWorker;
    return { url: worker.url };
  }),
);
