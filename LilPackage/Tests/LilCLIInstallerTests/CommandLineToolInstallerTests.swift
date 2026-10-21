import Foundation
import Testing

@testable import LilCLIInstaller

/// Installs fake `lil`s, shell scripts that print their version, into a temporary directory.
struct CommandLineToolInstallerTests {
  let root: URL
  let bin: URL

  init() throws {
    root = URL.temporaryDirectory.appending(
      path: "LilCLIInstallerTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    bin = root.appending(path: "home/.local/bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func fakeLil(version: Int, at url: URL) throws -> URL {
    try script("[ \"$1\" = --version ] && echo 'lil \(version)'", at: url)
  }

  func script(_ body: String, at url: URL) throws -> URL {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  var installed: URL { bin.appending(path: "lil") }

  @Test
  func decides() {
    typealias Installer = CommandLineToolInstaller
    #expect(Installer.decide(bundledVersion: 5, existing: .none) == .install)
    #expect(Installer.decide(bundledVersion: 5, existing: .lil(version: 4)) == .replace(version: 4))
    #expect(Installer.decide(bundledVersion: 5, existing: .lil(version: 5)) == .keep(version: 5))
    #expect(Installer.decide(bundledVersion: 5, existing: .lil(version: 6)) == .keep(version: 6))
    #expect(Installer.decide(bundledVersion: 5, existing: .other) == .leaveAlone)
  }

  @Test
  func installsCreatingTheDirectory() async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))

    let outcome = try await CommandLineToolInstaller.install(bundled, into: bin)

    #expect(outcome == .installed(installed, replacedVersion: nil))
    #expect(try Data(contentsOf: installed) == Data(contentsOf: bundled))
    #expect(CommandLineToolInstaller.existing(at: installed) == .lil(version: 5))
    // A copy, not a link into the app, which could move.
    let type = try FileManager.default.attributesOfItem(atPath: installed.path)[.type]
    #expect(type as? FileAttributeType == .typeRegular)
  }

  @Test
  func replacesAnOlderLil() async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))
    _ = try fakeLil(version: 4, at: installed)

    #expect(
      try await CommandLineToolInstaller.install(bundled, into: bin)
        == .installed(installed, replacedVersion: 4)
    )
    #expect(CommandLineToolInstaller.existing(at: installed) == .lil(version: 5))
  }

  @Test(arguments: [5, 6])
  func keepsTheSameOrANewerLil(version: Int) async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))
    _ = try fakeLil(version: version, at: installed)

    #expect(
      try await CommandLineToolInstaller.install(bundled, into: bin)
        == .upToDate(installed, version: version)
    )
    #expect(CommandLineToolInstaller.existing(at: installed) == .lil(version: version))
  }

  @Test
  func leavesAnotherCommandAlone() async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))
    let other = try script("echo 'Lilypond helper'", at: installed)
    let contents = try Data(contentsOf: other)

    #expect(
      try await CommandLineToolInstaller.install(bundled, into: bin) == .otherCommand(installed)
    )
    #expect(try Data(contentsOf: installed) == contents)
  }

  @Test
  func replacesABrokenLink() async throws {
    let bundled = try fakeLil(version: 5, at: root.appending(path: "app/lil"))
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: installed.path,
      withDestinationPath: root.appending(path: "Moved.app/Contents/MacOS/lil").path
    )

    #expect(
      try await CommandLineToolInstaller.install(bundled, into: bin)
        == .installed(installed, replacedVersion: nil)
    )
    #expect(CommandLineToolInstaller.existing(at: installed) == .lil(version: 5))
  }

  @Test
  func refusesABundledToolThatDoesntRun() async throws {
    let bundled = try script("exit 1", at: root.appending(path: "app/lil"))

    await #expect(throws: CommandLineToolInstaller.Failure.self) {
      try await CommandLineToolInstaller.install(bundled, into: bin)
    }
    #expect(!FileManager.default.fileExists(atPath: installed.path))
  }

  @Test
  func writabilityLooksAtTheClosestExistingDirectory() throws {
    #expect(CommandLineToolInstaller.isWritable(bin))
    #expect(!CommandLineToolInstaller.isWritable(URL(filePath: "/System/lil-tests/bin")))
  }
}
