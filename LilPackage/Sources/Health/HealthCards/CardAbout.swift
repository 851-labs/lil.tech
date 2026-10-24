import HealthCatalog

extension CardSpec {
  /// What the card charts, in one sentence, as its page's About This Card says (851-3207,
  /// docs/decisions/cards.md, UI › Mac): "Average heart rate in the 5 minutes before falling
  /// asleep, per night." Its visible series, each by its aggregation, type, window and filter, then
  /// its bucket (none for `auto`, whose points follow the range), then its visible formulas. A card
  /// showing only formulas is described by them. Built from the spec, never its labels, so it says
  /// what a label may not. In `HealthCards`, so the iPhone's page says the same.
  public var about: String {
    let visibleSeries = series.filter { !$0.hidden }
    let visibleFormulas = formulas.filter { !$0.hidden }
    var sentence: String
    var formulaPhrases: [String]
    if visibleSeries.isEmpty {
      sentence = visibleFormulas.map { describe($0, alone: true) }.joined(separator: " and ")
      formulaPhrases = []
    } else {
      sentence = visibleSeries.map { describe($0, drawn: true) }.joined(separator: " and ")
      formulaPhrases = visibleFormulas.map { describe($0, alone: false) }
    }
    if let bucket = bucketPhrase {
      sentence += ", \(bucket)"
    }
    if !formulaPhrases.isEmpty {
      sentence += ", with " + formulaPhrases.joined(separator: " and ")
    }
    return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
  }

  /// "per night", or `nil` for `auto`.
  private var bucketPhrase: String? {
    bucket == .auto ? nil : "per \(bucket.rawValue)"
  }

  /// What one of the card's points is called in a moving average's span: "7-day", or "7-point"
  /// for `auto`, whose points are the range's.
  private var pointName: String {
    bucket == .auto ? "point" : bucket.rawValue
  }

  /// A series in words: "average heart rate while asleep", "first weight reading before noon".
  /// `drawn`: as the chart draws it, so an average drawn as `ranges` is its range; a formula's
  /// series are its values.
  private func describe(_ series: Series, drawn: Bool) -> String {
    let name = Self.lowercased(series.dataType?.name ?? series.type)
    var phrase =
      switch series.aggregation {
      case .sum: "total \(name)"
      case .avg where drawn && chart.style == .ranges: "\(name) range"
      case .avg: "average \(name)"
      case .min: "lowest \(name)"
      case .max: "highest \(name)"
      case .first: "first \(name) reading"
      case .latest: "latest \(name) reading"
      case .count: "number of \(name) readings"
      }
    if let window = series.window {
      phrase += " " + Self.describe(window)
    }
    if let filter = series.filter {
      phrase += " " + Self.describe(filter)
    }
    return phrase
  }

  /// A formula in words. `alone`: it's what the card shows, its series hidden, so it names them.
  private func describe(_ formula: Formula, alone: Bool) -> String {
    func seriesPhrase(_ id: String) -> String {
      series.first { $0.id == id }.map { describe($0, drawn: false) } ?? id
    }
    switch formula.operation {
    case .movingAverage(let of, let points):
      let average = "a \(points)-\(pointName) moving average"
      // Which series, when it isn't the only one shown, or isn't shown.
      return alone || series.count > 1 ? "\(average) of \(seriesPhrase(of))" : average
    case .difference(let minuend, let subtrahend):
      return "\(seriesPhrase(minuend)) minus \(seriesPhrase(subtrahend))"
    }
  }

  private static func describe(_ window: Window) -> String {
    switch window {
    case .asleep:
      return "while asleep"
    case .beforeSleep(let minutes):
      return minutes == 1
        ? "in the minute before falling asleep" : "in the \(minutes) minutes before falling asleep"
    case .afterWaking(let minutes):
      return minutes == 1 ? "in the minute after waking" : "in the \(minutes) minutes after waking"
    case .workout(nil):
      return "during workouts"
    case .workout(let activities?):
      let names = activities.map { lowercased(HealthCatalog.workoutActivityName($0)) }
      return "during \(list(names, joinedBy: "or")) workouts"
    case .timeOfDay(let time):
      func clock(_ time: CardClockTime) -> String {
        time.hour == 12 && time.minute == 0 ? "noon" : time.description
      }
      if time.from.secondsSinceMidnight == 0 { return "before \(clock(time.to))" }
      if time.to.secondsSinceMidnight == 0 { return "from \(clock(time.from)) to midnight" }
      return "from \(clock(time.from)) to \(clock(time.to))"
    }
  }

  /// "from Watch", "from 2 sources", "from Watch in one source".
  private static func describe(_ filter: Filter) -> String {
    let sources = filter.sources.map { $0.count == 1 ? "one source" : "\($0.count) sources" }
    guard let models = filter.deviceModels else { return "from \(sources ?? "")" }
    let devices = "from \(list(models, joinedBy: "or"))"
    return sources.map { "\(devices) in \($0)" } ?? devices
  }

  /// "a", "a or b", "a, b or c".
  private static func list(_ items: [String], joinedBy word: String) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " \(word) " + items[items.count - 1]
  }

  /// A name as it reads mid-sentence: its capitalized words lowercased ("Heart Rate" is "heart
  /// rate"), abbreviations and symbols kept ("VO₂ Max" is "VO₂ max", "HRV" stays).
  static func lowercased(_ name: String) -> String {
    func lowercased(_ word: Substring) -> String {
      guard let first = word.first, first.isUppercase,
        word.dropFirst().allSatisfy({ $0.isLowercase })
      else { return String(word) }
      return word.lowercased()
    }
    // Each part of a hyphenated word too: "Six-Minute" is "six-minute".
    return name.split(separator: " ", omittingEmptySubsequences: false).map { word in
      word.split(separator: "-", omittingEmptySubsequences: false).map(lowercased)
        .joined(separator: "-")
    }
    .joined(separator: " ")
  }
}
