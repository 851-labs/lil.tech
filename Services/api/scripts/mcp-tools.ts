// Writes the Health toolkit's MCP tool definitions to mcp-tools.json, with the Swift copy
// `lil-health mcp` on the Mac registers its tools from, or with --check fails if either committed
// file is out of date. Both MCP servers list the same tools (851-2841, 851-2844).
import { readFileSync, writeFileSync } from "node:fs";
import { makeMcpTools } from "../src/health/tools/McpTools.ts";

const path = new URL("../mcp-tools.json", import.meta.url);
const tools = `${JSON.stringify(makeMcpTools(), null, 2)}\n`;

/**
 * The file as a Swift raw string literal, so the command-line tool carries it without a
 * resource bundle, which a tool inside an app's `Contents/MacOS` can't find.
 * `HealthMCPServerTests` checks it matches mcp-tools.json.
 */
const swiftPath = new URL(
  "../../../LilPackage/Sources/Health/HealthCLI/MCPToolsJSON.swift",
  import.meta.url,
);
const swiftSource = (json: string) => {
  // Enough #s that nothing in the JSON ends the literal or starts an escape.
  let hashes = "#";
  while (json.includes(`"""${hashes}`) || json.includes(`\\${hashes}`)) hashes += "#";
  return [
    "// Generated from Services/api/mcp-tools.json by Services/api/scripts/mcp-tools.ts. Don't edit:",
    "// run scripts/format.",
    "",
    "/// The Health toolkit's tools as an MCP server lists them (`Services/api/mcp-tools.json`).",
    `let mcpToolsJSON = ${hashes}"""`,
    `${json}"""${hashes}`,
    "",
  ].join("\n");
};
const swift = swiftSource(tools);

const isCurrent = (file: URL, contents: string) => {
  try {
    return readFileSync(file, "utf8") === contents;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    return false;
  }
};

if (process.argv.includes("--check")) {
  let stale = false;
  for (const [file, contents, name] of [
    [path, tools, "Services/api/mcp-tools.json"],
    [swiftPath, swift, "LilPackage/Sources/Health/HealthCLI/MCPToolsJSON.swift"],
  ] as const) {
    if (!isCurrent(file, contents)) {
      console.error(`${name} is out of date. Run scripts/format to regenerate it.`);
      stale = true;
    }
  }
  if (stale) process.exit(1);
} else {
  writeFileSync(path, tools);
  writeFileSync(swiftPath, swift);
}
