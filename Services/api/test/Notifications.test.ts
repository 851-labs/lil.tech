import { assert, describe, it } from "@effect/vitest";
import { type ExistingPolicy, planChanges, policies } from "../scripts/notifications.ts";

describe("notification policies", () => {
  const [first, second] = policies;
  if (first === undefined || second === undefined) throw new Error("policies");
  const existing = (policy: typeof first, id: string): ExistingPolicy => ({ ...policy, id });

  it("creates missing policies, updates changed ones, and leaves the rest alone", () => {
    const changed = existing({ ...second, filters: { total_spend_dollars: ["1"] } }, "b");
    const unrelated = existing({ ...first, name: "#eng-alerts" }, "c");
    const changes = planChanges([first, second], [existing(first, "a"), changed, unrelated]);
    assert.deepStrictEqual(changes, [{ kind: "update", id: "b", policy: second }]);
    assert.deepStrictEqual(planChanges([first], []), [{ kind: "create", policy: first }]);
  });

  it("ignores the order of recipients, filters and filter values", () => {
    const usage = policies.find((policy) => Object.keys(policy.filters).length > 1);
    if (usage === undefined) return assert.fail("a policy with several filters");
    const policy = {
      ...usage,
      mechanisms: { email: [{ id: "a@example.com" }, { id: "b@example.com" }] },
      filters: { ...usage.filters, extra: ["1", "2"] },
    };
    const reordered = existing(
      {
        ...policy,
        mechanisms: { email: policy.mechanisms.email.toReversed() },
        filters: Object.fromEntries(
          Object.entries(policy.filters)
            .toReversed()
            .map(([key, values]) => [key, values.toReversed()]),
        ),
      },
      "a",
    );
    assert.deepStrictEqual(planChanges([policy], [reordered]), []);
  });

  it("updates a same-named policy the API returns without emails or filters", () => {
    const bare = { ...existing(first, "a"), mechanisms: {}, filters: undefined } as never;
    assert.deepStrictEqual(planChanges([first], [bare]), [
      { kind: "update", id: "a", policy: first },
    ]);
  });

  it("names every policy uniquely, so matching by name is safe", () => {
    assert.strictEqual(new Set(policies.map((policy) => policy.name)).size, policies.length);
  });
});
