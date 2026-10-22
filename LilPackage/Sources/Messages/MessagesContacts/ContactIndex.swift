public import Foundation

/// Looks up contacts by the addresses Messages uses for handles: phone numbers and emails.
///
/// Emails match case-insensitively. Phone numbers match on their digits, falling back to the last
/// 10 digits so a number saved without a country code (`(415) 555-0100`) still matches the E.164
/// form Messages stores (`+14155550100`).
public struct ContactIndex: Sendable {
  private var contactsByEmail: [String: Contact] = [:]
  private var contactsByPhoneDigits: [String: Contact] = [:]
  private var contactsByPhoneSuffix: [String: Contact] = [:]

  public init(_ contacts: [Contact]) {
    for contact in contacts {
      for email in contact.emails {
        let key = Self.normalizedEmail(email)
        contactsByEmail[key] = contactsByEmail[key] ?? contact
      }
      for phone in contact.phoneNumbers {
        let digits = Self.digits(phone)
        guard !digits.isEmpty else { continue }
        contactsByPhoneDigits[digits] = contactsByPhoneDigits[digits] ?? contact
        if let suffix = Self.suffix(digits) {
          contactsByPhoneSuffix[suffix] = contactsByPhoneSuffix[suffix] ?? contact
        }
      }
    }
  }

  public func contact(for address: String) -> Contact? {
    if address.contains("@") {
      return contactsByEmail[Self.normalizedEmail(address)]
    }
    let digits = Self.digits(address)
    guard !digits.isEmpty else { return nil }
    return contactsByPhoneDigits[digits]
      ?? Self.suffix(digits).flatMap { contactsByPhoneSuffix[$0] }
  }

  public func name(for address: String) -> String? {
    contact(for: address)?.name
  }

  /// The contact's photo thumbnail, as image data (usually JPEG).
  public func thumbnail(for address: String) -> Data? {
    contact(for: address)?.thumbnailImageData
  }

  public struct Contact: Equatable, Sendable {
    public var name: String
    public var phoneNumbers: [String]
    public var emails: [String]
    public var thumbnailImageData: Data?

    public init(
      name: String,
      phoneNumbers: [String] = [],
      emails: [String] = [],
      thumbnailImageData: Data? = nil
    ) {
      self.name = name
      self.phoneNumbers = phoneNumbers
      self.emails = emails
      self.thumbnailImageData = thumbnailImageData
    }
  }

  private static func normalizedEmail(_ email: String) -> String {
    email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func digits(_ phone: String) -> String {
    String(phone.unicodeScalars.filter { ("0"..."9").contains($0) }.map(Character.init))
  }

  private static func suffix(_ digits: String) -> String? {
    digits.count >= 10 ? String(digits.suffix(10)) : nil
  }
}
