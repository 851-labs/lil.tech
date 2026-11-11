import Foundation
import HealthCatalog
import HealthTools

// How each answer reads without --json: short lines a person can scan, from the same values.

protocol TextOutput {
  var text: String { get }
}

extension HealthSummaryResult: TextOutput {
  var text: String {
    var lines = ["Summary for \(date) (\(timeZone))", ""]
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
      // A correlation's samples: "Systolic Blood Pressure 118 mmHg, Diastolic … 76 mmHg".
      let correlated = sample.details.values?.map { member in
        "\(name(of: member.type)) \(member.value.map { quantity($0, member.unit) } ?? "–")"
      }
      let value =
        sample.value.map { quantity($0, sample.unit) }
        ?? sample.categoryValue.map { "value \($0)" }
        ?? correlated?.joined(separator: ", ") ?? ""
      // A series (851-4171): "a series of 120", or which of its values this is.
      let series = sample.series.map { series in
        series.index.map { "   value \($0 + 1) of \(series.count)" }
          ?? "   series of \(series.count)"
      }
      lines.append("  \(time(sample.start))   \(value)   \(sample.source)\(series ?? "")")
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
      var parts = [
        time(workout.start), workout.name.map { "\(workout.activity) “\($0)”" } ?? workout.activity,
      ]
      let location =
        place(indoor: workout.indoor, swimmingLocation: workout.swimmingLocation)
        + (workout.hasRoute ? ["GPS route"] : [])
      if !location.isEmpty { parts.append(location.joined(separator: ", ")) }
      parts.append(durationText(workout.duration))
      if let distance = workout.distance { parts.append(numberText(distance / 1000) + " km") }
      if let energy = workout.activeEnergy { parts.append(numberText(energy.rounded()) + " kcal") }
      if let heartRate = workout.averageHeartRate {
        parts.append(numberText(heartRate.rounded()) + " bpm")
      }
      lines.append("  " + parts.joined(separator: "   "))
      for activity in workout.activities {
        let place = place(indoor: activity.indoor, swimmingLocation: activity.swimmingLocation)
        lines.append(
          "      "
            + ([activity.activity] + (place.isEmpty ? [] : [place.joined(separator: ", ")])
            + [durationText(activity.duration)]).joined(separator: "   "))
      }
    }
    if workouts.count < count {
      lines.append("  … and \(count - workouts.count) more")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthWorkoutResult: TextOutput {
  var text: String {
    let workout = self.workout
    var heading = [
      time(workout.start), workout.name.map { "\(workout.activity) “\($0)”" } ?? workout.activity,
    ]
    let location =
      place(indoor: workout.indoor, swimmingLocation: workout.swimmingLocation)
      + (workout.hasRoute ? ["GPS route"] : [])
    if !location.isEmpty { heading.append(location.joined(separator: ", ")) }
    heading.append(durationText(workout.duration))
    var lines = [heading.joined(separator: "   ") + " (\(timeZone))", "From \(workout.source)"]
    let details: [(String, String?)] = [
      ("Climbed", workout.elevationAscended.map { numberText($0) + " m" }),
      ("Descended", workout.elevationDescended.map { numberText($0) + " m" }),
      ("Avg. speed", workout.averageSpeed.map { numberText($0 * 3.6) + " km/h" }),
      ("Top speed", workout.maximumSpeed.map { numberText($0 * 3.6) + " km/h" }),
      ("Avg. METs", workout.averageMETs.map(numberText)),
      ("Pool", workout.lapLength.map { numberText($0) + " m" }),
      ("SWOLF", workout.swolf.map(numberText)),
      ("Weather", weatherText(workout)),
      ("Effort", workout.effort.map(effortText)),
    ]
    let shown = details.compactMap { label, value in value.map { (label, $0) } }
    lines += statisticsLines(workout.statistics, indent: "  ")
    if !shown.isEmpty {
      lines.append("")
      let width = shown.map(\.0.count).max() ?? 0
      lines += shown.map { "  " + row($0, width, $1) }
    }
    if !workout.pauses.isEmpty {
      lines += ["", "Pauses: \(workout.pauseCount)"]
      lines += workout.pauses.map { "  \(time($0.start))   \(durationText($0.duration))" }
      if workout.pauses.count < workout.pauseCount {
        lines.append("  … and \(workout.pauseCount - workout.pauses.count) more")
      }
    }
    lines += intervalLines("Laps", workout.laps, count: workout.lapCount)
    lines += intervalLines("Segments", workout.segments, count: workout.segmentCount)
    for leg in workout.activities {
      let place = place(indoor: leg.indoor, swimmingLocation: leg.swimmingLocation)
      lines.append("")
      lines.append(
        ([time(leg.start), leg.activity] + (place.isEmpty ? [] : [place.joined(separator: ", ")])
          + [durationText(leg.duration)] + (leg.effort.map { ["effort " + effortText($0)] } ?? []))
          .joined(separator: "   "))
      lines += statisticsLines(leg.statistics, indent: "  ")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

/// A workout's statistics, a line each: its name, then its values.
private func statisticsLines(_ statistics: [HealthWorkoutStatistic], indent: String) -> [String] {
  guard !statistics.isEmpty else { return [] }
  let names = statistics.map { $0.name ?? $0.type }
  let width = names.map(\.count).max() ?? 0
  return [""]
    + zip(names, statistics).map { name, statistic in
      let values = [
        statistic.sum.map { quantity($0, statistic.unit) },
        statistic.average.map { "avg. " + quantity($0, statistic.unit) },
        statistic.minimum.map { "min. " + quantity($0, statistic.unit) },
        statistic.maximum.map { "max. " + quantity($0, statistic.unit) },
      ]
      .compactMap(\.self)
      // A statistic with only its last reading shows that.
      let shown =
        values.isEmpty
        ? statistic.mostRecent.map { ["last " + quantity($0, statistic.unit)] } ?? [] : values
      return indent + row(name, width, shown.isEmpty ? "–" : shown.joined(separator: " · "))
    }
}

/// A workout's laps or segments, a line each, after how many there are.
private func intervalLines(_ title: String, _ intervals: [HealthWorkoutInterval], count: Int)
  -> [String]
{
  guard !intervals.isEmpty else { return [] }
  var lines = ["", "\(title): \(count)"]
  for interval in intervals {
    let parts = [
      time(interval.start), durationText(interval.duration), interval.strokeStyle,
      interval.swolf.map { "SWOLF " + numberText($0) },
      interval.averageSpeed.map { numberText($0 * 3.6) + " km/h" },
    ]
    lines.append("  " + parts.compactMap(\.self).joined(separator: "   "))
  }
  if intervals.count < count { lines.append("  … and \(count - intervals.count) more") }
  return lines
}

/// An effort score (851-4187): `7`, or `6.5 (estimated)` for Apple Watch's.
private func effortText(_ effort: HealthWorkoutEffortScore) -> String {
  numberText(effort.score) + (effort.estimated ? " (estimated)" : "")
}

/// The weather, as far as the workout says: `clear, 12 °C, 72% humidity`.
private func weatherText(_ workout: HealthWorkoutDetail) -> String? {
  let parts = [
    workout.weatherCondition,
    workout.weatherTemperature.map { numberText($0) + " °C" },
    workout.weatherHumidity.map { numberText($0) + "% humidity" },
  ]
  .compactMap(\.self)
  return parts.isEmpty ? nil : parts.joined(separator: ", ")
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

extension HealthActivityRingsResult: TextOutput {
  var text: String {
    var lines = ["Activity rings, \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))", ""]
    if days.isEmpty { lines.append("No Activity rings recorded.") }
    for day in days {
      let rings = [("Move", day.move), ("Exercise", day.exercise), ("Stand", day.stand)]
        .compactMap { name, ring in
          ring.map { "\(name) \(numberText($0.value))/\(numberText($0.goal)) \($0.unit)" }
        }
      lines.append(
        "  \(day.date)   " + (rings + (day.paused ? ["paused"] : [])).joined(separator: " · "))
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthStateOfMindResult: TextOutput {
  var text: String {
    var lines = [
      "State of Mind, \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))",
      "\(count) \(count == 1 ? "log" : "logs")",
    ]
    if !logs.isEmpty { lines.append("") }
    for log in logs {
      let parts =
        ["\(log.classification) (\(numberText(log.valence)))", log.kind]
        + (log.labels.isEmpty ? [] : [log.labels.joined(separator: ", ")])
        + (log.associations.isEmpty ? [] : ["about " + log.associations.joined(separator: ", ")])
      lines.append("  \(time(log.time))   " + parts.joined(separator: " · "))
    }
    if logs.count < count { lines += ["", "Showing the \(logs.count) most recent logs."] }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthAssessmentsResult: TextOutput {
  var text: String {
    var lines = [
      "Assessments, \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))",
      "\(count) \(count == 1 ? "assessment" : "assessments")",
    ]
    if !assessments.isEmpty { lines.append("") }
    for assessment in assessments {
      lines.append(
        "  \(time(assessment.time))   \(assessment.name)   \(assessment.risk), score "
          + "\(assessment.score) of \(assessment.maximumScore)")
      if !assessment.answers.isEmpty {
        lines.append("      " + assessment.answers.joined(separator: " · "))
      }
    }
    if assessments.count < count {
      lines += ["", "Showing the \(assessments.count) most recent assessments."]
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

// MARK: - ECGs (851-4159)

extension HealthElectrocardiogramsResult: TextOutput {
  var text: String {
    var lines = [
      "ECGs, \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))",
      "\(count) \(count == 1 ? "recording" : "recordings")",
    ]
    if !recordings.isEmpty { lines.append("") }
    for recording in recordings {
      let heartRate = recording.averageHeartRate.map { "\(Int($0.rounded())) BPM average" }
      // The symptoms logged with it by name, when its links say (851-4187).
      let symptoms =
        recording.loggedSymptoms.flatMap {
          $0.isEmpty ? nil : $0.map(\.name).joined(separator: ", ")
        }
        ?? recording.symptoms
      let parts = [recording.classification, heartRate, symptoms, recording.source]
      lines.append(
        "  \(time(recording.start))   " + parts.compactMap(\.self).joined(separator: " · ")
          + "   \(recording.id)")
    }
    if recordings.count < count {
      lines += ["", "Showing the \(recordings.count) most recent recordings."]
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthElectrocardiogramVoltagesResult: TextOutput {
  var text: String {
    var lines = [
      "ECG \(id)   \(time(start)) (\(timeZone))",
      "\(voltageCount) measurements at \(numberText(samplingFrequency)) Hz. This page: "
        + "\(values.count) values at \(numberText(rate)) Hz from \(numberText(offset)) s"
        + (measurementsPerValue > 1 ? ", each the average of \(measurementsPerValue)" : "")
        + ", in µV:",
    ]
    // A line a second, each starting with its time into the recording; the whole page on one
    // line if the rate isn't one a line can hold (a recording can say any sampling frequency).
    let perLine =
      rate.isFinite && rate < Double(max(values.count, 1))
      ? max(1, Int(rate.rounded())) : max(values.count, 1)
    for first in stride(from: 0, to: values.count, by: perLine) {
      let seconds = offset + Double(first) / rate
      let line = values[first..<min(first + perLine, values.count)]
        .map { $0.map(numberText) ?? "–" }
      lines.append("  \(numberText(seconds)) s   " + line.joined(separator: " "))
    }
    if let nextCursor { lines += ["", "More: --cursor \(nextCursor)"] }
    return lines.joined(separator: "\n") + "\n"
  }
}

// MARK: - Heartbeat series (851-4162)

extension HealthHeartbeatSeriesResult: TextOutput {
  var text: String {
    var lines = [
      "Heartbeat series, \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))",
      "\(count) series",
    ]
    if !series.isEmpty { lines.append("") }
    for item in series {
      let parts = [
        item.averageHeartRate.map { "\(numberText($0)) BPM average" },
        item.sdnn.map { "SDNN \(numberText($0)) ms" },
        item.rmssd.map { "RMSSD \(numberText($0)) ms" },
        "\(item.beatCount) \(item.beatCount == 1 ? "beat" : "beats")",
        item.gapCount == 0 ? nil : "\(item.gapCount) \(item.gapCount == 1 ? "gap" : "gaps")",
        item.source,
      ]
      lines.append(
        "  \(time(item.start))   " + parts.compactMap(\.self).joined(separator: " · ")
          + "   \(item.id)")
    }
    if series.count < count {
      lines += ["", "Showing the \(series.count) most recent series."]
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthHeartbeatSeriesBeatsResult: TextOutput {
  var text: String {
    var lines = [
      "Heartbeat series \(id)   \(time(start)) (\(timeZone))",
      "\(beatCount) \(beatCount == 1 ? "beat" : "beats"). Seconds from the start, and ms since "
        + "the beat before:",
    ]
    for beat in beats {
      let interval = beat.interval.map { "\(numberText($0)) ms" } ?? "–"
      lines.append(
        "  \(numberText(beat.time)) s   \(interval)" + (beat.precededByGap ? "   after a gap" : ""))
    }
    if let nextCursor { lines += ["", "More: --cursor \(nextCursor)"] }
    return lines.joined(separator: "\n") + "\n"
  }
}

// MARK: - Audiograms (851-4161)

extension HealthAudiogramsResult: TextOutput {
  var text: String {
    var lines = [
      "Audiograms, \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))",
      "\(count) \(count == 1 ? "audiogram" : "audiograms")",
    ]
    if !audiograms.isEmpty { lines.append("") }
    for audiogram in audiograms {
      let ears = [("Left Ear", audiogram.leftEar), ("Right Ear", audiogram.rightEar)].map {
        name, ear in
        guard let level = ear.hearingLevel, let loss = ear.hearingLoss else {
          return "\(name) Not Tested"
        }
        return "\(name) \(numberText(level)) dBHL (\(loss))"
      }
      lines.append(
        "  \(time(audiogram.start))   " + (ears + [audiogram.source]).joined(separator: " · ")
          + "   \(audiogram.id)")
      // Each ear's charted result by frequency, a bound as one (≥, ≤ or its range), and how it
      // was tested when that isn't plain air conduction.
      for (name, tests) in [
        ("Left", audiogram.points.map { ($0.frequency, $0.left.first) }),
        ("Right", audiogram.points.map { ($0.frequency, $0.right.first) }),
      ] {
        let results = tests.compactMap { frequency, test in
          test.map { test in
            let value = numberText(test.sensitivity)
            let result =
              switch (test.clampingLower, test.clampingUpper) {
              case (let lower?, let upper?):
                "\(value) (\(numberText(lower)) to \(numberText(upper)))"
              case (_?, nil): "≥\(value)"
              case (nil, _?): "≤\(value)"
              case (nil, nil): value
              }
            return "\(numberText(frequency)) Hz \(result)" + (test.masked ? " masked" : "")
              + (test.conduction == "Air" ? "" : " (\(test.conduction) conduction)")
          }
        }
        if !results.isEmpty {
          lines.append("      \(name)   " + results.joined(separator: " · "))
        }
      }
    }
    if audiograms.count < count {
      lines += ["", "Showing the \(audiograms.count) most recent audiograms."]
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

// MARK: - Health Documents (851-4163)

extension HealthDocumentsResult: TextOutput {
  var text: String {
    var lines = [
      "Health Documents, \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))",
      "\(count) \(count == 1 ? "document" : "documents")",
    ]
    if !documents.isEmpty { lines.append("") }
    // As the page lists them: its title, who it's from (its author, or else its custodian) and
    // its date.
    for document in documents {
      let parts = [document.title, document.author ?? document.custodian]
      lines.append(
        "  \(day(document.start))   " + parts.compactMap(\.self).joined(separator: " · ")
          + "   \(document.id)")
    }
    if documents.count < count {
      lines += ["", "Showing the \(documents.count) most recent documents."]
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthDocumentResult: TextOutput {
  var text: String {
    var lines = [
      "\(title)   \(time(start)) (\(timeZone))   \(id)",
      "Characters \(offset) to \(offset + xml.utf16.count) of \(length):",
      "",
      xml,
    ]
    if let nextCursor { lines += ["", "More: --cursor \(nextCursor)"] }
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
      let codes = medication.codings.map { "\(codingSystemName($0.system)) \($0.code)" }
      return "\(title)\n  \(parts.joined(separator: " · "))\n"
        + (codes.isEmpty ? "" : "  \(codes.joined(separator: " · "))\n")
    }
    .joined()
  }
}

/// A coding system's short name: RxNorm, SNOMED CT, or the system as HealthKit names it.
private func codingSystemName(_ system: String) -> String {
  switch system {
  case "http://www.nlm.nih.gov/research/umls/rxnorm": "RxNorm"
  case "http://snomed.info/sct": "SNOMED CT"
  default: system
  }
}

extension HealthMedicationDosesResult: TextOutput {
  var text: String {
    var lines = [
      "Medication doses, \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))",
      "\(count) \(count == 1 ? "dose" : "doses")",
    ]
    if !doses.isEmpty { lines.append("") }
    for dose in doses {
      var parts = [dose.medication, dose.status, dose.schedule]
      if let scheduled = dose.scheduledTime.map(time) {
        // Only its time when it was due the day it was logged.
        let sameDay = scheduled.hasPrefix(day(dose.time) + " ")
        parts.append("due " + (sameDay ? String(scheduled.dropFirst(11)) : scheduled))
      }
      // The amount logged, else the one scheduled, said to be, so it doesn't read as taken.
      if let amount = dose.amount {
        parts.append(quantity(amount, dose.unit))
      } else if let scheduled = dose.scheduledAmount {
        parts.append("\(quantity(scheduled, dose.unit)) scheduled")
      }
      lines.append("  \(time(dose.time))   " + parts.joined(separator: " · "))
    }
    if let nextCursor {
      lines.append("")
      lines.append("More: --cursor \(nextCursor)")
    }
    return lines.joined(separator: "\n") + "\n"
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
      let notes = [type.category, type.hasData ? nil : "no data"].compactMap(\.self)
      let suffix = notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))"
      lines.append(row(type.name, width, type.type + suffix))
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
/// Where a workout or activity was, as far as it says: indoor or outdoor, pool or open water.
private func place(indoor: Bool?, swimmingLocation: String?) -> [String] {
  [
    indoor.map { $0 ? "indoor" : "outdoor" },
    swimmingLocation.map { $0 == "openWater" ? "open water" : $0 },
  ]
  .compactMap(\.self)
}

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

// MARK: - Routes (851-4164)

extension HealthWorkoutRoutesResult: TextOutput {
  var text: String {
    var lines = [
      "Workout routes, \(range): \(day(start)) to \(lastDay(end)) (\(timeZone))",
      "\(count) \(count == 1 ? "route" : "routes")",
    ]
    if !routes.isEmpty { lines.append("") }
    for route in routes {
      lines.append(
        "  "
          + [
            time(route.start), durationText(route.duration), "\(route.pointCount) points",
            route.source, route.workout.map { "workout \($0)" } ?? "no workout", route.id,
          ].joined(separator: "   "))
    }
    if routes.count < count {
      lines.append("  … and \(count - routes.count) more")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthWorkoutRouteResult: TextOutput {
  var text: String {
    let route = self.route
    var lines = [
      "Route \(route.id)   \(time(route.start))   \(durationText(route.duration)) (\(timeZone))",
      (route.workout.map { "Workout \($0), from " } ?? "From ") + route.source,
      "",
    ]
    var figures = [numberText(route.distance / 1000) + " km", "\(route.pointCount) points"]
    if let gain = route.elevationGain, let loss = route.elevationLoss {
      figures.insert(
        contentsOf: ["climbed \(numberText(gain)) m", "descended \(numberText(loss)) m"], at: 1)
    }
    lines.append(figures.joined(separator: "   "))
    if let start = route.startArea, let end = route.endArea {
      lines.append(
        "Starts near \(coordinate(start.latitude, start.longitude)), ends near "
          + coordinate(end.latitude, end.longitude))
    }
    let shape = route.simplified
    lines += [
      "",
      "Shape: \(shape.pointCount) of its points, within \(numberText(shape.tolerance)) m",
    ]
    lines += shape.points.map { point in
      "  "
        + ([time(point.time), coordinate(point.latitude, point.longitude)]
        + (point.altitude.map { [numberText($0) + " m"] } ?? [])).joined(separator: "   ")
    }
    lines += ["", "Every point: route \(route.id) --points"]
    return lines.joined(separator: "\n") + "\n"
  }
}

extension HealthWorkoutRoutePointsResult: TextOutput {
  var text: String {
    var lines = ["Route \(id): \(points.count) of its \(pointCount) points (\(timeZone))", ""]
    for point in points {
      let parts = [
        String(point.time.prefix(19)).replacingOccurrences(of: "T", with: " "),
        coordinate(point.latitude, point.longitude),
        point.altitude.map { numberText($0) + " m" },
        point.speed.map { numberText($0) + " m/s" },
        point.course.map { numberText($0) + "°" },
        point.horizontalAccuracy.map { "±" + numberText($0) + " m" },
      ]
      lines.append("  " + parts.compactMap(\.self).joined(separator: "   "))
    }
    if let nextCursor {
      lines.append("")
      lines.append("More: --points --cursor \(nextCursor)")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

/// A latitude and longitude as written: `51.50012, -0.12`.
private func coordinate(_ latitude: Double, _ longitude: Double) -> String {
  "\(latitude), \(longitude)"
}
