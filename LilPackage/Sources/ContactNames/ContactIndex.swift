import Foundation

/// Looks up display names by the addresses Messages uses for handles: phone numbers and emails.
///
/// Emails match case-insensitively. Phone numbers match on their digits, falling back to the last
/// 10 digits so a number saved without a country code (`(415) 555-0100`) still matches the E.164
/// form Messages stores (`+14155550100`).
public struct ContactIndex: Sendable {
  private var namesByEmail: [String: String] = [:]
  private var namesByPhoneDigits: [String: String] = [:]
  private var namesByPhoneSuffix: [String: String] = [:]

  public init(_ contacts: [Contact]) {
    for contact in contacts {
      for email in contact.emails {
        let key = Self.normalizedEmail(email)
        namesByEmail[key] = namesByEmail[key] ?? contact.name
      }
      for phone in contact.phoneNumbers {
        let digits = Self.digits(phone)
        guard !digits.isEmpty else { continue }
        namesByPhoneDigits[digits] = namesByPhoneDigits[digits] ?? contact.name
        if let suffix = Self.suffix(digits) {
          namesByPhoneSuffix[suffix] = namesByPhoneSuffix[suffix] ?? contact.name
        }
      }
    }
  }

  public func name(for address: String) -> String? {
    if address.contains("@") {
      return namesByEmail[Self.normalizedEmail(address)]
    }
    let digits = Self.digits(address)
    guard !digits.isEmpty else { return nil }
    return namesByPhoneDigits[digits] ?? Self.suffix(digits).flatMap { namesByPhoneSuffix[$0] }
  }

  public struct Contact: Equatable, Sendable {
    public var name: String
    public var phoneNumbers: [String]
    public var emails: [String]

    public init(name: String, phoneNumbers: [String] = [], emails: [String] = []) {
      self.name = name
      self.phoneNumbers = phoneNumbers
      self.emails = emails
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
