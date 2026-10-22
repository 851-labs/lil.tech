// Checks Pixelbook's graph files (`graphs/*.json`) against the previews and state catalogs in
// LilPackage: every screen and state a graph names must exist in its app, so renaming one can't
// quietly break a flowchart. Reads previews from the Swift sources, and catalogs from their
// manifests, so it needs no render. Run by the pre-commit hook (lefthook.yml):
//   node Web/pixelbook/scripts/graphs.ts
import { existsSync } from "node:fs";
import { readdir, readFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import { type Graph, graphProblems, parseGraph, type Previews } from "../src/lib/Graph.ts";

const root = fileURLToPath(new URL("../../..", import.meta.url));
export const graphsDirectory = fileURLToPath(new URL("../graphs", import.meta.url));

/** Swift without its comments, so a commented-out preview doesn't count. */
const withoutComments = (source: string) =>
  source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");

/**
 * A Swift file's previews' names, in source order: `#Preview("Name")`, over one line or several.
 * Undefined if it has no previews; unnamed ones (`#Preview {`) count, but graphs can't name them.
 */
export const previewNames = (source: string): ReadonlyArray<string> | undefined => {
  const code = withoutComments(source);
  if (!/#Preview\s*[({]/.test(code)) return undefined;
  return [...code.matchAll(/#Preview\(\s*"((?:[^"\\]|\\.)*)"/g)].map(([, name]) =>
    (name ?? "").replace(/\\(.)/g, "$1"),
  );
};

/** Each graph's app's screens: preview files, and the app's state catalogs. */
export type Screens = (app: string) => Previews;

/**
 * Every state catalog's states, by app, from the manifests their snapshot tests write beside
 * their references (`<Target>/Catalogs/<Module>/__Snapshots__/<File>/<screen>.json`, 851-2955),
 * which say which app each screen is in: a catalog can be built for one platform, or differ on
 * each. Keyed by `Module/File.swift`, as graphs name them, in the catalog's order.
 */
export const scanCatalogs = async (
  tests = join(root, "LilPackage/Tests"),
): Promise<ReadonlyMap<string, Previews>> => {
  const apps = new Map<string, Map<string, ReadonlyArray<string>>>();
  for (const target of await readdir(tests, { withFileTypes: true })) {
    const folder = join(tests, target.name, "Catalogs");
    if (!target.isDirectory() || !existsSync(folder)) continue;
    const files = await readdir(folder, { recursive: true });
    for (const file of files.filter((name) =>
      /(^|\/)__Snapshots__\/[^/]+\/[^/]+\.json$/.test(name),
    )) {
      const path = join(folder, file);
      const manifest = parseManifest(JSON.parse(await readFile(path, "utf8")));
      if (manifest === undefined) throw new Error(`${path} isn't a catalog manifest.`);
      const catalogs = apps.get(manifest.app) ?? new Map<string, ReadonlyArray<string>>();
      apps.set(manifest.app, catalogs);
      // A catalog file can hold several screens.
      catalogs.set(manifest.catalog, [
        ...(catalogs.get(manifest.catalog) ?? []),
        ...manifest.states,
      ]);
    }
  }
  return apps;
};

/** A catalog manifest's app, catalog and state names, or `undefined` if it isn't one. */
const parseManifest = (json: unknown) => {
  if (typeof json !== "object" || json === null) return undefined;
  const { app, catalog, states } = json as Record<string, unknown>;
  if (typeof app !== "string" || typeof catalog !== "string" || !Array.isArray(states)) {
    return undefined;
  }
  const names = states.map((state: unknown) =>
    typeof state === "object" && state !== null ? (state as { name?: unknown }).name : undefined,
  );
  if (!names.every((name) => typeof name === "string")) return undefined;
  return { app, catalog, states: names as ReadonlyArray<string> };
};

/** Every screen a graph can name, by app: preview files and its catalogs, which can't share a name. */
export const scanScreens = async (): Promise<Screens> => {
  const [previews, catalogs] = await Promise.all([scanPreviews(), scanCatalogs()]);
  for (const appCatalogs of catalogs.values()) {
    for (const file of appCatalogs.keys()) {
      if (previews.has(file))
        throw new Error(`${file} is both a preview file and a state catalog.`);
    }
  }
  return (app) => new Map([...previews, ...(catalogs.get(app) ?? [])]);
};

/** Every preview file in LilPackage's modules, keyed by `Module/File.swift`, as graphs name them. */
export const scanPreviews = async (
  sources = join(root, "LilPackage/Sources"),
): Promise<Previews> => {
  const previews = new Map<string, ReadonlyArray<string>>();
  for (const module of await readdir(sources, { withFileTypes: true })) {
    if (!module.isDirectory()) continue;
    const files = await readdir(join(sources, module.name), { recursive: true });
    for (const file of files.filter((name) => name.endsWith(".swift"))) {
      const names = previewNames(await readFile(join(sources, module.name, file), "utf8"));
      if (names !== undefined) previews.set(`${module.name}/${basename(file)}`, names);
    }
  }
  return previews;
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
    const found = [...graphProblems(graph, screens(graph.app)), ...appProblems(graph, file, apps)];
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
  if (problems.size > 0) {
    console.error(
      "A state catalog's states come from its manifest, which its snapshot test writes " +
        "(scripts/snapshot, or scripts/snapshot --iphone): run it after adding or renaming states.",
    );
    process.exit(1);
  }
  console.log("Pixelbook's graphs match the previews and catalogs.");
}
