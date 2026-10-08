import AppKit
import Foundation
import MessagesDatabase
import Tagged
import Testing

@testable import MessageThreadFeature

struct MessageStatusTests {
  @Test
  func receiptsOnlyShowUnderTheReceiptMessage() {
    let delivered = message(isFromMe: true, isDelivered: true)
    #expect(MessageStatus.of(delivered, showsReceipt: true) == .delivered)
    #expect(MessageStatus.of(delivered, showsReceipt: false) == nil)
  }

  @Test
  func readWinsOverDelivered() {
    let read = message(isFromMe: true, isDelivered: true, dateRead: now)
    #expect(MessageStatus.of(read, showsReceipt: true) == .read(now))
  }

  @Test
  func undeliveredOutgoingMessagesShowNothing() {
    #expect(MessageStatus.of(message(isFromMe: true), showsReceipt: true) == nil)
  }

  @Test
  func failuresShowUnderAnyOutgoingMessage() {
    let failed = message(isFromMe: true, hasError: true)
    #expect(MessageStatus.of(failed, showsReceipt: false) == .notDelivered)
    #expect(MessageStatus.of(failed, showsReceipt: true) == .notDelivered)
  }

  @Test
  func receivedMessagesHaveNoStatus() {
    let received = message(isFromMe: false, isDelivered: true, dateRead: now, hasError: true)
    #expect(MessageStatus.of(received, showsReceipt: true) == nil)
  }

  @Test
  func text() {
    #expect(
      MessageStatus.delivered.text(now: now, calendar: calendar, locale: locale) == "Delivered")
    #expect(
      MessageStatus.notDelivered.text(now: now, calendar: calendar, locale: locale)
        == "Not Delivered"
    )
  }

  @Test
  func readTimestamps() {
    func read(_ secondsAgo: TimeInterval) -> String {
      MessageStatus.read(now.addingTimeInterval(-secondsAgo))
        .text(now: now, calendar: calendar, locale: locale)
    }
    #expect(read(2 * 60) == "Read 4:41\u{202F}PM")
    #expect(read(24 * 3_600) == "Read Yesterday")
    #expect(read(3 * 24 * 3_600) == "Read Saturday")
    #expect(read(30 * 24 * 3_600) == "Read 8/9/2026")
  }

  @MainActor
  @Test
  func statusTextStacksEditedAboveTheStatus() {
    #expect(MessageCellView.statusText(isEdited: false, status: nil) == nil)
    #expect(MessageCellView.statusText(isEdited: true, status: nil)?.string == "Edited")
    #expect(
      MessageCellView.statusText(isEdited: true, status: .delivered)?.string == "Edited\nDelivered"
    )
  }

  @MainActor
  @Test
  func notDeliveredIsRed() throws {
    let text = try #require(MessageCellView.statusText(isEdited: false, status: .notDelivered))
    let color = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(color == .systemRed)
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

private func message(
  isFromMe: Bool,
  isDelivered: Bool = false,
  dateRead: Date? = nil,
  hasError: Bool = false
) -> ThreadMessage {
  ThreadMessage(
    id: 1,
    guid: "message-1",
    date: now,
    text: "Hello",
    attributedBody: nil,
    isFromMe: isFromMe,
    senderAddress: isFromMe ? nil : "+15550000001",
    hasAttachments: false,
    isDelivered: isDelivered,
    dateRead: dateRead,
    hasError: hasError
  )
}
