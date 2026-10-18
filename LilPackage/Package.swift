// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "LilPackage",
  platforms: [
    .iOS(.v26),
    .macOS(.v26),
  ],
  products: [
    .library(name: "AppUpdates", targets: ["AppUpdates"]),
    .library(name: "ContactNames", targets: ["ContactNames"]),
    .library(name: "ConversationListFeature", targets: ["ConversationListFeature"]),
    .library(name: "HealthCatalog", targets: ["HealthCatalog"]),
    .library(name: "HealthDatabase", targets: ["HealthDatabase"]),
    .library(name: "HealthKitAccess", targets: ["HealthKitAccess"]),
    .library(name: "HealthMacApp", targets: ["HealthMacApp"]),
    .library(name: "HealthPhoneApp", targets: ["HealthPhoneApp"]),
    .library(name: "HealthUpload", targets: ["HealthUpload"]),
    .library(name: "LilAPI", targets: ["LilAPI"]),
    .library(name: "LilAuth", targets: ["LilAuth"]),
    .library(name: "LilSync", targets: ["LilSync"]),
    .library(name: "MessagesApp", targets: ["MessagesApp"]),
    .library(name: "MessageSending", targets: ["MessageSending"]),
    .library(name: "MessagesDatabase", targets: ["MessagesDatabase"]),
    .library(name: "MessageThreadFeature", targets: ["MessageThreadFeature"]),
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
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.0"),
    .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.2"),
    .package(url: "https://github.com/pointfreeco/swift-issue-reporting", from: "2.0.0"),
    .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
    // Already a dependency of sqlite-data; direct for its prepared statements (HealthDatabase).
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
  ],
  targets: [
    .target(
      name: "AppUpdates",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle")
      ]
    ),
    .target(
      name: "ContactNames",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies")
      ]
    ),
    .testTarget(
      name: "ContactNamesTests",
      dependencies: [
        "ContactNames"
      ]
    ),
    .target(
      name: "ConversationListFeature",
      dependencies: [
        "ContactNames",
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
      name: "GzipFiles"
    ),
    .target(
      name: "HealthCatalog"
    ),
    .testTarget(
      name: "HealthCatalogTests",
      dependencies: [
        "HealthCatalog",
        "HealthKitAccess",
      ]
    ),
    .target(
      name: "HealthDatabase",
      dependencies: [
        "HealthCatalog",
        "LilAPI",
        "LilSync",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ]
    ),
    .testTarget(
      name: "HealthDatabaseTests",
      dependencies: [
        "HealthDatabase",
        "LilTestSupport",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
    .target(
      name: "HealthKitAccess",
      dependencies: [
        "HealthCatalog",
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "HealthKitAccessTests",
      dependencies: [
        "HealthKitAccess"
      ]
    ),
    .target(
      name: "HealthMacApp",
      dependencies: [
        "HealthCatalog",
        "HealthDatabase",
        "LilAuth",
        "LilSync",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ]
    ),
    .testTarget(
      name: "HealthMacAppTests",
      dependencies: [
        "HealthCatalog",
        "HealthDatabase",
        "HealthMacApp",
        "LilAuth",
        "LilSync",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
    .target(
      name: "HealthPhoneApp",
      dependencies: [
        "HealthKitAccess",
        "HealthUpload",
        "LilAuth",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(
      name: "HealthPhoneAppTests",
      dependencies: [
        "HealthCatalog",
        "HealthKitAccess",
        "HealthPhoneApp",
        "HealthUpload",
        "LilAuth",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
    .target(
      name: "HealthUpload",
      dependencies: [
        "GzipFiles",
        "HealthCatalog",
        "HealthKitAccess",
        "LilAPI",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "IssueReporting", package: "swift-issue-reporting"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
      ]
    ),
    .testTarget(
      name: "HealthUploadTests",
      dependencies: [
        "GzipFiles",
        "HealthUpload",
        "LilAPI",
        "LilTestSupport",
      ]
    ),
    .target(
      name: "LilAPI",
      dependencies: [
        "LilAPIGenerated",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "IssueReporting", package: "swift-issue-reporting"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
      ]
    ),
    // Code generated by swift-openapi-generator (scripts/generate-api-client). Its warnings aren't
    // ours to fix, so they're suppressed and CI doesn't treat them as errors.
    .target(
      name: "LilAPIGenerated",
      dependencies: [
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
      ],
      exclude: ["openapi.sha256"],
      swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
    ),
    .testTarget(
      name: "LilAPITests",
      dependencies: [
        "LilAPI",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
    .target(
      name: "LilAuth",
      dependencies: [
        "LilAPI",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "IssueReporting", package: "swift-issue-reporting"),
      ]
    ),
    .testTarget(
      name: "LilAuthTests",
      dependencies: [
        "LilAuth",
        "LilTestSupport",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
      ]
    ),
    .target(
      name: "LilSync",
      dependencies: [
        "GzipFiles",
        "LilAPI",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "IssueReporting", package: "swift-issue-reporting"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ]
    ),
    // Clocks and waiting for test targets (`ManualClock`, `RecordingClock`, `eventually`).
    .target(
      name: "LilTestSupport",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies")
      ],
      path: "Tests/LilTestSupport"
    ),
    .testTarget(
      name: "LilSyncTests",
      dependencies: [
        "GzipFiles",
        "LilSync",
        "LilTestSupport",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
      ]
    ),
    .target(
      name: "MessagesApp",
      dependencies: [
        "ContactNames",
        "ConversationListFeature",
        "MessageThreadFeature",
        "MessagesDatabase",
        "OnboardingFeature",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "SQLiteData", package: "sqlite-data"),
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
        "LilTestSupport",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
    .target(
      name: "MessageSending",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies")
      ]
    ),
    .testTarget(
      name: "MessageSendingTests",
      dependencies: [
        "MessageSending"
      ]
    ),
    .target(
      name: "MessageThreadFeature",
      dependencies: [
        "MessageSending",
        "MessagesDatabase",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Tagged", package: "swift-tagged"),
      ]
    ),
    .testTarget(
      name: "MessageThreadFeatureTests",
      dependencies: [
        "MessageThreadFeature"
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
  if isCI && target.name != "LilAPIGenerated" {
    target.swiftSettings?.append(.treatAllWarnings(as: .error))
  }
}
