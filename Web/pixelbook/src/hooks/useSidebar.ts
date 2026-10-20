import { useCallback, useEffect, useState } from "react";
import { storage } from "../lib/Storage.ts";

/** The sidebar's width, in CSS pixels: as Linear's, and how far it can be dragged. */
const sidebarWidth = { initial: 244, min: 200, max: 400 };
/** Narrower than this, the sidebar starts hidden, so the canvas has the room. */
const narrowQuery = "(max-width: 899px)";
const widthKey = "pixelbook.sidebarWidth";

/**
 * Whether the sidebar shows, and how wide it is. `open` is `undefined` until it's toggled: then it
 * shows only in wide windows, by CSS, so it doesn't flash before the page knows the window's
 * width. Its width is remembered across visits.
 */
export function useSidebar() {
  const [open, setOpen] = useState<boolean>();
  const [width, setWidth] = useState(sidebarWidth.initial);
  useEffect(() => {
    const stored = Number(storage.get(widthKey));
    if (stored >= sidebarWidth.min && stored <= sidebarWidth.max) setWidth(stored);
  }, []);
  const resize = useCallback((to: number) => {
    setWidth(Math.round(Math.min(sidebarWidth.max, Math.max(sidebarWidth.min, to))));
  }, []);
  const remember = useCallback((width: number) => storage.set(widthKey, String(width)), []);
  const toggle = useCallback(
    () => setOpen((open) => !(open ?? !window.matchMedia(narrowQuery).matches)),
    [],
  );
  return { open, width, resize, remember, toggle };
}
