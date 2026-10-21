import ArgumentParser
import GRDB
import HealthTools

// `lil-health`'s commands: one per tool of the Health toolkit, with the tool's arguments as
// options, so `lil-health metric Steps --range W --json` answers as the `metric` tool does.

/// The root: `lil-health --describe`, else its help.
struct LilHealthCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "lil-health",
    abstract: "Reads lil health's data on this Mac, as lil health shows it.",
    discussion: """
      Each command answers from the data lil health has synced to this Mac, read-only, while \
      you allow command-line and agent access in lil health › Settings… › Agents. lil health \
      logs each one there.

      Types are HealthKit identifiers (HKQuantityTypeIdentifierStepCount), or names as lil \
      health shows them (Steps, "Heart Rate"). Find them with `types` and `search`. Days and \
      times are in this Mac's time zone, or --time-zone's. Add --json for the toolkit's JSON, \
      as lil health's MCP servers answer.

      Exit statuses: 64 for a usage error, 65 for an unknown type, time zone or date, 69 if \
      there's no lil health data to read, 77 while access is off.
      """,
    subcommands: [
      SummaryCommand.self, TypesCommand.self, MetricCommand.self, SamplesCommand.self,
      WorkoutsCommand.self, SleepCommand.self, MedicationsCommand.self, DetailsCommand.self,
      SearchCommand.self, SyncCommand.self, MCPCommand.self,
    ]
  )

  @Flag(help: "Print a one-line description, for `lil help`.")
  var describe = false
}

/// A command that answers a query.
protocol QueryCommand: ParsableCommand {
  var output: OutputOptions { get }
  func answer(_ tools: HealthTools, _ db: Database) throws -> Answer
}

/// A query's answer, as JSON and as text.
struct Answer {
  var json: any Encodable
  var text: String

  init<Output: HealthToolOutput & TextOutput>(_ output: Output) {
    json = output
    text = output.text
  }
}

struct OutputOptions: ParsableArguments {
  @Flag(help: "Print the answer as JSON.")
  var json = false
}

/// A range, as `ToolRange`, in any case (`6m`).
struct RangeArgument: ExpressibleByArgument {
  var range: ToolRange

  init(_ range: ToolRange) {
    self.range = range
  }

  init?(argument: String) {
    guard let range = ToolRange(rawValue: argument.uppercased()) else { return nil }
    self.range = range
  }

  var defaultValueDescription: String { range.rawValue }
  static var allValueStrings: [String] { ToolRange.allCases.map(\.rawValue) }
}

struct StatisticArgument: ExpressibleByArgument {
  var statistic: HealthTools.Statistic

  init?(argument: String) {
    guard let statistic = HealthTools.Statistic(rawValue: argument.lowercased()) else {
      return nil
    }
    self.statistic = statistic
  }

  static var allValueStrings: [String] { HealthTools.Statistic.allCases.map(\.rawValue) }
}

private let timeZoneHelp = ArgumentHelp(
  "An IANA time zone for days and times, e.g. Europe/London. Defaults to this Mac's.",
  valueName: "zone")
private let rangeHelp = ArgumentHelp(
  """
  D (a day, by the hour), W (7 days), M (30 days), 6M (26 weeks, by the week) or Y (12 months, \
  by the month), ending on --date.
  """,
  valueName: "range")
private let dateHelp = ArgumentHelp(
  "The last day of the range, as YYYY-MM-DD. Defaults to today.", valueName: "day")
private let typeHelp = ArgumentHelp(
  "A HealthKit identifier, or the name lil health shows, e.g. Steps.", valueName: "type")

struct SummaryCommand: QueryCommand {
  static let configuration = CommandConfiguration(
    commandName: "summary",
    abstract: "The pinned metrics (or everyday ones), with today's and the last 7 days' totals.")

  @Option(help: timeZoneHelp) var timeZone: String?
  @OptionGroup var output: OutputOptions

  func answer(_ tools: HealthTools, _ db: Database) throws -> Answer {
    Answer(try tools.summary(timeZone: timeZone, db))
  }
}

struct TypesCommand: QueryCommand {
  static let configuration = CommandConfiguration(
    commandName: "types", abstract: "The kinds of data there are, with their dates.")

  @Option(help: timeZoneHelp) var timeZone: String?
  @OptionGroup var output: OutputOptions

  func answer(_ tools: HealthTools, _ db: Database) throws -> Answer {
    Answer(try tools.listTypes(timeZone: timeZone, db))
  }
}

struct MetricCommand: QueryCommand {
  static let configuration = CommandConfiguration(
    commandName: "metric",
    abstract: "A quantity's statistic over a range, overall and per hour, day, week or month.",
    discussion: """
      Totals of types that add up (steps) come from the iPhone's own statistics, as lil health \
      charts them. For them, average, minimum and maximum are of daily totals.
      """)

  @Argument(help: typeHelp) var type: String
  @Option(name: .shortAndLong, help: rangeHelp) var range = RangeArgument(.week)
  @Option(
    name: .shortAndLong,
    help: "sum, average, minimum or maximum. Defaults to sum for types that add up, else average.")
  var statistic: StatisticArgument?
  @Option(help: dateHelp) var date: String?
  @Option(help: timeZoneHelp) var timeZone: String?
  @OptionGroup var output: OutputOptions

