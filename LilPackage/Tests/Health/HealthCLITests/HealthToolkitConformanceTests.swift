import Foundation
import HealthAgentAccess
import HealthDatabase
import MCP
import Testing

@testable import HealthCLI

/// The Mac's side of the Health toolkit's conformance cases (851-2841): the dataset synced into
/// the Mac's database, then each case's tool called through `lil-health mcp`'s server, as an
/// agent calls it. Every case has to pass: the Mac implements all of the tools.
@Suite
struct HealthToolkitConformanceTests {
  @Test(arguments: try Conformance.cases())
  func conformanceCase(_ testCase: Conformance.Case) async throws {
    let folder = try AppFolder()
    try await Conformance.sync(into: folder.database, pins: testCase.pins)
    try folder.access.setEnabled(true)
    // Without a time zone, the remote server answers in UTC and the Mac in its own: the cases
    // are written for the remote's default, so this Mac is in UTC.
    let connection = try await MCPConnection(
      folder.directory, now: try Conformance.date(testCase.now), timeZone: "UTC")

    guard case .object(let arguments) = Value(testCase.arguments) else {
      Issue.record("\(testCase.name): arguments aren't an object")
      return
    }
    let result = try await connection.call(testCase.tool, arguments)
    await connection.close()

    if testCase.expectedError == true {
      #expect(result.isError == true, "\(result.text)")
      return
    }
    #expect(result.isError == false, "\(result.text)")
    let output = try JSONDecoder().decode(
      JSONValue.self, from: JSONEncoder().encode(result.structuredContent))
    let expected = try #require(testCase.expected)
    #expect(output.matches(expected), "\(output)\nexpected:\n\(expected)")
  }
}

extension Conformance.Case: CustomTestStringConvertible {
  var testDescription: String { name }
}

extension Value {
  /// `json` as an MCP value: whole numbers as integers, as they come over the wire.
  init(_ json: JSONValue) {
    switch json {
    case .null: self = .null
    case .bool(let value): self = .bool(value)
    case .number(let value):
      self =
        value.rounded() == value
        ? Int(exactly: value).map(Value.int) ?? .double(value) : .double(value)
    case .string(let value): self = .string(value)
    case .array(let values): self = .array(values.map(Value.init))
    case .object(let values): self = .object(values.mapValues(Value.init))
    }
  }
}
