import { useEffect, useState } from "react";

/** The display's pixels per CSS pixel, kept up to date as the window moves between displays. */
export function useDevicePixelRatio() {
  const [ratio, setRatio] = useState(1);
  useEffect(() => {
    let query: MediaQueryList | undefined;
    const watch = () => {
      setRatio(window.devicePixelRatio);
      // Matches until the ratio changes, then is replaced.
      query = window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`);
      query.addEventListener("change", watch, { once: true });
    };
    watch();
    return () => query?.removeEventListener("change", watch);
  }, []);
  return ratio;
}
