// The canvas's keyboard shortcuts: which a key press is, which way an arrow key moves, and which
// keys are someone typing or scrolling a panel rather than shortcuts.
import type { Direction } from "./Selection.ts";

export const arrowDirections: Partial<Record<string, Direction>> = {
  ArrowLeft: "left",
  ArrowRight: "right",
  ArrowUp: "up",
  ArrowDown: "down",
};

/** Whether a key goes to a panel beside the canvas, such as the inspector, which it may scroll. */
export const inPanel = (target: EventTarget | null) =>
  target instanceof Element && target.closest("aside") !== null;

/** Whether a key goes to a group of controls, such as a segmented control, rather than the canvas. */
export const inGroup = (target: EventTarget | null) =>
  target instanceof Element && target.closest('[role="group"]') !== null;

/** Whether a key goes to a field being typed in, rather than to the canvas. */
export const isTyping = (target: EventTarget | null) =>
  target instanceof HTMLElement &&
  (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName));

/** A key press, as the shortcuts go by it: a `KeyboardEvent`'s fields. */
export interface KeyPress {
  readonly key: string;
  readonly code: string;
  readonly shiftKey: boolean;
  readonly metaKey: boolean;
  readonly ctrlKey: boolean;
  readonly altKey: boolean;
  readonly repeat: boolean;
}

/** What a shortcut does. */
export type Shortcut =
  | { readonly action: "help" }
  | { readonly action: "deselect" }
  | { readonly action: "move"; readonly direction: Direction }
  | { readonly action: "fit" }
  | { readonly action: "zoomToSelection" }
  | { readonly action: "zoomIn" }
  | { readonly action: "zoomOut" };

/**
 * The shortcut a key press is, if any, while the list of shortcuts is shown or not: `?` shows or
 * hides the list, and the rest wait until it's closed (its dialog closes on Escape, so that doesn't
 * deselect too). Escape deselects, the arrow keys move the selection, ⇧1 shows everything, ⇧2 zooms
 * to the selection, and + and − zoom, with ⌘ too, rather than the browser zooming the page. Other
 * shortcuts with modifiers are the browser's or the system's.
 */
export const shortcutFor = (press: KeyPress, helpShown: boolean): Shortcut | undefined => {
  const plain = !press.metaKey && !press.ctrlKey && !press.altKey;
  const direction = arrowDirections[press.key];
  if (press.key === "?" && plain) return press.repeat ? undefined : { action: "help" };
  if (helpShown) return undefined;
  if (press.key === "Escape") return { action: "deselect" };
  if (direction !== undefined && plain && !press.shiftKey) return { action: "move", direction };
  if (plain && press.shiftKey && press.code === "Digit1") return { action: "fit" };
  if (plain && press.shiftKey && press.code === "Digit2") return { action: "zoomToSelection" };
  if ((press.key === "+" || press.key === "=") && !press.altKey) return { action: "zoomIn" };
  if ((press.key === "-" || press.key === "_") && !press.altKey) return { action: "zoomOut" };
  return undefined;
};
