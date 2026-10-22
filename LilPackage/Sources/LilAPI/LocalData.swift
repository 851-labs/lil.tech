public import Foundation

/// Where an app keeps a server's local data: its database, caches, settings and other state that
/// belongs to the account signed in to that server (851-2977).
///
/// - Builds that only ever use prod (Release Mac builds, iPhone builds on a device) keep today's
///   folders and user defaults, unchanged, so updating moves and migrates nothing.
/// - Builds that can be pointed at another server (`allowsOverride`: the simulator's and Debug Mac
///   builds) keep each server's data apart, prod's included, in `Servers/<server>` inside the
///   folder a Release build uses, and their settings in a user defaults suite per server. So a
///   dev build never reads, replaces or deletes the Release app's data (signing out deletes the
///   account's), and switching a dev build between servers keeps each one's.
///
/// The Keychain's sessions are kept apart the same way (`SessionStore.keychainQuery`, 851-2974).
extension APIEnvironment {
  /// `baseURL`'s scheme, host and port, spelled one way: lowercased, without a default port. One
  /// server is one origin, however its URL is spelled.
  public var origin: String { Self.origin(baseURL) }

  /// `url`'s scheme, host and port, spelled one way: lowercased, without a default port.
  public static func origin(_ url: URL) -> String {
    let scheme = url.scheme?.lowercased() ?? ""
    let host = url.host(percentEncoded: false)?.lowercased() ?? ""
    let defaultPort = ["https": 443, "http": 80][scheme]
    let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)"
  }

  /// Whether this build keeps this server's data where it always has, rather than apart: only
  /// prod, in a build that can't use anything else. The Keychain's session follows the same
  /// rule, so a build's session and its local data are always kept apart together.
  public func usesDefaultLocation(allowsOverride: Bool = Self.allowsOverride) -> Bool {
    self == .prod && !allowsOverride
  }

  /// The folder this server's local data goes in, given the folder a Release build uses:
  /// `directory` itself for a build that only uses prod, else `directory/Servers/<server>`, e.g.
  /// `tech.lil.health/Servers/api.staging.lil.tech`.
  public func localDirectory(
    in directory: URL, allowsOverride: Bool = Self.allowsOverride
  ) -> URL {
    guard !usesDefaultLocation(allowsOverride: allowsOverride) else { return directory }
    return directory.appending(path: "Servers", directoryHint: .isDirectory)
      .appending(path: localFolderName, directoryHint: .isDirectory)
  }

  /// The user defaults suite for this server's settings, given the app's bundle ID: `nil` for a
  /// build that only uses prod, which keeps the app's own (`UserDefaults.standard`), else one
  /// per server, e.g. `tech.lil.health.Servers.api.staging.lil.tech`. A suite rather than a key
  /// per server, so every setting a dev build keeps is apart from the Release app's, including
  /// ones added later.
  public func localDefaultsSuiteName(
    bundleIdentifier: String, allowsOverride: Bool = Self.allowsOverride
  ) -> String? {
    guard !usesDefaultLocation(allowsOverride: allowsOverride) else { return nil }
    return "\(bundleIdentifier).Servers.\(localFolderName)"
  }

  /// The user defaults for this server's settings (``localDefaultsSuiteName(bundleIdentifier:allowsOverride:)``):
  /// `UserDefaults.standard` for a build that only uses prod.
  public func localDefaults(
    bundleIdentifier: String? = Bundle.main.bundleIdentifier,
    allowsOverride: Bool = Self.allowsOverride
  ) -> UserDefaults {
    guard
      let name = localDefaultsSuiteName(
        bundleIdentifier: bundleIdentifier ?? "lil", allowsOverride: allowsOverride)
    else { return .standard }
    // Only `nil` for the app's own bundle ID or the global domain, which `name` never is. Never
    // `.standard` instead: that's the Release app's.
    return UserDefaults(suiteName: name)!
  }

  /// The origin as a folder name: without `https://`, and with anything other than lowercase
  /// letters, digits, `.`, `-` and `_` percent-encoded, e.g. `api.staging.lil.tech` and
  /// `http%3A%2F%2Flocalhost%3A8787`. Distinct origins get distinct names: a host can't contain
  /// `%`, and what's left of an `https` origin can't start with `http%3A%2F%2F`.
  var localFolderName: String {
    let origin = origin
    let name = origin.hasPrefix("https://") ? String(origin.dropFirst("https://".count)) : origin
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
    return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
  }
}
