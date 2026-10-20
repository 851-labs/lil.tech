import { Dialog as BaseDialog } from "@base-ui/react/dialog";
import { Button } from "./Button.tsx";

/** Where focus goes once it closes: an element, `true` for its trigger, or `false` to leave it. */
export type DialogFinalFocus = NonNullable<BaseDialog.Popup.Props["finalFocus"]>;

/**
 * A dialog over the page, such as the keyboard shortcuts: Base UI's Dialog. It keeps focus while
 * open, closes with Escape (marking the key handled), its × or a click outside, and gives focus
 * back to its trigger, or to `finalFocus`.
 */
export function Dialog({
  title,
  open,
  onOpenChange,
  finalFocus,
  trigger,
  children,
}: {
  readonly title: string;
  readonly open: boolean;
  readonly onOpenChange: (open: boolean) => void;
  readonly finalFocus?: DialogFinalFocus;
  /** The button that opens it, which takes the trigger's props and ref. */
  readonly trigger: React.ReactElement;
  readonly children: React.ReactNode;
}) {
  return (
    <BaseDialog.Root open={open} onOpenChange={onOpenChange}>
      <BaseDialog.Trigger render={trigger} />
      <BaseDialog.Portal>
        <BaseDialog.Popup
          finalFocus={finalFocus}
          className="fixed top-1/2 left-1/2 z-10 w-[380px] max-w-[calc(100vw-32px)] -translate-x-1/2 -translate-y-1/2 rounded-control border border-border bg-surface p-4 shadow-popover"
        >
          <header className="mb-3 flex items-center justify-between">
            <BaseDialog.Title className="text-small font-semibold">{title}</BaseDialog.Title>
            <BaseDialog.Close render={<Button aria-label="Close" />}>×</BaseDialog.Close>
          </header>
          {children}
        </BaseDialog.Popup>
      </BaseDialog.Portal>
    </BaseDialog.Root>
  );
}
