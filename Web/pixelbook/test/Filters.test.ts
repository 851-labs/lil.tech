import { describe, expect, it } from "vite-plus/test";
import { filtersFrom, toggle, validateSearch } from "../src/Filters.ts";

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
    expect(filtersFrom(search)).toEqual({ apps: [], platforms: [], schemes: ["dark"] });
  });
});
