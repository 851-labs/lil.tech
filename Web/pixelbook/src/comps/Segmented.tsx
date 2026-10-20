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
