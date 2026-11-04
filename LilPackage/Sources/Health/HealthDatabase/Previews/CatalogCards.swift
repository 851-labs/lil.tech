import Foundation
public import HealthCardStore
import HealthCards
public import SQLiteData

// Cards snapshot catalogs share (851-3211): the Mac's and the iPhone's Summary, and the card page.
// Synthetic data only.

/// A card of spec version 2, which this version can't read: its name, symbol and color still
/// show.
public let laterVersionCard = Card(
  HealthCard(
    id: "card_01JB7Z0000000000000000000A",
    spec:
      #"{"version":2,"display":{"name":"Oxygen at Altitude","symbol":"lungs.fill","color":"teal","unit":null},"series":[]}"#,
    position: "a1V", createdAt: 0, updatedAt: 0))

/// The design's five example cards, in its order, as an agent would write them. Summary's catalogs
/// (the Mac's and the iPhone's) show their rows, and the Card Detail catalog their pages.
public let exampleCards: [Card] = [
  #"{"version": 1, "display": {"name": "Body Temperature", "symbol": "thermometer.medium", "color": "red"}, "series": [{"type": "Body Temperature"}], "range": "M", "chart": {"style": "line"}}"#,
  #"{"version": 1, "display": {"name": "Sleeping Heart Rate", "symbol": "moon.zzz.fill", "color": "indigo"}, "series": [{"type": "Heart Rate", "window": {"kind": "asleep"}}], "bucket": "night", "range": "M", "chart": {"style": "line"}}"#,
  #"{"version": 1, "display": {"name": "HRV", "symbol": "waveform.path.ecg", "color": "pink"}, "series": [{"type": "HeartRateVariabilitySDNN"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7}], "range": "M", "chart": {"style": "dots"}}"#,
  #"{"version": 1, "display": {"name": "Heart Rate Before Sleep", "symbol": "bed.double.fill", "color": "mint"}, "series": [{"type": "Heart Rate", "window": {"kind": "beforeSleep", "minutes": 5}}], "bucket": "night", "range": "M", "chart": {"style": "dots"}}"#,
  #"{"version": 1, "display": {"name": "Morning Weight", "symbol": "scalemass.fill", "color": "purple"}, "series": [{"type": "Weight", "aggregation": "first", "window": {"kind": "timeOfDay", "from": "00:00", "to": "12:00"}, "label": "First weigh-in before noon"}], "formulas": [{"id": "trend", "kind": "movingAverage", "of": "a", "points": 7, "label": "7-day rolling average"}], "bucket": "day", "range": "M", "chart": {"style": "dots"}}"#,
].enumerated().map { index, json in
  Card(
    id: "card_01JB7Z000000000000000000\(index)E",
    spec: try! CardSpec(inputJSON: Data(json.utf8)), position: "a\(index)", createdAt: 0,
    updatedAt: 0)
}

/// The catalog database, and a heart rate reading 3 minutes before each night's sleep, which
/// its readings every 30 minutes never are (it's asleep from 23:00): for the example of heart
/// rate before falling asleep. Its own, so no other catalog's images change.
public let exampleCardsDatabase = makeExampleCardsDatabase()

/// `exampleCardsDatabase` with no reading before falling asleep this week: the latest is the
/// night of Saturday, Aug 10, while heart rate goes on every 30 minutes to today. For a card with
/// a window whose type's latest data has none of its readings (851-3987).
public let lapsedBeforeSleepDatabase = makeExampleCardsDatabase(firstNight: 3)

/// The catalog database, with a heart rate reading 3 minutes before the sleep of each night
/// `firstNight` to 13 nights before `previewNow`'s (0 is last night's, the night of today).
private func makeExampleCardsDatabase(firstNight: Int = 0) -> any DatabaseWriter {
  let database = makePreviewHealthDatabase(now: previewNow, calendar: previewCalendar)
  let today = previewCalendar.startOfDay(for: previewNow)
  try! database.write { db in
    try HealthSample.insert {
      (firstNight..<14).map { night in
        let start = previewCalendar.date(byAdding: .day, value: -night, to: today)!
          .addingTimeInterval(-63 * 60)
        return HealthSample(
          id: "00000000-0000-4000-8000-0000000000\(10 + night)",
          type: HealthDatabase.heartRateType,
          startDate: start.unixMilliseconds, endDate: start.unixMilliseconds + 60_000,
          value: Double(62 + night * 7 % 9), unit: "count/min", sourceName: "Apple Watch",
          sourceBundleID: "com.apple.health.watch")
      }
    }
    .execute(db)
  }
  return database
}
