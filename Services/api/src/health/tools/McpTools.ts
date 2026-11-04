import { Effect, Layer, Schema } from "effect";
import { McpSchema, McpServer } from "effect/ai";
import { CardsToolkit, unimplementedCardTools } from "../cards/CardsToolkit.ts";
import { HealthToolkit, withUnimplementedTools } from "./HealthToolkit.ts";

/**
 * The Health toolkit's tools, then the card tools (851-3215), as an MCP server lists them
 * (`tools/list`), which `scripts/mcp-tools.ts` commits as `mcp-tools.json`: each tool's name,
 * title, description, input and output JSON Schemas, and annotations (the Health tools all
 * read-only; the card tools' writes not).
 *
 * They come from registering the toolkit with Effect's `McpServer`, as the API's MCP server will,
 * so the file has exactly the schemas it serves. `lil-health mcp` on the Mac registers its tools
 * from the file, so both servers list the same tools.
 */
export const makeMcpTools = (): ReadonlyArray<typeof McpSchema.Tool.Encoded> =>
  Effect.runSync(
    Effect.gen(function* () {
      yield* McpServer.registerToolkit(HealthToolkit);
      yield* McpServer.registerToolkit(CardsToolkit);
      const server = yield* McpServer.McpServer;
      // `tools/list` gives each tool its annotations' title, as `McpServer.addTool` does.
      return server.tools.map(({ tool }) => {
        const encoded = Schema.encodeSync(McpSchema.Tool)(tool);
        const title = tool.title ?? tool.annotations?.title;
        return title === undefined ? encoded : { ...encoded, title };
      });
    }).pipe(
      Effect.provide(
        Layer.mergeAll(
          McpServer.McpServer.layer,
          // Registering needs handlers, but listing never calls them.
          HealthToolkit.toLayer(withUnimplementedTools({})),
          CardsToolkit.toLayer(unimplementedCardTools),
        ),
      ),
    ),
  );
