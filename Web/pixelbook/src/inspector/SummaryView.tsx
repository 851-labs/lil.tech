import { Detail, DetailList } from "../comps/Detail.tsx";
import { ExternalLink } from "../comps/ExternalLink.tsx";
import { Kbd } from "../comps/Kbd.tsx";
import { SectionTitle } from "../comps/SectionTitle.tsx";
import { commitUrl, compareUrl } from "../lib/Snapshots.ts";
import type { Summary } from "./Inspector.tsx";

/** With nothing selected: what the canvas shows, from which commit, and in a comparison, what changed. */
export function SummaryView({ summary }: { readonly summary: Summary }) {
  return (
    <>
      <header>
        <h2 className="text-regular font-semibold text-foreground">
          {summary.ref === undefined ? "Snapshots" : summary.ref}
        </h2>
        <p className="mt-0.5 text-secondary">
          {summary.shown} from{" "}
          <ExternalLink className="font-mono text-mini" href={commitUrl(summary.commit)}>
            {summary.commit.slice(0, 7)}
          </ExternalLink>
        </p>
      </header>
      {summary.comparison !== undefined && (
        <section className="flex flex-col gap-1.5">
          <SectionTitle>
            Changes since{" "}
            <ExternalLink
              className="font-mono"
              href={compareUrl(summary.comparison.base, summary.commit)}
            >
              {summary.comparison.base.slice(0, 7)}
            </ExternalLink>
          </SectionTitle>
          <DetailList numeric>
            {summary.comparison.changes.map(([name, count]) => (
              <Detail key={name} name={name} numeric>
                {count}
              </Detail>
            ))}
          </DetailList>
        </section>
      )}
      <section className="flex flex-col gap-1.5">
        <SectionTitle>Apps</SectionTitle>
        <ul className="flex flex-col gap-1">
          {summary.apps.map((app) => (
            <li key={app}>{app}</li>
          ))}
        </ul>
      </section>
      <p className="text-secondary">
        Select a frame to inspect it. Press <Kbd plain>?</Kbd> for shortcuts.
      </p>
    </>
  );
}
