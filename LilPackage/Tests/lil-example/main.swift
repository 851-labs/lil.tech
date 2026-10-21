// `lil-example`: a stand-in for a second lil app's command line tool, for LilCLITests. Its
// `lil-example mcp` serves one tool, `echo`, and one resource, `example://greeting`, as an app's
// own MCP server would, so `lil mcp` is tested with two apps.
import Foundation
import MCP

guard Array(CommandLine.arguments.dropFirst()) == ["mcp"] else {
  FileHandle.standardError.write(Data("usage: lil-example mcp\n".utf8))
  exit(64)
}

let echo = Tool(
  name: "echo",
  title: "Echo",
  description: "Answers with its text, and the calling process the server was told of.",
  inputSchema: [
    "type": "object",
    "properties": ["text": ["type": "string"]],
    "required": ["text"],
  ],
  annotations: .init(readOnlyHint: true, openWorldHint: false))

let greeting = Resource(
  name: "greeting", uri: "example://greeting", description: "A greeting.", mimeType: "text/plain")

let server = Server(
  name: "lil-example",
  version: "1",
  title: "lil example",
  instructions: "Echoes text.",
  capabilities: Server.Capabilities(
    resources: .init(subscribe: false, listChanged: false),
    tools: .init(listChanged: false)))
await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: [echo]) }
await server.withMethodHandler(CallTool.self) { parameters in
  guard parameters.name == echo.name else {
    throw MCPError.invalidParams("Unknown tool: \(parameters.name)")
  }
  guard let text = parameters.arguments?["text"]?.stringValue else {
    throw MCPError.invalidParams("text is required")
  }
  let process = ProcessInfo.processInfo.environment["LIL_CALLING_PROCESS"] ?? ""
  return CallTool.Result(
    content: [.text(text: text, annotations: nil, _meta: nil)],
    structuredContent: ["text": .string(text), "callingProcess": .string(process)],
    isError: text == "fail")
}
await server.withMethodHandler(ListResources.self) { _ in
  ListResources.Result(resources: [greeting])
}
await server.withMethodHandler(ReadResource.self) { parameters in
  guard parameters.uri == greeting.uri else {
    throw MCPError.invalidParams("Unknown resource: \(parameters.uri)")
  }
  return ReadResource.Result(contents: [
    .text("Hello from lil example.", uri: greeting.uri, mimeType: greeting.mimeType)
  ])
}
try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
