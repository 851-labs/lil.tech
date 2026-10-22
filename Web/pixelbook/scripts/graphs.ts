// Checks Pixelbook's graph files (`graphs/*.json`) against the previews and state catalogs in
// LilPackage: every screen and state a graph names must exist, so renaming one can't quietly break
// a flowchart. Reads the Swift sources, so it needs no render. Run by the pre-commit hook (lefthook.yml):
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

/**
 * A state catalog's state names, in source order: `CatalogState("Name")`, over one line or several
 * (851-2949). Undefined if it has none.
 */
export const catalogStateNames = (source: string): ReadonlyArray<string> | undefined => {
  const names = [
    ...withoutComments(source).matchAll(/\bCatalogState\(\s*"((?:[^"\\]|\\.)*)"/g),
  ].map(([, name]) => (name ?? "").replace(/\\(.)/g, "$1"));
  return names.length > 0 ? names : undefined;
};

/**
 * Every state catalog in LilPackage's test targets, `<Target>/Catalogs/<Module>/<File>.swift`,
 * keyed by `Module/File.swift`, as graphs name them.
 */
export const scanCatalogs = async (tests = join(root, "LilPackage/Tests")): Promise<Previews> => {
  const catalogs = new Map<string, ReadonlyArray<string>>();
  for (const target of await readdir(tests, { withFileTypes: true })) {
    const folder = join(tests, target.name, "Catalogs");
    if (!target.isDirectory() || !existsSync(folder)) continue;
    for (const module of await readdir(folder, { withFileTypes: true })) {
      if (!module.isDirectory()) continue;
      const files = await readdir(join(folder, module.name), { recursive: true });
      for (const file of files.filter((name) => name.endsWith(".swift"))) {
        const names = catalogStateNames(await readFile(join(folder, module.name, file), "utf8"));
        if (names !== undefined) catalogs.set(`${module.name}/${basename(file)}`, names);
      }
    }
  }
  return catalogs;
};

/** Every screen a graph can name: preview files, then state catalogs. */
export const scanScreens = async (): Promise<Previews> =>
  new Map([...(await scanPreviews()), ...(await scanCatalogs())]);

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
  previews: Previews,
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
    const found = [...graphProblems(graph, previews), ...appProblems(graph, file, apps)];
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
  if (problems.size > 0) process.exit(1);
  console.log("Pixelbook's graphs match the previews and catalogs.");
}
