import Dependencies
import HealthDatabase
import LilSync
import SQLiteData
public import SwiftUI

/// ECG recordings, newest first and grouped by month, as in Health. Each opens its recording.
/// Follows the local database as sync changes it.
public struct ElectrocardiogramsView: View {
  @Fetch private var recordings: [HealthElectrocardiogram]

  public init() {
    _recordings = Fetch(
      wrappedValue: [], RecentElectrocardiograms(), scheduler: MainQueueScheduler())
  }

  public var body: some View {
    ElectrocardiogramsContent(
      state: $recordings.loadError.map { .failed($0.localizedDescription) }
        ?? ($recordings.isLoading && recordings.isEmpty ? .loading : .loaded(recordings)))
  }
}

/// The most recent recordings: years of them for most people.
struct RecentElectrocardiograms: FetchKeyRequest {
  static let limit = 1_000

  func fetch(_ db: Database) throws -> [HealthElectrocardiogram] {
    try HealthDatabase.electrocardiograms(limit: Self.limit, db)
  }
}

/// What the ECG list shows, however it got it.
struct ElectrocardiogramsContent: View {
  enum State {
    case loading
    case loaded([HealthElectrocardiogram])
    case failed(String)
  }

  let state: State
  /// How many the list holds at most (`RecentElectrocardiograms.limit`), to say when it's full.
  var limit = RecentElectrocardiograms.limit
  /// From dependencies, so snapshot catalogs fix it (`previewCalendar`).
  @Dependency(\.calendar) private var calendar

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let reason):
        ContentUnavailableView(
          "Couldn't Load ECGs", systemImage: "exclamationmark.triangle",
          description: Text(reason))
      case .loaded(let recordings) where recordings.isEmpty:
        ContentUnavailableView(
          "No ECGs", systemImage: "waveform.path.ecg",
          description: Text("ECGs you take with the ECG app on Apple Watch will appear here."))
      case .loaded(let recordings):
        list(recordings)
      }
    }
    .navigationTitle("ECG")
  }

  /// A section per month, in a grouped form's look (`LazyForm`): a `Form` builds every row at
  /// once, and the list holds up to 1,000.
  private func list(_ recordings: [HealthElectrocardiogram]) -> some View {
    LazyForm {
      LazyFormSections(
        sections(recordings, by: .month, calendar: calendar, startDate: \.startDate),
        title: { $0.formatted(.dateTime.month(.wide).year()) }
      ) { recording in
        ElectrocardiogramDetailView(recording: recording)
      } row: { recording in
        ElectrocardiogramRow(recording: recording)
      }
      if recordings.count >= limit {
        LazyFormFooter("Showing the \(limit.formatted()) most recent ECGs.")
      }
    }
  }
}

