import Foundation
public import HealthKit

extension HealthEncoder {
  public static let audiogramEntity = "health_audiogram"

  /// An audiogram: each tested frequency (Hz) with its tests, sensitivities in dBHL
  /// (`HealthAudiogram` on the server). HealthKit keeps the frequencies unique and ascending.
  public static func audiogram(_ audiogram: HKAudiogramSample) -> HealthMutation {
    var row = provenance(of: audiogram)
    let decibels = HKUnit.decibelHearingLevel()
    row["points"] = .array(
      audiogram.sensitivityPoints.map { point in
        .object([
          "frequency": .number(point.frequency.doubleValue(for: .hertz())),
          "tests": .array(
            point.tests.map { test in
              .object([
                "side": JSONValue(test.side.rawValue),
                "type": JSONValue(test.type.rawValue),
                "masked": .bool(test.masked),
                "sensitivity": .number(test.sensitivity.doubleValue(for: decibels)),
                "clampingLower": JSONValue(
                  test.clampingRange?.lowerBound?.doubleValue(for: decibels)),
                "clampingUpper": JSONValue(
                  test.clampingRange?.upperBound?.doubleValue(for: decibels)),
              ])
            }),
        ])
      })
    return .upsert(audiogramEntity, id: id(audiogram.uuid), row: row)
  }
}
