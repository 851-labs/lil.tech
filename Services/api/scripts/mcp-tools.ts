// Writes the Health toolkit's MCP tool definitions to mcp-tools.json, or with --check fails if the
// committed file is out of date. `lil-health mcp` on the Mac registers its tools from it, so both
// MCP servers list the same tools (851-2841).
import { readFileSync, writeFileSync } from "node:fs";
import { makeMcpTools } from "../src/health/tools/McpTools.ts";

const path = new URL("../mcp-tools.json", import.meta.url);
const tools = `${JSON.stringify(makeMcpTools(), null, 2)}\n`;

if (process.argv.includes("--check")) {
  let committed = "";
  try {
    committed = readFileSync(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  if (committed !== tools) {
    console.error(
      "Services/api/mcp-tools.json is out of date. Run scripts/format to regenerate it.",
    );
    process.exit(1);
  }
} else {
  writeFileSync(path, tools);
}
