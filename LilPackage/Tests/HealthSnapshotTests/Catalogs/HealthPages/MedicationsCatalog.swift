#if os(macOS)
  import Foundation
  import HealthDatabase
  @testable import HealthPages
  import SwiftUI
  import Testing

  // Medications (`MedicationsView`) and a medication's adherence and dose log
  // (`MedicationDetailContent`), with doses up to `previewNow`. Synthetic data only: made-up
  // medications and doses.

  extension MacSnapshotTests {
    @Test(arguments: medicationsCatalog.selectedStates)
    func medications(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let medicationsCatalog = StateCatalog(
    "Medications", width: 620, minHeight: 420,
    states: [
      CatalogState("Medications") { list(.loaded([tablet, drops, spray, capsule, patch])) },
      CatalogState("Medications, archived only") { list(.loaded([capsule, patch])) },
      CatalogState("Medications, long names") {
        list(.loaded([longName, tablet, unknownForm, spray, capsule]))
      },
      CatalogState("No medications") { list(.loaded([])) },
      CatalogState("Medications loading") { list(.loading) },
      CatalogState("Medications failed") { list(.failed("The database couldn't be read.")) },
      CatalogState("Scheduled medication", width: 760, minHeight: 640) {
        detailPage(.loaded(detail(tablet, twiceDaily(tablet, days: 9))))
      },
      CatalogState("As-needed medication", width: 760, minHeight: 640) {
        detailPage(
          .loaded(
            detail(
              spray,
              [
                dose(spray, day: 0, hour: 9.25, status: .taken, quantity: 2),
                dose(spray, day: 2, hour: 22.5, status: .taken),
                dose(spray, day: 12, hour: 7, status: .taken, quantity: 2),
              ])))
      },
      CatalogState("Medication with no doses", width: 760, minHeight: 640) {
        detailPage(.loaded(detail(drops, [])))
      },
      CatalogState("Archived medication", width: 760, minHeight: 640) {
        detailPage(
          .loaded(
            detail(
              capsule,
              (40..<44).map { dose(capsule, day: $0, hour: 9, status: .taken, quantity: 2) })))
      },
      CatalogState("Medication, many doses and a long name", width: 760, minHeight: 640) {
        detailPage(
          .loaded(
            detail(
              longName,
              twiceDaily(longName, days: 30)
                + [dose(longName, day: 1, hour: 13, status: .taken, quantity: 0.5, unit: "mg")],
              isLimited: true)),
          limit: 59)
      },
      CatalogState("Medication loading", width: 760, minHeight: 640) {
        detailPage(.loading(tablet))
      },
      CatalogState("Medication no longer shared", width: 760, minHeight: 640) {
        detailPage(.noLongerShared)
      },
      CatalogState("Medication failed", width: 760, minHeight: 640) {
        detailPage(.failed("The database couldn't be read."))
      },
    ])

  private func medication(
    _ index: Int, _ name: String, nickname: String? = nil, form: String, archived: Bool = false,
    scheduled: Bool = true
  ) -> HealthMedication {
    HealthMedication(
      id: String(repeating: "\(index)", count: 64), name: name, nickname: nickname,
      generalForm: form, isArchived: archived, hasSchedule: scheduled)
  }

  private let tablet = medication(
    1, "Synthetic Tablet A 10 mg", nickname: "Morning Tablet", form: "tablet")
  private let spray = medication(2, "Synthetic Spray B", form: "spray", scheduled: false)
  private let drops = medication(3, "Synthetic Drops C 0.5%", form: "drops")
  private let capsule = medication(4, "Synthetic Capsule D", form: "capsule", archived: true)
  private let patch = medication(
    5, "Synthetic Patch E", form: "patch", archived: true, scheduled: false)
  private let longName = medication(
    6,
    "Synthetic Extended-Release Combination Tablet F 24-Hour 150 mg / 12.5 mg with a Very Long Name",
    nickname: "The Long-Named Synthetic Evening Tablet That Wraps", form: "tablet")
  private let unknownForm = medication(7, "Synthetic Remedy G", form: "unknown", scheduled: false)

  /// A dose of `medication`, `day` days before `previewNow`'s day, due (or taken, as needed) at
  /// `hour`.
  private func dose(
    _ medication: HealthMedication, day: Int, hour: Double, status: MedicationDoseStatus,
    lateMinutes: Double = 0, quantity: Double = 1, unit: String = "count"
  ) -> HealthMedicationDose {
    let today = previewCalendar.startOfDay(for: previewNow)
    let due = previewCalendar.date(byAdding: .day, value: -day, to: today)!
      .addingTimeInterval(hour * 3600)
    let logged = due.addingTimeInterval(lateMinutes * 60)
    return HealthMedicationDose(
      id: "\(medication.id.prefix(8))-\(day)-\(hour)-\(status.rawValue)",
      startDate: logged.unixMilliseconds, endDate: logged.unixMilliseconds,
      medication: medication.id, logStatus: status.rawValue,
      scheduleType: medication.hasSchedule ? 2 : 1,
      scheduledDate: medication.hasSchedule ? due.unixMilliseconds : nil,
      scheduledDoseQuantity: medication.hasSchedule ? quantity : nil,
      doseQuantity: status == .taken ? quantity : nil, unit: unit, sourceName: "iPhone",
      sourceBundleID: "com.apple.Health")
  }

  /// Twice a day for `days` days, mostly taken, with today's evening dose still to come.
  private func twiceDaily(_ medication: HealthMedication, days: Int) -> [HealthMedicationDose] {
    (0..<days).flatMap { day in
      [8.0, 20.0].compactMap { hour -> HealthMedicationDose? in
        if day == 0 && hour == 20 { return nil }
        let status: MedicationDoseStatus =
          switch (day * 2 + Int(hour)) % 11 {
          case 3: .skipped
          case 7: .notInteracted
          case 9 where day < 3: .snoozed
          default: .taken
          }
        return dose(
          medication, day: day, hour: hour, status: status,
          lateMinutes: status == .taken ? Double((day * 7) % 25) : 0)
      }
    }
  }

  private func detail(
    _ medication: HealthMedication, _ doses: [HealthMedicationDose], isLimited: Bool = false
  ) -> MedicationDetail {
    MedicationDetail(
      medication: medication,
      adherence: [7, 30].map {
        MedicationAdherence(days: $0, doses: doses, now: previewNow, calendar: previewCalendar)
      },
      days: MedicationDoseDay.days(doses, calendar: previewCalendar), isLimited: isLimited)
  }

  @MainActor
  private func list(_ state: MedicationsContent.State) -> some View {
    NavigationStack {
      MedicationsContent(state: state)
    }
  }

  @MainActor
  private func detailPage(_ state: MedicationDetailContent.State, limit: Int = 1_000)
    -> some View
  {
    NavigationStack {
      MedicationDetailContent(state: state, limit: limit, now: previewNow)
    }
  }
#endif
