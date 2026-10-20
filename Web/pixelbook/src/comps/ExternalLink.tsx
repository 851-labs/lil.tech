/** A link out of Pixelbook, such as to GitHub. It opens in a new tab, keeping the canvas where it is. */
export function ExternalLink(props: Omit<React.ComponentProps<"a">, "target" | "rel">) {
  return <a {...props} target="_blank" rel="noreferrer" />;
}
