// A two-column list of names and values, such as the inspector's details.

/** The list: names, then values to their right; a list of counts aligns them right. */
export function DetailList({
  numeric = false,
  children,
}: {
  readonly numeric?: boolean;
  readonly children: React.ReactNode;
}) {
  return (
    <dl
      className={
        numeric ? "grid grid-cols-[1fr_auto] gap-y-1" : "grid grid-cols-[auto_1fr] gap-x-3 gap-y-1"
      }
    >
      {children}
    </dl>
  );
}

/** A row of a two-column list: a count's value aligns right. */
export function Detail({
  name,
  numeric = false,
  children,
}: {
  readonly name: string;
  readonly numeric?: boolean;
  readonly children: React.ReactNode;
}) {
  return (
    <>
      <dt className="text-secondary">{name}</dt>
      <dd className={numeric ? "text-right tabular-nums" : "[overflow-wrap:anywhere]"}>
        {children}
      </dd>
    </>
  );
}
