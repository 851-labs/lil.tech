// Writes the API's OpenAPI spec to openapi.json, or with --check fails if the committed file is
// out of date. The committed spec is the contract the Swift client is generated from.
import { readFileSync, writeFileSync } from "node:fs";
import { openApiSpec } from "../src/OpenApiSpec.ts";

const path = new URL("../openapi.json", import.meta.url);
const spec = `${JSON.stringify(openApiSpec, null, 2)}\n`;

if (process.argv.includes("--check")) {
  let committed = "";
  try {
    committed = readFileSync(path, "utf8");
  } catch {}
  if (committed !== spec) {
    console.error("Services/api/openapi.json is out of date. Run scripts/format to regenerate it.");
    process.exit(1);
  }
} else {
  writeFileSync(path, spec);
}
