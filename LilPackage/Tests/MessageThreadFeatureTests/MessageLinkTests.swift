import Foundation
import Testing

@testable import MessageThreadFeature

struct MessageLinkTests {
  @Test
  func detectsURLs() {
    let text = "Check https://example.com/path?q=1 when you can"
    let links = MessageLink.detect(in: text)
    #expect(links.map(\.url.absoluteString) == ["https://example.com/path?q=1"])
    #expect((text as NSString).substring(with: links[0].range) == "https://example.com/path?q=1")
  }

  @Test
  func detectsPhoneNumbersAsTelURLs() {
    let text = "Call (415) 555-0100 for changes"
    let links = MessageLink.detect(in: text)
    #expect(links.map(\.url.absoluteString) == ["tel:4155550100"])
    #expect((text as NSString).substring(with: links[0].range) == "(415) 555-0100")
  }

  @Test
  func detectsSeveralLinks() {
    let links = MessageLink.detect(in: "example.com or +1 415 555 0100")
    #expect(links.count == 2)
    #expect(links.contains { $0.url.scheme == "tel" })
    #expect(links.contains { $0.url.host() == "example.com" })
  }

  @Test
  func plainTextHasNoLinks() {
    #expect(MessageLink.detect(in: "See you there 🥾").isEmpty)
    #expect(MessageLink.detect(in: "").isEmpty)
  }
}
