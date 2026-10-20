import { Tooltip as BaseTooltip } from "@base-ui/react/tooltip";
import { Kbd } from "./Kbd.tsx";

/**
 * A hint for a control, such as what a zoom button does and its key, shown on hover or keyboard
 * focus: Base UI's Tooltip. Sighted mouse and keyboard users see it, so the control keeps its own
 * name (`aria-label`, or its text). Other props go to the control, so another trigger, such as a
 * dialog's, can render it.
 */
export function Tooltip({
  label,
  keys,
  children,
  ...props
}: Omit<BaseTooltip.Trigger.Props, "render" | "children"> & {
  readonly label: React.ReactNode;
  /** Its keyboard shortcut, as a key cap after the label. */
  readonly keys?: string;
  /** The control, which takes the trigger's props and ref. */
  readonly children: React.ReactElement;
}) {
  return (
    <BaseTooltip.Root>
      <BaseTooltip.Trigger {...props} render={children} />
      <BaseTooltip.Portal>
        <BaseTooltip.Positioner className="z-10" sideOffset={6} collisionPadding={8}>
          <BaseTooltip.Popup className="flex items-center gap-1.5 rounded-chip border border-border bg-surface px-2 py-1 text-mini text-foreground shadow-popover">
            {label}
            {keys !== undefined && <Kbd>{keys}</Kbd>}
          </BaseTooltip.Popup>
        </BaseTooltip.Positioner>
      </BaseTooltip.Portal>
    </BaseTooltip.Root>
  );
}

/** Around the page: once one tooltip shows, the next shows without waiting. */
export function TooltipProvider({ children }: { readonly children: React.ReactNode }) {
  return <BaseTooltip.Provider delay={500}>{children}</BaseTooltip.Provider>;
}
