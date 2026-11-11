import Testing

@testable import HealthCLI
@testable import HealthTools

// `lil-health documents` and `document`'s text (851-4163): each document as the Health Documents
// page lists it, and a page of its XML. Synthetic data only.
@Suite struct DocumentTextTests {
  @Test func listsEachDocument() {
    let result = HealthDocumentsResult(
      timeZone: "UTC", range: "Y", start: "2025-11-01T00:00:00+00:00",
      end: "2026-10-21T00:00:00+00:00", count: 3,
      documents: [
        HealthDocumentItem(
          id: "d1", title: "Visit Summary", patient: "Jane Example", author: "Dr. Sam Placeholder",
          custodian: "Synthetic Health Clinic", start: "2026-10-19T14:00:00+00:00",
          end: "2026-10-19T15:00:00+00:00", source: "Synthetic Clinic"),
        HealthDocumentItem(
          id: "d2", title: "Lab Report", patient: nil, author: nil,
          custodian: "Synthetic Lab", start: "2026-10-16T09:00:00+00:00",
          end: "2026-10-16T09:00:00+00:00", source: "Synthetic Records"),
      ])
    #expect(
      result.text == """
        Health Documents, Y: 2025-11-01 to 2026-10-20 (UTC)
        3 documents

          2026-10-19   Visit Summary · Dr. Sam Placeholder   d1
          2026-10-16   Lab Report · Synthetic Lab   d2

        Showing the 2 most recent documents.

        """)
  }

  @Test func showsAPageOfTheXML() {
    let result = HealthDocumentResult(
      timeZone: "UTC", id: "d1", title: "Visit Summary", start: "2026-10-19T14:00:00+00:00",
      length: 100, offset: 40, xml: "<title>🙂</title>", nextCursor: "57")
    #expect(
      result.text == """
        Visit Summary   2026-10-19 14:00 (UTC)   d1
        Characters 40 to 57 of 100:

        <title>🙂</title>

        More: --cursor 57

        """)
  }
}
