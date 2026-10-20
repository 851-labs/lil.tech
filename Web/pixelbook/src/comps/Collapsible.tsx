import { Collapsible as BaseCollapsible } from "@base-ui/react/collapsible";
import { ChevronIcon } from "./Icons.tsx";

/**
 * A row that shows or hides what's under it, with a disclosure chevron before its label, as the
 * layers list's apps and screens: Base UI's Collapsible, whose open state the caller keeps.
 */
export function Collapsible({
  open,
  onOpenChange,
  label,
  className,
  onClick,
  children,
}: {
  readonly open: boolean;
  readonly onOpenChange: (open: boolean) => void;
  /** The row's content, after the chevron. */
  readonly label: React.ReactNode;
  /** The row's classes. */
  readonly className: string;
  readonly onClick?: (event: React.MouseEvent<HTMLElement>) => void;
  /** What it shows when open. */
  readonly children: React.ReactNode;
}) {
  return (
    <BaseCollapsible.Root open={open} onOpenChange={onOpenChange}>
      <BaseCollapsible.Trigger className={className} onClick={onClick}>
        <ChevronIcon open={open} />
        {label}
      </BaseCollapsible.Trigger>
      <BaseCollapsible.Panel>{children}</BaseCollapsible.Panel>
    </BaseCollapsible.Root>
  );
}
