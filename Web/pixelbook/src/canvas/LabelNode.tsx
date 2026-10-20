// The canvas's text labels: an app's name, a screen's, and captions.
import type { NodeProps } from "@xyflow/react";
import type { LabelNode } from "../lib/Elements.ts";
import type { Label } from "../lib/Grid.ts";

/** A label's type, by its kind: sized to read on the zoomed-out canvas. */
const labelStyles: Record<Label["kind"], string> = {
  app: "text-[112px] leading-none font-bold",
  screen: "text-[56px] leading-none font-semibold text-secondary",
  caption: "text-[28px] font-semibold text-secondary",
};

export function LabelNodeView({ data: { label } }: NodeProps<LabelNode>) {
  return <div className={`whitespace-nowrap ${labelStyles[label.kind]}`}>{label.text}</div>;
}
