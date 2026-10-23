import Foundation
import HealthCatalog
import HealthDatabase
import HealthUI
import LilUI
import SQLiteData
import SwiftUI

/// Sleep's highlights (851-3103), as iPad Health's under its chart: a section of rows, each a
/// sentence and a chart, as Summary's highlights are. Each shows only with enough data
/// (`SleepHighlights`), and the section only with one. It's the page's last section, so nothing
/// moves when it loads or its rows come and go.
struct SleepHighlightsSection: View {
  enum State: Equatable {
    case loading
    case loaded(SleepHighlights)
    case failed(String)

    var isLoading: Bool { self == .loading }
  }

  let state: State
  /// Whether a load has run long enough to show its spinner (`DelayedProgress`, 851-3086). Until
  /// then there's no section: most pages have no highlights, so its header would flash on each
  /// open, then go.
  var showsProgress = true

  var body: some View {
    switch state {
    case .loading:
      if showsProgress {
        Section("Highlights") {
          // Already past the delay: the section only shows once the load has run that long.
          ProgressView()
            .frame(maxWidth: .infinity)
        }
      }
    case .failed(let reason):
      Section("Highlights") {
        Text("Couldn't load highlights. \(reason)")
          .foregroundStyle(.secondary)
      }
    case .loaded(let highlights) where highlights.isEmpty:
      EmptyView()
    case .loaded(let highlights):
      Section("Highlights") {
        if let bedtime = highlights.bedtime { BedtimeHighlight(bedtime: bedtime) }
        if let months = highlights.months { SleepMonthsHighlight(months: months) }
        if let heartRate = highlights.heartRate { SleepHeartRateHighlight(heartRate: heartRate) }
        if let week = highlights.week { SleepWeekHighlight(week: week) }
        if let night = highlights.stages { SleepStagesHighlight(night: night) }
      }
    }
  }
}

/// Sleep's highlights as of the day it's for, whichever period the page shows.
struct SleepHighlightsRequest: FetchKeyRequest {
  /// The day it's for, so a new day is a new request.
  let day: Date
  let calendar: Calendar

  init(day: Date, calendar: Calendar) {
    self.day = calendar.startOfDay(for: day)
    self.calendar = calendar
  }

  func fetch(_ db: Database) throws -> SleepHighlights? {
    try HealthDatabase.sleepHighlights(today: day, calendar: calendar, db)
  }
}

/// One highlight, in a form row: whose it is, what it says, in a sentence, and its chart, as
/// Summary's highlights are.
struct SleepHighlightRow<Content: View>: View {
  let title: String
  let systemImage: String
  let color: Color
  let sentence: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: systemImage)
        .font(.headline)
        .foregroundStyle(color)
      Text(sentence)
        .font(.title3.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      content
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// How Sleep's highlights look and read.
enum SleepHighlightStyle {
  /// Sleep's color in Health's highlights, an indigo.
  static let sleep = Color.indigo
  /// The average, in Health's teal (#00C7BE, the system's mint).
  static let average = Color.mint
  /// Earlier nights or months, as Summary's highlights draw the earlier week.
  static let earlier = ComparisonBars.earlierColor
  /// Heart's color, for heart rate while asleep.
  static let heart = HealthCategory.heart.color
  /// Heights of the highlights' charts.
  static let chartHeight: CGFloat = 120

  /// A clock time in hours from a day's midnight (`HealthDatabase.clockHours`), "10:54 PM", in
  /// the calendar's locale.
  static func clockTime(_ hours: Double, calendar: Calendar) -> String {
    let total = (Int((hours * 60).rounded()) % 1440 + 1440) % 1440
    // A time in GMT, which has no daylight saving gaps, formatted there.
    let style = Date.FormatStyle(
      date: .omitted, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar,
      timeZone: .gmt)
    let date = Date(timeIntervalSince1970: Double(total) * 60)
    return date.formatted(style.hour().minute())
  }

  /// A difference in minutes: "18 minutes", "1 minute", or "1 hr 5 min" from an hour.
  static func minutes(_ minutes: Int) -> String {
    let minutes = abs(minutes)
    if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
    return SleepFormat.duration(Double(minutes) * 60)
  }
}
