// Flowchart mode's nodes and edges: a node per screen that steps through its states, and the routes
// between them, with their labels.
import { EdgeLabelRenderer, type EdgeProps, Handle, type NodeProps, Position } from "@xyflow/react";
import { createContext, useCallback, useContext, useState } from "react";
import type { RouteEdge, ScreenNode } from "./Elements.ts";
import { nodeHeader } from "./Flow.ts";
import { TileButton } from "./Tiles.tsx";

/**
 * How far each screen was stepped through its states, by its key, and a function that steps one.
 * Kept above the canvas, so a node that leaves the view and comes back keeps its state.
 */
export function useSteps() {
  const [steps, setSteps] = useState<ReadonlyMap<string, number>>(new Map());
  const step = useCallback(
    (key: string, to: number) => setSteps((steps) => new Map(steps).set(key, to)),
    [],
  );
  return [steps, step] as const;
}

/** `useSteps`'s function, for the screens' nodes. */
export const StepContext = createContext<(key: string, steps: number) => void>(() => {});

/** A route: dagre's points, then an arrowhead, and its label at its center. */
export function RouteEdgeView({ data }: EdgeProps<RouteEdge>) {
  if (data === undefined) return null;
  const { points, label, labelAt } = data.edge;
  return (
    <>
      {/* In canvas points: sized to read when zoomed out. */}
      <path
        className="pointer-events-none fill-none stroke-secondary stroke-6 [stroke-linejoin:round]"
        d={points.map(({ x, y }, index) => `${index === 0 ? "M" : "L"}${x} ${y}`).join(" ")}
        markerEnd="url(#route-arrow)"
      />
      {label !== undefined && labelAt !== undefined && (
        <EdgeLabelRenderer>
          <div
            className="absolute w-max max-w-[280px] -translate-1/2 rounded-2xl border-2 border-border bg-background px-3.5 py-1.5 text-center text-[26px] leading-[1.2] font-semibold"
            style={{ left: labelAt.x, top: labelAt.y }}
          >
            {label}
          </div>
        </EdgeLabelRenderer>
      )}
    </>
  );
}

/** The ‹ and › buttons that step through a node's states. */
const stepButton =
  "pointer-events-auto min-w-11 cursor-pointer rounded-xl border-2 border-border px-2.5 text-[28px] leading-[1.3]";

/** A screen: its name, then one state at a time, with the others stacked behind it. */
export function ScreenNodeView({ data: { node, steps } }: NodeProps<ScreenNode>) {
  const onStep = useContext(StepContext);
  const count = node.tiles.length;
  // Wrapped here, since filters can leave a node fewer states than it was stepped through.
  const index = count === 0 ? 0 : steps % count;
  const tile = node.tiles[index];
  const step = (by: number) => onStep(node.key, index + by + count);
  return (
    <div className="relative" style={{ width: node.width, height: node.height }}>
      {/* Where its routes meet it, which React Flow needs to draw them; they're invisible. */}
      <Handle type="target" position={Position.Left} isConnectable={false} className="invisible" />
      <Handle type="source" position={Position.Right} isConnectable={false} className="invisible" />
      <header
        className="flex flex-col justify-end gap-1.5 pb-4 whitespace-nowrap"
        style={{ height: nodeHeader }}
      >
        <div className="overflow-hidden text-[44px] font-bold text-ellipsis">{node.title}</div>
        <div className="flex items-center gap-3 text-[28px] text-secondary">
          {count > 1 && (
            <button
              type="button"
              className={stepButton}
              onClick={() => step(-1)}
              aria-label="Previous state"
            >
              ‹
            </button>
          )}
          <span className="overflow-hidden text-ellipsis">
            {tile?.snapshot.state ?? "No snapshots"}
          </span>
          {count > 1 && (
            <>
              <span className="tabular-nums">
                {index + 1}/{count}
              </span>
              <button
                type="button"
                className={stepButton}
                onClick={() => step(1)}
                aria-label="Next state"
              >
                ›
              </button>
            </>
          )}
        </div>
      </header>
      {tile === undefined ? (
        // The graph names a screen with no snapshots here: not rendered for this app, or none in
        // this appearance.
        <div
          className="absolute right-0 left-0 flex items-center justify-center rounded-[10px] border-4 border-dashed border-border p-6 text-center text-[28px] text-secondary"
          style={{ top: nodeHeader, height: node.height - nodeHeader }}
        >
          No snapshots of {node.title} for this app in this appearance
        </div>
      ) : (
        // A screen with more states shows them stacked behind the current one.
        <TileButton tile={{ ...tile, x: 0, y: nodeHeader }} stacked={count > 1} />
      )}
    </div>
  );
}
