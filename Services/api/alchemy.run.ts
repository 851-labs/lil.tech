import { fileURLToPath } from "node:url";
import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Effect } from "effect";
import { CoreDatabase } from "./src/core/CoreDatabase.ts";
import { stageDomains } from "./src/Deployment.ts";
import ApiWorker from "./src/Worker.ts";

export default Alchemy.Stack(
  "lil-api",
  { providers: Cloudflare.providers(), state: Cloudflare.state() },
  Effect.gen(function* () {
    const core = yield* CoreDatabase;
    const worker = yield* ApiWorker;
    // The website (`Services/site`): static pages, such as the privacy policy, served by
    // Cloudflare's asset layer with no Worker code.
    const domain = stageDomains[yield* Alchemy.Stage]?.site;
    const site = yield* Cloudflare.Worker("Site", {
      assets: {
        directory: fileURLToPath(new URL("../site/public", import.meta.url)),
        htmlHandling: "drop-trailing-slash",
        notFoundHandling: "404-page",
      },
      ...(domain === undefined ? {} : { domain }),
    });
    return { url: worker.url, coreDatabase: core.databaseName, siteUrl: site.url };
  }),
);
