import Foundation
import HealthConformance
import Testing

/// A conformance dataset can't send a record under two keys (851-4181): the server would keep both,
/// and the Mac only the last, so the two sides would answer differently.
@Suite
struct ConformanceRecordKeysTests {
  // Synthetic data only (AGENTS.md).
  static let id = "0ca7d000-0000-4000-8000-000000000201"
  static let steps = "HKQuantityTypeIdentifierStepCount"

  static func sample(_ type: String, _ startDate: Int, value: Double = 1) -> [String: Any] {
    [
      "entity": "health_sample", "op": "upsert", "id": id,
      "row": ["type": type, "startDate": startDate, "endDate": startDate + 60_000, "value": value],
    ]
  }

  @Test
  func takesAnIDSentAgainUnderItsKey() throws {
    try ConformanceBatch.checkRecordKeys([
      Self.sample(Self.steps, 1_748_736_000_000),
      ["entity": "health_sample", "op": "delete", "id": Self.id],
      Self.sample(Self.steps, 1_748_736_000_000, value: 2),
      [
        "entity": "health_workout", "op": "upsert", "id": Self.id,
        "row": ["startDate": 1_748_740_000_000],
      ],
    ])
  }

  @Test
  func refusesAnIDSentUnderAnotherStartOrType() {
    #expect(throws: ConformanceError.self) {
      try ConformanceBatch.checkRecordKeys([
        Self.sample(Self.steps, 1_748_736_000_000), Self.sample(Self.steps, 1),
      ])
    }
    #expect(throws: ConformanceError.self) {
      try ConformanceBatch.checkRecordKeys([
        Self.sample(Self.steps, 1_748_736_000_000),
        Self.sample("HKQuantityTypeIdentifierHeartRate", 1_748_736_000_000),
      ])
    }
    // Compared as JSON, as the server does: a number isn't the same text in a string.
    var text = Self.sample(Self.steps, 1_748_736_000_000)
    text["row"] = ["type": Self.steps, "startDate": "1748736000000"]
    #expect(throws: ConformanceError.self) {
      try ConformanceBatch.checkRecordKeys([Self.sample(Self.steps, 1_748_736_000_000), text])
    }
  }
}
