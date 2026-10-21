import { useCallback } from "react";
import type { FlowLayout } from "../lib/Flow.ts";
import type { Tile } from "../lib/Grid.ts";
import { steppedTile } from "../lib/Selection.ts";

/**
 * Stepping a flowchart screen through its states, with `useSteps`'s `step`: stepping the selected
 * screen selects the state it steps to, which it shows.
 */
export function useStepScreen({
  flow,
  selected,
  step,
  select,
}: {
  readonly flow: FlowLayout | undefined;
  /** The selected tile's ID. */
  readonly selected: string | undefined;
  readonly step: (key: string, to: number) => void;
  readonly select: (tile: Tile) => void;
}) {
  return useCallback(
    (key: string, to: number) => {
      step(key, to);
      const tile = steppedTile(flow, key, to, selected);
      if (tile !== undefined) select(tile);
    },
    [step, flow, selected, select],
  );
}
