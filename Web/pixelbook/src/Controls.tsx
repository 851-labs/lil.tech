// Controls shared by the header and the panels: links out, buttons and segmented controls.

/** A link out of Pixelbook, such as to GitHub. It opens in a new tab, keeping the canvas where it is. */
export function ExternalLink(props: Omit<React.ComponentProps<"a">, "target" | "rel">) {
  return <a {...props} target="_blank" rel="noreferrer" />;
}

/** A small button, as Linear's: zoom, Show all and the like. */
export const plainButton =
  "flex h-6 cursor-pointer items-center rounded-chip border border-border px-2 text-mini font-medium text-muted hover:bg-hover";

/** A choice of a few options, one of them on, as Linear's segmented controls. */
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
    <div
      className="flex w-fit rounded-control border border-border p-0.5"
      role="group"
      aria-label={label}
    >
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          className={`h-6 cursor-pointer rounded-chip px-2.5 text-mini font-medium ${value === option.value ? "bg-selected text-foreground" : "text-secondary hover:bg-hover hover:text-muted"}`}
          aria-pressed={value === option.value}
          onClick={() => onChange(option.value)}
        >
          {option.name}
        </button>
      ))}
    </div>
  );
}
