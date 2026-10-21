public import Foundation
public import SQLiteData

extension HealthDatabase {
  /// ECG recordings, newest first, at most `limit`.
  public static func electrocardiograms(limit: Int, _ db: Database) throws
    -> [HealthElectrocardiogram]
  {
    try HealthElectrocardiogram
      .order { ($0.startDate.desc(), $0.id.desc()) }
      .limit(limit)
      .fetchAll(db)
  }

  /// An ECG's voltages blob as microvolts: one little-endian 32-bit float per measurement, NaN
  /// where a measurement has no value. Bytes past the last whole float are ignored.
  public static func electrocardiogramMicrovolts(_ blob: Data) -> [Float] {
    blob.withUnsafeBytes { buffer in
      stride(from: 0, through: buffer.count - 4, by: 4).map { offset in
        Float(
          bitPattern: UInt32(
            littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
      }
    }
  }

  /// A recording cut into strips of `seconds` each, as Health lays out its 30 seconds: three of
  /// 10. The last strip may be shorter.
  public static func electrocardiogramStrips(
    _ microvolts: [Float], samplingFrequency: Double, seconds: Double
  ) -> [ArraySlice<Float>] {
    let perStrip = max(1, Int((samplingFrequency * seconds).rounded()))
    return stride(from: 0, to: microvolts.count, by: perStrip).map {
      microvolts[$0..<min($0 + perStrip, microvolts.count)]
    }
  }

  /// A plausible lead-I trace for previews and tests: beats at `beatsPerMinute`, each a P wave,
  /// QRS complex and T wave, in microvolts. Not real data.
  public static func syntheticElectrocardiogram(
    seconds: Double = 30, samplingFrequency: Double = 512, beatsPerMinute: Double = 68
  ) -> [Float] {
    let count = Int(seconds * samplingFrequency)
    let beat = 60 / beatsPerMinute
    // Each wave as a Gaussian bump: its time after the beat (s), height (µV) and width (s).
    let waves: [(at: Double, height: Double, width: Double)] = [
      (0.10, 120, 0.025), (0.235, -90, 0.008), (0.25, 1_000, 0.010), (0.265, -220, 0.010),
      (0.48, 280, 0.045),
    ]
    return (0..<count).map { index in
      let time = Double(index) / samplingFrequency
      let phase = time.truncatingRemainder(dividingBy: beat)
      let wave = waves.reduce(0) { sum, wave in
        let offset = (phase - wave.at) / wave.width
        return sum + wave.height * exp(-0.5 * offset * offset)
      }
      // A slow baseline drift, as real traces have.
      return Float(wave + 20 * sin(2 * .pi * time / 7))
    }
  }
}

/// What an ECG's rhythm was classified as (`HKElectrocardiogram.Classification`), as Health
/// names it.
public enum ECGClassification: Equatable, Sendable {
  case sinusRhythm, atrialFibrillation, lowHeartRate, highHeartRate, poorRecording, inconclusive
  case unrecognized, notSet

  public init(rawValue: Int) {
    self =
      switch rawValue {
      case 1: .sinusRhythm
      case 2: .atrialFibrillation
      case 3: .lowHeartRate
      case 4: .highHeartRate
      case 5: .poorRecording
      case 6: .inconclusive
      case 100: .unrecognized
      default: .notSet
      }
  }

  public var name: String {
    switch self {
    case .sinusRhythm: "Sinus Rhythm"
    case .atrialFibrillation: "Atrial Fibrillation"
    case .lowHeartRate: "Low Heart Rate"
    case .highHeartRate: "High Heart Rate"
    case .poorRecording: "Poor Recording"
    case .inconclusive: "Inconclusive"
    case .unrecognized: "Unrecognized"
    case .notSet: "Not Classified"
    }
  }

  /// Whether Health shows it as something to look at (AFib), rather than normal or unclear.
  public var isAlert: Bool { self == .atrialFibrillation }
}

extension HealthElectrocardiogram {
  /// Measurements per second: as recorded, or worked out from the count and the recording's
  /// length if that's missing or not positive, or Apple Watch's 512 Hz.
  public var measurementsPerSecond: Double {
    if let samplingFrequency, samplingFrequency > 0 { return samplingFrequency }
    let seconds = Double(endDate - startDate) / 1000
    if voltageCount > 0, seconds > 0 { return Double(voltageCount) / seconds }
    return 512
  }

  public var decodedClassification: ECGClassification {
    ECGClassification(rawValue: classification)
  }

  /// Whether symptoms were logged with it (`HKElectrocardiogram.SymptomsStatus`): `nil` if not
  /// asked.
  public var hadSymptoms: Bool? {
    switch symptomsStatus {
    case 1: false
    case 2: true
    default: nil
    }
  }
}
