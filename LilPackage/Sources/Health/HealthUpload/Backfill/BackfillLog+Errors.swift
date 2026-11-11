import Dependencies
import Foundation
import HTTPTypes
import OpenAPIRuntime

extension BackfillLog {
  /// Logs `message`, then `error` as ``describe(_:)`` summarizes it: `run stopped after 1.25s:
  /// ClientError(operation: healthUploadBatch, status: 500, underlying: NSError(NSURLErrorDomain
  /// -1001))`. Every error the backfill logs goes through here, never `\(error)`.
  public static func write(_ message: String, error: any Error) {
    guard isEnabled.value else { return }
    write("\(message): \(describe(error))")
  }

  /// An error as its type and a summary that holds no values (851-4183), safe to log as public:
  /// what failed, never what it was failing on.
  ///
  /// An error's description can hold anything: `ClientError`'s has the operation's input and the
  /// request's and response's descriptions, `EncodingError.invalidValue` the value, a decoding
  /// error's debug description the text it couldn't read, and an `NSError`'s user info whatever
  /// its framework put there. So a summary is built from the parts that are codes:
  /// - `ClientError`: the operation ID, the response's status and the underlying error, itself
  ///   summarized.
  /// - `DecodingError` and `EncodingError`: the case, the type and the coding path. A path shows
  ///   the keys a type declares (its `CodingKeys`, an enum) and array indexes; any other key, such
  ///   as a dictionary's, whose keys are data, is `<key>`. Never the value or the debug
  ///   description.
  /// - A Cocoa error (`HKError`, `URLError`, which arrive as `NSError`, so `NSError(com.apple.healthkit
  ///   6)`): its domain and code, and its underlying error, summarized. Never its user info.
  /// - Any other Swift error: its type and an enum's case. Our own errors (`Health…` and `Lil…`
  ///   modules) show the fields named in ``keptFields`` too; other fields, and every field of
  ///   another module's error, show their type only.
  public static func describe(_ error: any Error) -> String {
    describe(error, depth: 0)
  }

  /// Fields of our own errors that hold counts, codes and type names, never a person's data:
  /// `SeriesUnavailable`'s `expected` and `read`, `TooLarge`'s `bytes`, `Rejected`'s
  /// `statusCode`, `LineTooLong`'s `entity`, `UnsupportedSample`'s `type`. A field not named here
  /// is logged as its type.
  static let keptFields: Set<String> = [
    "bytes", "code", "entity", "expected", "read", "retryAfter", "status", "statusCode", "type",
  ]

  /// How deep underlying errors are followed.
  private static let maxDepth = 4

  private static func describe(_ error: any Error, depth: Int) -> String {
    guard depth < maxDepth else { return typeName(error) }
    switch error {
    case let error as ClientError:
      let status = error.response.map { ", status: \($0.status.code)" } ?? ""
      return "ClientError(operation: \(identifier(error.operationID))\(status)"
        + "\(underlying(error.underlyingError, depth: depth)))"
    case let error as DecodingError:
      return describe(error, depth: depth)
    case let error as EncodingError:
      switch error {
      case .invalidValue(let value, let context):
        return "EncodingError.invalidValue(\(typeName(of: type(of: value)))"
          + "\(describe(context.codingPath))\(underlying(context.underlyingError, depth: depth)))"
      @unknown default:
        return "EncodingError"
      }
    case is CancellationError:
      return "CancellationError"
    default:
      break
    }
    let nsError = error as NSError
    // A Swift error's domain is its type's name, unless it says otherwise (`CustomNSError`).
    // Anything else is Cocoa's, whose user info and description can hold anything.
    if nsError.domain != String(reflecting: type(of: error)) {
      let underlying = underlying(
        nsError.userInfo[NSUnderlyingErrorKey] as? any Error, depth: depth)
      return "\(typeName(error))(\(identifier(nsError.domain)) \(nsError.code)\(underlying))"
    }
    return describeFields(of: error)
  }

  private static func describe(_ error: DecodingError, depth: Int) -> String {
    switch error {
    case .typeMismatch(let type, let context):
      "DecodingError.typeMismatch(\(typeName(of: type))\(details(context, depth: depth)))"
    case .valueNotFound(let type, let context):
      "DecodingError.valueNotFound(\(typeName(of: type))\(details(context, depth: depth)))"
    case .keyNotFound(let key, let context):
      "DecodingError.keyNotFound(\(name(of: key))\(details(context, depth: depth)))"
    case .dataCorrupted(let context):
      "DecodingError.dataCorrupted(\(details(context, depth: depth).dropFirst(2)))"
    @unknown default:
      "DecodingError"
    }
  }

