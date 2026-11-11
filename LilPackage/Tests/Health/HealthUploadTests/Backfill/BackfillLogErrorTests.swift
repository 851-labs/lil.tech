import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import HealthUpload

// Errors in the backfill's log (851-4183): their type and codes, never the values their
// descriptions print. Each error carries synthetic values, which must not reach the line.

/// What the errors below carry. None may appear in a summary.
private let values = [
  "Ada Lovelace", "ada@example.com", "ada%40example.com", "72.5", "secret-token", "token=",
  "https://api.example.com", "body-value", "Cannot decode", "Ada's note",
]

private func expectNoValues(_ summary: String, sourceLocation: SourceLocation = #_sourceLocation) {
  for value in values {
    #expect(!summary.contains(value), "\(summary) holds \(value)", sourceLocation: sourceLocation)
  }
}

@Suite struct BackfillLogErrorTests {
  /// An operation's input holding a value, as a new operation's could.
  struct SyntheticInput: Sendable {
    var name = "Ada Lovelace"
    var weight = 72.5
  }

  struct SyntheticFailure: Error {
    let statusCode: Int
    let expected: Int?
    let note: String
    let weight: Double
  }

  enum SyntheticReason: Error {
    case refused(note: String)
    case gone
  }

  enum SyntheticDescribed: Error, CustomStringConvertible {
    case gone
    var description: String { "Ada Lovelace's sample is gone" }
  }

  /// Keys a type declares, as synthesized `CodingKeys` are.
  enum Field: String, CodingKey {
    case samples, value, metadata, batches, status, failure
  }

