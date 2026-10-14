import { Layer, Redacted } from "effect";
import { Auth } from "../../src/auth/Auth.ts";
import { AccessTokens, SessionKey } from "../../src/auth/Tokens.ts";
import { TestCore } from "../core/TestCoreDatabase.ts";

export const TestSessionKey = Layer.succeed(SessionKey, Redacted.make("test-session-key"));

/** `Auth` and `AccessTokens` over a fresh test database, with the core repositories. */
export const TestAuth = Auth.layer.pipe(
  Layer.provideMerge(AccessTokens.layer),
  Layer.provideMerge(TestCore),
  Layer.provideMerge(TestSessionKey),
);
