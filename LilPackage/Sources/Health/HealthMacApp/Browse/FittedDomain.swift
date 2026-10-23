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
