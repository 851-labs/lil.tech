import { fileURLToPath } from "node:url";
import * as Alchemy from "alchemy";
import * as Cloudflare from "alchemy/Cloudflare";
import { Effect } from "effect";
import { CoreDatabase } from "./src/core/CoreDatabase.ts";
import {
  DisposableBucket,
  pixelbookAssetsDomain,
  pixelbookBucketName,
  stageDomains,
} from "./src/Deployment.ts";
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
    const domains = stageDomains[stage];
    const domain = domains?.site;
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
      yield* DisposableBucket("Pixelbook", {
        name: pixelbookBucketName,
        domains: [{ name: pixelbookAssetsDomain }],
        // Each stage's Pixelbook, on its own domain, fetches the manifests.
        cors: [{ allowedMethods: ["GET", "HEAD"], allowedOrigins: ["*"], maxAgeSeconds: 86400 }],
      });
    }
    // Pixelbook (`Web/pixelbook`), a TanStack Start app that shows the snapshots in that bucket.
    // Its own ID: the bucket's is `Pixelbook`, and a repeated ID silently reuses that resource.
    const pixelbook = yield* Cloudflare.Website.Vite("PixelbookViewer", {
      rootDir: fileURLToPath(new URL("../../Web/pixelbook", import.meta.url)),
      ...(domains === undefined ? {} : { domain: domains.pixelbook }),
    });
    return {
      url: worker.url,
      coreDatabase: core.databaseName,
      siteUrl: site.url,
      pixelbookUrl: pixelbook.url,
    };
  }),
);
