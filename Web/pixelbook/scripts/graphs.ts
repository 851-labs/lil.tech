// Checks Pixelbook's graph files (`graphs/*.json`) against the state catalogs in LilPackage's
// test targets: every screen and state a graph names must exist in its app, so renaming one can't
// quietly break a flowchart. Reads catalogs from their manifests, so it needs no render. Run by
// the pre-commit hook (lefthook.yml):
//   node Web/pixelbook/scripts/graphs.ts
import { existsSync } from "node:fs";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { type CatalogStates, type Graph, graphProblems, parseGraph } from "../src/lib/Graph.ts";

const root = fileURLToPath(new URL("../../..", import.meta.url));
export const graphsDirectory = fileURLToPath(new URL("../graphs", import.meta.url));

/** Each graph's app's screens: the app's state catalogs, or undefined if it has none. */
export type Screens = (app: string) => CatalogStates | undefined;

/** Swift's escapes in a string literal: `\"`, `\\`, `\n`, `\t`, `\r`, `\0`, `\'` and `\u{…}`. */
const unescapeSwift = (literal: string) =>
  literal.replace(/\\(u\{([0-9a-fA-F]{1,8})\}|.)/g, (_, escape: string, hex?: string) =>
    hex === undefined
      ? (({ n: "\n", t: "\t", r: "\r", "0": "\0" } as Record<string, string>)[escape] ?? escape)
      : String.fromCodePoint(Number.parseInt(hex, 16)),
  );

/** Swift's string literals, unescaped, outside comments (a `//` in a string isn't one). */
const stringLiterals = (source: string): ReadonlyArray<string> =>
  [...source.matchAll(/"((?:[^"\\\n]|\\.)*)"|\/\*[\s\S]*?\*\/|\/\/.*$/gm)].flatMap(([, literal]) =>
    literal === undefined ? [] : [unescapeSwift(literal)],
  );

/**
 * A Swift file's state catalog states' names, in source order: `CatalogState("Name")`, over one
 * line or several, outside comments and strings.
 */
