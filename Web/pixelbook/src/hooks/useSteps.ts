import { useCallback, useState } from "react";

/**
 * How far each flowchart screen was stepped through its states, by its key, and a function that
 * steps one. Kept above the canvas, so a node that leaves the view and comes back keeps its state.
 */
export function useSteps() {
  const [steps, setSteps] = useState<ReadonlyMap<string, number>>(new Map());
  const step = useCallback(
    (key: string, to: number) => setSteps((steps) => new Map(steps).set(key, to)),
    [],
  );
  return [steps, step] as const;
}