  /// `, at: samples[3].end, underlying: …`, or nothing.
  private static func details(_ context: DecodingError.Context, depth: Int) -> String {
    describe(context.codingPath) + underlying(context.underlyingError, depth: depth)
  }

  private static func underlying(_ error: (any Error)?, depth: Int) -> String {
    error.map { ", underlying: \(describe($0, depth: depth + 1))" } ?? ""
  }

  /// `, at: samples[3].end`, or nothing for the top level.
  private static func describe(_ path: [any CodingKey]) -> String {
    guard !path.isEmpty else { return "" }
    var text = ""
    for key in path {
      let name = name(of: key)
      text += name.hasPrefix("[") || text.isEmpty ? name : ".\(name)"
    }
    return ", at: \(text)"
  }

  /// A key a type declares (`startDate`), as written in code; an array's index (`[3]`); or
  /// `<key>` for any other, such as a dictionary's, whose keys are data even when they read as
  /// names (`Ada`, `72`). Declared keys are cases of a `CodingKeys` enum, without payloads; the
  /// coders' own keys are an enum too, Foundation's `_CodingKey`, but with them (`.index(3)`,
  /// which reads `Index 3`, or a dictionary's `.string("Ada")`).
  private static func name(of key: any CodingKey) -> String {
    if let index = key.intValue, key.stringValue == "Index \(index)" { return "[\(index)]" }
    let mirror = Mirror(reflecting: key)
    if mirror.displayStyle == .enum, mirror.children.isEmpty { return identifier(key.stringValue) }
    return "<key>"
  }

  /// `text` if it reads as a name in code (letters, digits, `_`, `.`, `-`, at most 100), as
  /// domains, operation IDs and coding keys do, or `<key>`.
  private static func identifier(_ text: String) -> String {
    let isIdentifier =
      !text.isEmpty && text.count <= 100
      && text.unicodeScalars.allSatisfy {
        ($0.isASCII && (CharacterSet.alphanumerics.contains($0)))
          || "_.-".unicodeScalars.contains($0)
      }
    return isIdentifier ? text : "<key>"
  }

  /// A Swift error as its type, an enum's case, and its kept fields: `SeriesUnavailable(expected:
  /// 4, read: 2)`, `Failure.server`, `LineTooLong(entity: health_sample, id: <String>)`.
  private static func describeFields(of error: any Error) -> String {
    let name = typeName(error)
    let module = String(reflecting: type(of: error)).prefix { $0 != "." }
    let isOurs = module.hasPrefix("Health") || module.hasPrefix("Lil")
    let mirror = Mirror(reflecting: error)
    switch mirror.displayStyle {
    case .enum:
      // A case with a payload is its only child, labelled with the case's name. One without has
      // no children, and only its description names it, unless the type has its own, which
      // could say anything. (Not `is CustomStringConvertible`, which every error is, as an
      // `NSError`.)
      if let label = mirror.children.first?.label { return "\(name).\(label)" }
      let description = String(describing: error)
      let isPlain =
        String(reflecting: error) == "\(String(reflecting: type(of: error))).\(description)"
      return isPlain ? "\(name).\(identifier(description))" : name
    case .struct, .class:
      let fields = mirror.children.compactMap { child -> String? in
        guard let label = child.label else { return nil }
        return
          "\(label): \(isOurs ? field(label, child.value) : "<\(typeName(of: type(of: child.value)))>")"
      }
      return fields.isEmpty ? name : "\(name)(\(fields.joined(separator: ", ")))"
    default:
      return name
    }
  }

  /// A kept field's value if it's a number, a flag or a name, or one of those optional, otherwise
  /// its type.
  private static func field(_ label: String, _ value: Any) -> String {
    guard keptFields.contains(label) else { return "<\(typeName(of: type(of: value)))>" }
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
      return mirror.children.first.map { field(label, $0.value) } ?? "nil"
    }
    switch value {
    case let value as any BinaryInteger: return "\(value)"
    case let value as Double: return "\(value)"
    case let value as Bool: return "\(value)"
    case let value as String: return identifier(value)
    default: return "<\(typeName(of: type(of: value)))>"
    }
  }

  private static func typeName(_ error: any Error) -> String {
    typeName(of: type(of: error))
  }

  /// A type's name without its module: `HealthBatchUploader.Rejected`, `HKError`.
  static func typeName(of type: Any.Type) -> String {
    let name = String(reflecting: type)
    guard let dot = name.firstIndex(of: "."), !name.hasPrefix("(") else { return name }
    return String(name[name.index(after: dot)...])
  }
}
