// Buttons shared by the header and the panels.

/** A small button, as Linear's: zoom, Show all and the like. For a link that looks like one, too. */
export const plainButton =
  "flex h-6 cursor-pointer items-center rounded-chip border border-border px-2 text-mini font-medium text-muted hover:bg-hover";

/** A borderless square button for a glyph, such as a panel's ×. */
const iconButton =
  "flex size-7 cursor-pointer items-center justify-center rounded-control text-large leading-none text-secondary hover:bg-hover hover:text-foreground";

const variants = { plain: plainButton, icon: iconButton };

/** A button, plain by default; `className` adds to its variant's classes. */
export function Button({
  variant = "plain",
  className,
  ...props
}: Omit<React.ComponentProps<"button">, "type"> & {
  readonly variant?: keyof typeof variants;
}) {
  return (
    <button
      type="button"
      className={className === undefined ? variants[variant] : `${variants[variant]} ${className}`}
      {...props}
    />
  );
}
