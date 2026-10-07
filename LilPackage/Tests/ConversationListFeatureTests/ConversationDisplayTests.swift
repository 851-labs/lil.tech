import ConversationListFeature
import Foundation
import MessagesDatabase
import Tagged
import Testing

struct ConversationDisplayTests {
  @Test
  func titlePrefersDisplayName() {
    let conversation = makeConversation(displayName: "Book Club", participants: ["+15550000001"])
    #expect(conversation.title() == "Book Club")
  }

  @Test
  func titleFallsBackToParticipants() {
    #expect(makeConversation(participants: ["+15550000001"]).title() == "+15550000001")
    #expect(
      makeConversation(displayName: "", participants: ["a@example.com", "b@example.com"]).title()
        == "a@example.com & b@example.com"
    )
  }

  @Test
  func titleUsesContactNamesForParticipants() {
    let conversation = makeConversation(participants: ["+14155550100", "b@example.com"])
    #expect(
      conversation.title(contactNames: ["+14155550100": "Grace Hopper"])
        == "Grace Hopper & b@example.com"
    )
  }

  @Test
  func titleFallsBackToChatIdentifier() {
    #expect(makeConversation(chatIdentifier: "chat123").title() == "chat123")
  }

  @Test
  func previewUsesText() {
    #expect(makeConversation(text: "  Hello  ").previewText == "Hello")
  }

  @Test
  func previewDecodesAttributedBody() {
    #expect(makeConversation(attributedBody: Data(helloArchive)).previewText == "Hello")
  }

  @Test
  func previewDropsAttachmentPlaceholders() {
    #expect(makeConversation(text: "Look \u{FFFC}").previewText == "Look")
  }

  @Test
  func previewForAttachmentOnlyMessage() {
    #expect(
      makeConversation(text: "\u{FFFC}", hasAttachments: true).previewText == "Attachment"
    )
  }

  @Test
  func timestamps() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let locale = Locale(identifier: "en_US")
    // Wednesday, October 7, 2026 at 18:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_396_000)

    func timestamp(hoursAgo: Double) -> String {
      conversationTimestamp(
        now.addingTimeInterval(-hoursAgo * 3600),
        now: now,
        calendar: calendar,
        locale: locale
      )
    }

    #expect(timestamp(hoursAgo: 2).replacing("\u{202F}", with: " ") == "4:00 PM")
    #expect(timestamp(hoursAgo: 24) == "Yesterday")
    #expect(timestamp(hoursAgo: 72) == "Sunday")
    #expect(timestamp(hoursAgo: 24 * 30) == "9/7/26")
  }
}

private func makeConversation(
  chatIdentifier: String = "+15550000001",
  displayName: String? = nil,
  participants: [String] = [],
  text: String? = nil,
  attributedBody: Data? = nil,
  hasAttachments: Bool = false
) -> Conversation {
  Conversation(
    id: 1,
    guid: "iMessage;-;\(chatIdentifier)",
    style: .oneOnOne,
    chatIdentifier: chatIdentifier,
    displayName: displayName,
    participants: participants,
    latestMessage: Conversation.LatestMessage(
      date: Date(timeIntervalSinceReferenceDate: 800_000_000),
      text: text,
      attributedBody: attributedBody,
      isFromMe: false,
      hasAttachments: hasAttachments
    )
  )
}

/// `NSArchiver.archivedData(withRootObject: NSAttributedString(string: "Hello"))`
private let helloArchive: [UInt8] = [
  0x04, 0x0B, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x74, 0x79, 0x70, 0x65, 0x64, 0x81, 0xE8, 0x03,
  0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12, 0x4E, 0x53, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75,
  0x74, 0x65, 0x64, 0x53, 0x74, 0x72, 0x69, 0x6E, 0x67, 0x00, 0x84, 0x84, 0x08, 0x4E, 0x53, 0x4F,
  0x62, 0x6A, 0x65, 0x63, 0x74, 0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08, 0x4E, 0x53, 0x53, 0x74,
  0x72, 0x69, 0x6E, 0x67, 0x01, 0x94, 0x84, 0x01, 0x2B, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x86,
  0x84, 0x02, 0x69, 0x49, 0x01, 0x05, 0x92, 0x84, 0x84, 0x84, 0x0C, 0x4E, 0x53, 0x44, 0x69, 0x63,
  0x74, 0x69, 0x6F, 0x6E, 0x61, 0x72, 0x79, 0x00, 0x94, 0x84, 0x01, 0x69, 0x00, 0x86, 0x86,
]