/// A recording in the list: its classification, average heart rate, and when.
struct ElectrocardiogramRow: View {
  let recording: HealthElectrocardiogram

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "waveform.path.ecg")
        .font(.title3)
        .foregroundStyle(.red)
        .frame(width: 36, height: 36)
        .background(.red.opacity(0.15), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(recording.decodedClassification.name)
          .font(.headline)
          .foregroundStyle(recording.decodedClassification.isAlert ? .red : .primary)
        Text(ECGFormat.averageHeartRate(recording))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(
        Date(unixMilliseconds: recording.startDate).formatted(date: .abbreviated, time: .shortened)
      )
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

/// A recording, as in Health: its classification, average heart rate and time, the trace on ECG
/// paper, and whether symptoms were logged.
struct ElectrocardiogramDetailView: View {
  let recording: HealthElectrocardiogram
  @Dependency(\.blobCache) private var blobCache
  @State private var trace = ElectrocardiogramDetailContent.Trace.loading

  var body: some View {
    ElectrocardiogramDetailContent(recording: recording, trace: trace)
      // Again if sync brings the recording's voltages, or new ones.
      .task(id: [recording.id, recording.voltages ?? ""]) {
        guard let sha256 = recording.voltages else {
          trace = .none
          return
        }
        do {
          let microvolts = HealthDatabase.electrocardiogramMicrovolts(
            try await blobCache.data(for: sha256))
          trace = microvolts.isEmpty ? .none : .loaded(microvolts)
        } catch {
          trace = .failed(error.localizedDescription)
        }
      }
  }
}

/// What a recording's detail shows, however it got its voltages.
struct ElectrocardiogramDetailContent: View {
  enum Trace {
    case loading
    /// The recording has no measurements.
    case none
    case loaded([Float])
    case failed(String)
  }

  let recording: HealthElectrocardiogram
  let trace: Trace

  var body: some View {
    // A grouped form, as Metric Detail is (851-2989, 851-3032): the headline and the trace, then
    // the recording's details.
    Form {
      Section {
        VStack(alignment: .leading, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            Text(recording.decodedClassification.name)
              .font(.largeTitle.bold())
              .foregroundStyle(recording.decodedClassification.isAlert ? .red : .primary)
            Text(ECGFormat.averageHeartRate(recording))
              .font(.title3)
            Text(
              Date(unixMilliseconds: recording.startDate).formatted(
                date: .complete, time: .shortened)
            )
            .foregroundStyle(.secondary)
          }
          traceView
        }
        .padding(.vertical, 6)
      }
      Section {
        LabeledContent("Symptoms", value: ECGFormat.symptoms(recording))
        LabeledContent("Recorded With", value: recording.sourceName)
        if let frequency = recording.samplingFrequency {
          LabeledContent(
            "Sample Rate",
            value: "\(frequency.formatted(.number.precision(.fractionLength(0...1)))) Hz")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("ECG")
  }

  /// The trace, or a placeholder about as tall.
  @ViewBuilder private var traceView: some View {
    switch trace {
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, minHeight: 270)
    case .none:
      ContentUnavailableView(
        "No Recording", systemImage: "waveform.path.ecg",
        description: Text("This ECG has no measurements.")
      )
      .frame(maxWidth: .infinity, minHeight: 270)
    case .failed(let reason):
      ContentUnavailableView(
        "Couldn't Load the Recording", systemImage: "exclamationmark.triangle",
        description: Text(reason)
      )
      .frame(maxWidth: .infinity, minHeight: 270)
    case .loaded(let microvolts):
      let frequency = recording.measurementsPerSecond
      let range = ECGStrip.range(microvolts)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(
          Array(
            HealthDatabase.electrocardiogramStrips(
              microvolts, samplingFrequency: frequency, seconds: ECGStrip.seconds
            )
            .enumerated()), id: \.offset
        ) { _, strip in
          ECGStrip(microvolts: strip, samplingFrequency: frequency, millivolts: range)
        }
        Text("25 mm/s, 10 mm/mV, Lead I")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: ECGStrip.maxWidth)
    }
  }
}

/// Ten seconds of trace on ECG paper at the standard speed and gain: 25 mm a second, 10 mm a
/// millivolt, with 1 mm and 5 mm grid lines. The paper is as wide as there's room for, up to 3
/// points a millimeter, keeping that ratio. NaN measurements leave a gap.
struct ECGStrip: View {
  let microvolts: ArraySlice<Float>
  let samplingFrequency: Double
  /// The millivolts the paper shows, bottom to top (`range(_:)`).
  let millivolts: ClosedRange<Double>

  static let seconds: Double = 10
  /// Paper millimeters across a strip: 10 s at 25 mm/s.
  static let millimetersAcross = seconds * 25
  static let maxWidth = CGFloat(millimetersAcross * 3)

  /// The paper's range for a trace: at least -1.25 to +1.75 mV, as Health shows, and more in
  /// half-millivolt steps to fit taller waves.
  nonisolated static func range(_ microvolts: [Float]) -> ClosedRange<Double> {
    let finite = microvolts.lazy.filter(\.isFinite).map { Double($0) / 1000 }
    let low = min(-1.25, ((finite.min() ?? 0) * 2).rounded(.down) / 2)
    let high = max(1.75, ((finite.max() ?? 0) * 2).rounded(.up) / 2)
    return low...high
  }

  var body: some View {
    let millimetersUp = (millivolts.upperBound - millivolts.lowerBound) * 10
    Canvas { context, size in
      let millimeter = size.width / CGFloat(Self.millimetersAcross)
      // The grid: thin lines every millimeter, stronger ones every 5.
      for (step, opacity) in [(1, 0.15), (5, 0.35)] {
        var grid = Path()
        var x: CGFloat = 0
        while x <= size.width + 0.5 {
          grid.move(to: CGPoint(x: x, y: 0))
          grid.addLine(to: CGPoint(x: x, y: size.height))
          x += CGFloat(step) * millimeter
        }
        var y: CGFloat = 0
        while y <= size.height + 0.5 {
          grid.move(to: CGPoint(x: 0, y: y))
          grid.addLine(to: CGPoint(x: size.width, y: y))
          y += CGFloat(step) * millimeter
        }
        context.stroke(grid, with: .color(.red.opacity(opacity)), lineWidth: step == 1 ? 0.5 : 1)
      }
      // The trace: 25 mm a second across, 10 mm a millivolt up from the baseline.
      let pointsPerSample = 25 * millimeter / samplingFrequency
      let baseline = CGFloat(millivolts.upperBound * 10) * millimeter
      var trace = Path()
      var drawing = false
      for (index, microvolt) in microvolts.enumerated() {
        guard microvolt.isFinite else {
          drawing = false
          continue
        }
        let point = CGPoint(
          x: CGFloat(index) * pointsPerSample,
          y: baseline - CGFloat(Double(microvolt) / 1000 * 10) * millimeter)
        if drawing { trace.addLine(to: point) } else { trace.move(to: point) }
        drawing = true
      }
      context.stroke(
        trace, with: .color(.red), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
    }
    .aspectRatio(CGFloat(Self.millimetersAcross / millimetersUp), contentMode: .fit)
    .frame(maxWidth: Self.maxWidth)
    .clipped()
    .background(Color.red.opacity(0.03))
    .accessibilityLabel("ECG trace")
  }
}

/// How ECG figures read.
enum ECGFormat {
  static func averageHeartRate(_ recording: HealthElectrocardiogram) -> String {
    guard let bpm = recording.averageHeartRate else { return "No Average Heart Rate" }
    return "\(Int(bpm.rounded())) BPM Average"
  }

  static func symptoms(_ recording: HealthElectrocardiogram) -> String {
    switch recording.hadSymptoms {
    case false: "No Symptoms"
    case true: "Symptoms Logged"
    case nil: "Not Logged"
    }
  }
}
