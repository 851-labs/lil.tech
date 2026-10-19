// Sets up the account's Cloudflare billing and usage notifications (`docs/DECISIONS.md`). They're
// account-wide, not per stage, so they aren't part of the Alchemy stack: run this by hand after
// changing `policies`, from `Services/api`: `node scripts/notifications.ts` (not `vp run`, whose
// tasks are cached and don't see your environment). It creates missing policies and updates
// changed ones, matched by name, and leaves every other policy alone. `--dry-run` only prints
// what it would do.
//
// Credentials: CLOUDFLARE_API_TOKEN (with Notifications: Edit) and CLOUDFLARE_ACCOUNT_ID, or else
// your Alchemy profile's Cloudflare OAuth login (`npx alchemy profile show` refreshes it), if
// it was granted the notifications scopes; "Basic Scopes" doesn't include them.
import { credentials } from "./cloudflare.ts";

/** A notification policy as the Cloudflare API takes it. */
export interface Policy {
  readonly name: string;
  readonly alert_type: string;
  readonly description: string;
  readonly enabled: boolean;
  readonly mechanisms: { readonly email: ReadonlyArray<{ readonly id: string }> };
  readonly filters: Readonly<Record<string, ReadonlyArray<string>>>;
}

const email = [{ id: "alexandru@851.sh" }];

/** When total spend this billing period reaches `dollars`. */
const spend = (dollars: number): Policy => ({
  name: `lil: spend reached $${dollars}`,
  alert_type: "billing_budget_alert",
  description: `This month's Cloudflare spend reached $${dollars}.`,
  enabled: true,
  mechanisms: { email },
  filters: { total_spend_dollars: [String(dollars)] },
});

/** When a product's usage this billing period reaches `limit`. */
const usage = (product: string, limit: number, what: string): Policy => ({
  name: `lil: ${what}`,
  alert_type: "billing_usage_alert",
  description: `This month's ${what} passed ${limit.toLocaleString("en-US")}.`,
  enabled: true,
  mechanisms: { email },
  filters: { product: [product], limit: [String(limit)] },
});

// Usage thresholds are the monthly amounts included for free (by Workers Paid for Workers,
// Durable Objects and D1; by R2's free tier for R2), so each alert means we've started paying for
// that product. Queues and CPU time have no usage alerts; spend covers them.
export const policies: ReadonlyArray<Policy> = [
  spend(25),
  spend(100),
  usage("worker_requests", 10_000_000, "Workers requests"),
  usage("worker_durable_objects_requests", 1_000_000, "Durable Objects requests"),
  usage("d1_rows_read", 25_000_000_000, "D1 rows read"),
  usage("d1_rows_written", 50_000_000, "D1 rows written"),
  usage("r2_class_a_operations", 1_000_000, "R2 class A operations"),
  usage("r2_class_b_operations", 10_000_000, "R2 class B operations"),
];

/** A policy that already exists, as the API lists it. */
export interface ExistingPolicy extends Policy {
  readonly id: string;
}

export type Change =
  | { readonly kind: "create"; readonly policy: Policy }
  | { readonly kind: "update"; readonly id: string; readonly policy: Policy };

// Fields the API may leave out (e.g. a policy with only webhooks) count as empty.
const comparable = (policy: Policy) =>
  JSON.stringify([
    policy.alert_type,
    policy.description,
    policy.enabled,
    (policy.mechanisms?.email ?? []).map((mechanism) => mechanism.id).toSorted(),
    Object.entries(policy.filters ?? {})
      .map(([key, values]) => [key, values.toSorted()] as const)
      .toSorted(([a], [b]) => a.localeCompare(b)),
  ]);

/** What brings `existing` in line with `desired`, matching policies by name. */
export const planChanges = (
  desired: ReadonlyArray<Policy>,
  existing: ReadonlyArray<ExistingPolicy>,
): ReadonlyArray<Change> =>
  desired.flatMap((policy): Array<Change> => {
    const match = existing.find((candidate) => candidate.name === policy.name);
    if (match === undefined) return [{ kind: "create", policy }];
    return comparable(match) === comparable(policy)
      ? []
      : [{ kind: "update", id: match.id, policy }];
  });

const main = async () => {
  const { token, account } = credentials();
  const api = async <A>(path: string, init: { method?: string; body?: unknown } = {}) => {
    const response = await fetch(
      `https://api.cloudflare.com/client/v4/accounts/${account}/alerting/v3${path}`,
      {
        method: init.method ?? "GET",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
      },
    );
    const text = await response.text();
    let json: { success?: boolean; result?: A; errors?: unknown } | undefined;
    try {
      json = JSON.parse(text) as typeof json;
    } catch {
      json = undefined;
    }
    if (!response.ok || json?.success !== true) {
      throw new Error(
        `${init.method ?? "GET"} ${path} answered ${response.status}: ${
          json === undefined ? text.slice(0, 200) : JSON.stringify(json.errors)
        }`,
      );
    }
    return json.result as A;
  };

  const changes = planChanges(policies, await api<Array<ExistingPolicy>>("/policies"));
  if (changes.length === 0) console.log("Every notification policy is up to date.");
  for (const change of changes) {
    console.log(`${change.kind} ${change.policy.name}`);
    if (process.argv.includes("--dry-run")) continue;
    if (change.kind === "create") await api("/policies", { method: "POST", body: change.policy });
    else await api(`/policies/${change.id}`, { method: "PUT", body: change.policy });
  }
};

if (import.meta.main) await main();
