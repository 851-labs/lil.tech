// Fetches the Developer ID provisioning profile a headless Mac release exports with (851-3076),
// through the App Store Connect API, making it when it's missing or no longer usable.
// Usage: xcrun swift scripts/developer-id-profile.swift <bundle-id> <certificate-sha1> <directory>
//   bundle-id         The app's bundle identifier, e.g. tech.lil.health.
//   certificate-sha1  The SHA-1 of the Developer ID Application certificate the export signs with,
//                     as `security find-identity` prints it.
//   directory         Where to write the profile, as <uuid>.provisionprofile.
// The API key comes from LIL_RELEASE_ASC_KEY_PATH, LIL_RELEASE_ASC_KEY_ID and
// LIL_RELEASE_ASC_ISSUER_ID, as in scripts/release. Prints the profile's UUID.
//
// The profile is ours, named after the bundle identifier ("lil.tech CI Developer ID <bundle-id>"),
// never the one Xcode manages: an export with manual signing needs a profile it doesn't manage, and
// that one's certificates are Xcode's choice. It's used as long as it's active, for the bundle
// identifier, and holds the certificate; otherwise it's deleted and made again with just that
// certificate. A team key can make Developer ID profiles, but not use cloud-managed Developer ID
// certificates, which are only the Account Holder's: so the export can't sign with automatic
// signing headless.
import CryptoKit
import Foundation

struct Failure: Error, CustomStringConvertible {
  var description: String
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else {
  FileHandle.standardError.write(
    Data(
      "usage: xcrun swift scripts/developer-id-profile.swift <bundle-id> <certificate-sha1> <directory>\n"
        .utf8))
  exit(64)
}
let bundleIdentifier = arguments[0]
let certificateHash = arguments[1].uppercased()
let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
let profileName = "lil.tech CI Developer ID \(bundleIdentifier)"

func log(_ message: String) {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func environment(_ name: String) throws -> String {
  guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
    throw Failure(description: "\(name) isn't set")
  }
  return value
}

func base64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

func hex(_ data: some Sequence<UInt8>) -> String {
  data.map { String(format: "%02X", $0) }.joined()
}

/// A token for the API: ES256, signed with the key, valid for 10 minutes, which is longer than
/// this takes.
func makeToken() throws -> String {
  let pem = try String(contentsOfFile: try environment("LIL_RELEASE_ASC_KEY_PATH"), encoding: .utf8)
  let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
  let now = Int(Date().timeIntervalSince1970)
  let header = try JSONSerialization.data(
    withJSONObject: [
      "alg": "ES256", "kid": try environment("LIL_RELEASE_ASC_KEY_ID"), "typ": "JWT",
    ])
  let payload = try JSONSerialization.data(
    withJSONObject: [
      "iss": try environment("LIL_RELEASE_ASC_ISSUER_ID"), "iat": now, "exp": now + 600,
      "aud": "appstoreconnect-v1",
    ])
  let input = "\(base64URL(header)).\(base64URL(payload))"
  let signature = try key.signature(for: Data(input.utf8))
  return "\(input).\(base64URL(signature.rawRepresentation))"
}

let token = try makeToken()

typealias Resource = [String: Any]

func url(_ path: String, _ query: [String: String] = [:]) -> URL {
  var components = URLComponents(string: "https://api.appstoreconnect.apple.com\(path)")!
  if !query.isEmpty {
    components.queryItems = query.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0, value: $1)
    }
  }
  return components.url!
}

@discardableResult
func send(_ method: String, _ url: URL, body: Resource? = nil) async throws -> Resource {
  var request = URLRequest(url: url)
  request.httpMethod = method
  request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
  if let body {
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  }
  let (data, response) = try await URLSession.shared.data(for: request)
  let status = (response as? HTTPURLResponse)?.statusCode ?? 0
  let object = (try? JSONSerialization.jsonObject(with: data)) as? Resource ?? [:]
  guard (200..<300).contains(status) else {
    // The API's errors name what's wrong, never the key.
    let errors = (object["errors"] as? [Resource] ?? [])
      .map { "\($0["title"] ?? ""): \($0["detail"] ?? "")" }
      .joined(separator: "; ")
    throw Failure(description: "\(method) \(url.path) failed (\(status)): \(errors)")
  }
  return object
}

