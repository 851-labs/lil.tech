// The frames on the canvas that can be selected, and moving the selection between them with the
// arrow keys (851-2765): along the flowchart's routes, or to the nearest frame that way.
import { type FlowLayout, nodeHeader } from "./Flow.ts";
import { type Tile, tileId } from "./Grid.ts";

/** A rectangle on the canvas, in canvas points. */
export interface Box {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** A frame on the canvas: the tile it shows, and where. */
export interface Frame {
  readonly tile: Tile;
  readonly box: Box;
  /** The IDs of the tiles it can show, selecting it: a flowchart screen's states. */
  readonly ids: ReadonlyArray<string>;
  /** Unique among the frames: a flowchart screen's key, or its tile's ID. */
  readonly key: string;
  /** The keys of the flowchart screens it has routes to, and from. */
  readonly next: ReadonlyArray<string>;
  readonly previous: ReadonlyArray<string>;
}

const tileFrame = (tile: Tile): Frame => {
  const id = tileId(tile);
  return { tile, box: tile, ids: [id], key: id, next: [], previous: [] };
};

/** The grid's, or a comparison's: each tile. */
export const gridFrames = (tiles: ReadonlyArray<Tile>): Frame[] => tiles.map(tileFrame);

/**
 * The flowchart's: each screen, showing the state it's stepped to (`steps`, by its key), then the
 * screens not in a graph.
 */
export const flowFrames = (layout: FlowLayout, steps: ReadonlyMap<string, number>): Frame[] => [
  ...layout.nodes.flatMap((node) => {
    const tile = node.tiles[(steps.get(node.key) ?? 0) % node.tiles.length];
    if (tile === undefined) return [];
    const box = { x: node.x, y: node.y + nodeHeader, width: tile.width, height: tile.height };
    const routes = (end: "from" | "to", other: "from" | "to") =>
      layout.edges.filter((edge) => edge[end] === node.key).map((edge) => edge[other]);
    return [
      {
        tile,
        box,
        ids: node.tiles.map(tileId),
        key: node.key,
        next: routes("from", "to"),
        previous: routes("to", "from"),
      },
    ];
  }),
  ...layout.unlinked.map(tileFrame),
];

/** The frame that shows the tile with this ID. */
export const frameOf = (frames: ReadonlyArray<Frame>, id: string | undefined) =>
  id === undefined ? undefined : frames.find((frame) => frame.ids.includes(id));

export type Direction = "left" | "right" | "up" | "down";

const vectors: Record<Direction, readonly [number, number]> = {
  left: [-1, 0],
  right: [1, 0],
  up: [0, -1],
  down: [0, 1],
};

const center = ({ x, y, width, height }: Box) => [x + width / 2, y + height / 2] as const;

/**
 * The frame to move to from `from` in `direction`. Right and left follow a flowchart screen's
 * routes, to the nearest screen it leads to or comes from. Otherwise, of the frames whose centers
 * are ahead of its center, the one with the least distance along the way plus twice the distance
 * across it, so the next one in a row wins over one diagonally nearer. None at the end.
 */
export const neighbor = (
  frames: ReadonlyArray<Frame>,
  from: Frame,
  direction: Direction,
): Frame | undefined => {
  const [fx, fy] = center(from.box);
  const routed = direction === "right" ? from.next : direction === "left" ? from.previous : [];
  const linked = frames.filter((frame) => frame !== from && routed.includes(frame.key));
  if (linked.length > 0) {
    const distance = (frame: Frame) => {
      const [x, y] = center(frame.box);
      return Math.hypot(x - fx, y - fy);
    };
    return linked.reduce((nearest, frame) =>
      distance(frame) < distance(nearest) ? frame : nearest,
    );
  }
  const [dx, dy] = vectors[direction];
  let best: Frame | undefined;
  let bestScore = Number.POSITIVE_INFINITY;
  for (const frame of frames) {
    if (frame === from) continue;
    const [x, y] = center(frame.box);
    const along = (x - fx) * dx + (y - fy) * dy;
    if (along <= 0) continue;
    const across = Math.abs((x - fx) * dy - (y - fy) * dx);
    const score = along + 2 * across;
    if (score < bestScore) {
      best = frame;
      bestScore = score;
    }
  }
  return best;
};
