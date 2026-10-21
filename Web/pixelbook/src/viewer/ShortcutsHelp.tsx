import { Fragment } from "react";
import { Button } from "../comps/Button.tsx";
import { Dialog, type DialogFinalFocus } from "../comps/Dialog.tsx";
import { Kbd } from "../comps/Kbd.tsx";
import { Tooltip } from "../comps/Tooltip.tsx";

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

/** The header's `?` button, and the list of shortcuts it opens, as `?` does. */
export function ShortcutsHelp({
  open,
  onOpenChange,
  finalFocus,
}: {
  readonly open: boolean;
  readonly onOpenChange: (open: boolean, trigger: Element | undefined) => void;
  readonly finalFocus: DialogFinalFocus;
}) {
  return (
    <Dialog
      title="Keyboard shortcuts"
      open={open}
      onOpenChange={onOpenChange}
      finalFocus={finalFocus}
      trigger={
        <Tooltip label="Keyboard shortcuts" keys="?">
          <Button aria-label="Keyboard shortcuts" aria-keyshortcuts="?">
            ?
          </Button>
        </Tooltip>
      }
    >
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
    </Dialog>
  );
}
