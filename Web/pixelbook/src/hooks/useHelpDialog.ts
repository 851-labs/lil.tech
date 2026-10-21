import { useCallback, useRef, useState } from "react";
import type { DialogFinalFocus } from "../comps/Dialog.tsx";

/**
 * Whether the list of shortcuts is open, and where focus goes when it closes: back to what opened
 * it. Opening records it: the header's `?` button, when that's pressed, or what had focus when `?`
 * was, such as the canvas. Focus stays where it is if that was nothing.
 */
export function useHelpDialog() {
  const [open, setOpen] = useState(false);
  const opener = useRef<Element | null>(null);
  /** Opens or closes it; opening from `from`, by default what has focus. */
  const change = useCallback((open: boolean, from: Element | null = document.activeElement) => {
    if (open) opener.current = from;
    setOpen(open);
  }, []);
  const finalFocus: DialogFinalFocus = useCallback(() => {
    const from = opener.current;
    // Forgotten once used, so it doesn't keep an element the page has since removed.
    opener.current = null;
    return from instanceof HTMLElement && from !== document.body ? from : false;
  }, []);
  return { open, change, finalFocus };
}
