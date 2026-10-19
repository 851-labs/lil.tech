import { fileURLToPath } from "node:url";
import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Effect } from "effect";
import { CoreDatabase } from "./src/core/CoreDatabase.ts";
import { pixelbookAssetsDomain, pixelbookBucketName, stageDomains } from "./src/Deployment.ts";
import ApiWorker from "./src/Worker.ts";

export default Alchemy.Stack(
  "lil-api",
  { providers: Cloudflare.providers(), state: Cloudflare.state() },
  Effect.gen(function* () {
    const core = yield* CoreDatabase;
    const worker = yield* ApiWorker;
    // The website (`Web/site`): static pages, such as the privacy policy, served by
    // Cloudflare's asset layer with no Worker code.
    const stage = yield* Alchemy.Stage;
    const domain = stageDomains[stage]?.site;
    const site = yield* Cloudflare.Worker("Site", {
      assets: {
        directory: fileURLToPath(new URL("../../Web/site/public", import.meta.url)),
        htmlHandling: "drop-trailing-slash",
        notFoundHandling: "404-page",
      },
      ...(domain === undefined ? {} : { domain }),
    });
    // Pixelbook's snapshots (851-2696), which every stage's Pixelbook shows: so only prod has the
    // bucket, publicly readable at `pixelbookAssetsDomain`. `scripts/pixelbook publish` uploads.
    if (stage === "prod") {
      yield* Cloudflare.R2.Bucket("Pixelbook", {
        name: pixelbookBucketName,
        domains: [{ name: pixelbookAssetsDomain }],
        // Each stage's Pixelbook, on its own domain, fetches the manifests.
        cors: [{ allowedMethods: ["GET", "HEAD"], allowedOrigins: ["*"], maxAgeSeconds: 86400 }],
      });
    }
    return { url: worker.url, coreDatabase: core.databaseName, siteUrl: site.url };
  }),
);
