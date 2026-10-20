import { Toggle } from "@base-ui/react/toggle";
import { ToggleGroup } from "@base-ui/react/toggle-group";
import { focusRing } from "./Focus.ts";

/**
 * A choice of a few options, one of them on, as Linear's segmented controls: Base UI's Toggle
 * Group, where the arrow keys move between options and Space or Enter chooses one.
 */
export function Segmented<A extends string>({
  label,
  options,
  value,
  onChange,
}: {
  readonly label: string;
  readonly options: ReadonlyArray<{ readonly value: A; readonly name: string }>;
  readonly value: A;
  readonly onChange: (value: A) => void;
}) {
  return (
    <ToggleGroup
      className="flex w-fit rounded-control border border-border p-0.5"
      aria-label={label}
      value={[value]}
      onValueChange={(values) => {
        // Pressing the chosen option again would leave none on.
        const chosen = options.find((option) => values.includes(option.value));
        if (chosen !== undefined) onChange(chosen.value);
      }}
    >
      {options.map((option) => (
        <Toggle
          key={option.value}
          value={option.value}
          className={`h-6 cursor-pointer rounded-chip px-2.5 text-mini font-medium text-secondary not-data-pressed:hover:bg-hover not-data-pressed:hover:text-muted data-pressed:bg-selected data-pressed:text-foreground ${focusRing}`}
        >
          {option.name}
        </Toggle>
      ))}
    </ToggleGroup>
  );
}
