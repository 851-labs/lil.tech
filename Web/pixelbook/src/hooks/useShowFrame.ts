import { type RefObject, useCallback, useEffect, useRef, useState } from "react";
import type { CanvasHandle, Insets } from "../canvas/Canvas.tsx";
import { type Tile, tileId } from "../lib/Grid.ts";
import { type Frame, frameOf } from "../lib/Selection.ts";

/** A frame to show once it's selected. */
interface ToShow {
  readonly id: string;
  readonly zoom: boolean;
  /** What was selected when it was asked for, until the selection catches up. */
  readonly from: string | undefined;
}

/**
 * Selecting a frame and showing it on the canvas, in what the panels beside it leave of the view
 * (narrow windows show them over it). `show` selects a tile, then, once the selection and the
 * inspector it opens are laid out, pans to its frame (as the arrow keys do) or zooms to it (as the
 * layers list does). It counts requests, so choosing the selected frame again zooms to it too.
 * `zoomToSelection` zooms to the selected frame.
 */
export function useShowFrame({
  canvas,
  body,
  frames,
  selected,
  select,
}: {
  readonly canvas: RefObject<CanvasHandle | null>;
  /** What holds the canvas and its panels, `<aside>`s, beside it. */
  readonly body: RefObject<HTMLElement | null>;
  /** What can be selected. */
  readonly frames: ReadonlyArray<Frame>;
  /** The selected tile's ID. */
  readonly selected: string | undefined;
  readonly select: (tile: Tile) => void;
}) {
  // What the panels shown over the canvas cover of it.
  const covered = useCallback((): Insets => {
    let insets = { left: 0, right: 0 };
    for (const panel of body.current?.querySelectorAll<HTMLElement>(":scope > aside") ?? []) {
      if (getComputedStyle(panel).position !== "absolute") continue;
      insets =
        panel.offsetLeft === 0
          ? { ...insets, left: panel.offsetWidth }
          : { ...insets, right: panel.offsetWidth };
    }
    return insets;
  }, [body]);

  const toShow = useRef<ToShow | undefined>(undefined);
  const [shows, setShows] = useState(0);
  const show = useCallback(
    (tile: Tile, zoom: boolean) => {
      toShow.current = { id: tileId(tile), zoom, from: selected };
      select(tile);
      setShows((count) => count + 1);
    },
    [select, selected],
  );
  useEffect(() => {
    const target = toShow.current;
    if (target === undefined) return;
    if (selected !== target.id) {
      // Not selected yet; or selected, then something else was, so it's dropped.
      if (selected !== target.from) toShow.current = undefined;
      return;
    }
    toShow.current = undefined;
    // A stepped flowchart screen's frame shows the state it was stepped to.
    const frame = frameOf(frames, target.id);
    if (frame === undefined) return;
    const next = requestAnimationFrame(() =>
      target.zoom
        ? canvas.current?.zoomTo(frame.box, covered())
        : canvas.current?.reveal(frame.box, covered()),
    );
    return () => cancelAnimationFrame(next);
  }, [shows, selected, frames, canvas, covered]);

  const selectedFrame = frameOf(frames, selected);
  const zoomToSelection = useCallback(() => {
    if (selectedFrame !== undefined) canvas.current?.zoomTo(selectedFrame.box, covered());
  }, [selectedFrame, canvas, covered]);

  return { show, zoomToSelection };
}
