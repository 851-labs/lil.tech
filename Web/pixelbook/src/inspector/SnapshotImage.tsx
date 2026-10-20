import { imageUrl, type Variant } from "../lib/Snapshots.ts";

/** A variant's size in points. */
export const points = (variant: Variant) => ({
  width: variant.width / variant.scale,
  height: variant.height / variant.scale,
});

/** A snapshot at its size in points, or the panel's width if that's smaller. */
export function SnapshotImage({
  variant,
  background,
  alt,
  className = "",
  style,
}: {
  readonly variant: Variant;
  readonly background: string;
  readonly alt: string;
  readonly className?: string;
  readonly style?: React.CSSProperties;
}) {
  return (
    <img
      className={`max-w-full rounded-control shadow-[0_0_0_1px_var(--color-border)] ${background} ${className}`}
      src={imageUrl(variant)}
      alt={alt}
      draggable={false}
      style={{
        width: points(variant).width,
        aspectRatio: `${variant.width} / ${variant.height}`,
        ...style,
      }}
    />
  );
}
