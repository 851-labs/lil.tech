public import Foundation

/// Records (newest first) by the `component` (day, month…) of `calendar` they started in, as
/// Health lists them: workouts and ECGs by month, beat-to-beat measurements, State of Mind, All
/// Data's samples and Food's foods by day (851-3045).
///
/// It asks the calendar only when a record leaves the section before it, since All Data can load
/// thousands of samples in a day. A record at the section's end (the next one's start) starts the
/// next section, so the sections are the same as asking the calendar for every record. Records out
/// of order start a section each time their section changes, and two records the calendar can't
/// place (no interval) share one only when they started at the same moment.
public func sections<Record>(
  _ records: [Record], by component: Calendar.Component, calendar: Calendar,
  startDate: (Record) -> Int
) -> [(start: Date, records: [Record])] {
  var sections: [(start: Date, records: [Record])] = []
  // The last section's interval, while the calendar gave one.
  var interval: DateInterval?
  for record in records {
    let date = Date(unixMilliseconds: startDate(record))
    if let interval, interval.start <= date, date < interval.end {
      sections[sections.count - 1].records.append(record)
      continue
    }
    interval = calendar.dateInterval(of: component, for: date)
    let start = interval?.start ?? date
    if sections.last?.start == start {
      sections[sections.count - 1].records.append(record)
    } else {
      sections.append((start, [record]))
    }
  }
  return sections
}
