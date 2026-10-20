import { Fragment } from "react";
import { Button } from "../comps/Button.tsx";
import { Kbd } from "../comps/Kbd.tsx";

/** The canvas's keyboard shortcuts, and the rest of its input, for the list `?` opens. */
const shortcuts: ReadonlyArray<readonly [keys: string, action: string]> = [
  ["← ↑ → ↓", "Select the nearest frame that way"],
  ["Esc", "Deselect"],
  ["⇧1", "Show everything"],
  ["⇧2", "Zoom to the selection"],
  ["+ and −", "Zoom in and out, with or without ⌘"],
  ["Drag or scroll", "Pan, also while holding Space"],
  ["Pinch or ⌘-scroll", "Zoom"],
  ["?", "Show or hide these shortcuts"],
];

export function ShortcutsHelp({ onClose }: { readonly onClose: () => void }) {
  return (
    // A click outside it closes it.
    <div className="absolute inset-0 z-4 flex items-center justify-center" onClick={onClose}>
      <div
        role="dialog"
        aria-label="Keyboard shortcuts"
        className="w-[380px] max-w-[calc(100vw-32px)] rounded-control border border-border bg-surface p-4 shadow-popover"
        onClick={(event) => event.stopPropagation()}
      >
        <header className="mb-3 flex items-center justify-between">
          <h2 className="text-small font-semibold">Keyboard shortcuts</h2>
          <Button onClick={onClose} aria-label="Close">
            ×
          </Button>
        </header>
        <dl className="grid grid-cols-[auto_1fr] items-baseline gap-x-4 gap-y-2 text-small">
          {shortcuts.map(([keys, action]) => (
            <Fragment key={keys}>
              <dt>
                <Kbd>{keys}</Kbd>
              </dt>
              <dd className="text-secondary">{action}</dd>
            </Fragment>
          ))}
        </dl>
      </div>
    </div>
  );
}
