/** A panel on the canvas's right, such as the inspector. Narrow windows show it over the canvas. */
const panel =
  "flex w-[400px] max-w-full shrink-0 flex-col gap-4 overflow-auto border-l border-border bg-surface p-4 max-lg:absolute max-lg:inset-y-0 max-lg:right-0 max-lg:z-3 max-lg:shadow-popover";

export function Panel({
  label,
  className,
  children,
}: {
  readonly label: string;
  /** Adds to the panel's classes. */
  readonly className?: string;
  readonly children: React.ReactNode;
}) {
  return (
    <aside className={className === undefined ? panel : `${panel} ${className}`} aria-label={label}>
      {children}
    </aside>
  );
}