  func answer(_ tools: HealthTools, _ db: Database) throws -> Answer {
    Answer(
      try tools.metric(
        type: type, range: range.range, statistic: statistic?.statistic, date: date,
        timeZone: timeZone, db))
  }
}

struct SamplesCommand: QueryCommand {
  static let configuration = CommandConfiguration(
    commandName: "samples",
    abstract: "A quantity or category type's samples in a range, newest first, a page at a time.")

  @Argument(help: typeHelp) var type: String
  @Option(name: .shortAndLong, help: rangeHelp) var range = RangeArgument(.day)
  @Option(help: dateHelp) var date: String?
  @Option(help: "The previous page's next cursor.") var cursor: String?
  @Option(help: "Samples per page, at most \(HealthTools.samplesLimit). Defaults to 100.")
  var limit: Int?
  @Option(help: timeZoneHelp) var timeZone: String?
  @OptionGroup var output: OutputOptions

  func answer(_ tools: HealthTools, _ db: Database) throws -> Answer {
    Answer(
      try tools.samples(
        type: type, range: range.range, date: date, timeZone: timeZone, cursor: cursor,
        limit: limit,
        db))
  }
}

struct WorkoutsCommand: QueryCommand {
  static let configuration = CommandConfiguration(
    commandName: "workouts", abstract: "Workouts in a range, newest first, with their totals.")

  @Option(name: .shortAndLong, help: rangeHelp) var range = RangeArgument(.week)
  @Option(help: dateHelp) var date: String?
  @Option(help: timeZoneHelp) var timeZone: String?
  @OptionGroup var output: OutputOptions

  func answer(_ tools: HealthTools, _ db: Database) throws -> Answer {
    Answer(try tools.workouts(range: range.range, date: date, timeZone: timeZone, db))
  }
}

struct SleepCommand: QueryCommand {
  static let configuration = CommandConfiguration(
    commandName: "sleep", abstract: "Sleep per night in a range: in bed, asleep, and stages.")

  @Option(name: .shortAndLong, help: rangeHelp) var range = RangeArgument(.week)
  @Option(help: dateHelp) var date: String?
  @Option(help: timeZoneHelp) var timeZone: String?
  @OptionGroup var output: OutputOptions

  func answer(_ tools: HealthTools, _ db: Database) throws -> Answer {
    Answer(try tools.sleep(range: range.range, date: date, timeZone: timeZone, db))
  }
}

struct MedicationsCommand: QueryCommand {
  static let configuration = CommandConfiguration(
    commandName: "medications",
    abstract: "Medications, with the doses taken over the last 7 and 30 days.")

  @Option(help: timeZoneHelp) var timeZone: String?
  @OptionGroup var output: OutputOptions

  func answer(_ tools: HealthTools, _ db: Database) throws -> Answer {
    Answer(try tools.medications(timeZone: timeZone, db))
  }
}

struct DetailsCommand: QueryCommand {
  static let configuration = CommandConfiguration(
    commandName: "details",
    abstract: "Health Details: date of birth, sex, blood type… and vision prescriptions.")

  @Option(help: timeZoneHelp) var timeZone: String?
  @OptionGroup var output: OutputOptions

  func answer(_ tools: HealthTools, _ db: Database) throws -> Answer {
    Answer(try tools.healthDetails(timeZone: timeZone, db))
  }
}

struct SearchCommand: QueryCommand {
  static let configuration = CommandConfiguration(
    commandName: "search",
    abstract: "Finds data types and medications by name, e.g. 'blood pressure'.")

  @Argument(help: "Words to look for, in any case.") var words: [String]
  @OptionGroup var output: OutputOptions

  func answer(_ tools: HealthTools, _ db: Database) throws -> Answer {
    Answer(try tools.search(query: words.joined(separator: " "), db))
  }
}

struct SyncCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sync", abstract: "How fresh the data is.",
    subcommands: [SyncStatusCommand.self], defaultSubcommand: SyncStatusCommand.self)
}

struct SyncStatusCommand: QueryCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "The newest sample, and when each iPhone last uploaded.")

  @Option(help: timeZoneHelp) var timeZone: String?
  @OptionGroup var output: OutputOptions

  func answer(_ tools: HealthTools, _ db: Database) throws -> Answer {
    Answer(try tools.syncStatus(timeZone: timeZone, db))
  }
}

/// `lil-health mcp`: not a query itself, but a server that answers the tools' calls, each checked
/// and logged as a command is.
struct MCPCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    abstract: "Runs a local MCP server for agents, on standard input and output.",
    discussion: """
      Agents such as Claude Code start it themselves, with lil health's tools (summary, metric, \
      sleep…) and the catalog of data types. Add it to Claude Code with:

        claude mcp add --scope user lil-health -- lil health mcp

      Each tool call answers only while command-line and agent access is on, and is logged \
      there, like a command.
      """)
}
