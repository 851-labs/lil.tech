// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "LilPackage",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .library(name: "ConversationListFeature", targets: ["ConversationListFeature"]),
    .library(name: "MessagesApp", targets: ["MessagesApp"]),
    .library(name: "MessagesDatabase", targets: ["MessagesDatabase"]),
    .library(name: "OnboardingFeature", targets: ["OnboardingFeature"]),
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
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.17.0"),
    .package(url: "https://github.com/pointfreeco/swift-tagged", from: "0.10.0"),
  ],
  targets: [
    .target(
      name: "ConversationListFeature",
      dependencies: [
        "MessagesDatabase",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Tagged", package: "swift-tagged"),
      ]
    ),
    .testTarget(
      name: "ConversationListFeatureTests",
      dependencies: [
        "ConversationListFeature"
      ]
    ),
    .target(
      name: "MessagesApp",
      dependencies: [
        "ConversationListFeature",
        "MessagesDatabase",
        "OnboardingFeature",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
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
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Tagged", package: "swift-tagged"),
      ]
    ),
    .testTarget(
      name: "MessagesDatabaseTests",
      dependencies: [
        "MessagesDatabase",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
    .target(
      name: "OnboardingFeature",
      dependencies: [
        "MessagesDatabase",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(
      name: "OnboardingFeatureTests",
      dependencies: [
        "OnboardingFeature"
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
