import Contacts
public import Dependencies
public import Foundation

/// Resolves the addresses Messages uses for handles to names and photos from the user's contacts.
public struct ContactNames: Sendable {
  public var isAccessDetermined: @Sendable () -> Bool
  public var requestAccess: @Sendable () async -> Bool
  public var names: @Sendable (_ addresses: Set<String>) async -> [String: String]
  /// Photo thumbnails, as image data, for the addresses whose contacts have one.
  public var photos: @Sendable (_ addresses: Set<String>) async -> [String: Data]

  public init(
    isAccessDetermined: @escaping @Sendable () -> Bool,
    requestAccess: @escaping @Sendable () async -> Bool,
    names: @escaping @Sendable (_ addresses: Set<String>) async -> [String: String],
    photos: @escaping @Sendable (_ addresses: Set<String>) async -> [String: Data] = { _ in [:] }
  ) {
    self.isAccessDetermined = isAccessDetermined
    self.requestAccess = requestAccess
    self.names = names
    self.photos = photos
  }
}

extension ContactNames {
  public static var live: Self {
    let cache = ContactIndexCache()
    return Self(
      isAccessDetermined: {
        CNContactStore.authorizationStatus(for: .contacts) != .notDetermined
      },
      requestAccess: {
        let isGranted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        await cache.invalidate()
        return isGranted
      },
      names: { addresses in
        let index = await cache.index()
        var names: [String: String] = [:]
        for address in addresses {
          names[address] = index.name(for: address)
        }
        return names
      },
      photos: { addresses in
        let index = await cache.index()
        var photos: [String: Data] = [:]
        for address in addresses {
          photos[address] = index.thumbnail(for: address)
        }
        return photos
      }
    )
  }

  public static func constant(_ index: ContactIndex) -> Self {
    Self(
      isAccessDetermined: { true },
      requestAccess: { true },
      names: { addresses in
        var names: [String: String] = [:]
        for address in addresses {
          names[address] = index.name(for: address)
        }
        return names
      },
      photos: { addresses in
        var photos: [String: Data] = [:]
        for address in addresses {
          photos[address] = index.thumbnail(for: address)
        }
        return photos
      }
    )
  }
}

extension ContactNames: DependencyKey {
  public static var liveValue: Self {
    .live
  }

  public static var testValue: Self {
    Self(
      isAccessDetermined: unimplemented("ContactNames.isAccessDetermined", placeholder: true),
      requestAccess: unimplemented("ContactNames.requestAccess", placeholder: false),
      names: unimplemented("ContactNames.names", placeholder: [:]),
      photos: unimplemented("ContactNames.photos", placeholder: [:])
    )
  }

  public static var previewValue: Self {
    .constant(ContactIndex([]))
  }
}

extension DependencyValues {
  public var contactNames: ContactNames {
    get { self[ContactNames.self] }
    set { self[ContactNames.self] = newValue }
  }
}

/// Builds the contact index once and rebuilds it when the user's contacts change.
private actor ContactIndexCache {
  private var cachedIndex: ContactIndex?
  private var observer: (any NSObjectProtocol)?

  func index() -> ContactIndex {
    if let cachedIndex {
      return cachedIndex
    }
    observeChanges()
    let index = ContactIndex(Self.fetchContacts())
    cachedIndex = index
    return index
  }

  func invalidate() {
    cachedIndex = nil
  }

  private func observeChanges() {
    guard observer == nil else { return }
    observer = NotificationCenter.default.addObserver(
      forName: .CNContactStoreDidChange,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { await self?.invalidate() }
    }
  }

  private static func fetchContacts() -> [ContactIndex.Contact] {
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
    let keys: [any CNKeyDescriptor] = [
      CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
      CNContactOrganizationNameKey as NSString,
      CNContactNicknameKey as NSString,
      CNContactPhoneNumbersKey as NSString,
      CNContactEmailAddressesKey as NSString,
      CNContactThumbnailImageDataKey as NSString,
    ]
    var contacts: [ContactIndex.Contact] = []
    try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) {
      contact,
      _ in
      let name =
        CNContactFormatter.string(from: contact, style: .fullName)
        ?? (contact.organizationName.isEmpty ? nil : contact.organizationName)
        ?? (contact.nickname.isEmpty ? nil : contact.nickname)
      guard let name else { return }
      contacts.append(
        ContactIndex.Contact(
          name: name,
          phoneNumbers: contact.phoneNumbers.map(\.value.stringValue),
          emails: contact.emailAddresses.map { $0.value as String },
          thumbnailImageData: contact.thumbnailImageData
        )
      )
    }
    return contacts
  }
}
