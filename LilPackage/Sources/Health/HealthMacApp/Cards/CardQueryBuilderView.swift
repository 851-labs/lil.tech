import ComposableArchitecture
import HealthCards
import HealthCatalog
import HealthDatabase
import HealthPages
import SwiftUI

// The query builder (851-3209, docs/decisions/cards.md, UI › Mac): the editor's sections that
// write a card's query. Data, a section per series (type, value, when, sources and devices,
// label), with Add Series; Chart (each point, the range it opens on, style, unit, goal); and
// Formulas (moving averages and differences). Each control offers only what the rules allow, and
// the validator's errors show in a row under the field they're about.

/// The query builder's sections, in the editor's form.
struct CardQueryBuilderSections: View {
  let store: StoreOf<CardEditorFeature>

  var body: some View {
    let series = store.draft.series
    ForEach(Array(series.enumerated()), id: \.element.id) { index, series in
      CardSeriesSection(store: store, series: series, index: index)
    }
    if !store.needsType {
      Section {
        Button("Add Series") { store.send(.addSeriesButtonTapped) }
          .disabled(!store.canAddSeries)
        CardFieldErrors(messages: store.state.errors(for: .seriesList))
      } footer: {
        if !store.canAddSeries {
          Text("A card has up to 4 series.")
        }
      }
      CardChartSection(store: store)
      ForEach(store.draft.formulas, id: \.id) { formula in
        CardFormulaSection(store: store, formula: formula)
      }
      Section {
        Menu("Add Formula") {
          Button("Moving Average") { store.send(.addFormulaButtonTapped(.movingAverage)) }
            .disabled(!store.state.canAddFormula(.movingAverage))
          Button("Difference") { store.send(.addFormulaButtonTapped(.difference)) }
            .disabled(!store.state.canAddFormula(.difference))
        }
        .fixedSize()
        .disabled(!store.state.canAddFormula(.movingAverage))
        CardFieldErrors(messages: store.state.errors(for: .formulaList))
      } header: {
        if store.draft.formulas.isEmpty { Text("Formulas") }
      }
    }
    let rest = store.state.errors(for: .query)
    if !rest.isEmpty {
      Section {
        CardFieldErrors(messages: rest)
      }
    }
  }
}

/// A field's errors, a row under it each.
struct CardFieldErrors: View {
  let messages: [String]

