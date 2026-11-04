import { defineConfig } from "vite-plus";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    // What a test logs is shown only when it fails, so a passing run (the pre-commit hook's) is
    // its summary lines rather than the server's request log, as in every workspace package with
    // tests (851-3229).
    silent: "passed-only",
  },
});
