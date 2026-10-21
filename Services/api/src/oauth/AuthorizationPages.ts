import { HttpServerResponse } from "effect/http";
import { appleLogoPath, googleLogoPng, googleSansMediumWoff2 } from "./SignInButtons.ts";

// The agents' authorization page (`/oauth/authorize`, 851-2849): server-rendered HTML with no
// JavaScript and no remote resources, in a plain system look that follows light and dark. Every
// string a client supplied (its name, its URLs) goes through `escape`.

/** Escapes text for HTML, in content and in quoted attributes. */
export const escape = (text: string) =>
  text.replace(/[&<>"']/g, (char) => `&#${char.charCodeAt(0)};`);

/** The test account the sign-in suggests: the one the apps' test-account sign-in uses too. */
export const defaultTestAccount = "e2e";

/** The longest test account name. */
export const maxAccountLength = 100;

/** A form's hidden fields, which bind it to its authorization request (`AuthorizationPage.ts`). */
export interface FormBinding {
  readonly request: string;
  readonly csrf: string;
}

/** Who's asking, as the page shows it. */
export interface ClientView {
  /** The client's name, as it gave it, if it did. */
  readonly name: string | null;
  /** Registered (DCR), so its name is unverified, or a metadata document (CIMD) on `domain`. */
  readonly kind: "cimd" | "dcr";
  /** A metadata document's host: the domain that vouches for it. */
  readonly domain: string | null;
  /** Where the browser goes back to: the redirect URI's host, or its scheme. */
  readonly redirectHost: string;
  /** Whether the redirect URI is loopback, so a program on this computer gets the code. */
  readonly loopback: boolean;
}

/** An app the agent would read, as the page lists it. */
export interface AppView {
  /** The app's key in the registry (`health`), which picks its icon. */
  readonly key: string;
  readonly name: string;
}

/** What an agent asks to connect to, as the page names it: one app's server, or the combined one. */
export interface TargetView {
  /** An app's name ("lil health"), or "lil" for the combined server. */
  readonly name: string;
  /** Whether it's the combined server, which lists the apps it reads. */
  readonly combined: boolean;
  /** The apps the agent would read: the one app, or those its scopes chose. */
  readonly apps: ReadonlyArray<AppView>;
  readonly privacyUrl: string;
}

/** The client's name, for sentences. */
const agentName = (client: ClientView) => client.name ?? "An unnamed agent";

/** A rounded tile with a vertical gradient, and `mark` on it, as an inline SVG of `className`. */
const tile = (className: string, id: string, colors: readonly [string, string], mark: string) =>
  `<svg class="${className}" viewBox="0 0 100 100" aria-hidden="true">
  <defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="${colors[0]}"/><stop offset="1" stop-color="${colors[1]}"/>
  </linearGradient></defs>
  <rect width="100" height="100" rx="22.5" fill="url(#${id})"/>
  ${mark}
</svg>`;

/** A letter on an icon, in the system font. */
const letters = (text: string, size: number) =>
  `<text x="50" y="${50 + size * 0.35}" text-anchor="middle" fill="#fff" font-size="${size}"
    font-weight="700" font-family="-apple-system, BlinkMacSystemFont, system-ui, sans-serif">` +
  `${escape(text)}</text>`;

/**
 * An app's icon (`Apps/LilHealth` for lil health), inline: the page loads nothing else. An app
 * without one of its own gets its initial on a gray tile.
 */
const appIcon = (app: AppView, className: string) => {
  const id = `${className}-${app.key}`;
  switch (app.key) {
    case "health":
      return tile(
        className,
        id,
        ["#655af2", "#3a2ba0"],
        `<polyline points="22,51 38,51 44,27 52,74 60,38 64,51 78,51" fill="none" stroke="#fff"
    stroke-width="5.5" stroke-linecap="round" stroke-linejoin="round"/>`,
      );
    default:
      return tile(
        className,
        id,
        ["#8e8e93", "#48484a"],
        letters(app.name.replace(/^lil /, "").slice(0, 1), 52),
      );
  }
};

/** lil's own icon, for the combined server, which reads every app. */
const lilIcon = tile("icon", "icon-lil", ["#3a3a3c", "#1c1c1e"], letters("lil", 46));

/** The page's icon: the app's, or lil's for the combined server. */
const targetIcon = (target: TargetView) => {
  const app = target.apps[0];
  return target.combined || app === undefined ? lilIcon : appIcon(app, "icon");
};

/** lil health's icon, for pages that don't know what the agent asked for (errors). */
const defaultIcon = appIcon({ key: "health", name: "lil health" }, "icon");

const styles = `
:root { color-scheme: light dark; --bg: #f5f5f7; --card: #fff; --text: #1d1d1f;
  --secondary: #6e6e73; --separator: #d2d2d7; --accent: #0071e3; --accent-text: #fff;
  --warning-bg: #fff4e5; --warning: #8a4b00; --badge-bg: #f2f2f7; }
@media (prefers-color-scheme: dark) { :root { --bg: #000; --card: #1c1c1e; --text: #f5f5f7;
  --secondary: #a1a1a6; --separator: #38383a; --accent: #0a84ff; --warning-bg: #3a2a12;
  --warning: #ffb340; --badge-bg: #2c2c2e; } }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
  padding: 24px 16px; background: var(--bg); color: var(--text);
  font: 15px/1.45 -apple-system, BlinkMacSystemFont, system-ui, "Segoe UI", sans-serif; }
main { width: 100%; max-width: 440px; background: var(--card); border-radius: 18px;
  padding: 32px 28px 24px; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
.icon { display: block; width: 64px; height: 64px; margin: 0 auto 16px; }
h1 { font-size: 22px; line-height: 1.25; font-weight: 600; text-align: center; margin: 0 0 8px; }
.lead { text-align: center; color: var(--secondary); margin: 0 0 20px; }
section { border-top: 1px solid var(--separator); padding: 14px 0; }
section h2 { font-size: 13px; font-weight: 600; color: var(--secondary); margin: 0 0 6px;
  text-transform: uppercase; letter-spacing: .02em; }
section p { margin: 4px 0; }
.name { font-weight: 600; overflow-wrap: anywhere; }
.badge { display: inline-block; font-size: 12px; font-weight: 600; padding: 1px 7px;
  border-radius: 6px; background: var(--badge-bg); color: var(--secondary); margin-left: 6px;
  vertical-align: 1px; }
.muted { color: var(--secondary); font-size: 13px; }
ul.apps { list-style: none; margin: 8px 0 10px; padding: 0; }
ul.apps li { display: flex; align-items: center; gap: 10px; padding: 3px 0; font-weight: 600; }
.app-icon { width: 28px; height: 28px; flex: none; }
.warning { background: var(--warning-bg); color: var(--warning); border-radius: 10px;
  padding: 10px 12px; margin: 10px 0 0; font-size: 14px; }
a { color: var(--accent); }
label { display: block; font-size: 13px; color: var(--secondary); margin: 0 0 6px; }
input[type=text] { width: 100%; font: inherit; color: inherit; background: transparent;
  padding: 9px 11px; border: 1px solid var(--separator); border-radius: 9px; margin: 0 0 12px; }
.buttons { display: flex; gap: 10px; margin-top: 18px; }
.buttons form { flex: 1; margin: 0; }
button { width: 100%; font: inherit; font-weight: 600; padding: 10px 14px; border-radius: 10px;
  border: 1px solid var(--separator); background: transparent; color: var(--text);
  cursor: pointer; }
button.primary { background: var(--accent); border-color: var(--accent);
  color: var(--accent-text); }
footer { margin-top: 18px; text-align: center; }
.notice { margin: 0 0 12px; }
form.provider { margin: 0 0 10px; }
button.provider { display: flex; align-items: center; justify-content: center; height: 44px;
  padding: 0 12px; border-radius: 8px; }
button.apple { gap: 6px; background: #000; border-color: #000; color: #fff;
  font: 500 17px/1 -apple-system, BlinkMacSystemFont, system-ui, "Segoe UI", sans-serif; }
button.apple svg { width: 15px; height: 19px; margin-top: -3px; fill: currentColor; }
button.google { gap: 10px; background: #fff; border-color: #747775; color: #1f1f1f;
  font: 500 14px/20px "Google Sans Medium", Roboto, system-ui, sans-serif; }
button.google img { width: 20px; height: 20px; }
@media (prefers-color-scheme: dark) {
  button.apple { background: #fff; border-color: #fff; color: #000; }
  button.google { background: #131314; border-color: #8e918f; color: #e3e3e3; } }
`;

/** Google Sans, for Google's button only: it has just that label's letters. */
const googleFont = `@font-face { font-family: "Google Sans Medium"; font-weight: 500;
  src: url(data:font/woff2;base64,${googleSansMediumWoff2}) format("woff2"); }`;

const layout = (
  title: string,
  body: string,
  extraStyles = "",
  icon = defaultIcon,
) => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${escape(title)}</title>
<style>${styles}${extraStyles}</style>
</head>
<body>
<main>
${icon}
${body}
</main>
</body>
</html>
`;

const hidden = (binding: FormBinding) =>
  `<input type="hidden" name="request" value="${escape(binding.request)}">` +
  `<input type="hidden" name="csrf" value="${escape(binding.csrf)}">`;

/** Who's asking: the name (unverified for a registered client), its domain and where it returns. */
const whoIsAsking = (client: ClientView) => {
  const name = client.name === null ? "<em>No name given</em>" : escape(client.name);
  const unverified = client.kind === "dcr" ? `<span class="badge">Unverified</span>` : "";
  const origin =
    client.kind === "cimd" && client.domain !== null
      ? `<p class="muted">Identified by <strong>${escape(client.domain)}</strong></p>`
      : `<p class="muted">This agent named itself; lil can't check who made it.</p>`;
  const loopback = client.loopback
    ? `<p class="warning">This agent is a program on your computer. Only allow it if you just started ` +
      `connecting it yourself.</p>`
    : "";
  return `<section>
<h2>Who's asking</h2>
<p><span class="name">${name}</span>${unverified}</p>
${origin}
<p class="muted">Returns you to <strong>${escape(client.redirectHost)}</strong></p>
${loopback}
</section>`;
};

/** The Cancel button, which tells the agent the user said no. */
const cancelForm = (binding: FormBinding) =>
  `<form method="post" action="/oauth/authorize/decision">${hidden(binding)}` +
  `<button type="submit" name="decision" value="cancel">Cancel</button></form>`;

/** How someone can sign in on the page. */
export interface SignInMethods {
  /** The test-account sign-in (previews and `alchemy dev`). */
  readonly testAccounts: boolean;
  /** Sign in with Apple (staging and prod). */
  readonly apple: boolean;
  /** Sign in with Google (staging and prod, where its web client is set up). */
  readonly google: boolean;
}

/** Why the sign-in page is shown again, after a sign-in with Apple or Google that didn't work. */
export const SignInNotice = ["apple_unknown", "google_unknown", "failed", "unavailable"] as const;
export type SignInNotice = (typeof SignInNotice)[number];

/** The app whose iPhone app makes accounts, as the sign-in page names it. */
const setUpApp = (target: TargetView) => target.apps[0]?.name ?? "lil health";

const noticeText = (notice: SignInNotice, target: TargetView) => {
  switch (notice) {
    case "apple_unknown":
      return (
        `No ${target.name} account uses this Apple ID. Set up ${setUpApp(target)} on your ` +
        `iPhone first.`
      );
    case "google_unknown":
      return (
        `No ${target.name} account uses this Google account. Set up ${setUpApp(target)} on your ` +
        `iPhone first.`
      );
    case "failed":
      return "Signing in didn't work. Try again.";
    case "unavailable":
      return "Signing in isn't available right now. Try again in a minute.";
  }
};

/** A form that starts signing in with `provider`. */
const providerForm = (binding: FormBinding, provider: "apple" | "google", label: string) =>
  `<form class="provider" method="post" action="/oauth/authorize/sign-in">${hidden(binding)}` +
  `<input type="hidden" name="provider" value="${provider}">` +
  `<button type="submit" class="provider ${provider}">${label}</button></form>`;

/** Sign in with Apple and Google, as each brand draws its button. */
const providerButtons = (binding: FormBinding, methods: SignInMethods, target: TargetView) => {
  const apple = methods.apple
    ? providerForm(
        binding,
        "apple",
        `<svg viewBox="20.5 16 15 19" aria-hidden="true"><path d="${appleLogoPath}"/></svg>` +
          `Sign in with Apple`,
      )
    : "";
  const google = methods.google
    ? providerForm(
        binding,
        "google",
        `<img src="data:image/png;base64,${googleLogoPng}" alt="">Sign in with Google`,
      )
    : "";
  const accounts = methods.google ? "Apple ID or Google account" : "Apple ID";
  return `${apple}${google}
<p class="muted">Use the ${accounts} you use with ${escape(setUpApp(target))} on your iPhone.</p>`;
};

/** Signing in, before consent, with the ways `methods` allows. */
export const signInPage = (options: {
  readonly client: ClientView;
  readonly app: TargetView;
  readonly binding: FormBinding;
  readonly methods: SignInMethods;
  readonly notice?: SignInNotice | undefined;
}) => {
  const { client, app, binding, methods } = options;
  const title = `Sign in to connect ${agentName(client)} to ${app.name}`;
  const notice =
    options.notice === undefined
      ? ""
      : `<p class="warning notice" role="alert">${escape(noticeText(options.notice, app))}</p>\n`;
  const providers = methods.apple || methods.google;
  const signIn = providers
    ? `<section>${notice}${providerButtons(binding, methods, app)}</section>`
    : methods.testAccounts
      ? `<section>
<form method="post" action="/oauth/authorize/sign-in">${hidden(binding)}
<label for="account">Test account</label>
<input type="text" id="account" name="account" value="${defaultTestAccount}"
  maxlength="${maxAccountLength}" autocomplete="off"
  autocapitalize="off" spellcheck="false" required>
<button type="submit" class="primary">Sign in to a Test Account</button>
</form>
<p class="muted">This is a preview, so it only has synthetic test accounts.</p>
</section>`
      : `<section><p>Signing in on the web isn't available here yet.</p></section>`;
  return layout(
    title,
    `<h1>${escape(title)}</h1>
<p class="lead">Sign in to the ${escape(app.name)} account the agent should read.</p>
${whoIsAsking(client)}
${signIn}
<div class="buttons">${cancelForm(binding)}</div>`,
    methods.google ? googleFont : "",
    targetIcon(app),
  );
};

/** What an agent connecting to one app's server can read. */
const appScope = (agent: string, target: TargetView) => `<section>
<h2>What it can read</h2>
<p>${agent} will be able to read <strong>all of your ${escape(target.name)} data</strong>. It can't
change or delete anything.</p>
<p>Agents may send what they read to their AI provider, which handles it under its own terms.</p>
<p class="muted">Only ${escape(target.name)}: your other lil apps' data isn't included. See the
<a href="${escape(target.privacyUrl)}" target="_blank" rel="noreferrer">privacy policy</a>.</p>
</section>`;

/**
 * What an agent connecting to the combined server can read: every app its scopes chose, all or
 * nothing. One that should read fewer connects to each app's own server instead.
 */
const combinedScope = (agent: string, target: TargetView) => {
  const names = target.apps.map((app) => escape(app.name)).join(", ");
  const list = target.apps
    .map((app) => `<li>${appIcon(app, "app-icon")}<span>${escape(app.name)}</span></li>`)
    .join("\n");
  return `<section>
<h2>What it can read</h2>
<ul class="apps">
${list}
</ul>
<p>${agent} will be able to read <strong>all of your data in these lil apps: ${names}</strong>.
It can't change or delete anything.</p>
<p>Agents may send what they read to their AI provider, which handles it under its own terms.</p>
<p class="muted">Allowing gives it every app listed. To let an agent read only one of them, connect
it to that app's own server instead. See the
<a href="${escape(target.privacyUrl)}" target="_blank" rel="noreferrer">privacy policy</a>.</p>
</section>`;
};

/** Consent: who's asking, which apps, and what it gets, with Allow and Cancel. */
export const consentPage = (options: {
  readonly client: ClientView;
  readonly app: TargetView;
  readonly binding: FormBinding;
  /** Who's signed in, as the page names them. */
  readonly account: string;
}) => {
  const { client, app, binding } = options;
  const agent = escape(agentName(client));
  const title = `Allow ${agentName(client)} to read your ${app.name} data?`;
  return layout(
    title,
    `<h1>${escape(title)}</h1>
<p class="lead">Signed in as <strong>${escape(options.account)}</strong></p>
${whoIsAsking(client)}
${app.combined ? combinedScope(agent, app) : appScope(agent, app)}
<div class="buttons">${cancelForm(binding)}
<form method="post" action="/oauth/authorize/decision">${hidden(binding)}
<button type="submit" class="primary" name="decision" value="allow">Allow</button></form></div>`,
    "",
    targetIcon(app),
  );
};

/** A request that can't go on, and why. */
export const errorPage = (title: string, message: string) =>
  layout(
    title,
    `<h1>${escape(title)}</h1>
<p class="lead">${escape(message)}</p>
<footer class="muted">You can close this page, then connect again from your agent.</footer>`,
  );

/**
 * The CSP `form-action` source that lets the browser follow a form's redirect to `redirectUri`:
 * its origin, or its scheme for a private-use one. Chrome checks redirects after a form against
 * `form-action`, so `'self'` alone would block Allow's and Cancel's redirect to the agent.
 */
export const formActionSource = (redirectUri: string) => {
  const url = new URL(redirectUri);
  return url.protocol === "http:" || url.protocol === "https:" ? url.origin : url.protocol;
};

/**
 * An authorization page response: never cached, framed or sent with a referrer, and with no CORS
 * headers (it uses a cookie). Its forms may post to this origin, and redirect to `formActions`
 * (the agent, and Apple's and Google's sign-in pages).
 */
export const pageResponse = (
  html: string,
  options: { readonly status?: number; readonly formActions?: ReadonlyArray<string> } = {},
) =>
  HttpServerResponse.text(html, {
    status: options.status ?? 200,
    contentType: "text/html; charset=utf-8",
    headers: {
      // Images and fonts only as `data:` URLs: the sign-in buttons' marks and Google's font.
      "content-security-policy":
        `default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; ` +
        `form-action ${["'self'", ...(options.formActions ?? [])].join(" ")}; ` +
        `frame-ancestors 'none'`,
      "referrer-policy": "no-referrer",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
