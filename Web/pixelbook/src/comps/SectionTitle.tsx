/**
 * A section's title: a sidebar's list's (an `h2`, inset to its rows' text), or a panel's (an `h3`,
 * under the panel's own title).
 */
export function SectionTitle({
  in: place = "panel",
  children,
}: {
  readonly in?: "sidebar" | "panel";
  readonly children: React.ReactNode;
}) {
  return place === "sidebar" ? (
    <h2 className="px-2 pb-1 text-mini font-medium text-secondary">{children}</h2>
  ) : (
    <h3 className="text-mini font-medium text-secondary">{children}</h3>
  );
}
