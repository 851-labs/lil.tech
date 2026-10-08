import ConversationListFeature
import Foundation
import MessagesDatabase
import Tagged
import Testing

@testable import ConversationListFeature

struct ConversationDisplayTests {
  @Test
  func titlePrefersDisplayName() {
    let conversation = makeConversation(displayName: "Book Club", participants: ["+15550000001"])
    #expect(conversation.title() == "Book Club")
  }

  @Test
  func titleFallsBackToParticipants() {
    #expect(makeConversation(participants: ["+15550000001"]).title() == "+1 (555) 000-0001")
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
  func titleFormatsUnnamedGroupParticipants() {
    let conversation = makeConversation(participants: ["+14155550100", "+442079460958"])
    #expect(conversation.title() == "+1 (415) 555-0100 & +442079460958")
  }

  @Test
  func titleFallsBackToChatIdentifier() {
    #expect(makeConversation(chatIdentifier: "chat123").title() == "chat123")
  }

  @Test
  func previewUsesText() {
    #expect(makeConversation(text: "  Hello  ").previewText() == "Hello")
  }

  @Test
  func previewDecodesAttributedBody() {
    #expect(makeConversation(attributedBody: Data(helloArchive)).previewText() == "Hello")
  }

  @Test
  func previewDropsAttachmentPlaceholders() {
    #expect(makeConversation(text: "Look \u{FFFC}").previewText() == "Look")
  }

  @Test
  func previewForAttachmentOnlyMessage() {
    #expect(
      makeConversation(text: "\u{FFFC}", hasAttachments: true).previewText() == "Attachment"
    )
  }

  @Test
  func avatarAddressIsTheOneOnOneParticipant() {
    #expect(makeConversation(participants: ["+15550000002"]).avatarAddress == "+15550000002")
    #expect(makeConversation(chatIdentifier: "+15550000003").avatarAddress == "+15550000003")
    var group = makeConversation(participants: ["+15550000001", "+15550000002"])
    group.style = .group
    #expect(group.avatarAddress == nil)
  }

  @Test
  func attachmentPreviews() {
    func preview(
      _ attachments: [Conversation.AttachmentSummary],
      text: String? = nil,
      isAudioMessage: Bool = false
    ) -> String {
      var conversation = makeConversation(text: text, hasAttachments: true)
      conversation.latestMessage.attachments = attachments
      conversation.latestMessage.isAudioMessage = isAudioMessage
      return conversation.previewText()
    }
    let photo = Conversation.AttachmentSummary(
      mimeType: "image/heic", uti: "public.heic", transferName: "IMG_0001.HEIC")
    let video = Conversation.AttachmentSummary(
      mimeType: "video/quicktime", uti: "com.apple.quicktime-movie", transferName: "IMG_0002.MOV")
    let pdf = Conversation.AttachmentSummary(
      mimeType: "application/pdf", uti: "com.adobe.pdf", transferName: "Plan.pdf")

    #expect(preview([photo]) == "Photo")
    #expect(preview([video]) == "Video")
    #expect(preview([pdf]) == "Plan.pdf")
    #expect(
      preview([.init(mimeType: nil, uti: "public.jpeg", transferName: "photo.jpg")]) == "Photo")
    #expect(preview([.init(mimeType: "application/zip", uti: nil, transferName: nil)]) == "File")
    #expect(
      preview([.init(mimeType: "image/png", uti: nil, transferName: nil, isSticker: true)])
        == "Sticker"
    )
    #expect(
      preview(
        [.init(mimeType: "audio/x-caf", uti: "com.apple.coreaudio-format", transferName: nil)],
        isAudioMessage: true
      ) == "Audio Message"
    )
    #expect(preview([photo, photo]) == "Attachments: 2 Photos")
    #expect(preview([photo, video, photo]) == "Attachments: 2 Photos, 1 Video")
    #expect(preview([photo], text: "Look at this") == "Look at this")
    #expect(preview([]) == "Attachment")
  }

  @Test
  func tapbackPreviewsForEachType() {
    let cases: [(Tapback, String)] = [
      (.loved, "Ada loved “See you there”"),
      (.liked, "Ada liked “See you there”"),
      (.disliked, "Ada disliked “See you there”"),
      (.laughed, "Ada laughed at “See you there”"),
      (.emphasized, "Ada emphasized “See you there”"),
      (.questioned, "Ada questioned “See you there”"),
      (.emoji("🔥"), "Ada reacted 🔥 to “See you there”"),
    ]
    for (tapback, expected) in cases {
      let conversation = makeTapbackConversation(
        tapback, reactedTo: .init(body: "See you there", hasAttachments: false))
      #expect(conversation.previewText(contactNames: contactNames) == expected)
    }
  }

  @Test
  func tapbackPreviewFromMe() {
    let conversation = makeTapbackConversation(
      .loved, isFromMe: true, reactedTo: .init(body: "excited 2 see u", hasAttachments: false))
    #expect(conversation.previewText(contactNames: contactNames) == "You loved “excited 2 see u”")
  }

  @Test
  func tapbackPreviewFromUnknownSenderUsesFormattedHandle() {
    let conversation = makeTapbackConversation(
      .laughed, reactedTo: .init(body: "bruh", hasAttachments: false))
    #expect(conversation.previewText() == "+1 (555) 000-0001 laughed at “bruh”")
  }

  @Test
  func tapbackPreviewForMissingOrAttachmentOriginal() {
    #expect(
      makeTapbackConversation(.liked, reactedTo: nil).previewText(contactNames: contactNames)
        == "Ada liked a message"
    )
    #expect(
      makeTapbackConversation(.liked, reactedTo: .init(body: "", hasAttachments: true))
        .previewText(contactNames: contactNames) == "Ada liked an attachment"
    )
  }

  @Test
  func tapbackPreviewTruncatesLongQuotes() {
    let long = String(repeating: "a", count: 60)
    let conversation = makeTapbackConversation(
      .loved, reactedTo: .init(body: long, hasAttachments: false))
    #expect(
      conversation.previewText(contactNames: contactNames)
        == "Ada loved “\(String(repeating: "a", count: 50))…”"
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

private let contactNames = ["+15550000001": "Ada Lovelace"]

private func makeTapbackConversation(
  _ tapback: Tapback,
  isFromMe: Bool = false,
  reactedTo: Conversation.ReactedMessage?
) -> Conversation {
  var conversation = makeConversation(text: "Loved “something”")
  conversation.latestMessage.isFromMe = isFromMe
  conversation.latestMessage.senderAddress = isFromMe ? nil : "+15550000001"
  conversation.latestMessage.tapback = tapback
  conversation.latestMessage.reactedTo = reactedTo
  return conversation
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

struct MonogramTests {
  @Test
  func initials() {
    #expect(monogramInitials("Ada Lovelace") == "AL")
    #expect(monogramInitials("Grace Brewster Hopper") == "GH")
    #expect(monogramInitials("mami") == "M")
    #expect(monogramInitials("+1 (415) 555-0100") == nil)
    #expect(monogramInitials("") == nil)
  }
}
