import Testing

@testable import HealthCLI
@testable import HealthTools

// `lil-health samples`' text for a correlation (851-4166): its samples, by name. Synthetic data
// only.
@Suite struct SamplesTextTests {
  @Test func correlationListsItsSamples() {
    var details = HealthSampleDetails()
    details.values = [
      HealthCorrelatedValue(
        type: "HKQuantityTypeIdentifierBloodPressureDiastolic", value: 76, unit: "mmHg"),
      HealthCorrelatedValue(
        type: "HKQuantityTypeIdentifierBloodPressureSystolic", value: 118, unit: "mmHg"),
    ]
    let result = HealthSamplesResult(
      timeZone: "UTC", range: "D", start: "2026-10-19T00:00:00+00:00",
      end: "2026-10-20T00:00:00+00:00", type: "HKCorrelationTypeIdentifierBloodPressure",
      samples: [
        HealthSampleItem(
          id: "0c0f0000-0000-4000-8000-000000000341", start: "2026-10-19T08:00:00+00:00",
          end: "2026-10-19T08:01:00+00:00", value: nil, unit: nil, categoryValue: nil,
          source: "Test Cuff", details: details)
      ],
      nextCursor: nil)
    #expect(
      result.text == """
        Blood Pressure, D: 2026-10-19 to 2026-10-19 (UTC)

          2026-10-19 08:00   Diastolic Blood Pressure 76 mmHg, Systolic Blood Pressure 118 mmHg   Test Cuff

        """)
  }
}
