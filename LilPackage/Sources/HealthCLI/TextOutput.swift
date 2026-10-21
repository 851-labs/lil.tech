import Foundation
import HealthCatalog
import HealthTools

// How each answer reads without --json: short lines a person can scan, from the same values.

protocol TextOutput {
  var text: String { get }
}

extension HealthSummaryResult: TextOutput {
  var text: String {
    var lines = ["Summary for \(date) (\(timeZone))\(pinned ? "" : ", everyday metrics")", ""]
    let width = metrics.map { name(of: $0.type).count }.max() ?? 0
    for metric in metrics {
      var parts: [String] = []
      if let today = metric.today { parts.append("\(quantity(today, metric.unit)) today") }
      if let week = metric.last7Days {
        parts.append("\(quantity(week, metric.unit)) in the last 7 days")
      }
      if let latest = metric.latest {
        let value = latest.value.map { quantity($0, metric.unit) + ", " } ?? ""
        parts.append("latest \(value)\(time(latest.start))")
      }
      lines.append(
        row(
          name(of: metric.type), width, parts.isEmpty ? "No data" : parts.joined(separator: " · ")))
    }
    lines.append("")
    lines.append(
      "Workouts in the last 7 days: \(workouts.count), \(durationText(workouts.duration))")
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthTypesResult: TextOutput {
  var text: String {
    guard !types.isEmpty else { return "No data yet.\n" }
    let width = types.map(\.name.count).max() ?? 0
    var lines: [String] = []
    var category: String??
    for type in types {
      if category != type.category {
        category = type.category
        if !lines.isEmpty { lines.append("") }
        lines.append(type.category ?? "Other")
      }
      lines.append(
        "  " + row(type.name, width, "\(day(type.first)) to \(day(type.last))   \(type.type)"))
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthMetricResult: TextOutput {
  var text: String {
    var lines = [
      "\(name(of: type)), \(statistic), \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))",
      "\(statistic == "sum" ? "Total" : statistic.capitalized): "
        + (value.map { quantity($0, unit) } ?? "No data"),
      "",
    ]
    for bucket in buckets {
      let label = range == "D" ? String(time(bucket.start).suffix(5)) : day(bucket.start)
      lines.append("  \(label)   \(bucket.value.map { quantity($0, unit) } ?? "–")")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthSamplesResult: TextOutput {
  var text: String {
    var lines = ["\(name(of: type)), \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))", ""]
    if samples.isEmpty { lines.append("No samples.") }
    for sample in samples {
      let value =
        sample.value.map { quantity($0, sample.unit) }
        ?? sample.categoryValue.map { "value \($0)" } ?? ""
      lines.append("  \(time(sample.start))   \(value)   \(sample.source)")
    }
    if let nextCursor {
      lines.append("")
      lines.append("More: --cursor \(nextCursor)")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthWorkoutsResult: TextOutput {
  var text: String {
    var lines = [
      "Workouts, \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))",
      "\(count) \(count == 1 ? "workout" : "workouts"), \(durationText(duration))",
    ]
    if !workouts.isEmpty { lines.append("") }
    for workout in workouts {
      var parts = [time(workout.start), workout.activity, durationText(workout.duration)]
      if let distance = workout.distance { parts.append(numberText(distance / 1000) + " km") }
      if let energy = workout.activeEnergy { parts.append(numberText(energy.rounded()) + " kcal") }
      if let heartRate = workout.averageHeartRate {
        parts.append(numberText(heartRate.rounded()) + " bpm")
      }
      lines.append("  " + parts.joined(separator: "   "))
    }
    if workouts.count < count {
      lines.append("  … and \(count - workouts.count) more")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthSleepResult: TextOutput {
  var text: String {
    var lines = ["Sleep, \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))", ""]
    if nights.isEmpty { lines.append("No sleep recorded.") }
    for night in nights {
      var parts = [
        "asleep \(durationText(night.asleep))", "in bed \(durationText(night.inBed))",
        "awake \(durationText(night.awake))",
      ]
      for (name, seconds) in [("core", night.core), ("deep", night.deep), ("REM", night.rem)]
      where seconds > 0 {
        parts.append("\(name) \(durationText(seconds))")
      }
      lines.append(
        "  \(night.date)   \(time(night.start).suffix(5))–\(time(night.end).suffix(5))   "
          + parts.joined(separator: " · "))
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthMedicationsResult: TextOutput {
  var text: String {
    guard !medications.isEmpty else { return "No medications.\n" }
    return medications.map { medication in
      var title = "\(medication.name) (\(medication.form))"
      if medication.archived { title += ", archived" }
      var parts: [String] = []
      if medication.scheduled {
        for (days, adherence) in [(7, medication.last7Days), (30, medication.last30Days)] {
          parts.append("\(adherence.taken) of \(adherence.scheduled) taken in \(days) days")
        }
      }
      if medication.last30Days.asNeeded > 0 {
        parts.append("\(medication.last30Days.asNeeded) as needed in 30 days")
      }
      parts.append("last taken \(medication.lastTaken.map(time) ?? "never")")
      return "\(title)\n  \(parts.joined(separator: " · "))\n"
    }
    .joined()
  }
}

extension HealthDetailsResult: TextOutput {
  var text: String {
    let notSet = "Not Set"
    var lines = [
      "Date of birth: \(dateOfBirth.map { "\($0)\(age.map { " (age \($0))" } ?? "")" } ?? notSet)",
      "Sex: \(sex?.capitalized ?? notSet)",
      "Blood type: \(bloodType ?? notSet)",
      "Fitzpatrick skin type: \(fitzpatrickSkinType.map { "Type \($0)" } ?? notSet)",
      "Wheelchair: \(wheelchairUse.map { $0 ? "Yes" : "No" } ?? notSet)",
    ]
    if !visionPrescriptions.isEmpty {
      lines.append("")
      lines.append("Vision prescriptions:")
      for prescription in visionPrescriptions {
        var parts = ["\(prescription.kind.capitalized), issued \(prescription.issued)"]
        if let expires = prescription.expires { parts.append("expires \(expires)") }
        if let brand = prescription.brand { parts.append(brand) }
        lines.append("  " + parts.joined(separator: ", "))
        for (eye, lens) in [("Right", prescription.rightEye), ("Left", prescription.leftEye)] {
          guard let lens else { continue }
          let values = [
            ("sphere", lens.sphere), ("cylinder", lens.cylinder), ("axis", lens.axis),
            ("add", lens.addPower),
          ]
          .compactMap { name, value in value.map { "\(name) \(numberText($0))" } }
          lines.append("    \(eye): \(values.isEmpty ? "–" : values.joined(separator: ", "))")
        }
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthSearchResult: TextOutput {
  var text: String {
    guard !types.isEmpty || !medications.isEmpty else { return "Nothing found.\n" }
    var lines: [String] = []
    let width = types.map(\.name.count).max() ?? 0
    for type in types {
      let category = type.category.map { "\($0), " } ?? ""
      let data = type.hasData ? "" : ", no data"
      lines.append(row(type.name, width, "\(type.type) (\(category.dropLast(2))\(data))"))
    }
    if !medications.isEmpty {
      if !lines.isEmpty { lines.append("") }
      lines.append("Medications:")
      lines += medications.map { "  \($0.name)" }
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthSyncStatusResult: TextOutput {
  var text: String {
    var lines = ["Latest sample: \(latestSample.map(time) ?? "none") (\(timeZone))", ""]
    if iPhones.isEmpty { lines.append("No iPhone has uploaded Health data yet.") }
    for iPhone in iPhones {
      var parts = ["last reported \(time(iPhone.lastReported))"]
      if iPhone.pairedWithWatch { parts.append("paired with an Apple Watch") }
      if iPhone.statisticsSource { parts.append("totals come from it") }
      lines.append("iPhone \(iPhone.device): " + parts.joined(separator: ", "))
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

// MARK: - Formatting

/// A type's name as lil health shows it, or its identifier.
private func name(of type: String) -> String {
  HealthCatalog.type(id: type)?.name ?? type
}

private func row(_ label: String, _ width: Int, _ value: String) -> String {
  label.padding(toLength: width, withPad: " ", startingAt: 0) + "   " + value
}

/// Up to two decimals, without trailing zeros: `8500`, `72.5`, `0.33`.
func numberText(_ value: Double) -> String {
  var text = String(format: "%.2f", value)
  while text.hasSuffix("0") { text.removeLast() }
  if text.hasSuffix(".") { text.removeLast() }
  return text == "-0" ? "0" : text
}

private func quantity(_ value: Double, _ unit: String?) -> String {
  guard let unit, unit != "count" else { return numberText(value) }
  return "\(numberText(value)) \(unit)"
}

/// `2026-10-20T08:15:00+01:00` as `2026-10-20 08:15`.
private func time(_ localTime: String) -> String {
  String(localTime.prefix(16)).replacingOccurrences(of: "T", with: " ")
}

/// A local time's day.
private func day(_ localTime: String) -> String {
  String(localTime.prefix(10))
}

/// The last day of a period ending (exclusive) at `end`, a day's start.
private func lastDay(_ end: String) -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(identifier: "UTC")
  formatter.dateFormat = "yyyy-MM-dd"
  guard let date = formatter.date(from: day(end)) else { return day(end) }
  return formatter.string(from: date.addingTimeInterval(-86_400))
}

/// `7h 05m`, `42m`, `30s`.
func durationText(_ seconds: Double) -> String {
  let total = Int(seconds.rounded())
  let (hours, minutes) = (total / 3600, total % 3600 / 60)
  if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
  if minutes > 0 { return "\(minutes)m" }
  return "\(total)s"
}
