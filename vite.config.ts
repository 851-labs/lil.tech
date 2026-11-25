import { defineConfig } from "vite-plus";

/**
 * What the formatter and linter skip: everything outside the TypeScript workspace (Web/ and the
 * root config). Anchored to the root, so Markdown and YAML inside the workspace are still
 * formatted. A new top-level folder that isn't TypeScript belongs here. (Oxfmt can't express
 * "only these folders": `/*` with negations also hides the root files.)
 */
const outsideWorkspace = ["/.github/", "/.claude/", "/*.md", "/skills-lock.json"];

export default defineConfig({
  fmt: { ignorePatterns: outsideWorkspace },
  lint: {
    ignorePatterns: outsideWorkspace,
    jsPlugins: [{ name: "vite-plus", specifier: "vite-plus/oxlint-plugin" }],
    rules: { "vite-plus/prefer-vite-plus-imports": "error" },
    options: { typeAware: true, typeCheck: true },
  },
  run: {
    cache: true,
  },
});
