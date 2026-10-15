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

  it("ignores the order of recipients and filters", () => {
    const reordered = existing(
      {
        ...first,
        mechanisms: { email: first.mechanisms.email.toReversed() },
        filters: Object.fromEntries(Object.entries(first.filters).toReversed()),
      },
      "a",
    );
    assert.deepStrictEqual(planChanges([first], [reordered]), []);
  });

  it("names every policy uniquely, so matching by name is safe", () => {
    assert.strictEqual(new Set(policies.map((policy) => policy.name)).size, policies.length);
  });
});
