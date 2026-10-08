import Foundation
import MessagesDatabase
import Tagged
import Testing

@testable import MessageThreadFeature

@MainActor
struct ThreadTimestampTests {
  @Test
  func labels() {
    func label(_ secondsAgo: TimeInterval) -> String {
      ThreadTimestamp(
        now.addingTimeInterval(-secondsAgo), now: now, calendar: calendar, locale: locale
      )
      .text
    }
    #expect(label(4 * 3_600 + 37 * 60) == "Today 12:06\u{202F}PM")
    #expect(label(24 * 3_600) == "Yesterday 4:43\u{202F}PM")
    #expect(label(5 * 24 * 3_600) == "Thursday 4:43\u{202F}PM")
    #expect(label(7 * 24 * 3_600) == "Tue, Sep 1 at 4:43\u{202F}PM")
    #expect(label(365 * 24 * 3_600) == "Mon, Sep 8, 2025 at 4:43\u{202F}PM")
  }

  @Test
  func dayIsSeparateFromTime() {
    let timestamp = ThreadTimestamp(now, now: now, calendar: calendar, locale: locale)
    #expect(timestamp.day == "Today")
    #expect(timestamp.time == " 4:43\u{202F}PM")
  }

  @Test
  func separatorsGoBeforeTheFirstMessageAndAfterHourLongGaps() {
    let messages = [
      message(1, minutes: 0),
      message(2, minutes: 30),
      message(3, minutes: 90),
      message(4, minutes: 151),
    ]
    let pending = MessageThreadFeature.PendingMessage(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, text: "Hi",
      sentAt: messages[3].date.addingTimeInterval(2 * 3_600))

    let items = MessageThreadViewController.items(messages: messages, pendingMessages: [pending])

    #expect(
      items == [
        .separator(messages[0].date), .message(1), .message(2), .message(3),
        .separator(messages[3].date), .message(4),
        .separator(pending.sentAt), .pending(pending.id),
      ]
    )
  }

  @Test
  func duplicateMessagesGetOneRow() {
    let items = MessageThreadViewController.items(
      messages: [message(1, minutes: 0), message(1, minutes: 0)],
      pendingMessages: []
    )
    #expect(items == [.separator(message(1, minutes: 0).date), .message(1)])
  }
}

/// Tuesday, September 8, 2026 at 4:43 PM UTC.
private let now = Date(timeIntervalSince1970: 1_788_885_780)
private let locale = Locale(identifier: "en_US")
private let calendar: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}()

private func message(_ id: Int64, minutes: Double) -> ThreadMessage {
  ThreadMessage(
    id: Message.ID(id),
    guid: "message-\(id)",
    date: now.addingTimeInterval(minutes * 60),
    text: "Message \(id)",
    attributedBody: nil,
    isFromMe: false,
    senderAddress: "+15550000001",
    hasAttachments: false
  )
}
