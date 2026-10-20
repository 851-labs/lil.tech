import { Checkbox as BaseCheckbox } from "@base-ui/react/checkbox";
import { focusRingInset } from "./Focus.ts";
import { CheckIcon } from "./Icons.tsx";

/**
 * A row that turns something on or off, with a checkbox before its label, as the filters': Base
 * UI's Checkbox, the whole row a native button that's checked or not.
 */
export function Checkbox({
  checked,
  onCheckedChange,
  children,
}: {
  readonly checked: boolean;
  readonly onCheckedChange: (checked: boolean) => void;
  readonly children: React.ReactNode;
}) {
  return (
    <BaseCheckbox.Root
      checked={checked}
      onCheckedChange={onCheckedChange}
      nativeButton
      render={<button type="button" />}
      className={`group flex h-7 cursor-pointer items-center gap-2 rounded-chip px-2 text-left text-small text-secondary hover:bg-hover data-checked:text-foreground ${focusRingInset}`}
    >
      <span
        className="flex size-3.5 shrink-0 items-center justify-center rounded-[4px] border border-border group-data-checked:border-accent group-data-checked:bg-accent group-data-checked:text-white"
        aria-hidden="true"
      >
        <BaseCheckbox.Indicator className="flex">
          <CheckIcon />
        </BaseCheckbox.Indicator>
      </span>
      <span className="truncate">{children}</span>
    </BaseCheckbox.Root>
  );
}