export const catalogStateNames = (source: string): ReadonlyArray<string> =>
  [
    ...source.matchAll(
      /"(?:[^"\\\n]|\\.)*"|\/\*[\s\S]*?\*\/|\/\/.*$|\bCatalogState\(\s*"((?:[^"\\]|\\.)*)"/gm,
    ),
  ].flatMap(([, name]) => (name === undefined ? [] : [unescapeSwift(name)]));

/** A catalog manifest, as its snapshot test writes it (`CatalogManifest` in `StateCatalog.swift`). */
interface CatalogManifest {
  readonly app: string;
  readonly screen: string;
  /** `Module/File.swift`, as graphs name catalogs. */
  readonly catalog: string;
  readonly states: ReadonlyArray<{
    readonly name: string;
    readonly source: string;
    readonly light: string;
    readonly dark: string;
  }>;
}

/** A catalog manifest, or `undefined` if it isn't one. */
const parseManifest = (json: unknown): CatalogManifest | undefined => {
  if (typeof json !== "object" || json === null) return undefined;
  const { app, screen, catalog, states } = json as Record<string, unknown>;
  const isState = (state: unknown) =>
    typeof state === "object" &&
    state !== null &&
    ["name", "source", "light", "dark"].every(
      (field) => typeof (state as Record<string, unknown>)[field] === "string",
    );
  return typeof app === "string" &&
    typeof screen === "string" &&
    typeof catalog === "string" &&
    Array.isArray(states) &&
    states.every(isState)
    ? (json as CatalogManifest)
    : undefined;
};

/**
 * Every catalog manifest
 * (`<Product>/<Target>/Catalogs/<Module>/__Snapshots__/<File>/<screen>.json`, 851-2955) and
 * catalog file in LilPackage's test targets, by their paths from the repository's root.
 */
const readCatalogs = async (repository: string) => {
  const manifests: { readonly path: string; readonly manifest: CatalogManifest }[] = [];
  const files: string[] = [];
  const tests = join(repository, "LilPackage/Tests");
  // Test targets are grouped by product, `LilPackage/Tests/<Product>/<Target>` (851-3065).
  const targets: string[] = [];
  for (const product of await readdir(tests, { withFileTypes: true })) {
    if (!product.isDirectory()) continue;
    for (const target of await readdir(join(tests, product.name), { withFileTypes: true })) {
      if (target.isDirectory()) targets.push(`${product.name}/${target.name}`);
    }
  }
  for (const target of targets.toSorted()) {
    const folder = join(tests, target, "Catalogs");
    if (!existsSync(folder)) continue;
    for (const file of (await readdir(folder, { recursive: true })).toSorted()) {
      const path = `LilPackage/Tests/${target}/Catalogs/${file}`;
      if (/(^|\/)__Snapshots__\/[^/]+\/[^/]+\.json$/.test(file)) {
        const manifest = parseManifest(JSON.parse(await readFile(join(repository, path), "utf8")));
        if (manifest === undefined) throw new Error(`${path} isn't a catalog manifest.`);
        manifests.push({ path, manifest });
      } else if (file.endsWith(".swift") && !file.includes("__Snapshots__")) {
        files.push(path);
      }
    }
  }
  return { manifests, files };
};

/**
 * Every state catalog's states, by app, from the manifests their snapshot tests write beside their
 * references, which say which app each screen is in: a catalog can be built for one platform, or
 * differ on each. Keyed by `Module/File.swift`, as graphs name them, in the catalog's order.
 */
export const scanCatalogs = async (
  repository = root,
): Promise<ReadonlyMap<string, CatalogStates>> => {
  const apps = new Map<string, Map<string, ReadonlyArray<string>>>();
  for (const { manifest } of (await readCatalogs(repository)).manifests) {
    const catalogs = apps.get(manifest.app) ?? new Map<string, ReadonlyArray<string>>();
    apps.set(manifest.app, catalogs);
    // A catalog file can hold several screens.
    const names = manifest.states.map((state) => state.name);
    catalogs.set(manifest.catalog, [...(catalogs.get(manifest.catalog) ?? []), ...names]);
  }
  return apps;
};

/**
 * What's out of date in the catalogs' manifests, which their tests only rewrite when they run (the
 * iPhone's only after merging): a manifest whose catalog file is gone or whose screen was renamed
 * (left behind), a state it has that isn't in its file any more, or a missing reference, and a
 * state in a catalog file that no manifest has.
 */
export const manifestProblems = async (repository = root): Promise<ReadonlyArray<string>> => {
  const problems: string[] = [];
  const { manifests, files } = await readCatalogs(repository);
  const sources = new Map<string, string | undefined>();
  const source = async (path: string) => {
    if (!sources.has(path)) {
      sources.set(path, await readFile(join(repository, path), "utf8").catch(() => undefined));
    }
    return sources.get(path);
  };
  const inManifests = new Set<string>();
  for (const { path, manifest } of manifests) {
    const paths = [...new Set(manifest.states.map((state) => state.source))];
    const texts = await Promise.all(paths.map(source));
    const gone = paths.filter((_, index) => texts[index] === undefined);
    if (gone.length > 0) {
      problems.push(`${path}: ${gone.join(", ")} doesn't exist. Delete the manifest.`);
      continue;
    }
    if (!texts.some((text) => stringLiterals(text ?? "").includes(manifest.screen))) {
      problems.push(
        `${path}: its screen, "${manifest.screen}", isn't in ${paths.join(", ")}. If it was ` +
          "renamed, delete the manifest and the old references.",
      );
      continue;
    }
    for (const state of manifest.states) {
      inManifests.add(`${state.source}\n${state.name}`);
      if (!catalogStateNames((await source(state.source)) ?? "").includes(state.name)) {
        problems.push(`${path}: "${state.name}" isn't in ${state.source} any more.`);
      }
      for (const reference of [state.light, state.dark]) {
        if (!existsSync(join(repository, reference))) {
          problems.push(`${path}: "${state.name}" has no reference ${reference}.`);
        }
      }
    }
  }
  for (const file of files) {
    for (const name of catalogStateNames((await source(file)) ?? "")) {
      if (!inManifests.has(`${file}\n${name}`)) {
        problems.push(`${file}: "${name}" isn't in a manifest.`);
      }
    }
  }
  return problems;
};

/** Every screen a graph can name, by app: its state catalogs. */
export const scanScreens = async (): Promise<Screens> => {
  const catalogs = await scanCatalogs();
  return (app) => catalogs.get(app);
};

/** Each graph file's problems, by file name; none if all are fine. */
export const checkGraphs = async (
  screens: Screens,
  directory = graphsDirectory,
): Promise<ReadonlyMap<string, ReadonlyArray<string>>> => {
  const problems = new Map<string, ReadonlyArray<string>>();
  const files = (await readdir(directory)).filter((name) => name.endsWith(".json")).toSorted();
  const apps = new Map<string, string>();
  for (const file of files) {
    let json: unknown;
    try {
      json = JSON.parse(await readFile(join(directory, file), "utf8"));
    } catch (error) {
      problems.set(file, [
        `It isn't JSON: ${error instanceof Error ? error.message : String(error)}`,
      ]);
      continue;
    }
    const graph = parseGraph(json);
    if ("problems" in graph) {
      problems.set(file, graph.problems);
      continue;
    }
    const catalogs = screens(graph.app);
    const found = [
      ...(catalogs === undefined
        ? [`No state catalog's manifest is for ${graph.app}: is the app's name right?`]
        : graphProblems(graph, catalogs)),
      ...appProblems(graph, file, apps),
    ];
    if (found.length > 0) problems.set(file, found);
  }
  return problems;
};

/** A graph is named after its app, and there's one per app. */
const appProblems = (graph: Graph, file: string, apps: Map<string, string>) => {
  const problems: string[] = [];
  if (file !== `${graph.app}.json`)
    problems.push(`It's for ${graph.app}, so name it ${graph.app}.json.`);
  const other = apps.get(graph.app);
  if (other !== undefined) problems.push(`${other} is for ${graph.app} too.`);
  apps.set(graph.app, file);
  return problems;
};

if (import.meta.main) {
  const problems = await checkGraphs(await scanScreens());
  for (const [file, list] of problems) {
    console.error(`Web/pixelbook/graphs/${file}:`);
    for (const problem of list) console.error(`  ${problem}`);
  }
  const stale = await manifestProblems();
  if (stale.length > 0) {
    console.error("State catalogs' Pixelbook manifests:");
    for (const problem of stale) console.error(`  ${problem}`);
  }
  if (problems.size > 0 || stale.length > 0) {
    console.error(
      "A state catalog's manifest is written by its snapshot test (scripts/snapshot <test>, or " +
        "scripts/snapshot --iphone <test>): run it after adding, renaming or removing states, " +
        "and commit the manifest with the references.",
    );
    process.exit(1);
  }
  console.log("Pixelbook's graphs match the state catalogs, whose manifests are up to date.");
}
