import Foundation

/// A new, empty directory for one test.
func makeTemporaryDirectory() throws -> URL {
  let url = URL.temporaryDirectory.appending(
    path: "LilCLITests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Writes an executable shell script, creating its directory.
@discardableResult
func writeScript(_ body: String, to url: URL, executable: Bool = true) throws -> URL {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
  try FileManager.default.setAttributes(
    [.posixPermissions: executable ? 0o755 : 0o644],
    ofItemAtPath: url.path
  )
  return url
}
