// Flowchart mode's graph files (`graphs/<app>.json`): how an app's screens connect, which state
// catalogs can't say. A node is a screen, named by its state catalog's file, and an edge is the
// action that goes from one to another. The files ship with the viewer, so a PR's preview shows
// its graphs.
/** A screen on the flowchart. */
export interface GraphScreen {
  /** Unique in the file; edges use it. */
  readonly id: string;
  /** Its state catalog, a test target's `Catalogs/Module/File.swift`, as `Module/File.swift` (851-2949). */
  readonly screen: string;
  /** Which states to show, first by default. All of the catalog's, in its order, if left out. */
  readonly states?: ReadonlyArray<string>;
  /**
   * Its name, if not its file's: a catalog file can hold several screens' states (a list and
   * its detail, say), each a screen here with its own `states`.
   */
  readonly title?: string;
  /** Moves the screen from where the automatic layout puts it, in points. */
  readonly nudge?: readonly [number, number];
}

/** An action that goes from one screen to another, e.g. "Choose Account…". */
export interface GraphEdge {
  readonly from: string;
  readonly to: string;
  readonly label?: string;
}

export interface Graph {
  /** The app it's for, e.g. `health-mac`, as in the snapshots. */
  readonly app: string;
  readonly screens: ReadonlyArray<GraphScreen>;
  readonly edges: ReadonlyArray<GraphEdge>;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const isStrings = (value: unknown): value is ReadonlyArray<string> =>
  Array.isArray(value) && value.every((item) => typeof item === "string");

/** Reads a graph file's JSON, or says what's wrong with its shape. */
export const parseGraph = (json: unknown): Graph | { readonly problems: ReadonlyArray<string> } => {
  const problems: string[] = [];
  if (!isRecord(json)) return { problems: ["The graph isn't an object."] };
  if (typeof json["app"] !== "string") problems.push('"app" isn\'t a string.');
  const screens = Array.isArray(json["screens"]) ? json["screens"] : [];
  if (!Array.isArray(json["screens"])) problems.push('"screens" isn\'t a list.');
  for (const [index, screen] of screens.entries()) {
    const where = `Screen ${index + 1}`;
    if (!isRecord(screen)) {
      problems.push(`${where} isn't an object.`);
      continue;
    }
    if (typeof screen["id"] !== "string") problems.push(`${where}'s "id" isn't a string.`);
    if (typeof screen["screen"] !== "string") problems.push(`${where}'s "screen" isn't a string.`);
    if (screen["states"] !== undefined && !isStrings(screen["states"])) {
      problems.push(`${where}'s "states" isn't a list of strings.`);
    }
    if (screen["title"] !== undefined && typeof screen["title"] !== "string") {
      problems.push(`${where}'s "title" isn't a string.`);
    }
    const nudge = screen["nudge"];
    if (
      nudge !== undefined &&
      !(Array.isArray(nudge) && nudge.length === 2 && nudge.every((n) => typeof n === "number"))
    ) {
      problems.push(`${where}'s "nudge" isn't [x, y].`);
    }
  }
  const edges = Array.isArray(json["edges"]) ? json["edges"] : [];
  if (!Array.isArray(json["edges"])) problems.push('"edges" isn\'t a list.');
  for (const [index, edge] of edges.entries()) {
    const where = `Edge ${index + 1}`;
    if (!isRecord(edge) || typeof edge["from"] !== "string" || typeof edge["to"] !== "string") {
      problems.push(`${where} needs "from" and "to" strings.`);
    } else if (edge["label"] !== undefined && typeof edge["label"] !== "string") {
      problems.push(`${where}'s "label" isn't a string.`);
    }
  }
  return problems.length > 0 ? { problems } : (json as unknown as Graph);
};

/** Each state catalog's state names, keyed by `Module/File.swift`, in the catalog's order. */
export type CatalogStates = ReadonlyMap<string, ReadonlyArray<string>>;

/** What in a graph refers to something that doesn't exist. */
export const graphProblems = (graph: Graph, catalogs: CatalogStates): ReadonlyArray<string> => {
  const problems: string[] = [];
  const ids = new Set<string>();
  for (const screen of graph.screens) {
    if (ids.has(screen.id)) problems.push(`Two screens are "${screen.id}".`);
    ids.add(screen.id);
    const states = catalogs.get(screen.screen);
    if (states === undefined) {
      problems.push(`"${screen.id}": ${screen.screen} isn't a state catalog.`);
      continue;
    }
    for (const state of screen.states ?? []) {
      if (!states.includes(state)) {
        problems.push(`"${screen.id}": ${screen.screen} has no state "${state}".`);
      }
    }
  }
  for (const edge of graph.edges) {
    for (const end of [edge.from, edge.to]) {
      if (!ids.has(end))
        problems.push(`An edge goes ${edge.from} → ${edge.to}, but "${end}" isn't a screen.`);
    }
  }
  // A file split into several screens by `states` has every state on one of them, so a new state
  // there can't go missing from the flowchart.
  for (const [file, screens] of Map.groupBy(graph.screens, (screen) => screen.screen)) {
    // One screen's `states` can be a selection; several split the file.
    if (screens.length < 2 || screens.some((screen) => screen.states === undefined)) continue;
    const shown = new Set(screens.flatMap((screen) => screen.states ?? []));
    const missing = (catalogs.get(file) ?? []).filter((state) => !shown.has(state));
    if (missing.length > 0) {
      const names = missing.map((state) => `"${state}"`).join(", ");
      problems.push(
        `${file}'s ${names} ${missing.length === 1 ? "isn't" : "aren't"} on any screen.`,
      );
    }
  }
  return problems;
};
