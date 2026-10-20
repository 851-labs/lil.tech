import { useState } from "react";
import { SectionTitle } from "../comps/SectionTitle.tsx";
import { Segmented } from "../comps/Segmented.tsx";
import type { Variant } from "../lib/Snapshots.ts";
import { points, SnapshotImage } from "./SnapshotImage.tsx";

type CompareMode = "sides" | "overlay" | "slider";

const compareModes: ReadonlyArray<{ readonly value: CompareMode; readonly name: string }> = [
  { value: "sides", name: "Side by side" },
  { value: "overlay", name: "Overlay" },
  { value: "slider", name: "Slider" },
];

/**
 * A changed snapshot's before and after: one above the other, the after over the before with an
 * opacity to fade between them, or split by a divider to drag across.
 */
export function Compare({
  before,
  after,
  background,
  alt,
}: {
  readonly before: Variant;
  readonly after: Variant;
  readonly background: string;
  readonly alt: string;
}) {
  const [mode, setMode] = useState<CompareMode>("sides");
  const box = {
    width: Math.max(points(before).width, points(after).width),
    height: Math.max(points(before).height, points(after).height),
  };
  // The after's opacity, or where the divider is, in percent.
  const [amount, setAmount] = useState(50);
  return (
    <>
      <Segmented label="Compare" options={compareModes} value={mode} onChange={setMode} />
      {mode === "sides" ? (
        <>
          <SectionTitle>Before</SectionTitle>
          <SnapshotImage variant={before} background={background} alt={`${alt}, before`} />
          <SectionTitle>After</SectionTitle>
          <SnapshotImage variant={after} background={background} alt={`${alt}, after`} />
        </>
      ) : (
        <>
          <label className="flex items-center gap-2 text-mini text-secondary">
            Before
            <input
              className="flex-1 accent-accent"
              type="range"
              min={0}
              max={100}
              value={amount}
              onChange={(event) => setAmount(Number(event.target.value))}
              aria-label={mode === "overlay" ? "After's opacity" : "Divider"}
            />
            After
          </label>
          {/* Both in one box as large as the larger, at the same scale, from its top left. */}
          <div
            className="relative w-full"
            style={{ maxWidth: box.width, aspectRatio: `${box.width} / ${box.height}` }}
          >
            <SnapshotImage
              variant={before}
              background={background}
              alt={`${alt}, before`}
              className="absolute top-0 left-0"
              style={{ width: `${(points(before).width / box.width) * 100}%` }}
            />
            <SnapshotImage
              variant={after}
              background={background}
              alt={`${alt}, after`}
              className="absolute top-0 left-0"
              style={{
                width: `${(points(after).width / box.width) * 100}%`,
                // The divider shows the after to its left and the before to its right.
                ...(mode === "overlay"
                  ? { opacity: amount / 100 }
                  : { clipPath: `inset(0 ${100 - amount}% 0 0)` }),
              }}
            />
            {mode === "slider" && (
              <div
                className="pointer-events-none absolute inset-y-0 w-0.5 -translate-x-1/2 bg-accent"
                // Where the after's clip ends, in the box.
                style={{ left: `${(amount * points(after).width) / box.width}%` }}
              />
            )}
          </div>
        </>
      )}
    </>
  );
}
