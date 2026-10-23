import HealthCatalog
import HealthPages

/// Averages' values, with room above and below, rather than from zero: a weight's change of a
/// kilogram would be a flat line at the top of a chart from 0 (851-3097). A single value, or
/// several the same, gets a few percent of itself each side, and values that are all 0 a unit.
/// Never below 0 for values that aren't (a UV index, blood alcohol). Metric Detail's dots and
/// lines use it, and so do the rows' sparklines (851-3101). `nil` without values.
func fittedDomain(_ values: [Double]) -> ClosedRange<Double>? {
  guard let low = values.min(), let high = values.max() else { return nil }
  var padding = max((high - low) * 0.2, abs(high) * 0.02, abs(low) * 0.02)
  if padding == 0 { padding = 1 }
  let lower = low >= 0 ? max(low - padding, 0) : low - padding
  return lower...(high + padding)
}

/// An empty period's y-axis (851-3102): from 0 to about as high as the type's readings, or a
/// day's total, usually reach, a tenth of that for a total's hourly bars (`hourly`), so the
/// chart keeps its gridlines and a scale that reads as the type's while the header says No Data,
/// rather than an axis with no marks. In `unit`, what the values are stored in (the type's, or a
/// category chart's): Metric Detail plots it `converted(by:)` the type's display unit (851-3105),
/// so 5,000 m is 0–5 km.
func emptyDomain(for type: HealthDataType, unit: String?, hourly: Bool = false)
  -> ClosedRange<Double>
{
  let top = typicalTop(type, unit: unit)
  return 0...(hourly ? top / 10 : top)
}

/// About the most a type's readings, or a day's total, reach.
private func typicalTop(_ type: HealthDataType, unit: String?) -> Double {
  let prefix = "HKQuantityTypeIdentifier"
  switch type.id.hasPrefix(prefix) ? String(type.id.dropFirst(prefix.count)) : type.id {
  case "StepCount", "NikeFuel": return 10_000
  case "PushCount": return 5_000
  case "SwimmingStrokeCount": return 2_000
  case "BodyMassIndex": return 40
  case "SixMinuteWalkTestDistance": return 600
  case "UnderwaterDepth": return 40
  case "RunningGroundContactTime": return 300
  // 0.1%, over the stored fraction.
  case "BloodAlcoholContent": return 0.001
  default: break
  }
  switch unit {
  case "%": return 1
  case "count/min", "mmHg", "ms": return 150
  case "mg/dL": return 200
  case "dBASPL", "kg", "mcg": return 100
  case "g": return 300
  case "degC": return 40
  case "mg": return 1_000
  case "kcal", "mL": return 2_500
  case "min": return 60
  case "hr": return 12
  case "IU": return 50
  case "W": return 300
  case "L": return 5
  case "L/min": return 600
  case "ml/(kg*min)": return 60
  case "count", "times", "cm", "mcS", "appleEffortScore", "kcal/(kg*hr)": return 10
  // 0–25 km/h, as speeds show (stair speeds stay in m/s, and are their own).
  case "m/s": return type.id.contains("Stair") ? 1 : 25 / 3.6
  // A distance's total, or a length: a height, a step.
  case "m": return type.aggregation?.isCumulative == true ? 5_000 : 2
  default: return 100
  }
}

extension ClosedRange<Double> {
  /// Both ends in `unit`, as Metric Detail plots values (851-3105).
  func converted(by unit: MetricFormat.DisplayUnit) -> ClosedRange<Double> {
    unit.convert(lowerBound)...unit.convert(upperBound)
  }
}
