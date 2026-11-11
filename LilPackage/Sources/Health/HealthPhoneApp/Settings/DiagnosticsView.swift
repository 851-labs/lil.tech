#if DEBUG
  import HealthCatalog
  import HealthUpload
  import SwiftUI

  /// Diagnostics, from Settings in Debug builds only (851-4173, 851-4190): checks a developer
  /// runs on their own iPhone's real Health data, whose numbers they read back. It shows counts
  /// and durations only, never a value, date, name or source, and keeps them only while it's
  /// open.
  struct DiagnosticsView: View {
    @State var model: DiagnosticsModel

    init(model: DiagnosticsModel = DiagnosticsModel()) {
      _model = State(initialValue: model)
    }

    var body: some View {
      List {
        Section {
        } footer: {
          Text(
            "Counts only, read on this iPhone. Nothing is uploaded, logged or saved, and they're gone when you leave."
          )
        }
        seriesSection
        linkOrderSection
        arrivalsSection
      }
      .navigationTitle("Diagnostics")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .onDisappear { model.disappeared() }
    }

    // MARK: Quantity series (851-4173)

    @ViewBuilder private var seriesSection: some View {
      Section {
        switch model.series {
        case .notRun, .failed:
          Button("Count Series") { model.countSeriesButtonTapped() }
        case .counting(let done, let total):
          LabeledContent("Counting… \(done) of \(total) types") { ProgressView() }
        case .counted:
          Button("Count Again") { model.countSeriesButtonTapped() }
        }
        if case .failed(let message) = model.series {
          Text(message).foregroundStyle(.red)
        }
        if case .counted(let counts) = model.series {
          let read = counts.filter { $0.samples > 0 }.sorted {
            ($1.series, $1.samples, $0.type) < ($0.series, $0.samples, $1.type)
          }
          SeriesRow(title: "All Types", count: total(read))
          ForEach(read) { count in
            SeriesRow(title: HealthCatalog.type(id: count.type)?.name ?? count.type, count: count)
          }
          if read.isEmpty {
            Text("No samples").foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Quantity Series")
      } footer: {
        Text(
          "Each quantity type's samples, and those holding several values (series): how many, their values together and the most one holds. Reads every sample, which can take minutes."
        )
      }
    }

    private func total(_ counts: [HealthDiagnostics.SeriesCount]) -> HealthDiagnostics.SeriesCount {
      HealthDiagnostics.SeriesCount(
        type: "", samples: counts.reduce(0) { $0 + $1.samples },
        series: counts.reduce(0) { $0 + $1.series }, values: counts.reduce(0) { $0 + $1.values },
        largest: counts.map(\.largest).max() ?? 0)
    }

    // MARK: Link order (851-4190)

    @ViewBuilder private var linkOrderSection: some View {
      Section {
        switch model.links {
        case .notRun, .failed:
          Button("Check Link Order") { model.checkLinkOrderButtonTapped() }
        case .checking:
          LabeledContent("Checking…") { ProgressView() }
        case .checked:
          Button("Check Again") { model.checkLinkOrderButtonTapped() }
        }
        if case .failed(let message) = model.links {
          Text(message).foregroundStyle(.red)
        }
        if case .checked(let workouts, let electrocardiograms) = model.links {
          number("Workouts", workouts.checked)
          number("With Linked Samples", workouts.withLinks)
          number("With Samples Added After Them", workouts.withLateLinks)
          number("Linked Samples", workouts.linked)
          number("Added After Their Workout", workouts.late)
          number("ECGs with Symptoms", electrocardiograms.checked)
          number("With Symptoms Linked", electrocardiograms.withLinks)
          number("With Symptoms Added After Them", electrocardiograms.withLateLinks)
          number("Symptoms Linked", electrocardiograms.linked)
          number("Added After Their ECG", electrocardiograms.late)
        }
      } header: {
        Text("Link Order")
      } footer: {
        Text(
          "Workouts and ECGs with symptoms from the last \(DiagnosticsModel.linkDays) days, and how many of their linked samples reached this iPhone after them. Some may have arrived together, in one sync."
        )
      }
    }

    private func number(_ title: LocalizedStringKey, _ value: Int) -> some View {
      LabeledContent(title) { Text(value, format: .number).monospacedDigit() }
    }

    // MARK: Watching for new workouts and ECGs (851-4190)

    @ViewBuilder private var arrivalsSection: some View {
      Section {
        switch model.watch {
        case .off, .failed:
          Button("Start Watching") { model.startWatchingButtonTapped() }
        case .starting, .watching:
          LabeledContent {
            ProgressView()
          } label: {
            Button("Stop Watching") { model.stopWatchingButtonTapped() }
          }
        }
        if case .failed(let message) = model.watch {
          Text(message).foregroundStyle(.red)
        }
        ForEach(model.arrivals) { arrival in
          ArrivalRow(arrival: arrival)
        }
      } header: {
        Text("New Workouts and ECGs")
      } footer: {
        Text(
          "Start before ending a workout on Apple Watch, or recording an ECG with symptoms, and keep this screen open until it arrives. Its links are counted when it arrives, then for 5 minutes."
        )
      }
    }
  }

  private struct SeriesRow: View {
    var title: String
    var count: HealthDiagnostics.SeriesCount

    var body: some View {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(
          "\(count.samples, format: .number) samples · \(count.series, format: .number) series · \(count.values, format: .number) values · largest \(count.largest, format: .number)"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      }
    }
  }

  private struct ArrivalRow: View {
    var arrival: DiagnosticsModel.Arrival

    var body: some View {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(arrival.kind == .workout ? "Workout" : "ECG") \(arrival.id)")
        Text(detail)
          .font(.caption)
          .foregroundStyle(arrival.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
          .monospacedDigit()
      }
    }

    private var detail: String {
      guard let atArrival = arrival.atArrival, let latest = arrival.latest else {
        return arrival.failed ? "Couldn't count its links" : "Counting…"
      }
      var parts = ["\(atArrival.formatted()) linked on arrival"]
      if arrival.counted > .zero {
        parts.append("\(latest.formatted()) after \(seconds(arrival.counted))")
      }
      if let changed = arrival.lastChanged {
        parts.append("last changed by \(seconds(changed))")
      }
      if arrival.failed {
        parts.append("then a count failed")
      } else if !arrival.isDone {
        parts.append("counting…")
      }
      return parts.joined(separator: " · ")
    }

    private func seconds(_ duration: Duration) -> String {
      "\(duration.components.seconds.formatted()) s"
    }
  }
#endif
