#if os(macOS)
  import Foundation
  import HealthDatabase
  @testable import HealthPages
  import SwiftUI
  import Testing

  // Health Documents (`HealthDocumentsView`), a document read as the viewer reads it
  // (`HealthDocumentDetailContent`), and its XML (`DocumentXMLSheet`), dated before `previewNow`.
  // Synthetic data only:
  // made-up documents, people and providers, in a hand-written CDA.

  extension MacSnapshotTests {
    @Test(arguments: healthDocumentsCatalog.selectedStates)
    func healthDocuments(_ state: CatalogState) {
      state.assertMacSnapshots()
    }
  }

  let healthDocumentsCatalog = StateCatalog(
    "Health Documents", width: 620, minHeight: 480,
    states: [
      CatalogState("Health documents") { list(.loaded(documents)) },
      // As if these were the most it holds: it says the list is cut short.
      CatalogState("Health documents, at the limit") {
        list(.loaded(documents), limit: documents.count)
      },
      CatalogState("No health documents") { list(.loaded([])) },
      CatalogState("Health documents loading") { list(.loading) },
      CatalogState("Health documents failed") { list(.failed("The database couldn't be read.")) },
      CatalogState("Visit summary", width: 820, minHeight: 680) {
        detail(documents[0], read(visitSummary))
      },
      CatalogState("Some not shown", width: 820, minHeight: 680) {
        detail(documents[2], read(labResults))
      },
      CatalogState("Malformed document", width: 820, minHeight: 680) {
        detail(documents[1], read(malformed))
      },
      CatalogState("Document loading", width: 820, minHeight: 680) {
        detail(documents[0], .loading)
      },
      CatalogState("Document failed", width: 820, minHeight: 680) {
        detail(documents[0], .failed("The document couldn't be downloaded."))
      },
      CatalogState("Document no longer shared", width: 820, minHeight: 680) {
        detail(nil, .loading)
      },
      CatalogState("Document XML", width: 760, minHeight: 560) {
        DocumentXMLSheet(
          title: documents[0].displayTitle, id: documents[0].xml, xml: Data(visitSummary.utf8))
      },
    ])

  private func document(
    _ index: Int, _ title: String, patient: String = "Robin Example",
    author: String = "", custodian: String = "", daysAgo: Double
  ) -> HealthDocument {
    let start = Int(previewNow.addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970 * 1000)
    return HealthDocument(
      id: "8a2d4c10-0000-4000-8000-\(String(format: "%012d", index))", startDate: start,
      endDate: start, title: title, patientName: patient, authorName: author,
      custodianName: custodian, xml: String(repeating: "\(index % 10)", count: 64),
      sourceName: "Health", sourceBundleID: "com.apple.Health")
  }

  private let documents = [
    document(
      1, "Visit Summary", author: "Dr. Alex Sample", custodian: "Example Family Clinic",
      daysAgo: 3),
    document(2, "Discharge Summary", custodian: "Synthetic General Hospital", daysAgo: 41),
    document(3, "Lab Results", author: "Jordan Placeholder, NP", daysAgo: 96),
    document(4, "", daysAgo: 400),
  ]

  /// A visit summary with paragraphs, emphasis, a list, a table (with superscripts and a cell
  /// spanning its columns) and a nested section.
  private let visitSummary = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ClinicalDocument xmlns="urn:hl7-org:v3">
      <title>Visit Summary</title>
      <recordTarget><patientRole><patient><name>
        <given>Robin</given><family>Example</family>
      </name></patient></patientRole></recordTarget>
      <component>
        <structuredBody>
          <component>
            <section>
              <title>Reason for Visit</title>
              <text>
                <paragraph>Annual check-up. Mentions occasional
                  <content styleCode="Bold">headaches</content> after long days at a screen.</paragraph>
                <paragraph>Follow-up in <content styleCode="Italics">twelve months</content>.</paragraph>
              </text>
            </section>
          </component>
          <component>
            <section>
              <title>Medications</title>
              <text>
                <list>
                  <item>Example-statin 10 mg tablet, once daily</item>
                  <item>Vitamin D 1,000 IU, once daily</item>
                  <item>Ibuprofen 200 mg as needed<br/>No more than 3 a day</item>
                </list>
              </text>
            </section>
          </component>
          <component>
            <section>
              <title>Vital Signs</title>
              <text>
                <table>
                  <thead>
                    <tr><th>Measurement</th><th>Value</th><th>Reference</th></tr>
                  </thead>
                  <tbody>
                    <tr><td>Blood Pressure</td><td>118/76 mmHg</td><td>Below 120/80</td></tr>
                    <tr><td>Heart Rate</td><td>64 BPM</td><td>60–100</td></tr>
                    <tr><td>Weight</td><td>70.2 kg</td><td></td></tr>
                    <tr><td>White Cells</td><td>6.1 × 10<sup>9</sup>/L</td><td>4.0–11.0 × 10<sup>9</sup>/L</td></tr>
                    <tr><td colspan="3"><content styleCode="Italics">Measured seated, after five minutes' rest.</content></td></tr>
                  </tbody>
                </table>
              </text>
            </section>
          </component>
          <component>
            <section>
              <title>Plan</title>
              <text>
                <list listType="ordered">
                  <item>Keep taking the current medications.</item>
                  <item>Screen breaks every hour.</item>
                </list>
              </text>
              <component>
                <section>
                  <title>Instructions</title>
                  <text>Call the clinic if the headaches get worse.</text>
                </section>
              </component>
            </section>
          </component>
        </structuredBody>
      </component>
    </ClinicalDocument>
    """

  /// A document with a section of coded data only and an image: the viewer says some isn't shown.
  private let labResults = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ClinicalDocument xmlns="urn:hl7-org:v3">
      <component>
        <structuredBody>
          <component>
            <section>
              <title>Results</title>
              <text>
                <paragraph>Cholesterol panel, fasting.</paragraph>
                <renderMultiMedia referencedObject="chart-1"/>
              </text>
            </section>
          </component>
          <component>
            <section>
              <entry><observation classCode="OBS" moodCode="EVN"/></entry>
            </section>
          </component>
        </structuredBody>
      </component>
    </ClinicalDocument>
    """

  /// Cut off partway: not well-formed.
  private let malformed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ClinicalDocument xmlns="urn:hl7-org:v3">
      <component>
        <structuredBody>
          <component>
            <section>
              <title>Hospital Course</title>
              <text><paragraph>Admitted for observation.</paragraph>
    """

  @MainActor
  private func list(
    _ state: HealthDocumentsContent.State, limit: Int = RecentHealthDocuments.limit
  ) -> some View {
    NavigationStack {
      HealthDocumentsContent(state: state, limit: limit)
    }
  }

  @MainActor
  private func detail(_ document: HealthDocument?, _ state: HealthDocumentDetailContent.State)
    -> some View
  {
    NavigationStack {
      HealthDocumentDetailContent(document: document, state: state)
    }
  }

  /// A document read as the viewer reads it.
  private func read(_ xml: String) -> HealthDocumentDetailContent.State {
    HealthDocumentDetailContent.State(reading: Data(xml.utf8))
  }
#endif
