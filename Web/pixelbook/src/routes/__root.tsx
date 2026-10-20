import { createRootRoute, HeadContent, Outlet, Scripts } from "@tanstack/react-router";
import inter from "@fontsource-variable/inter/files/inter-latin-wght-normal.woff2?url";
import styles from "../styles.css?url";

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { name: "color-scheme", content: "light dark" },
      { title: "Pixelbook" },
    ],
    links: [
      // Requested with the page rather than once the stylesheet asks, so text doesn't reflow
      // into it.
      { rel: "preload", href: inter, as: "font", type: "font/woff2", crossOrigin: "anonymous" },
      { rel: "stylesheet", href: styles },
    ],
  }),
  component: Root,
});

function Root() {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body>
        <Outlet />
        <Scripts />
      </body>
    </html>
  );
}
