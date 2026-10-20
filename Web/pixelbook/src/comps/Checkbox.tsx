import { CheckIcon } from "./Icons.tsx";

/** A row that toggles something on or off, with a checkbox before its label, as the filters'. */
export function Checkbox({
  checked,
  onClick,
  children,
}: {
  readonly checked: boolean;
  readonly onClick: () => void;
  readonly children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      className={`flex h-7 cursor-pointer items-center gap-2 rounded-chip px-2 text-left text-small hover:bg-hover ${checked ? "text-foreground" : "text-secondary"}`}
      aria-pressed={checked}
      onClick={onClick}
    >
      <span
        className={`flex size-3.5 shrink-0 items-center justify-center rounded-[4px] border ${checked ? "border-accent bg-accent text-white" : "border-border"}`}
        aria-hidden="true"
      >
        {checked && <CheckIcon />}
      </span>
      <span className="truncate">{children}</span>
    </button>
  );
}
