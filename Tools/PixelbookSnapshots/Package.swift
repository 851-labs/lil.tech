// swift-tools-version: 6.4

import PackageDescription

// Renders the Mac apps' SwiftUI previews to PNGs for Pixelbook (851-2696), with SnapshotPreviews.
// Its own package, so LilPackage's tests (and the pre-commit hook) don't render previews. The
// iPhone's need a host app, so they're in PixelbookHost/. `scripts/pixelbook` runs both.
let package = Package(
  name: "PixelbookSnapshots",
  platforms: [
    .iOS(.v26),
    .macOS(.v26),
  ],
  dependencies: [
    .package(path: "../../LilPackage"),
    .package(url: "https://github.com/getsentry/SnapshotPreviews", exact: "0.20.0"),
  ],
  targets: [
    .testTarget(
      name: "HealthMacSnapshots",
      dependencies: [
        .product(name: "HealthMacApp", package: "LilPackage"),
        .product(name: "SnapshottingTests", package: "SnapshotPreviews"),
      ]
    )
  ]
)
