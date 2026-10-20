// What the canvas shows, as React Flow's nodes (851-2766): snapshot tiles and labels in both modes,
// and the flowchart's screens and the routes between them. The layouts are ours.
import type { Node } from "@xyflow/react";
import {
  type FlowLayout,
  type FlowNode,
  flowSpacing,
  nodeExtent,
  type PlacedEdge,
} from "./Flow.ts";
import { type Label, type Tile, tileId } from "./Grid.ts";

export type TileNode = Node<{ readonly tile: Tile }, "tile">;
export type LabelNode = Node<{ readonly label: Label }, "label">;
/** A flowchart screen, stepped `steps` times through its states. */
export type ScreenNode = Node<{ readonly node: FlowNode; readonly steps: number }, "screen">;
/**
 * The flowchart's routes and their labels, as one node: React Flow culls an edge by the box of the
 * nodes at its ends, and dagre routes some, such as those back to an earlier screen, around them.
 */
export type RoutesNode = Node<{ readonly edges: ReadonlyArray<PlacedEdge> }, "routes">;
export type CanvasNode = TileNode | LabelNode | ScreenNode | RoutesNode;

/**
 * Room for a label's text, which isn't measured, in points: an app's title (`.label.app`, 112
 * points) runs to about 1,500 points.
 */
export const labelExtent = { width: 2000, height: 120 };

// Every node comes with its size, and no handles, so React Flow renders only those in view from the
// start, rather than every node once to measure it.

const tileNode = (tile: Tile): TileNode => ({
  id: `tile/${tileId(tile)}`,
  type: "tile",
  position: { x: tile.x, y: tile.y },
  width: tile.width,
  height: tile.height,
  handles: [],
  data: { tile },
});

const labelNode = (label: Label): LabelNode => ({
  id: `label/${label.kind}/${label.x}/${label.y}`,
  type: "label",
  position: { x: label.x, y: label.y },
  ...labelExtent,
  handles: [],
  data: { label },
});

/** Its size reaches as far as its largest state (`nodeExtent`), so it shows while any is in view. */
const screenNode = (node: FlowNode, steps: number): ScreenNode => {
  const { width, height } = nodeExtent(node);
  const stepped = node.tiles.length > 0 && steps % node.tiles.length > 0;
  return {
    id: `screen/${node.key}`,
    type: "screen",
    position: { x: node.x, y: node.y },
    width,
    height,
    // Raised once stepped, since another state can be larger than the first and overlap.
    zIndex: stepped ? 1 : 0,
    handles: [],
    data: { node, steps },
  };
};

/** Room around the routes for their lines and arrowheads, in points. */
const routeMargin = 40;

const routesNode = (edges: ReadonlyArray<PlacedEdge>): RoutesNode[] => {
  const label = flowSpacing.label;
  const boxes = edges.flatMap((edge) => [
    ...edge.points.map(({ x, y }) => ({ x0: x, y0: y, x1: x, y1: y })),
    ...(edge.labelAt === undefined
      ? []
      : [
          {
            x0: edge.labelAt.x - label.width / 2,
            y0: edge.labelAt.y - label.height / 2,
            x1: edge.labelAt.x + label.width / 2,
            y1: edge.labelAt.y + label.height / 2,
          },
        ]),
  ]);
  if (boxes.length === 0) return [];
  const x = Math.min(...boxes.map((box) => box.x0)) - routeMargin;
  const y = Math.min(...boxes.map((box) => box.y0)) - routeMargin;
  return [
    {
      id: "routes",
      type: "routes",
      position: { x, y },
      width: Math.max(...boxes.map((box) => box.x1)) + routeMargin - x,
      height: Math.max(...boxes.map((box) => box.y1)) + routeMargin - y,
      handles: [],
      data: { edges },
    },
  ];
};

/** The grid's, or a comparison's: labels, then tiles. */
export const gridNodes = (layout: {
  readonly tiles: ReadonlyArray<Tile>;
  readonly labels: ReadonlyArray<Label>;
}): CanvasNode[] => [...layout.labels.map(labelNode), ...layout.tiles.map(tileNode)];

/** The flowchart's: labels, the routes under the screens, the screens, then those not in a graph. */
export const flowNodes = (layout: FlowLayout): CanvasNode[] => [
  ...layout.labels.map(labelNode),
  ...routesNode(layout.edges),
  ...layout.nodes.map((node) => screenNode(node, 0)),
  ...layout.unlinked.map(tileNode),
];

/**
 * The nodes with each screen stepped as far as `steps` has it, by its key. The rest stay the same
 * objects, so React Flow updates only the stepped screens.
 */
export const withSteps = (nodes: CanvasNode[], steps: ReadonlyMap<string, number>): CanvasNode[] =>
  steps.size === 0
    ? nodes
    : nodes.map((node) => {
        if (node.type !== "screen") return node;
        const stepped = steps.get(node.data.node.key);
        return stepped === undefined ? node : screenNode(node.data.node, stepped);
      });
