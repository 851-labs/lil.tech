import { Effect } from "effect";
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";

// Sign in with Apple on the Mac, through Apple's web page. A Developer ID–distributed Mac app
// can't use the native sheet (851-2538), so it opens `appleid.apple.com/auth/authorize` with the
// Services ID (`appleWebServicesId`) in a web authentication session. Apple posts the result here,
// the registered return URL, and this hands it to the app, which signs in through
// `POST /v1/auth/apple` like the iPhone. That checks the identity token, and the nonce the app
// generated, so a forged post can't sign anyone in; the app also checks `state`.

/** The app's callback, which its web authentication session waits for. */
export const appleWebCallback = "tech.lil.health://apple-signin";

/** Where Apple's sign-in page posts from. */
export const appleWebOrigin = "https://appleid.apple.com";

/**
 * Where Apple posts the web sign-in's result, on the API's own origin: the app's `redirect_uri`,
 * which redeeming its code needs again.
 */
export const appleWebCallbackPath = "/v1/auth/apple/web";

/** Apple's post is a few KB: anything much bigger isn't from Apple. */
export const maxAppleWebPostBytes = 16 * 1024;

/**
 * What Apple posts that the app needs: `user` only comes with the first sign-in, and the app sends
 * `code` back with the identity token for the server to redeem (`AppleTokens.ts`).
 */
const forwarded = ["id_token", "code", "state", "user", "error"] as const;

/** A redirect to the app's callback with `fields`. It always ends there, so the sheet closes. */
const toApp = (fields: Readonly<Record<string, string>>) => {
  const callback = new URL(appleWebCallback);
  for (const [field, value] of Object.entries(fields)) callback.searchParams.set(field, value);
  return HttpServerResponse.redirect(callback, { status: 303 });
};

/**
 * `POST /v1/auth/apple/web`: Apple's `form_post` from its sign-in page, redirected to the app's
 * callback with the same fields. A post from another web origin, or one too big to be Apple's,
 * gets an `error` instead. Not rate limited: it does nothing but redirect, and the sign-in that
 * follows is. Left out of the OpenAPI spec: only Apple calls it.
 */
export const AppleWebCallbackRoute = HttpRouter.add(
  "POST",
  appleWebCallbackPath,
  Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest;
    const origin = request.headers["origin"];
    if (origin !== undefined && origin !== appleWebOrigin) {
      return toApp({ error: "invalid_origin" });
    }
    if (Number(request.headers["content-length"] ?? 0) > maxAppleWebPostBytes) {
      return toApp({ error: "request_too_large" });
    }
    const text = yield* request.text.pipe(
      Effect.tapError((error) => Effect.logWarning("Reading Apple's sign-in post failed", error)),
      Effect.option,
    );
    if (text._tag === "None") return toApp({ error: "server_error" });
    // Sent without a length (chunked): checked once read.
    if (text.value.length > maxAppleWebPostBytes) return toApp({ error: "request_too_large" });
    const posted = new URLSearchParams(text.value);
    const fields: Record<string, string> = {};
    for (const field of forwarded) {
      const value = posted.get(field);
      if (value !== null) fields[field] = value;
    }
    return toApp(fields);
  }),
);
