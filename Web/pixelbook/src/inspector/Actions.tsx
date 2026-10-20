import { useEffect, useState } from "react";
import { Button, plainButton } from "../comps/Button.tsx";
import { ExternalLink } from "../comps/ExternalLink.tsx";
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
      <Button onClick={onZoomTo} title="Zoom to it (⇧2)">
        Zoom to
      </Button>
      <ExternalLink className={`${plainButton} hover:no-underline`} href={imageUrl(image)}>
        Open image
      </ExternalLink>
      <Button onClick={() => void copy()}>{copied ?? "Copy link"}</Button>
    </div>
  );
}