  var body: some View {
    ForEach(messages, id: \.self) { message in
      Text(message)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Series

/// One series: its type, value, window, filter, label and visibility.
struct CardSeriesSection: View {
  let store: StoreOf<CardEditorFeature>
  let series: CardSpec.Series
  let index: Int

  private var type: HealthDataType? { series.dataType }

  private func errors(_ field: CardEditorFeature.State.Field.SeriesField) -> some View {
    CardFieldErrors(messages: store.state.errors(for: .series(series.id, field)))
  }

  private func change(_ edit: (inout CardSpec.Series) -> Void) {
    var series = series
    edit(&series)
    store.send(.seriesChanged(series))
  }

  var body: some View {
    Section {
      typeRow
      errors(.type)
      if let type {
        Picker(
          "Value",
          selection: Binding(
            get: { series.aggregation }, set: { a in change { $0.aggregation = a } })
        ) {
          ForEach(store.state.aggregations(for: series), id: \.self) {
            Text($0.label).tag($0)
          }
        }
        .disabled(store.state.aggregations(for: series).count < 2)
        errors(.aggregation)
        // Totals are Health's de-duplicated sums, which can't be split by time or source.
        if type.aggregation?.isCumulative == false {
          CardWindowRows(series: series, change: change)
          errors(.window)
          CardFilterRows(store: store, series: series, change: change)
          errors(.filter)
        }
        TextField(
          "Label",
          text: Binding(
            get: { series.label ?? "" },
            set: { text in change { $0.label = text.isEmpty ? nil : text } }),
          prompt: Text(type.name))
        errors(.label)
        if store.state.hasSeveralLines {
          Toggle(
            "Show in Chart",
            isOn: Binding(get: { !series.hidden }, set: { shown in change { $0.hidden = !shown } }))
          errors(.hidden)
        }
        if store.draft.series.count > 1 {
          Button("Remove Series", role: .destructive) {
            store.send(.removeSeriesButtonTapped(id: series.id))
          }
        }
      }
    } header: {
      Text(store.draft.series.count > 1 ? "Series \(index + 1)" : "Data")
    }
  }

  /// The type, opening a searchable list of the types this series can chart.
  private var typeRow: some View {
    LabeledContent("Type") {
      Button(type?.name ?? "Choose…") {
        store.send(.typePickerButtonTapped(series: series.id))
      }
      .popover(
        isPresented: Binding(
          get: { store.typePickerSeries == series.id },
          set: { if !$0 { store.send(.binding(.set(\.typePickerSeries, nil))) } }),
        arrowEdge: .trailing
      ) {
        CardTypeList(types: store.state.types(forSeries: series.id), selection: type?.id) {
          store.send(.typeChosen(series: series.id, type: $0))
        }
      }
    }
  }
}

/// When a series' readings count: all the time, around sleep, during workouts or at a time of
/// day, with the window's minutes, activities or hours.
struct CardWindowRows: View {
  let series: CardSpec.Series
  let change: ((inout CardSpec.Series) -> Void) -> Void

  var body: some View {
    Picker(
      "When",
      selection: Binding(
        get: { CardWindowChoice(series.window) },
        set: { choice in change { $0.window = choice.window(from: $0.window) } })
    ) {
      Text("All the Time").tag(CardWindowChoice.none)
      Divider()
      Text("While Asleep").tag(CardWindowChoice.asleep)
      Text("Before Falling Asleep").tag(CardWindowChoice.beforeSleep)
      Text("After Waking").tag(CardWindowChoice.afterWaking)
      Divider()
      Text("During Workouts").tag(CardWindowChoice.workout)
      Text("Time of Day").tag(CardWindowChoice.timeOfDay)
    }
    switch series.window {
    case .beforeSleep(let minutes):
      CardNumberField(
        title: "Minutes", value: minutes, range: HealthCards.windowMinutes
      ) { minutes in change { $0.window = .beforeSleep(minutes: minutes) } }
    case .afterWaking(let minutes):
      CardNumberField(
        title: "Minutes", value: minutes, range: HealthCards.windowMinutes
      ) { minutes in change { $0.window = .afterWaking(minutes: minutes) } }
    case .workout(let activities):
      LabeledContent("Workouts") {
        CardActivitiesMenu(activities: activities) { activities in
          change { $0.window = .workout(activities: activities) }
        }
      }
    case .timeOfDay(let window):
      CardClockPicker(title: "From", time: window.from) { from in
        change { $0.window = .timeOfDay(CardTimeOfDay(from: from, to: window.to)) }
      }
      CardClockPicker(title: "To", time: window.to) { to in
        change { $0.window = .timeOfDay(CardTimeOfDay(from: window.from, to: to)) }
      }
    case .asleep, nil:
      EmptyView()
    }
  }
}

/// The window menu's choices.
enum CardWindowChoice: Hashable {
  case none, asleep, beforeSleep, afterWaking, workout, timeOfDay

  init(_ window: CardSpec.Window?) {
    switch window {
    case nil: self = .none
    case .asleep: self = .asleep
    case .beforeSleep: self = .beforeSleep
    case .afterWaking: self = .afterWaking
    case .workout: self = .workout
    case .timeOfDay: self = .timeOfDay
    }
  }

  /// The window chosen, keeping the minutes of the one it replaces: 5 minutes before falling
  /// asleep, 30 after waking, every workout, or the morning, otherwise.
  func window(from previous: CardSpec.Window?) -> CardSpec.Window? {
    let minutes: Int? =
      switch previous {
      case .beforeSleep(let minutes), .afterWaking(let minutes): minutes
      default: nil
      }
    switch self {
    case .none: return nil
    case .asleep: return .asleep
    case .beforeSleep: return .beforeSleep(minutes: minutes ?? 5)
    case .afterWaking: return .afterWaking(minutes: minutes ?? 30)
    case .workout: return .workout(activities: nil)
    case .timeOfDay:
      return .timeOfDay(
        CardTimeOfDay(
          from: CardClockTime(hour: 0, minute: 0)!, to: CardClockTime(hour: 12, minute: 0)!))
    }
  }
}

/// A whole number typed or stepped within its range. A number typed outside it is the
/// validator's to explain.
struct CardNumberField: View {
  let title: String
  let value: Int
  let range: ClosedRange<Int>
  let change: (Int) -> Void

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 4) {
        TextField(
          title, value: Binding(get: { value }, set: { change($0) }), format: .number,
          prompt: nil
        )
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 56)
        Stepper(
          title,
          value: Binding(
            get: { min(max(value, range.lowerBound), range.upperBound) }, set: { change($0) }),
          in: range
        )
        .labelsHidden()
      }
    }
  }
}

