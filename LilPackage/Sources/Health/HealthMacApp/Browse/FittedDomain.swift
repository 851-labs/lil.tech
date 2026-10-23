import HealthCatalog

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
/// day's total, usually reach, so the chart keeps its gridlines and a scale that reads as the
/// type's while the header says No Data, rather than an axis with no marks. In `unit`, what the
/// values are stored in (the type's, or a category chart's).
func emptyDomain(for type: HealthDataType, unit: String?) -> ClosedRange<Double> {
  switch type.id {
  case "HKQuantityTypeIdentifierStepCount": return 0...10_000
  case "HKQuantityTypeIdentifierBodyMassIndex": return 0...40
  case "HKQuantityTypeIdentifierSixMinuteWalkTestDistance": return 0...600
  case "HKQuantityTypeIdentifierUnderwaterDepth": return 0...40
  default: break
  }
  switch unit {
  case "%": return 0...1
  case "count/min", "mmHg", "ms": return 0...150
  case "mg/dL": return 0...200
  case "dBASPL", "kg", "g", "mcg": return 0...100
  case "degC": return 0...40
  case "kcal", "mg": return 0...1_000
  case "mL": return 0...2_000
  case "min": return 0...60
  case "hr": return 0...12
  case "IU": return 0...50
  case "W": return 0...300
  case "L": return 0...5
  case "L/min": return 0...600
  case "ml/(kg*min)": return 0...60
  case "count", "times", "cm", "m/s", "mcS", "appleEffortScore", "kcal/(kg*hr)": return 0...10
  // A distance's total, or a length: a height, a step.
  case "m": return type.aggregation?.isCumulative == true ? 0...5_000 : 0...2
  default: return 0...100
  }
}
