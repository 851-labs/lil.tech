// Writes the API's OpenAPI spec to openapi.json, or with --check fails if the committed file is
// out of date. The committed spec is the contract the Swift client is generated from, and the
// Worker serves it at /v1/openapi.json.
import { readFileSync, writeFileSync } from "node:fs";
import { makeOpenApiSpec } from "../src/OpenApiSpec.ts";

const path = new URL("../openapi.json", import.meta.url);
const spec = `${JSON.stringify(makeOpenApiSpec(), null, 2)}\n`;

if (process.argv.includes("--check")) {
  let committed = "";
  try {
    committed = readFileSync(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  if (committed !== spec) {
    console.error("Services/api/openapi.json is out of date. Run scripts/format to regenerate it.");
    process.exit(1);
  }
} else {
  writeFileSync(path, spec);
}
