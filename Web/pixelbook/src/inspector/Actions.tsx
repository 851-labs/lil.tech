import { useEffect, useState } from "react";
import { Button, ButtonLink } from "../comps/Button.tsx";
import { Tooltip } from "../comps/Tooltip.tsx";
import { imageUrl, type Variant } from "../lib/Snapshots.ts";

/** Zoom to the frame, open its image full size, or copy a link to it. */
export function Actions({
  image,
  onZoomTo,
}: {
  readonly image: Variant;
  readonly onZoomTo: () => void;
}) {
  // How copying the link went, said for a moment.
  const [copied, setCopied] = useState<"Copied" | "Couldn't copy">();
  useEffect(() => {
    if (copied === undefined) return;
    const timeout = setTimeout(() => setCopied(undefined), 1500);
    return () => clearTimeout(timeout);
  }, [copied]);
  const copy = async () => {
    try {
      // Missing outside secure contexts, such as a dev server on another machine's address.
      if (navigator.clipboard === undefined) throw new Error("No clipboard");
      await navigator.clipboard.writeText(window.location.href);
      setCopied("Copied");
    } catch {
      setCopied("Couldn't copy");
    }
  };
  return (
    <div className="flex flex-wrap gap-1.5">
      <Tooltip label="Zoom to it" keys="⇧2">
        <Button onClick={onZoomTo} aria-keyshortcuts="Shift+2">
          Zoom to
        </Button>
      </Tooltip>
      <ButtonLink href={imageUrl(image)}>Open image</ButtonLink>
      <Button onClick={() => void copy()}>{copied ?? "Copy link"}</Button>
    </div>
  );
}
