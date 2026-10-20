import { Checkbox } from "../comps/Checkbox.tsx";
import { SectionTitle } from "../comps/SectionTitle.tsx";

/** A filter's choices, as a list in the sidebar: each one on unless chosen otherwise. */
export function FilterList<A extends string>({
  label,
  values,
  chosen,
  name,
  onToggle,
}: {
  readonly label: string;
  readonly values: ReadonlyArray<A>;
  readonly chosen: ReadonlyArray<A>;
  readonly name: (value: A) => string;
  readonly onToggle: (value: A) => void;
}) {
  return (
    <section className="flex flex-col gap-0.5" aria-label={label}>
      <SectionTitle in="sidebar">{label}</SectionTitle>
      {values.map((value) => (
        <Checkbox
          key={value}
          checked={chosen.length === 0 || chosen.includes(value)}
          // The filter toggles it, and keeps the last one on.
          onCheckedChange={() => onToggle(value)}
        >
          {name(value)}
        </Checkbox>
      ))}
    </section>
  );
}
