import { type RefObject, useEffect } from "react";
import type { CanvasHandle } from "../canvas/Canvas.tsx";
import type { Tile } from "../lib/Grid.ts";
import { inGroup, inPanel, isTyping, shortcutFor } from "../lib/Keys.ts";
import { type Frame, frameOf, frameToward } from "../lib/Selection.ts";

/**
 * The canvas's keyboard shortcuts, on the window (`shortcutFor` says which key does what). Keys
 * typed into a field aren't shortcuts, and the arrow keys are left to the sidebar and inspector,
 * which they scroll, and to segmented controls, where they choose.
 */
export function useShortcuts({
  canvas,
  frames,
  selected,
  show,
  deselect,
  zoomToSelection,
  help,
}: {
  readonly canvas: RefObject<CanvasHandle | null>;
  /** What the arrow keys move between. */
  readonly frames: ReadonlyArray<Frame>;
  /** The selected tile's ID. */
  readonly selected: string | undefined;
  /** Selects a tile and pans to it. */
  readonly show: (tile: Tile, zoom: boolean) => void;
  readonly deselect: () => void;
  readonly zoomToSelection: () => void;
  /** The list of shortcuts, which `?` opens and closes. */
  readonly help: { readonly open: boolean; readonly change: (open: boolean) => void };
}) {
  const { open: helpShown, change: changeHelp } = help;
  useEffect(() => {
    const keydown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || isTyping(event.target)) return;
      const shortcut = shortcutFor(event, helpShown);
      const view = canvas.current;
      switch (shortcut?.action) {
        case "help":
          changeHelp(!helpShown);
          break;
        case "move": {
          if (inPanel(event.target) || inGroup(event.target)) return;
          const next = frameToward(frames, frameOf(frames, selected), shortcut.direction);
          if (next === undefined) return;
          // So Space or Enter doesn't press a tile clicked before.
          const focused = document.activeElement;
          if (focused instanceof HTMLElement && focused.closest(".react-flow") !== null)
            focused.blur();
          show(next.tile, false);
          break;
        }
        case "fit":
          view?.fit();
          break;
        case "zoomToSelection":
          zoomToSelection();
          break;
        case "zoomIn":
          view?.zoomBy(1.5);
          break;
        case "zoomOut":
          view?.zoomBy(1 / 1.5);
          break;
        // Escape is `escape`'s, below.
        case "deselect":
        case undefined:
          return;
      }
      event.preventDefault();
    };
    // Escape deselects before anything else sees it: an open tooltip (Base UI's) takes the key,
    // which would otherwise make deselecting take two. The tooltip still closes.
    const escape = (event: KeyboardEvent) => {
      if (isTyping(event.target) || shortcutFor(event, helpShown)?.action !== "deselect") return;
      if (selected !== undefined) deselect();
    };
    window.addEventListener("keydown", keydown);
    window.addEventListener("keydown", escape, { capture: true });
    return () => {
      window.removeEventListener("keydown", keydown);
      window.removeEventListener("keydown", escape, { capture: true });
    };
  }, [canvas, frames, selected, show, deselect, zoomToSelection, helpShown, changeHelp]);
}
