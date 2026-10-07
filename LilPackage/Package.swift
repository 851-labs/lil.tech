// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "LilPackage",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .library(name: "MessagesApp", targets: ["MessagesApp"]),
    .library(name: "MessagesDatabase", targets: ["MessagesDatabase"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      from: "1.26.0",
      traits: ["ComposableArchitecture2Deprecations"]
    ),
    .package(
      url: "https://github.com/pointfreeco/sqlite-data",
      from: "1.12.0",
      traits: ["Tagged"]
    ),
    .package(url: "https://github.com/pointfreeco/swift-tagged", from: "0.10.0"),
  ],
  targets: [
    .target(
      name: "MessagesApp",
      dependencies: [
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture")
      ]
    ),
    .testTarget(
      name: "MessagesAppTests",
      dependencies: [
        "MessagesApp"
      ]
    ),
    .target(
      name: "MessagesDatabase",
      dependencies: [
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Tagged", package: "swift-tagged"),
      ]
    ),
    .testTarget(
      name: "MessagesDatabaseTests",
      dependencies: [
        "MessagesDatabase"
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)

let isCI = Context.environment["CI"] != nil

for target in package.targets {
  target.swiftSettings =
    (target.swiftSettings ?? []) + [
      .enableUpcomingFeature("ExistentialAny"),
      .enableUpcomingFeature("ImmutableWeakCaptures"),
      .enableUpcomingFeature("InferIsolatedConformances"),
      .enableUpcomingFeature("InternalImportsByDefault"),
      .enableUpcomingFeature("MemberImportVisibility"),
      .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ]
  if isCI {
    target.swiftSettings?.append(.treatAllWarnings(as: .error))
  }
}
