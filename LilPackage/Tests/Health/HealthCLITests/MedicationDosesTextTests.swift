import Testing

@testable import HealthCLI
@testable import HealthTools

// `lil-health doses` and `medications`' text (851-4167): each dose's medication, status, schedule,
// when it was due and how much, the next page's cursor, and each medication's codings. Synthetic
// data only.
@Suite struct MedicationDosesTextTests {
  @Test func listsEachDose() {
    let result = HealthMedicationDosesResult(
      timeZone: "UTC", range: "W", start: "2026-10-14T00:00:00+00:00",
      end: "2026-10-21T00:00:00+00:00", count: 12,
      doses: [
        HealthMedicationDoseItem(
          medicationId: "a1", medication: "Synthetic Tablet", status: "Taken",
          schedule: "Scheduled", time: "2026-10-20T08:05:00+00:00",
          scheduledTime: "2026-10-20T08:00:00+00:00", amount: 1, scheduledAmount: 1,
          unit: "count", source: "Health"),
        HealthMedicationDoseItem(
          medicationId: "a1", medication: "Synthetic Tablet", status: "Skipped",
          schedule: "Scheduled", time: "2026-10-14T00:30:00+00:00",
          scheduledTime: "2026-10-13T23:00:00+00:00", amount: nil, scheduledAmount: 0.5,
          unit: "count", source: "Health"),
        HealthMedicationDoseItem(
          medicationId: "b2", medication: "Synthetic Spray", status: "Not Logged",
          schedule: "As Needed", time: "2026-10-16T09:00:00+00:00", scheduledTime: nil,
          amount: nil, scheduledAmount: nil, unit: "count", source: "Health"),
      ],
      nextCursor: "1792396800000_1792396830000_0c0f")
    #expect(
      result.text == """
        Medication doses, W: 2026-10-14 to 2026-10-20 (UTC)
        12 doses

          2026-10-20 08:05   Synthetic Tablet · Taken · Scheduled · due 08:00 · 1 count
          2026-10-14 00:30   Synthetic Tablet · Skipped · Scheduled · due 2026-10-13 23:00 · 0.5 count
          2026-10-16 09:00   Synthetic Spray · Not Logged · As Needed

        More: --cursor 1792396800000_1792396830000_0c0f

        """)
  }

  @Test func saysWhenThereAreNoDoses() {
    let result = HealthMedicationDosesResult(
      timeZone: "UTC", range: "D", start: "2026-10-17T00:00:00+00:00",
      end: "2026-10-18T00:00:00+00:00", count: 0, doses: [], nextCursor: nil)
    #expect(
      result.text == """
        Medication doses, D: 2026-10-17 to 2026-10-17 (UTC)
        0 doses

        """)
  }

  @Test func listsEachMedicationsCodings() {
    let adherence = HealthMedicationAdherence(scheduled: 7, taken: 6, asNeeded: 0)
    let result = HealthMedicationsResult(
      timeZone: "UTC",
      medications: [
        HealthMedicationItem(
          id: "a1", name: "Synthetic Tablet", healthName: "Synthetic Tablet", form: "tablet",
          archived: false, scheduled: true, last7Days: adherence, last30Days: adherence,
          lastTaken: "2026-10-20T08:05:00+00:00",
          codings: [
            HealthMedicationCoding(
              system: "http://www.nlm.nih.gov/research/umls/rxnorm", version: nil, code: "1"),
            HealthMedicationCoding(system: "http://snomed.info/sct", version: "1", code: "2"),
            HealthMedicationCoding(system: "urn:example", version: nil, code: "3"),
          ])
      ])
    #expect(
      result.text == """
        Synthetic Tablet (tablet)
          6 of 7 taken in 7 days · 6 of 7 taken in 30 days · last taken 2026-10-20 08:05
          RxNorm 1 · SNOMED CT 2 · urn:example 3

        """)
  }
}
