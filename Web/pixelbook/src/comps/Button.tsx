// Buttons shared by the header and the panels, on Base UI's Button, and links that look like them.
import { Button as BaseButton } from "@base-ui/react/button";
import { ExternalLink } from "./ExternalLink.tsx";
import { focusRing } from "./Focus.ts";

const base = `cursor-pointer ${focusRing}`;

const variants = {
  /** A small button, as Linear's: zoom, Show all and the like. */
  plain: `${base} flex h-6 items-center rounded-chip border border-border px-2 text-mini font-medium text-muted hover:bg-hover`,
  /** A borderless square button for a glyph, such as a panel's ×. */
  icon: `${base} flex size-7 items-center justify-center rounded-control text-large leading-none text-secondary hover:bg-hover hover:text-foreground`,
};

type Variant = keyof typeof variants;

const classes = (variant: Variant, className: string | undefined) =>
  className === undefined ? variants[variant] : `${variants[variant]} ${className}`;

/** A button, plain by default; `className` adds to its variant's classes. */
export function Button({
  variant = "plain",
  className,
  ...props
}: Omit<BaseButton.Props, "type" | "className"> & {
  readonly variant?: Variant;
  readonly className?: string;
}) {
  return <BaseButton type="button" className={classes(variant, className)} {...props} />;
}

/**
 * A link out of Pixelbook that looks like a button, such as the inspector's Open image. Still a
 * link, so it opens in a new tab or copies as one.
 */
export function ButtonLink({
  variant = "plain",
  className,
  ...props
}: Omit<React.ComponentProps<typeof ExternalLink>, "className"> & {
  readonly variant?: Variant;
  readonly className?: string;
}) {
  return (
    <ExternalLink className={`${classes(variant, className)} hover:no-underline`} {...props} />
  );
}
