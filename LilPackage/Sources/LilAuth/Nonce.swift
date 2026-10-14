import CryptoKit
import Foundation

/// Sign-in nonces. Apple and Google get a nonce's SHA-256 (hex) and the server gets the nonce,
/// so both must match the server's `checkNonce`.
enum Nonce {
  /// `count` random bytes as lowercase hex.
  static func randomHex(bytes count: Int, using generator: inout some RandomNumberGenerator)
    -> String
  {
    (0..<count).map { _ in
      String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
    }
    .joined()
  }

  /// The SHA-256 of `string` as lowercase hex: what the provider gets for a nonce.
  static func sha256Hex(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
