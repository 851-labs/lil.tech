// Checks Pixelbook's graph files (`graphs/*.json`) against the previews in LilPackage: every screen
// and state a graph names must exist, so renaming a preview can't quietly break a flowchart.
// Reads the Swift sources, so it needs no render. Run by the pre-commit hook (lefthook.yml):
//   node Web/pixelbook/scripts/graphs.ts
import { readdir, readFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import { type Graph, graphProblems, parseGraph, type Previews } from "../src/Graph.ts";

const root = fileURLToPath(new URL("../../..", import.meta.url));
export const graphsDirectory = fileURLToPath(new URL("../graphs", import.meta.url));

/** A Swift file's preview names, in source order: `#Preview("Name")`, over one line or several. */
export const previewNames = (source: string): ReadonlyArray<string> =>
  [...source.matchAll(/#Preview\(\s*"((?:[^"\\]|\\.)*)"/g)].map(([, name]) =>
    (name ?? "").replace(/\\(.)/g, "$1"),
  );

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
      if (names.length > 0) previews.set(`${module.name}/${basename(file)}`, names);
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
  const problems = await checkGraphs(await scanPreviews());
  for (const [file, list] of problems) {
    console.error(`Web/pixelbook/graphs/${file}:`);
    for (const problem of list) console.error(`  ${problem}`);
  }
  if (problems.size > 0) process.exit(1);
  console.log("Pixelbook's graphs match the previews.");
}