/// A time of the 24-hour clock, to the minute, picked as the locale writes times.
struct CardClockPicker: View {
  let title: String
  let time: CardClockTime
  let change: (CardClockTime) -> Void

  /// Times are placed on one fixed day in UTC, so no time zone or daylight saving time moves
  /// them.
  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }

  var body: some View {
    DatePicker(
      title,
      selection: Binding(
        get: { Date(timeIntervalSinceReferenceDate: TimeInterval(time.secondsSinceMidnight)) },
        set: { date in
          let parts = Self.calendar.dateComponents([.hour, .minute], from: date)
          if let time = CardClockTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0) {
            change(time)
          }
        }),
      displayedComponents: .hourAndMinute
    )
    .environment(\.timeZone, .gmt)
    .environment(\.calendar, Self.calendar)
  }
}

/// The workouts a window covers: every one, or up to 10 activities, picked from Health's names.
struct CardActivitiesMenu: View {
  let activities: [Int]?
  let change: ([Int]?) -> Void

  /// Every activity the catalog names, by name.
  static let all: [(id: Int, name: String)] = HealthCatalog.workoutActivityNames
    .map { (id: $0.key, name: $0.value) }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

  private var label: String {
    guard let activities, !activities.isEmpty else { return "All Workouts" }
    let names = activities.map(HealthCatalog.workoutActivityName)
    return names.count <= 2 ? names.formatted(.list(type: .and)) : "\(names.count) Activities"
  }

  var body: some View {
    Menu(label) {
      Toggle(
        "All Workouts",
        isOn: Binding(get: { activities == nil }, set: { if $0 { change(nil) } }))
      Divider()
      ForEach(Self.all, id: \.id) { activity in
        let isOn = activities?.contains(activity.id) ?? false
        Toggle(
          activity.name,
          isOn: Binding(
            get: { isOn },
            set: { on in
              var chosen = activities ?? []
              if on { chosen.append(activity.id) } else { chosen.removeAll { $0 == activity.id } }
              change(chosen.isEmpty ? nil : chosen)
            })
        )
        .disabled(!isOn && (activities?.count ?? 0) >= HealthCards.windowActivities.upperBound)
      }
    }
    .fixedSize()
  }
}

/// A series' filter, under a disclosure: the apps and device models its readings come from, picked
/// from those its type's data came from.
struct CardFilterRows: View {
  let store: StoreOf<CardEditorFeature>
  let series: CardSpec.Series
  let change: ((inout CardSpec.Series) -> Void) -> Void
  @State private var isExpanded: Bool

  init(
    store: StoreOf<CardEditorFeature>, series: CardSpec.Series,
    change: @escaping ((inout CardSpec.Series) -> Void) -> Void
  ) {
    self.store = store
    self.series = series
    self.change = change
    _isExpanded = State(initialValue: series.filter != nil)
  }

  private var sources: SampleSources? { store.sources[series.type] }

  var body: some View {
    DisclosureGroup("Sources and Devices", isExpanded: $isExpanded) {
      LabeledContent("Apps") {
        CardChoicesMenu(
          every: "Every App", chosen: series.filter?.sources ?? [],
          choices: (sources?.apps ?? []).map { ($0.id, $0.name) }
        ) { sources in
          change {
            $0.filter = Self.filter(sources: sources, deviceModels: $0.filter?.deviceModels)
          }
        }
      }
      LabeledContent("Devices") {
        CardChoicesMenu(
          every: "Every Device", chosen: series.filter?.deviceModels ?? [],
          choices: Self.models(of: sources?.devices ?? []).map { ($0, $0) }
        ) { models in
          change { $0.filter = Self.filter(sources: $0.filter?.sources, deviceModels: models) }
        }
      }
      .task(id: series.type) { store.send(.sourcesNeeded(type: series.type)) }
    }
  }

  /// The device models, each once, the most common first.
  static func models(of devices: [SampleDeviceSummary]) -> [String] {
    var seen = Set<String>()
    return devices.compactMap(\.device.model).filter { seen.insert($0).inserted }
  }

  /// A filter of these lists, `nil` for an empty one; no filter when both are.
  static func filter(sources: [String]?, deviceModels: [String]?) -> CardSpec.Filter? {
    let sources = sources?.isEmpty == false ? sources : nil
    let deviceModels = deviceModels?.isEmpty == false ? deviceModels : nil
    guard sources != nil || deviceModels != nil else { return nil }
    return CardSpec.Filter(sources: sources, deviceModels: deviceModels)
  }
}

