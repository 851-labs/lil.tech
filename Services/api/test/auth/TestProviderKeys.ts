import { Effect } from "effect";
import { createLocalJWKSet, exportJWK, generateKeyPair } from "jose";
import type { ProviderKeys } from "../../src/auth/ProviderTokens.ts";
import { ProviderKeysUnavailable } from "../../src/auth/ProviderTokens.ts";

/** How a test provider's key endpoint behaves, and how often it was asked for fresh keys. */
export interface TestKeysControl {
  mode: "normal" | "staleCache" | "down";
  freshFetches: number;
}

/**
 * A key pair generated for the tests, and `ProviderKeys` serving its public key. `control`
 * simulates a stale cache (the key only arrives with a fresh fetch) or an outage.
 */
export const makeTestProviderKeys = async (kid: string) => {
  const { privateKey, publicKey } = await generateKeyPair("RS256");
  const keySet = createLocalJWKSet({
    keys: [{ ...(await exportJWK(publicKey)), kid, alg: "RS256" }],
  });
  const emptyKeySet = createLocalJWKSet({ keys: [] });
  const control: TestKeysControl = { mode: "normal", freshFetches: 0 };
  const keys: ProviderKeys = {
    keys: ({ fresh }) =>
      Effect.suspend(() => {
        if (fresh) control.freshFetches += 1;
        if (control.mode === "down") {
          return Effect.fail(new ProviderKeysUnavailable({ message: "The provider is down" }));
        }
        return Effect.succeed(control.mode === "staleCache" && !fresh ? emptyKeySet : keySet);
      }),
  };
  return { privateKey, kid, keys, control };
};
