import { Option } from "effect";

// The rules for OAuth redirect URIs, shared by client registration (CIMD and DCR), `/oauth/authorize`
// and `/oauth/token` (851-2845).

/** The longest redirect URI a client may register. */
export const maxRedirectUriLength = 2000;

/** The most redirect URIs a client may register. */
export const maxRedirectUris = 10;

/** Hosts that name this machine, where `http` is allowed (RFC 8252 §7.3). */
const loopbackHosts: ReadonlySet<string> = new Set(["localhost", "127.0.0.1", "[::1]"]);

/**
 * A private-use scheme: reverse DNS, so with a dot (RFC 8252 §7.1), e.g. `com.example.app`. A
 * scheme without one could be anything (`javascript`, `data`, `file`).
 */
const privateUseScheme = /^[a-z][a-z0-9+-]*(\.[a-z0-9+-]+)+$/;

/** Whether `url` is `http` to this machine. */
const isLoopback = (url: URL) => url.protocol === "http:" && loopbackHosts.has(url.hostname);

/**
 * Why `uri` can't be a redirect URI, if it can't: it must be HTTPS, `http` on loopback
 * (`localhost`, `127.0.0.1`, `[::1]`), or a reverse-DNS private-use scheme, with no fragment and
 * no user info.
 */
export const redirectUriProblem = (uri: string): Option.Option<string> => {
  if (uri.length > maxRedirectUriLength) {
    return Option.some(`is longer than ${maxRedirectUriLength} characters`);
  }
  if (!URL.canParse(uri)) return Option.some("isn't a URL");
  const url = new URL(uri);
  if (uri.includes("#")) return Option.some("has a fragment");
  if (url.username !== "" || url.password !== "") return Option.some("has user info");
  const scheme = url.protocol.slice(0, -1);
  if (scheme === "https") return url.hostname === "" ? Option.some("has no host") : Option.none();
  if (scheme === "http") {
    return isLoopback(url) ? Option.none() : Option.some("uses http on a host other than loopback");
  }
  return privateUseScheme.test(scheme)
    ? Option.none()
    : Option.some("uses a scheme that's neither HTTPS nor reverse DNS");
};

/** Whether `uri` is `http` to this machine, so a program on it gets what's sent there. */
export const isLoopbackUri = (uri: string) => URL.canParse(uri) && isLoopback(new URL(uri));

/** Whether `uri` is a native app's: loopback or a private-use scheme. */
export const isNativeRedirectUri = (uri: string) => {
  if (!URL.canParse(uri)) return false;
  const url = new URL(uri);
  return isLoopback(url) || (url.protocol !== "https:" && url.protocol !== "http:");
};

/**
 * Whether `requested` is one of `registered`: exactly, except that a loopback URI's port is
 * ignored, since native clients (Claude Code) listen on whatever port is free (RFC 8252 §7.3).
 */
export const matchesRedirectUri = (registered: ReadonlyArray<string>, requested: string) => {
  if (registered.includes(requested)) return true;
  if (redirectUriProblem(requested)._tag === "Some") return false;
  const asked = new URL(requested);
  if (!isLoopback(asked)) return false;
  return registered.some((uri) => {
    if (!URL.canParse(uri)) return false;
    const url = new URL(uri);
    return isLoopback(url) && withoutPort(url) === withoutPort(asked);
  });
};

const withoutPort = (url: URL) => {
  const copy = new URL(url);
  copy.port = "";
  return copy.href;
};