/// Every one, or some of a list, each checked in a menu: a filter's apps or devices. Chosen
/// values the list doesn't have (data since deleted) stay, by their IDs.
struct CardChoicesMenu: View {
  let every: String
  let chosen: [String]
  let choices: [(id: String, name: String)]
  let change: ([String]) -> Void

  private var all: [(id: String, name: String)] {
    choices + chosen.filter { id in !choices.contains { $0.id == id } }.map { ($0, $0) }
  }

  private var label: String {
    let names = chosen.map { id in all.first { $0.id == id }?.name ?? id }
    guard !names.isEmpty else { return every }
    return names.count <= 2 ? names.formatted(.list(type: .and)) : "\(names.count) Chosen"
  }

  var body: some View {
    Menu(label) {
      Toggle(every, isOn: Binding(get: { chosen.isEmpty }, set: { if $0 { change([]) } }))
      Divider()
      ForEach(all, id: \.id) { choice in
        let isOn = chosen.contains(choice.id)
        Toggle(
          choice.name,
          isOn: Binding(
            get: { isOn },
            set: { on in
              change(on ? chosen + [choice.id] : chosen.filter { $0 != choice.id })
            })
        )
        .disabled(!isOn && chosen.count >= HealthCards.filterListLength.upperBound)
      }
    }
    .fixedSize()
  }
}

/// The types a series can chart, by category, with a search field matching their names as the
/// sidebar's search does (and the names `lil-health` accepts).
struct CardTypeList: View {
  let types: [HealthDataType]
  let selection: String?
  let choose: (String) -> Void
  @State private var query = ""

  private var groups: [CardTypeGroup] {
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return CardTypeGroup.grouping(types) }
    let named = HealthCatalog.type(named: query)
    return CardTypeGroup.grouping(
      types.filter { $0.name.localizedStandardContains(query) || $0.id == named?.id })
  }

  var body: some View {
    VStack(spacing: 0) {
      TextField("Search", text: $query, prompt: Text("Search"))
        .textFieldStyle(.roundedBorder)
        .padding(10)
      Divider()
      let groups = groups
      if groups.isEmpty {
        ContentUnavailableView.search(text: query)
          .frame(maxHeight: .infinity)
      } else {
        List(
          selection: Binding(get: { selection }, set: { id in if let id { choose(id) } })
        ) {
          ForEach(groups) { group in
            Section(group.name) {
              ForEach(group.types) { type in
                Text(type.name).tag(type.id)
              }
            }
          }
        }
      }
    }
    .frame(width: 300, height: 400)
  }
}

// MARK: - Chart

/// What each point covers, the range the card opens on, its style, unit and goal.
struct CardChartSection: View {
  let store: StoreOf<CardEditorFeature>
  @Dependency(\.locale) private var locale

  private var draft: CardSpec { store.draft }

  private func errors(_ field: CardEditorFeature.State.Field) -> some View {
    CardFieldErrors(messages: store.state.errors(for: field))
  }

  var body: some View {
    Section("Chart") {
      Picker(
        "Each Point",
        selection: Binding(get: { draft.bucket }, set: { store.send(.bucketChosen($0)) })
      ) {
        ForEach(store.state.buckets, id: \.self) { Text($0.label).tag($0) }
      }
      errors(.bucket)
      Picker(
        "Opens On", selection: Binding(get: { draft.range }, set: { store.send(.rangeChosen($0)) })
      ) {
        ForEach(draft.bucket.ranges, id: \.self) { Text(ChartRange($0).periodName).tag($0) }
      }
      errors(.range)
      Picker(
        "Style",
        selection: Binding(get: { draft.chart.style }, set: { store.send(.styleChosen($0)) })
      ) {
        ForEach(store.state.styles, id: \.self) { Text($0.label).tag($0) }
      }
      errors(.style)
      let units = store.state.units
      if !units.isEmpty {
        Picker(
          "Unit",
          selection: Binding(get: { draft.display.unit }, set: { store.send(.unitChosen($0)) })
        ) {
          Text("Automatic").tag(String?.none)
          Divider()
          ForEach(units, id: \.self) { Text(CardUnitName.name(of: $0)).tag(String?.some($0)) }
        }
        errors(.unit)
      }
      goalRow
      errors(.goal)
    }
  }

