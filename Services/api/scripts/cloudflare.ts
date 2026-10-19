// Cloudflare API credentials for scripts run by hand: CLOUDFLARE_API_TOKEN and
// CLOUDFLARE_ACCOUNT_ID, or else your Alchemy profile's Cloudflare OAuth login
// (`npx alchemy profile show` refreshes it).
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const credentials = () => {
  const token = process.env["CLOUDFLARE_API_TOKEN"];
  const account = process.env["CLOUDFLARE_ACCOUNT_ID"];
  if (token !== undefined && account !== undefined) return { token, account };
  const profile = process.env["ALCHEMY_PROFILE"] ?? "default";
  const path = join(homedir(), ".alchemy", "profiles", profile, "cloudflare.json");
  let stored: { values?: { access?: string; accountId?: string; expires?: number } };
  try {
    stored = JSON.parse(readFileSync(path, "utf8")) as typeof stored;
  } catch {
    throw new Error(`Set CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID, or log in: no ${path}`);
  }
  const { access, accountId, expires } = stored.values ?? {};
  if (access === undefined || accountId === undefined || expires === undefined) {
    throw new Error(`Alchemy profile "${profile}" isn't an OAuth login; set CLOUDFLARE_API_TOKEN`);
  }
  if (expires < Date.now()) {
    throw new Error("The Alchemy login expired; run `npx alchemy profile show` to refresh it");
  }
  return { token: access, account: accountId };
};
