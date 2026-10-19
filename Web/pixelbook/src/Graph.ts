// Flowchart mode's graph files (`graphs/<app>.json`): how an app's screens connect, which previews
// can't say. A node is a screen, named by the file its previews are in, and an edge is the action
// that goes from one to another. The files ship with the viewer, so a PR's preview shows its graphs.
import dagre from "@dagrejs/dagre";

/** A screen on the flowchart. */
export interface GraphScreen {
  /** Unique in the file; edges use it. */
  readonly id: string;
  /** The file its previews are in, as `Module/File.swift`. */
  readonly screen: string;
  /** Which previews (states) to show, first by default. All of the file's, in source order, if left out. */
  readonly states?: ReadonlyArray<string>;
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

/** Each preview file's preview names, keyed by `Module/File.swift`, in source order. */
export type Previews = ReadonlyMap<string, ReadonlyArray<string>>;

/** What in a graph refers to something that doesn't exist. */
export const graphProblems = (graph: Graph, previews: Previews): ReadonlyArray<string> => {
  const problems: string[] = [];
  const ids = new Set<string>();
  for (const screen of graph.screens) {
    if (ids.has(screen.id)) problems.push(`Two screens are "${screen.id}".`);
    ids.add(screen.id);
    const states = previews.get(screen.screen);
    if (states === undefined) {
      problems.push(`"${screen.id}": ${screen.screen} has no previews.`);
      continue;
    }
    for (const state of screen.states ?? []) {
      if (!states.includes(state)) {
        problems.push(`"${screen.id}": ${screen.screen} has no preview "${state}".`);
      }
    }
  }
  for (const edge of graph.edges) {
    for (const end of [edge.from, edge.to]) {
      if (!ids.has(end))
        problems.push(`An edge goes ${edge.from} → ${edge.to}, but "${end}" isn't a screen.`);
    }
  }
  return problems;
};

/** A screen placed on the canvas: its top-left corner and size, in points. */
export interface PlacedScreen {
  readonly id: string;
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** An edge's route, through points on the canvas, and where its label goes. */
export interface PlacedEdge {
  readonly from: string;
  readonly to: string;
  readonly label: string | undefined;
  readonly points: ReadonlyArray<{ readonly x: number; readonly y: number }>;
  readonly labelAt: { readonly x: number; readonly y: number } | undefined;
}

/** Spacing between screens, in points. */
export const flowSpacing = { rank: 280, node: 120, label: { width: 240, height: 48 } };

/**
 * Lays a graph out left to right with dagre, given each screen's size, then applies nudges. Edges
 * that a nudge moved an end of are drawn straight between the screens.
 */
export const layoutFlow = (
  graph: Graph,
  sizes: ReadonlyMap<string, { readonly width: number; readonly height: number }>,
): { readonly screens: ReadonlyArray<PlacedScreen>; readonly edges: ReadonlyArray<PlacedEdge> } => {
  const shown = graph.screens.filter((screen) => sizes.has(screen.id));
  const g = new dagre.graphlib.Graph({ multigraph: true });
  g.setGraph({ rankdir: "LR", ranksep: flowSpacing.rank, nodesep: flowSpacing.node });
  g.setDefaultEdgeLabel(() => ({}));
  for (const screen of shown) {
    const size = sizes.get(screen.id) ?? { width: 0, height: 0 };
    g.setNode(screen.id, { width: size.width, height: size.height });
  }
  const edges = graph.edges.filter((edge) => g.hasNode(edge.from) && g.hasNode(edge.to));
  for (const [index, edge] of edges.entries()) {
    const label = edge.label === undefined ? {} : flowSpacing.label;
    g.setEdge(edge.from, edge.to, { ...label, labelpos: "c" }, String(index));
  }
  dagre.layout(g);

  const nudges = new Map(shown.map((screen) => [screen.id, screen.nudge ?? [0, 0]] as const));
  const placed = shown.map((screen): PlacedScreen => {
    const node = g.node(screen.id);
    const [dx, dy] = nudges.get(screen.id) ?? [0, 0];
    return {
      id: screen.id,
      x: node.x - node.width / 2 + dx,
      y: node.y - node.height / 2 + dy,
      width: node.width,
      height: node.height,
    };
  });
  const byId = new Map(placed.map((screen) => [screen.id, screen]));
  const nudged = (id: string) => {
    const [dx, dy] = nudges.get(id) ?? [0, 0];
    return dx !== 0 || dy !== 0;
  };
  const placedEdges = edges.map((edge, index): PlacedEdge => {
    const routed = g.edge({ v: edge.from, w: edge.to, name: String(index) });
    const from = byId.get(edge.from);
    const to = byId.get(edge.to);
    if ((nudged(edge.from) || nudged(edge.to)) && from !== undefined && to !== undefined) {
      const start = { x: from.x + from.width, y: from.y + from.height / 2 };
      const end = { x: to.x, y: to.y + to.height / 2 };
      const middle = { x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 };
      return { ...edge, label: edge.label, points: [start, end], labelAt: middle };
    }
    const labelAt =
      routed.x === undefined || routed.y === undefined ? undefined : { x: routed.x, y: routed.y };
    return { ...edge, label: edge.label, points: routed.points ?? [], labelAt };
  });
  return { screens: placed, edges: placedEdges };
};