/// Every page of a list.
func list(_ path: String, _ query: [String: String]) async throws -> [Resource] {
  var resources: [Resource] = []
  var next: URL? = url(path, query)
  while let page = next {
    let object = try await send("GET", page)
    resources += object["data"] as? [Resource] ?? []
    next = ((object["links"] as? Resource)?["next"] as? String).flatMap(URL.init(string:))
  }
  return resources
}

func attributes(_ resource: Resource) -> Resource {
  resource["attributes"] as? Resource ?? [:]
}

func relatedIDs(_ resource: Resource, _ relationship: String) -> [String] {
  let data = ((resource["relationships"] as? Resource)?[relationship] as? Resource)?["data"]
  if let one = data as? Resource { return [one["id"] as? String].compactMap { $0 } }
  return (data as? [Resource] ?? []).compactMap { $0["id"] as? String }
}

do {
  let bundleIDs = try await list(
    "/v1/bundleIds",
    ["filter[identifier]": bundleIdentifier, "fields[bundleIds]": "identifier", "limit": "200"])
  // The filter matches prefixes too (tech.lil.health.debug).
  guard
    let bundleID = bundleIDs.first(where: {
      attributes($0)["identifier"] as? String == bundleIdentifier
    })?["id"] as? String
  else {
    throw Failure(description: "No bundle ID \(bundleIdentifier) in the team")
  }

  let certificates = try await list(
    "/v1/certificates",
    ["fields[certificates]": "certificateContent,certificateType,displayName", "limit": "200"])
  guard
    let certificate = certificates.first(where: {
      guard let content = attributes($0)["certificateContent"] as? String,
        let der = Data(base64Encoded: content)
      else { return false }
      return hex(Insecure.SHA1.hash(data: der)) == certificateHash
    }), let certificateID = certificate["id"] as? String
  else {
    throw Failure(description: "The certificate \(certificateHash) isn't one of the team's")
  }
  let certificateType = attributes(certificate)["certificateType"] as? String ?? ""
  guard certificateType.hasPrefix("DEVELOPER_ID_APPLICATION") else {
    throw Failure(
      description:
        "The certificate \(certificateHash) is \(certificateType), not Developer ID Application")
  }

  let existing = try await list(
    "/v1/profiles",
    [
      "filter[name]": profileName,
      "fields[profiles]": "name,profileType,profileState,profileContent,uuid,bundleId,certificates",
      "include": "bundleId,certificates",
      "limit[certificates]": "50",
      "limit": "200",
    ]
  ).filter { attributes($0)["name"] as? String == profileName }
  var profile = existing.first {
    let attributes = attributes($0)
    return attributes["profileType"] as? String == "MAC_APP_DIRECT"
      && attributes["profileState"] as? String == "ACTIVE"
      && relatedIDs($0, "bundleId") == [bundleID]
      && relatedIDs($0, "certificates").contains(certificateID)
  }
  if profile != nil {
    log("Using the profile \"\(profileName)\"")
  } else {
    // Names are unique, so an unusable profile of ours (another certificate, or invalid) goes first.
    for stale in existing {
      if let id = stale["id"] as? String {
        log(
          "Deleting the profile \"\(profileName)\" (\(attributes(stale)["profileState"] ?? "?")), which can't be used"
        )
        try await send("DELETE", url("/v1/profiles/\(id)"))
      }
    }
    log("Making the profile \"\(profileName)\"")
    let created = try await send(
      "POST", url("/v1/profiles"),
      body: [
        "data": [
          "type": "profiles",
          "attributes": ["name": profileName, "profileType": "MAC_APP_DIRECT"],
          "relationships": [
            "bundleId": ["data": ["type": "bundleIds", "id": bundleID]],
            "certificates": ["data": [["type": "certificates", "id": certificateID]]],
          ],
        ]
      ])
    profile = created["data"] as? Resource
  }

  guard let profile,
    let uuid = attributes(profile)["uuid"] as? String,
    let content = (attributes(profile)["profileContent"] as? String).flatMap({
      Data(base64Encoded: $0)
    })
  else {
    throw Failure(description: "The profile \"\(profileName)\" has no UUID or content")
  }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try content.write(to: directory.appendingPathComponent("\(uuid).provisionprofile"))
  print(uuid)
} catch {
  log("error: \(error)")
  exit(1)
}
