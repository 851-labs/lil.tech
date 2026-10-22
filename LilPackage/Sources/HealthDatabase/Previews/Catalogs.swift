public import Foundation
public import SQLiteData

// What snapshot catalogs share (851-2950), so their images only change when the UI does: one
// "now", one calendar, and the preview database built from them. Catalogs pass `previewNow` and
// `previewCalendar` to everything that asks for the date, and nothing a catalog state reaches reads
// `Date()`, `.now` or `Calendar.current`.

/// The fixed "now" of snapshot catalogs: Tuesday, August 13, 2024, 3 PM in `previewCalendar`'s
/// time zone. Pixelbook's day, but the afternoon: its clock (07:00 UTC) is midnight in Los
/// Angeles, which leaves today without data.
public let previewNow = Date(timeIntervalSince1970: 1_723_586_400)

/// The calendar of snapshot catalogs: Gregorian, in Los Angeles, with `en_US`'s weeks (starting
/// on Sunday). Snapshot tests make its time zone and locale the process's.
public let previewCalendar: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
  calendar.locale = Locale(identifier: "en_US")
  return calendar
}()

/// The synthetic database of snapshot catalogs: the preview database's data at `previewNow`, in
/// `previewCalendar`, so the same rows on any day and any Mac. Built once per process. A catalog's
/// suite makes it the `defaultDatabase`, with `previewNow` and `previewCalendar` the `date` and
/// `calendar` (a `.dependencies { … }` trait, as `MacSnapshotTests`'), and its states read it,
/// never write to it.
public let catalogDatabase: any DatabaseWriter = makePreviewHealthDatabase(
  now: previewNow, calendar: previewCalendar)
