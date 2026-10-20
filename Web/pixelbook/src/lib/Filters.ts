// The grid's filters and selection, kept in the URL so a view can be shared: comma-separated lists,
// where none means all.
import type { Filters } from "./Grid.ts";
import { platforms, type Platform, type Scheme, schemes } from "./Snapshots.ts";

export interface Search {
  /** A branch whose latest snapshots to show; `main` by default. */
  readonly ref?: string;
  /** A commit whose snapshots to show, instead of a branch's. */
  readonly commit?: string;
  readonly apps?: string;
  readonly platforms?: string;
  readonly schemes?: string;
  /** The tile shown full size (`tileId`). */
  readonly tile?: string;
  /** `flow` for the flowchart; the grid otherwise. */
  readonly mode?: string;
  /** A commit (or branch) to compare with, showing only what changed since it. */
  readonly base?: string;
}

export type Mode = "grid" | "flow";

export const modeFrom = (search: Search): Mode => (search.mode === "flow" ? "flow" : "grid");

const text = (value: unknown) => (typeof value === "string" && value !== "" ? value : undefined);

/** Keeps the parameters Pixelbook knows, as strings. */
export const validateSearch = (search: Record<string, unknown>): Search => {
  const result: Record<string, string> = {};
  for (const name of [
    "ref",
    "commit",
    "apps",
    "platforms",
    "schemes",
    "tile",
    "mode",
    "base",
  ] as const) {
    const value = text(search[name]);
    if (value !== undefined) result[name] = value;
  }
  return result;
};

const list = (value: string | undefined) =>
  value === undefined ? [] : value.split(",").filter((item) => item !== "");

const known = <A extends string>(values: ReadonlyArray<A>, chosen: ReadonlyArray<string>) =>
  values.filter((value) => chosen.includes(value));

/** A change to the search: a parameter set to `undefined` is cleared. */
export type SearchChange = { [Name in keyof Search]?: Search[Name] | undefined };

/** `search` with `change`'s parameters, leaving out those it clears. */
export const withChange = (search: Search, change: SearchChange): Search =>
  Object.fromEntries(
    Object.entries({ ...search, ...change }).filter(([, value]) => value !== undefined),
  );

/** The filters in `search`, ignoring values that don't exist, such as an app this commit lacks. */
export const filtersFrom = (
  search: Pick<SearchChange, "apps" | "platforms" | "schemes">,
  apps: ReadonlyArray<string>,
): Filters => ({
  apps: known(apps, list(search.apps)),
  platforms: known<Platform>(platforms, list(search.platforms)),
  schemes: known<Scheme>(schemes, list(search.schemes)),
});

/**
 * Turns `value` on or off in a filter of `all` its values. Everything is on to start with; turning
 * the last value off does nothing, rather than showing nothing.
 */
export const toggle = <A extends string>(
  all: ReadonlyArray<A>,
  chosen: ReadonlyArray<A>,
  value: A,
): string | undefined => {
  const on = chosen.length === 0 ? all : chosen;
  const next = on.includes(value) ? on.filter((item) => item !== value) : [...on, value];
  if (next.length === 0) return chosen.length === 0 ? undefined : chosen.join(",");
  // Everything on is the default: no parameter.
  if (all.every((item) => next.includes(item))) return undefined;
  return all.filter((item) => next.includes(item)).join(",");
};
