import { Effect, Schema } from "effect";
import { McpServer, Tool, Toolkit } from "effect/ai";
import type { StoreMcpApp } from "../../src/mcp/StoreMcpServer.ts";

// A fake lil mail for the combined MCP server's tests (851-2900), beside `registryWithMail`
// (`test/oauth/TestAgents.ts`): lil mail doesn't exist yet. Its `summary` shares a name with lil
// health's, so the tests can tell that each call reaches its own app.

class MailToolError extends Schema.TaggedError<MailToolError>()("MailToolError", {
  message: Schema.String,
}) {}

const MailToolkit = Toolkit.make(
  Tool.make("summary", {
    description: "An overview of the person's mail.",
    parameters: Tool.EmptyParams,
    success: Schema.Struct({ app: Schema.Literal("mail"), unread: Schema.Int }),
    failure: MailToolError,
  }).annotate(Tool.Readonly, true),
  Tool.make("search", {
    description: "Finds messages.",
    parameters: Schema.Struct({ query: Schema.String }),
    success: Schema.Struct({ app: Schema.Literal("mail"), matches: Schema.Array(Schema.String) }),
    failure: MailToolError,
  }).annotate(Tool.Readonly, true),
);

/** lil mail's tools, answering from synthetic mail. */
export const testMailApp: StoreMcpApp = {
  instructions: "Read-only access to the user's lil mail.",
  register: McpServer.registerToolkit(MailToolkit).pipe(
    Effect.provide(
      MailToolkit.toLayer({
        summary: () => Effect.succeed({ app: "mail" as const, unread: 3 }),
        search: ({ query }) => Effect.succeed({ app: "mail" as const, matches: [`Re: ${query}`] }),
      }),
    ),
  ),
};
