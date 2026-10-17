import { Effect } from "effect";
import { HttpRouter, HttpServerRequest, HttpServerResponse } from "effect/http";
import { checkAddressRateLimit, RateLimits, tooManyRequests } from "../RateLimits.ts";

// Sign in with Apple on the Mac, through Apple's web page. A Developer ID–distributed Mac app
// can't use the native sheet (851-2538), so it opens `appleid.apple.com/auth/authorize` with the
// Services ID `tech.lil.health.web` in a web authentication session. Apple posts the result here,
// the registered return URL, and this hands it to the app, which signs in through
// `POST /v1/auth/apple` like the iPhone. That checks the identity token and the app's nonce.

/** The Services ID the Mac's web sign-in uses, grouped under the `tech.lil.health` App ID. */
export const appleWebServicesId = "tech.lil.health.web";

/** The app's callback, which its web authentication session waits for. */
export const appleWebCallback = "tech.lil.health://apple-signin";

/** What Apple posts that the app needs: `user` only comes with the first sign-in. */
const forwarded = ["id_token", "code", "state", "user", "error"] as const;

/**
 * `POST /v1/auth/apple/web`: Apple's `form_post` from its sign-in page, redirected to the app's
 * callback with the same fields, so nothing here needs checking. Left out of the OpenAPI spec:
 * only Apple calls it.
 */
export const AppleWebCallbackRoute = HttpRouter.use((router) =>
  Effect.gen(function* () {
    const limits = yield* RateLimits;
    yield* router.add(
      "POST",
      "/v1/auth/apple/web",
      Effect.gen(function* () {
        yield* checkAddressRateLimit(limits, "signIn");
        const text = yield* (yield* HttpServerRequest.HttpServerRequest).text.pipe(
          Effect.orElseSucceed(() => ""),
        );
        const posted = new URLSearchParams(text);
        const callback = new URL(appleWebCallback);
        for (const field of forwarded) {
          const value = posted.get(field);
          if (value !== null) callback.searchParams.set(field, value);
        }
        return HttpServerResponse.redirect(callback, { status: 303 });
      }).pipe(Effect.catchTag("TooManyRequests", tooManyRequests)),
    );
  }),
);
