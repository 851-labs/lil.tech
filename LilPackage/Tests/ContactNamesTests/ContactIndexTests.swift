import ContactNames
import Testing

struct ContactIndexTests {
  let index = ContactIndex([
    ContactIndex.Contact(
      name: "Ada Lovelace",
      phoneNumbers: ["(415) 555-0100"],
      emails: ["Ada@Example.com"]
    ),
    ContactIndex.Contact(name: "Charles Babbage", phoneNumbers: ["+44 20 7946 0958"]),
    ContactIndex.Contact(name: "Short Code", phoneNumbers: ["72727"]),
  ])

  @Test
  func matchesE164PhoneAgainstNumberSavedWithoutCountryCode() {
    #expect(index.name(for: "+14155550100") == "Ada Lovelace")
  }

  @Test
  func matchesInternationalNumbersByDigits() {
    #expect(index.name(for: "+442079460958") == "Charles Babbage")
  }

  @Test
  func matchesShortCodesExactly() {
    #expect(index.name(for: "72727") == "Short Code")
    #expect(index.name(for: "27272") == nil)
  }

  @Test
  func matchesEmailsCaseInsensitively() {
    #expect(index.name(for: "ada@example.com") == "Ada Lovelace")
    #expect(index.name(for: " ADA@EXAMPLE.COM ") == "Ada Lovelace")
  }

  @Test
  func unknownAddresses() {
    #expect(index.name(for: "+15550000000") == nil)
    #expect(index.name(for: "someone@example.com") == nil)
    #expect(index.name(for: "") == nil)
  }

  @Test
  func firstContactWinsForSharedNumbers() {
    let index = ContactIndex([
      ContactIndex.Contact(name: "First", phoneNumbers: ["+14155550100"]),
      ContactIndex.Contact(name: "Second", phoneNumbers: ["415-555-0100"]),
    ])
    #expect(index.name(for: "+14155550100") == "First")
  }
}
