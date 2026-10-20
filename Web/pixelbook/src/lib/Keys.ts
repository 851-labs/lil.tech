// What the canvas's keyboard shortcuts go by: which way an arrow key moves, and which keys are
// someone typing or scrolling a panel rather than shortcuts.
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

/** Whether a key goes to a field being typed in, rather than to the canvas. */
export const isTyping = (target: EventTarget | null) =>
  target instanceof HTMLElement &&
  (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName));
