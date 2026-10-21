import Foundation
import HealthDatabase
import SwiftUI

// In their own file: previewing a file with a `List` of `ForEach` rows trips an assertion in
// SwiftUI's macOS `List` (AGENTS.md). Synthetic data only: made-up documents, people and
// providers, in a hand-written CDA.

private let now = Date(timeIntervalSince1970: 1_760_400_000)

private func document(
  _ index: Int, _ title: String, patient: String = "Robin Example",
  author: String = "", custodian: String = "", daysAgo: Double
) -> HealthDocument {
  let start = Int(now.addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970 * 1000)
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
private func list(_ state: HealthDocumentsContent.State, limit: Int = RecentHealthDocuments.limit)
  -> some View
{
  NavigationStack {
    HealthDocumentsContent(state: state, limit: limit)
  }
  .previewFrame(width: 620, height: 480)
}

@MainActor
private func detail(_ document: HealthDocument?, _ state: HealthDocumentDetailContent.State)
  -> some View
{
  NavigationStack {
    HealthDocumentDetailContent(document: document, state: state)
  }
  .previewFrame(width: 820, height: 680)
}

/// A document read as the viewer reads it.
private func read(_ xml: String) -> HealthDocumentDetailContent.State {
  HealthDocumentDetailContent.State(reading: Data(xml.utf8))
}

#Preview("Health documents") {
  list(.loaded(documents))
}

#Preview("Health documents, at the limit") {
  // As if these were the most it holds: it says the list is cut short.
  list(.loaded(documents), limit: documents.count)
}

#Preview("No health documents") {
  list(.loaded([]))
}

#Preview("Health documents loading") {
  list(.loading)
}

#Preview("Health documents failed") {
  list(.failed("The database couldn't be read."))
}

#Preview("Visit summary") {
  detail(documents[0], read(visitSummary))
}

#Preview("Some not shown") {
  detail(documents[2], read(labResults))
}

#Preview("Malformed document") {
  detail(documents[1], read(malformed))
}

#Preview("Document loading") {
  detail(documents[0], .loading)
}

#Preview("Document failed") {
  detail(documents[0], .failed("The document couldn't be downloaded."))
}

#Preview("Document no longer shared") {
  detail(nil, .loading)
}

#Preview("Document XML") {
  DocumentXMLSheet(
    title: documents[0].displayTitle, id: documents[0].xml, xml: Data(visitSummary.utf8)
  )
  .previewFrame(width: 760, height: 560)
}