  /// The goal, typed in the card's display unit and kept in the lead's value unit; none when
  /// it's empty.
  private var goalRow: some View {
    let shown = MetricFormat.unit(of: draft, locale: locale)
    let label =
      switch shown.compound {
      case .stonesAndPounds?: "lb"
      case .feetAndInches?: "in"
      case nil: shown.label
      }
    return LabeledContent("Goal") {
      HStack(spacing: 6) {
        TextField(
          "Goal",
          value: Binding(
            get: { draft.chart.goal.map { shown.convert($0.value) } },
            set: { store.send(.goalChanged($0.map { ($0 - shown.offset) / shown.scale })) }),
          format: .number, prompt: Text("None")
        )
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 90)
        if !label.isEmpty {
          Text(label)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// How the unit menu names a unit a card may pin.
enum CardUnitName {
  static func name(of unit: String) -> String {
    names[unit] ?? unit
  }

  private static let names = [
    "kg": "Kilograms", "lb": "Pounds", "st": "Stones and Pounds", "cm": "Centimeters",
    "m": "Meters", "km": "Kilometers", "in": "Inches", "ft": "Feet", "yd": "Yards",
    "mi": "Miles", "degC": "Celsius", "degF": "Fahrenheit", "km/hr": "Kilometers per Hour",
    "mi/hr": "Miles per Hour", "m/s": "Meters per Second", "mL": "Milliliters", "L": "Liters",
    "fl_oz_us": "Fluid Ounces", "kcal": "Kilocalories", "kJ": "Kilojoules",
  ]
}

// MARK: - Formulas

/// A moving average or a difference: its series, points, label and visibility.
struct CardFormulaSection: View {
  let store: StoreOf<CardEditorFeature>
  let formula: CardSpec.Formula

  private func errors(_ field: CardEditorFeature.State.Field.FormulaField) -> some View {
    CardFieldErrors(messages: store.state.errors(for: .formula(formula.id, field)))
  }

  private func change(_ edit: (inout CardSpec.Formula) -> Void) {
    var formula = formula
    edit(&formula)
    store.send(.formulaChanged(formula))
  }

  private func name(of series: CardSpec.Series) -> String {
    store.draft.name(of: series)
  }

  var body: some View {
    Section {
      switch formula.operation {
      case .movingAverage(let of, let points):
        if store.draft.series.count > 1 {
          seriesPicker("Of", selection: of, excluding: nil) { id in
            change { $0.operation = .movingAverage(of: id, points: points) }
          }
        }
        errors(.operands)
        CardNumberField(title: "Points", value: points, range: HealthCards.movingAveragePoints) {
          points in change { $0.operation = .movingAverage(of: of, points: points) }
        }
        errors(.points)
      case .difference(let minuend, let subtrahend):
        seriesPicker("Series", selection: minuend, excluding: subtrahend) { id in
          change { $0.operation = .difference(of: id, minus: subtrahend) }
        }
        seriesPicker("Minus", selection: subtrahend, excluding: minuend) { id in
          change { $0.operation = .difference(of: minuend, minus: id) }
        }
        errors(.operands)
      }
      TextField(
        "Label",
        text: Binding(
          get: { formula.label ?? "" },
          set: { text in change { $0.label = text.isEmpty ? nil : text } }),
        prompt: Text(store.draft.description(of: formula)))
      errors(.label)
      Toggle(
        "Show in Chart",
        isOn: Binding(get: { !formula.hidden }, set: { shown in change { $0.hidden = !shown } }))
      errors(.hidden)
      Button("Remove Formula", role: .destructive) {
        store.send(.removeFormulaButtonTapped(id: formula.id))
      }
    } header: {
      Text(formula.operation.kind == .movingAverage ? "Moving Average" : "Difference")
    }
  }

  private func seriesPicker(
    _ title: String, selection: String, excluding other: String?,
    change: @escaping (String) -> Void
  ) -> some View {
    Picker(title, selection: Binding(get: { selection }, set: { change($0) })) {
      ForEach(store.state.operands(excluding: other), id: \.id) { series in
        Text(name(of: series)).tag(series.id)
      }
    }
  }
}

// MARK: - Names

extension CardSpec.Aggregation {
  /// What the Value menu calls it.
  var label: String {
    switch self {
    case .sum: "Total"
    case .avg: "Average"
    case .min: "Lowest"
    case .max: "Highest"
    case .first: "First Reading"
    case .latest: "Latest Reading"
    case .count: "Number of Readings"
    }
  }
}

extension CardSpec.Bucket {
  var label: String {
    switch self {
    case .auto: "Automatic"
    case .hour: "Hour"
    case .day: "Day"
    case .night: "Night"
    case .week: "Week"
    case .month: "Month"
    }
  }
}

extension HealthDataType.ChartStyle {
  var label: String {
    switch self {
    case .bars: "Bars"
    case .ranges: "Ranges"
    case .dots: "Dots"
    case .line: "Line"
    }
  }
}
