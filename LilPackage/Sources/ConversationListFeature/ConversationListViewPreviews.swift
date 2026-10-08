import AppKit
import ComposableArchitecture
import ContactNames
import MessagesDatabase
import SQLiteData
import SwiftUI

// Lives in its own file: previewing a file instruments its functions, and with ForEach rows that
// trips an assertion in SwiftUI's macOS List (TableViewListCore_Mac2). Keeping the view code in
// ConversationListView.swift leaves it uninstrumented, as in the app.

#Preview("Messages", traits: .previewChatDatabase) {
  ConversationListPreview(filter: .messages)
}

#Preview("Spam", traits: .previewChatDatabase) {
  ConversationListPreview(filter: .spam)
}

#Preview("Recently Deleted", traits: .previewChatDatabase) {
  ConversationListPreview(filter: .recentlyDeleted)
}

#Preview("Selection", traits: .previewChatDatabase) {
  ConversationListPreview(selection: PreviewChatDatabase.groupChatID)
}

#Preview("Without Contact Names", traits: .previewChatDatabase) {
  ConversationListPreview(showsContactNames: false)
}

#Preview("Empty", traits: .emptyChatDatabase) {
  ConversationListPreview(isEmpty: true)
}

#Preview("Empty Spam", traits: .emptyChatDatabase) {
  ConversationListPreview(filter: .spam, isEmpty: true)
}

#Preview("Load Failed", traits: .emptyChatDatabase) {
  ConversationListPreview(isEmpty: true, loadFailed: true)
}

/// The sidebar showing `filter`, seeded from the preview `chat.db`.
private struct ConversationListPreview: View {
  var filter = ConversationFilter.messages
  var selection: Chat.ID?
  var showsContactNames = true
  var isEmpty = false
  var loadFailed = false
  /// Static previews skip the reducer, so the view's `.task` can't replace the seeded state
  /// (loading sets `isLoading`, which hides the empty state) before the snapshot.
  var isStatic: Bool { isEmpty || loadFailed }

  var body: some View {
    let conversations =
      isEmpty
      ? []
      : try! makePreviewChatDatabase().read { db in
        try ConversationsRequest(filter: filter).fetch(db)
      }
    let contactNames =
      showsContactNames
      ? Dictionary(
        uniqueKeysWithValues: PreviewChatDatabase.contactNames.map { ($0.address, $0.name) }
      )
      : [:]
    NavigationSplitView {
      ConversationListView(
        store: Store(
          initialState: ConversationListFeature.State(
            contactNames: contactNames,
            contactPhotos: showsContactNames ? ["+14155550101": previewContactPhoto] : [:],
            conversations: conversations,
            filter: filter,
            loadFailed: loadFailed,
            selection: selection
          )
        ) {
          if isStatic {
            EmptyReducer()
          } else {
            ConversationListFeature()
          }
        }
      )
      .navigationSplitViewColumnWidth(min: 240, ideal: 300)
    } detail: {
      Text("Detail")
    }
    .frame(width: 720, height: 480)
  }
}

extension PreviewTrait where T == Preview.ViewTraits {
  /// An empty `chat.db`, so the list's `.task` load keeps the seeded empty state.
  fileprivate static var emptyChatDatabase: Self {
    .dependencies {
      $0.chatDatabase = .constant(try makeInMemoryChatDatabase())
      $0.contactNames = .constant(ContactIndex([]))
    }
  }

  fileprivate static var previewChatDatabase: Self {
    .dependencies {
      $0.chatDatabase = .constant(try makePreviewChatDatabase())
      $0.contactNames = .constant(
        ContactIndex(
          PreviewChatDatabase.contactNames.map {
            ContactIndex.Contact(
              name: $0.name,
              phoneNumbers: [$0.address],
              emails: [$0.address],
              thumbnailImageData: $0.address == "+14155550101" ? previewContactPhoto : nil
            )
          }
        )
      )
    }
  }
}

/// A synthetic contact photo: a smiley on a gradient. Previews never use real contact photos.
private let previewContactPhoto: Data = {
  let size = NSSize(width: 120, height: 120)
  let image = NSImage(size: size, flipped: false) { rect in
    NSGradient(starting: .systemOrange, ending: .systemPink)?.draw(in: rect, angle: -90)
    let symbol = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 64, weight: .regular))
    symbol?.isTemplate = true
    if let symbol {
      let tinted = NSImage(size: symbol.size, flipped: false) { symbolRect in
        symbol.draw(in: symbolRect)
        NSColor.white.set()
        symbolRect.fill(using: .sourceAtop)
        return true
      }
      tinted.draw(
        in: NSRect(
          x: (rect.width - symbol.size.width) / 2,
          y: (rect.height - symbol.size.height) / 2,
          width: symbol.size.width,
          height: symbol.size.height
        )
      )
    }
    return true
  }
  let bitmap = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
  return bitmap?.representation(using: .png, properties: [:]) ?? Data()
}()
