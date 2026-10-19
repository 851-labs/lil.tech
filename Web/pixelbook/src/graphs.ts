// The graph files, bundled with the viewer. `scripts/graphs.ts` checks them before every commit,
// so one that doesn't parse is left out here rather than failing the page.
import { type Graph, parseGraph } from "./Graph.ts";

const files = import.meta.glob<unknown>("../graphs/*.json", { eager: true, import: "default" });

export const graphs: ReadonlyArray<Graph> = Object.values(files).flatMap((json) => {
  const graph = parseGraph(json);
  return "problems" in graph ? [] : [graph];
});
