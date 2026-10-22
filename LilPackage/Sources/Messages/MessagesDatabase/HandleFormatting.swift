/// Formats a handle address (phone number or email) for display, like Messages does.
///
/// North American numbers get Messages' formatting, e.g. "+18669854321" becomes
/// "+1 (866) 985-4321". Emails, short codes and other international numbers are shown as stored.
public func formattedHandle(_ address: String) -> String {
  guard !address.contains("@") else { return address }
  let digits = address.filter(\.isASCII).filter(\.isNumber)
  let hasCountryCode = address.hasPrefix("+")
  let national: Substring
  switch (hasCountryCode, digits.count) {
  case (true, 11) where digits.hasPrefix("1"), (false, 11) where digits.hasPrefix("1"):
    national = digits.dropFirst()
  case (false, 10):
    national = Substring(digits)
  default:
    return address
  }
  let area = national.prefix(3)
  let exchange = national.dropFirst(3).prefix(3)
  let line = national.suffix(4)
  return "+1 (\(area)) \(exchange)-\(line)"
}
