import { fileURLToPath } from "node:url";
import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Effect } from "effect";

/**
 * The site's custom domain per stage. Other stages (PR previews, `pr-<number>`, and personal
 * stages, `live_<user>`) are served on workers.dev.
 */
const stageDomains: Partial<Record<string, string>> = {
  prod: "lil.tech",
  staging: "staging.lil.tech",
};

/**
 * lil.tech: the static pages in `public`, served by Cloudflare's asset layer with no Worker code.
 * Its state is in Cloudflare (the account's `alchemy-state-store` Worker), so every machine and CI
 * share it.
 */
export default Alchemy.Stack(
  "lil-site",
  { providers: Cloudflare.providers(), state: Cloudflare.state() },
  Effect.gen(function* () {
    const stage = yield* Alchemy.Stage;
    const domain = stageDomains[stage];
    const site = yield* Cloudflare.Worker("Site", {
      assets: {
        directory: fileURLToPath(new URL("./public", import.meta.url)),
        htmlHandling: "drop-trailing-slash",
        notFoundHandling: "404-page",
      },
      ...(domain === undefined ? {} : { domain }),
    });
    return { url: site.url };
  }),
);
