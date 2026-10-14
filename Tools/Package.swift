// swift-tools-version: 6.4

// Command-line tools used by scripts in this repo, pinned here so everyone runs the same versions.
// Not part of the app; nothing depends on this package.

import PackageDescription

let package = Package(
  name: "Tools",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.1")
  ]
)