  /// A dictionary's key, or a coder's index (`Index 3`).
  struct Key: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init(intValue: Int) {
      stringValue = "\(intValue)"
      self.intValue = intValue
    }
    static func index(_ index: Int) -> Self {
      var key = Self(intValue: index)
      key.stringValue = "Index \(index)"
      return key
    }
  }

  struct Sample: Codable {
    var value: Double
    var metadata: [String: Double] = [:]
  }

  @Test func clientErrorKeepsItsOperationStatusAndUnderlyingType() {
    let underlying = EncodingError.invalidValue(
      72.5,
      .init(
        codingPath: [Field.samples, Key.index(3), Field.value],
        debugDescription: "Ada's note: 72.5 isn't valid"))
    let error = ClientError(
      operationID: "healthUploadBatch",
      operationInput: SyntheticInput(),
      request: HTTPRequest(
        method: .post, scheme: "https", authority: "api.example.com",
        path: "/v1/health/batches/b1?email=ada%40example.com&token=secret-token",
        headerFields: [.authorization: "Bearer secret-token"]),
      requestBody: HTTPBody("body-value"),
      baseURL: URL(string: "https://api.example.com/?token=secret-token"),
      response: HTTPResponse(
        status: .internalServerError, headerFields: [.setCookie: "Ada Lovelace"]),
      responseBody: HTTPBody("body-value"),
      causeDescription: "Cannot decode Ada Lovelace",
      underlyingError: underlying)
    // What the log used to get.
    #expect("\(error)".contains("Ada Lovelace"))

    let summary = BackfillLog.describe(error)
    #expect(
      summary
        == "ClientError(operation: healthUploadBatch, status: 500, underlying: "
        + "EncodingError.invalidValue(Double, at: samples[3].value))")
    expectNoValues(summary)
  }

  @Test func encodingErrorKeepsTheValuesTypeAndPath() {
    let error = EncodingError.invalidValue(
      "Ada Lovelace",
      .init(
        codingPath: [Field.metadata, Key(stringValue: "ada@example.com")],
        debugDescription: "Ada Lovelace isn't valid",
        underlyingError: NSError(
          domain: "Synthetic", code: 7,
          userInfo: [NSLocalizedDescriptionKey: "Ada Lovelace", "value": 72.5])))
    #expect("\(error)".contains("Ada Lovelace"))

    let summary = BackfillLog.describe(error)
    // A dictionary's key is data.
    #expect(
      summary
        == "EncodingError.invalidValue(String, at: metadata.<key>, underlying: NSError(Synthetic 7))"
    )
    expectNoValues(summary)
  }

  @Test func aDictionarysKeysAreData() {
    // Even when they read as names or numbers.
    let named = EncodingError.invalidValue(
      72.5, .init(codingPath: [Field.metadata, Key(stringValue: "Ada")], debugDescription: ""))
    #expect(BackfillLog.describe(named) == "EncodingError.invalidValue(Double, at: metadata.<key>)")
    let numbered = DecodingError.typeMismatch(
      Int.self, .init(codingPath: [Key(intValue: 72)], debugDescription: ""))
    #expect(BackfillLog.describe(numbered) == "DecodingError.typeMismatch(Int, at: <key>)")
  }

  @Test func theCodersOwnErrors() throws {
    // What JSONEncoder and JSONDecoder throw, not errors made up to look like theirs.
    let encoding = #expect(throws: EncodingError.self) {
      try JSONEncoder().encode([Sample(value: 1), Sample(value: 2, metadata: ["Ada": .nan])])
    }
    let encoded = BackfillLog.describe(try #require(encoding))
    #expect(encoded == "EncodingError.invalidValue(Double, at: [1].metadata.<key>)")
    expectNoValues(encoded)

    let decoding = #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        [Sample].self,
        from: Data(
          #"[{"value": 1, "metadata": {}}, {"value": "Ada Lovelace", "metadata": {}}]"#.utf8))
    }
    let decoded = BackfillLog.describe(try #require(decoding))
    #expect(decoded == "DecodingError.typeMismatch(Double, at: [1].value)")
    expectNoValues(decoded)

    let keyed = #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        [String: Sample].self, from: Data(#"{"Ada": {"value": 1, "metadata": {"Ada": "x"}}}"#.utf8))
    }
    let decodedKeyed = BackfillLog.describe(try #require(keyed))
    #expect(decodedKeyed == "DecodingError.typeMismatch(Double, at: <key>.metadata.<key>)")
    expectNoValues(decodedKeyed)
  }

  @Test func decodingErrorsKeepTheirCaseTypeAndPath() {
    let context = DecodingError.Context(
      codingPath: [Field.batches, Key.index(0), Field.status],
      debugDescription: "Cannot decode 'Ada Lovelace' as Int")
    #expect(
      BackfillLog.describe(DecodingError.typeMismatch(Int.self, context))
        == "DecodingError.typeMismatch(Int, at: batches[0].status)")
    #expect(
      BackfillLog.describe(DecodingError.valueNotFound(String.self, context))
        == "DecodingError.valueNotFound(String, at: batches[0].status)")
    #expect(
      BackfillLog.describe(DecodingError.keyNotFound(Field.failure, context))
        == "DecodingError.keyNotFound(failure, at: batches[0].status)")
    let corrupted = DecodingError.dataCorrupted(
      .init(
        codingPath: [], debugDescription: "Cannot decode 'Ada Lovelace'",
        underlyingError: NSError(
          domain: NSCocoaErrorDomain, code: 3840,
          userInfo: [NSDebugDescriptionErrorKey: "Unexpected 'Ada Lovelace' around 72.5"])))
    let summary = BackfillLog.describe(corrupted)
    #expect(summary == "DecodingError.dataCorrupted(underlying: NSError(NSCocoaErrorDomain 3840))")
    expectNoValues(summary)
  }

  @Test func cocoaErrorsKeepTheirDomainAndCode() {
    let url = URLError(
      .timedOut,
      userInfo: [
        NSURLErrorFailingURLErrorKey: URL(string: "https://api.example.com/?token=secret-token")!,
        NSUnderlyingErrorKey: NSError(
          domain: "kCFErrorDomainCFNetwork", code: -1001,
          userInfo: [NSLocalizedDescriptionKey: "Ada Lovelace"]),
      ])
    let summary = BackfillLog.describe(url)
    #expect(
      summary
        == "NSError(NSURLErrorDomain -1001, underlying: NSError(kCFErrorDomainCFNetwork -1001))")
    expectNoValues(summary)

    let healthKit = NSError(
      domain: "com.apple.healthkit", code: 6,
      userInfo: [NSLocalizedDescriptionKey: "Protected health data is inaccessible: Ada Lovelace"])
    #expect(BackfillLog.describe(healthKit) == "NSError(com.apple.healthkit 6)")
  }

  @Test func swiftErrorsKeepTheirTypeCaseAndKeptFields() {
    let failure = SyntheticFailure(statusCode: 500, expected: 4, note: "Ada's note", weight: 72.5)
    let summary = BackfillLog.describe(failure)
    #expect(
      summary
        == "BackfillLogErrorTests.SyntheticFailure(statusCode: 500, expected: 4, note: <String>, weight: <Double>)"
    )
    expectNoValues(summary)

    #expect(
      BackfillLog.describe(SyntheticReason.refused(note: "Ada Lovelace"))
        == "BackfillLogErrorTests.SyntheticReason.refused")
    #expect(
      BackfillLog.describe(SyntheticReason.gone) == "BackfillLogErrorTests.SyntheticReason.gone")
    // Its description could say anything.
    #expect(
      BackfillLog.describe(SyntheticDescribed.gone) == "BackfillLogErrorTests.SyntheticDescribed")
    #expect(BackfillLog.describe(CancellationError()) == "CancellationError")
  }

  @Test func theBackfillsOwnErrors() {
    #expect(
      BackfillLog.describe(HealthReader.SeriesUnavailable(expected: 4, read: 2))
        == "HealthReader.SeriesUnavailable(expected: 4, read: 2)")
    #expect(
      BackfillLog.describe(HealthBatchUploader.Rejected(statusCode: 413))
        == "HealthBatchUploader.Rejected(statusCode: 413)")
    #expect(
      BackfillLog.describe(
        HealthBatchWriter.LineTooLong(entity: "health_sample", id: "Ada Lovelace"))
        == "HealthBatchWriter.LineTooLong(entity: health_sample, id: <String>)")
  }

  @Test func privateDetailNeverGoesToTheFile() {
    #expect(
      BackfillLog.fileLine("batch b1 of StepCount failed", privateDetail: nil)
        == "batch b1 of StepCount failed")
    #expect(
      BackfillLog.fileLine(
        "batch b1 of StepCount failed", privateDetail: "Unexpected token in 'Ada Lovelace'")
        == "batch b1 of StepCount failed: <private>")
  }
}
