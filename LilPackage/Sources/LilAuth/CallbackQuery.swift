import Foundation

/// A browser callback's query fields, decoded as a form encodes them: `+` is a space (the API's
/// redirect encodes spaces that way, and `URLComponents.queryItems` leaves them as `+`). A field
/// that's there twice gives its first value.
struct CallbackQuery {
  private let fields: [String: String]

  init(_ callback: URL) {
    let query =
      URLComponents(url: callback, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
    let decode = { (part: Substring) in
      let spaced = part.replacingOccurrences(of: "+", with: " ")
      return spaced.removingPercentEncoding ?? spaced
    }
    var fields: [String: String] = [:]
    for pair in query.split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let name = decode(parts[0])
      if fields[name] == nil { fields[name] = parts.count > 1 ? decode(parts[1]) : "" }
    }
    self.fields = fields
  }

  subscript(_ name: String) -> String? { fields[name] }
}
