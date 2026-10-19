import { describe, expect, it } from "vite-plus/test";
import { filtersFrom, toggle, validateSearch, withChange } from "../src/Filters.ts";

describe("filters", () => {
  const all = ["light", "dark"] as const;

  it("starts with everything on, and turns values off and on", () => {
    expect(toggle(all, [], "light")).toBe("dark");
    expect(toggle(all, ["dark"], "light")).toBeUndefined();
    const apps = ["a", "b", "c"];
    expect(toggle(apps, ["a"], "c")).toBe("a,c");
  });

  it("doesn't turn the last value off", () => {
    expect(toggle(all, ["dark"], "dark")).toBe("dark");
  });

  it("reads the URL's lists, ignoring unknown values", () => {
    const search = validateSearch({ schemes: "dark,sepia", platforms: "", apps: 3, tile: "x" });
    expect(search).toEqual({ schemes: "dark,sepia", tile: "x" });
    expect(filtersFrom(search, ["health-mac"])).toEqual({
      apps: [],
      platforms: [],
      schemes: ["dark"],
    });
    // An app the commit doesn't have, e.g. from a link to another commit.
    expect(filtersFrom({ apps: "messages-mac,health-mac" }, ["health-mac"]).apps).toEqual([
      "health-mac",
    ]);
  });

  it("clears parameters set to undefined", () => {
    expect(withChange({ ref: "main", tile: "x" }, { tile: undefined, schemes: "dark" })).toEqual({
      ref: "main",
      schemes: "dark",
    });
  });
});
