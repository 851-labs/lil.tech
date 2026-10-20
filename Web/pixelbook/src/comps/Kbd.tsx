/** A key, or keys, to press: a key cap, or `plain` in running text. */
export function Kbd({
  plain = false,
  children,
}: {
  readonly plain?: boolean;
  readonly children: React.ReactNode;
}) {
  return (
    <kbd
      className={
        plain
          ? "font-sans"
          : "rounded-chip border border-border bg-background px-1.5 py-0.5 font-sans text-mini whitespace-nowrap"
      }
    >
      {children}
    </kbd>
  );
}
