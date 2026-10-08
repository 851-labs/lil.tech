public import ComposableArchitecture
import MessagesDatabase
import SQLiteData
public import SwiftUI
import Tagged

public struct ConversationListView: View {
  @Bindable var store: StoreOf<ConversationListFeature>

  public init(store: StoreOf<ConversationListFeature>) {
    self.store = store
  }

  public var body: some View {
    List(selection: $store.selection.sending(\.selectionChanged)) {
      Section {
        ForEach(store.conversations) { conversation in
          ConversationRow(
            conversation: conversation,
            contactNames: store.contactNames,
            contactPhoto: conversation.avatarAddress.flatMap { store.contactPhotos[$0] }
          )
          .tag(conversation.id)
        }
      } header: {
        if store.filter != .messages {
          Text(store.filter.title)
        }
      }
    }
    .listStyle(.sidebar)
    .overlay {
      if store.loadFailed {
        ContentUnavailableView(
          "Couldn’t Load Conversations",
          systemImage: "exclamationmark.bubble",
          description: Text("The Messages database couldn’t be read.")
        )
      } else if store.conversations.isEmpty, !store.isLoading {
        switch store.filter {
        case .messages:
          ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right")
        case .spam:
          ContentUnavailableView("No Spam", systemImage: "xmark.bin")
        case .recentlyDeleted:
          ContentUnavailableView(
            "No Recently Deleted Messages",
            systemImage: "trash",
            description: Text("Deleted messages stay here for up to 30 days.")
          )
        }
      }
    }
    .toolbar {
      ToolbarItem {
        Menu {
          Picker("Filter", selection: $store.filter.sending(\.filterChanged)) {
            ForEach(ConversationFilter.allCases, id: \.self) { filter in
              Text(filter.title).tag(filter)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        } label: {
          Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
        .help("Filter Conversations")
      }
    }
    .task(id: store.filter) { await store.send(.task).finish() }
  }
}

extension ConversationFilter {
  var title: String {
    switch self {
    case .messages: "Messages"
    case .spam: "Spam"
    case .recentlyDeleted: "Recently Deleted"
    }
  }
}

struct ConversationRow: View {
  let conversation: Conversation
  let contactNames: [String: String]
  let contactPhoto: Data?

  @Dependency(\.calendar) var calendar
  @Dependency(\.date.now) var now
  @Dependency(\.locale) var locale

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      ConversationAvatar(
        isGroup: conversation.style == .group,
        name: conversation.avatarAddress.flatMap { contactNames[$0] },
        photo: contactPhoto
      )

      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline) {
          Text(conversation.title(contactNames: contactNames))
            .font(.headline)
            .lineLimit(1)
          Spacer()
          Text(
            conversationTimestamp(
              conversation.latestMessage.date,
              now: now,
              calendar: calendar,
              locale: locale
            )
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        Text(conversation.previewText(contactNames: contactNames))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, 4)
  }
}

/// A conversation's avatar, like Messages: the contact's photo, their initials when they have no
/// photo, or a stock silhouette for unknown senders and groups.
struct ConversationAvatar: View {
  let isGroup: Bool
  let name: String?
  let photo: Data?

  private let size: CGFloat = 36

  var body: some View {
    if let photo, let image = ContactPhotoCache.image(for: photo) {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: size, height: size)
        .clipShape(Circle())
    } else if !isGroup, let initials = name.flatMap(monogramInitials) {
      Circle()
        .fill(
          LinearGradient(
            colors: [Color(white: 0.66), Color(white: 0.53)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .frame(width: size, height: size)
        .overlay {
          Text(initials)
            .font(.system(size: size * 0.42, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
        }
    } else {
      Image(systemName: isGroup ? "person.2.circle.fill" : "person.crop.circle.fill")
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)
        .foregroundStyle(.secondary)
    }
  }
}

/// Decoded contact photos, so rows don't decode image data on every render.
enum ContactPhotoCache {
  nonisolated(unsafe) private static let cache = NSCache<NSData, NSImage>()

  static func image(for data: Data) -> NSImage? {
    let key = data as NSData
    if let image = cache.object(forKey: key) { return image }
    guard let image = NSImage(data: data) else { return nil }
    cache.setObject(image, forKey: key)
    return image
  }
}
