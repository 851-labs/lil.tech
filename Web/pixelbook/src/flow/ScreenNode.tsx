// Flowchart mode's screens: a node per screen that steps through its states.
import type { NodeProps } from "@xyflow/react";
import { useContext } from "react";
import { TileButton } from "../canvas/Tile.tsx";
import type { ScreenNode } from "../lib/Elements.ts";
import { nodeHeader } from "../lib/Flow.ts";
import { StepContext } from "./StepContext.ts";

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
