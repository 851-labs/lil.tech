import Foundation
import HealthCatalog
import HealthDatabase
import SQLiteData
import Testing

// Synthetic data only (AGENTS.md): hand-written CDA with made-up people and providers.

/// A CDA document whose structured body is `components`.
private func cda(_ components: String) -> Data {
  Data(
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ClinicalDocument xmlns="urn:hl7-org:v3" xmlns:sdtc="urn:hl7-org:sdtc">
      <title>Synthetic Summary</title>
      <component><structuredBody>\(components)</structuredBody></component>
    </ClinicalDocument>
    """.utf8)
}

private func section(_ title: String, _ text: String) -> String {
  "<component><section><title>\(title)</title><text>\(text)</text></section></component>"
}

private func readSections(_ components: String) throws -> [DocumentSection] {
  try ClinicalDocument(xml: cda(components)).sections
}

private func readError(_ xml: Data) -> ClinicalDocument.ReadError? {
  do {
    _ = try ClinicalDocument(xml: xml)
    return nil
  } catch {
    return error
  }
}

@Suite
struct ClinicalDocumentTests {
  @Test
  func readsSectionsTitlesAndParagraphs() throws {
    let sections = try readSections(
      section(
        "Reason for Visit",
        """
        <paragraph>Annual
            check-up.</paragraph>
        <paragraph>  Follow-up in <content styleCode="Bold Italics">a year</content>.  </paragraph>
        """)
        + section("Allergies", "No known allergies."))
    #expect(
      sections == [
        DocumentSection(
          title: "Reason for Visit",
          blocks: [
            .paragraph(NarrativeText("Annual check-up.")),
            .paragraph(
              NarrativeText([
                NarrativeText.Run("Follow-up in "),
                NarrativeText.Run("a year", isBold: true, isItalic: true),
                NarrativeText.Run("."),
              ])),
          ]),
        DocumentSection(
          title: "Allergies", blocks: [.paragraph(NarrativeText("No known allergies."))]),
      ])
  }

  @Test
  func textBetweenBlocksIsAParagraphAndBreaksAreNewlines() throws {
    let sections = try readSections(
      section(
        "Notes",
        """
        Seen today.<br/>
        Feeling well.
        <paragraph>Plan below.</paragraph>
        <br/>Afterwards <content styleCode="Underline">rest</content>.<br/><br/>
        """))
    #expect(
      sections.first?.blocks == [
        .paragraph(NarrativeText("Seen today.\nFeeling well.")),
        .paragraph(NarrativeText("Plan below.")),
        .paragraph(
          NarrativeText([
            NarrativeText.Run("Afterwards "), NarrativeText.Run("rest", isUnderlined: true),
            NarrativeText.Run("."),
          ])),
      ])
  }

  @Test
  func readsListsAndNestedLists() throws {
    let sections = try readSections(
      section(
        "Medications",
        """
        <list>
          <item>Example-statin 10 mg</item>
          <item><paragraph>Vitamin D</paragraph>
            <list listType="ordered"><item>Morning</item><item>Evening</item></list>
          </item>
          <item>   </item>
        </list>
        """))
    #expect(
      sections.first?.blocks == [
        .list(
          ordered: false,
          items: [
            [.paragraph(NarrativeText("Example-statin 10 mg"))],
            [
              .paragraph(NarrativeText("Vitamin D")),
              .list(
                ordered: true,
                items: [
                  [.paragraph(NarrativeText("Morning"))], [.paragraph(NarrativeText("Evening"))],
                ]),
            ],
          ])
      ])
  }

  @Test
  func readsTablesWithHeaderRowsAndCells() throws {
    let sections = try readSections(
      section(
        "Vital Signs",
        """
        <table border="1">
          <caption>Today</caption>
          <colgroup><col width="50%"/></colgroup>
          <thead><tr><th>Measurement</th><th>Value</th></tr></thead>
          <tbody>
            <tr><th>Heart Rate</th><td>64 <content styleCode="Bold">BPM</content></td></tr>
            <tr><td>Weight</td><td></td></tr>
            <tr><td>Notes</td><td><paragraph>Taken twice</paragraph><paragraph>Seated</paragraph></td></tr>
          </tbody>
        </table>
        """))
    let table = NarrativeTable(
      caption: NarrativeText("Today"),
      rows: [
        NarrativeTable.Row(
          cells: [
            NarrativeTable.Cell(text: NarrativeText("Measurement"), isHeader: true),
            NarrativeTable.Cell(text: NarrativeText("Value"), isHeader: true),
          ], isHeader: true),
        NarrativeTable.Row(cells: [
          NarrativeTable.Cell(text: NarrativeText("Heart Rate"), isHeader: true),
          NarrativeTable.Cell(
            text: NarrativeText([NarrativeText.Run("64 "), NarrativeText.Run("BPM", isBold: true)])
          ),
        ]),
        NarrativeTable.Row(cells: [
          NarrativeTable.Cell(text: NarrativeText("Weight")), NarrativeTable.Cell(text: nil),
        ]),
        NarrativeTable.Row(cells: [
          NarrativeTable.Cell(text: NarrativeText("Notes")),
          NarrativeTable.Cell(text: NarrativeText("Taken twice\nSeated")),
        ]),
      ])
    #expect(sections.first?.blocks == [.table(table)])
    #expect(table.columnCount == 2)
  }

  @Test
  func readsNestedSections() throws {
    let sections = try readSections(
      """
      <component><section>
        <title>Plan</title>
        <component><section><title>Instructions</title><text>Rest.</text></section></component>
      </section></component>
      """)
    #expect(
      sections == [
        DocumentSection(
          title: "Plan",
          sections: [
            DocumentSection(title: "Instructions", blocks: [.paragraph(NarrativeText("Rest."))])
          ])
      ])
  }

  @Test
  func unknownElementsShowTheirTextAndDeletedContentIsLeftOut() throws {
    let document = try ClinicalDocument(
      xml: cda(
        section(
          "Results",
          """
          <paragraph>Within <sdtc:note>the</sdtc:note> <unknownThing>normal</unknownThing> \
          range<sup>1</sup><footnoteRef IDREF="f1"/>.</paragraph>
          <paragraph><content revised="delete">Struck.</content>Kept.</paragraph>
          """)))
    #expect(
      document.sections.first?.blocks == [
        .paragraph(NarrativeText("Within the normal range1.")),
        .paragraph(NarrativeText("Kept.")),
      ])
    #expect(!document.omitsContent)
  }

  @Test
  func sectionsWithoutTextAndImagesAreNotedAsLeftOut() throws {
    let document = try ClinicalDocument(
      xml: cda(
        section(
          "Results", "<paragraph>Panel.</paragraph><renderMultiMedia referencedObject=\"x\"/>")
            + """
            <component><section>
              <code code="00000-0"/>
              <entry><observation><value value="5.2">Ignored</value></observation></entry>
            </section></component>
            <component><section><title>Procedures</title>
              <entry><procedure/></entry>
            </section></component>
            """))
    #expect(
      document.sections == [
        DocumentSection(title: "Results", blocks: [.paragraph(NarrativeText("Panel."))]),
        DocumentSection(title: "Procedures"),
      ])
    #expect(document.omitsContent)
    #expect(try !ClinicalDocument(xml: cda(section("Notes", "Fine."))).omitsContent)
  }

  @Test
  func unreadableDocumentsSayWhy() {
    #expect(
      readError(
        Data(
          """
          <?xml version="1.0"?>
          <ClinicalDocument xmlns="urn:hl7-org:v3">
            <component><structuredBody><component><section>
          """.utf8)) == .malformed(line: 3))
    #expect(readError(Data()) == .malformed(line: 1))
    #expect(
      readError(Data("<ClinicalDocument><component/></ClinicalDocument>".utf8))
        == .notClinicalDocument)
    #expect(readError(Data(#"<html xmlns="urn:hl7-org:v3"/>"#.utf8)) == .notClinicalDocument)
    #expect(
      readError(
        Data(
          """
          <ClinicalDocument xmlns="urn:hl7-org:v3"><component><nonXMLBody>
            <text mediaType="application/pdf" representation="B64">JVBERi0=</text>
          </nonXMLBody></component></ClinicalDocument>
          """.utf8)) == .noStructuredBody)
    #expect(
      readError(cda("<component><section><entry><act/></entry></section></component>"))
        == .noReadableSections)
  }

  @Test
  func textOfUTF16DocumentsIsDecoded() throws {
    let xml = #"<ClinicalDocument xmlns="urn:hl7-org:v3"/>"#
    let utf16 = try #require(xml.data(using: .utf16))
    #expect(ClinicalDocument.text(of: utf16) == xml)
    #expect(ClinicalDocument.text(of: Data(xml.utf8)) == xml)
  }
}

@Suite
struct DocumentQueriesTests {
  private func document(
    _ id: String, start: Int, author: String = "", custodian: String = ""
  ) -> HealthDocument {
    HealthDocument(
      id: id, startDate: start, endDate: start, title: "Summary \(id)",
      patientName: "Robin Example", authorName: author, custodianName: custodian,
      xml: String(repeating: "a", count: 64), sourceName: "Health",
      sourceBundleID: "com.apple.Health")
  }

  @Test
  func documentsListNewestFirstUpToTheLimit() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthDocument.insert {
        document("a", start: 1_000)
        document("b", start: 3_000)
        document("c", start: 2_000)
        document("d", start: 3_000)
      }
      .execute(db)
    }
    let documents = try database.read { db in try HealthDatabase.healthDocuments(limit: 3, db) }
    #expect(documents.map(\.id) == ["d", "b", "c"])
  }

  @Test
  func bylineIsTheAuthorOrElseTheCustodian() {
    #expect(
      document("a", start: 0, author: "Dr. Alex Sample", custodian: "Example Clinic").byline
        == "Dr. Alex Sample")
    #expect(
      document("a", start: 0, author: "  ", custodian: "Example Clinic").byline == "Example Clinic")
    #expect(document("a", start: 0).byline == nil)
  }

  @Test
  func browseDatesDocumentsByTheLatest() throws {
    let database = try HealthDatabase.make()
    try database.write { db in
      try HealthDocument.insert {
        document("a", start: 1_760_000_000_000)
        document("b", start: 1_760_300_000_000)
      }
      .execute(db)
    }
    let type = try #require(HealthCatalog.type(id: "HKDocumentTypeIdentifierCDA"))
    let summary = try database.read { db in
      try HealthDatabase.metricSummary(of: type, now: .now, calendar: .current, db)
    }
    #expect(summary.latestDate == Date(unixMilliseconds: 1_760_300_000_000))
  }
}
