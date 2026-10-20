import { useRef } from "react";

/**
 * The left sidebar, such as what to show on the canvas. Its right edge drags to resize it. Narrow
 * windows show it over the canvas.
 */
export function Sidebar({
  label,
  width,
  onResize,
  onResized,
  hiddenWhenNarrow,
  children,
}: {
  readonly label: string;
  readonly width: number;
  readonly onResize: (width: number) => void;
  /** Once a drag ends, with the width it ended at. */
  readonly onResized: (width: number) => void;
  readonly hiddenWhenNarrow: boolean;
  readonly children: React.ReactNode;
}) {
  const start = useRef<{ x: number; width: number } | null>(null);
  const latest = useRef(width);
  latest.current = width;
  return (
    <aside
      className={`relative flex max-w-[calc(100vw-48px)] shrink-0 border-r border-border bg-surface max-[899px]:absolute max-[899px]:inset-y-0 max-[899px]:left-0 max-[899px]:z-3 max-[899px]:shadow-popover ${hiddenWhenNarrow ? "max-[899px]:hidden" : ""}`}
      style={{ width }}
      aria-label={label}
    >
      <div className="flex min-w-0 flex-1 flex-col gap-4 overflow-auto px-2 py-3">{children}</div>
      <div
        className="absolute inset-y-0 right-0 w-1.5 cursor-col-resize hover:bg-accent/20"
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize the sidebar"
        onPointerDown={(event) => {
          if (event.button !== 0 || !event.isPrimary) return;
          // Not a text selection across the sidebar.
          event.preventDefault();
          event.currentTarget.setPointerCapture(event.pointerId);
          start.current = { x: event.clientX, width };
        }}
        onPointerMove={(event) => {
          if (start.current === null) return;
          onResize(start.current.width + event.clientX - start.current.x);
        }}
        onPointerUp={() => {
          if (start.current === null) return;
          start.current = null;
          onResized(latest.current);
        }}
        onPointerCancel={() => (start.current = null)}
      />
    </aside>
  );
}
