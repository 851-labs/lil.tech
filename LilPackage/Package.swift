// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "LilPackage",
  platforms: [
    .iOS(.v26),
    .macOS(.v26),
  ],
  products: [
    .library(name: "HealthAgentAccess", targets: ["HealthAgentAccess"]),
    .library(name: "HealthCatalog", targets: ["HealthCatalog"]),
    .library(name: "HealthCLI", targets: ["HealthCLI"]),
    .library(name: "HealthDatabase", targets: ["HealthDatabase"]),
    .library(name: "HealthKitAccess", targets: ["HealthKitAccess"]),
    .library(name: "HealthMacApp", targets: ["HealthMacApp"]),
    .library(name: "HealthPages", targets: ["HealthPages"]),
    .library(name: "HealthPhoneApp", targets: ["HealthPhoneApp"]),
    .library(name: "HealthTools", targets: ["HealthTools"]),
    .library(name: "HealthUpload", targets: ["HealthUpload"]),
    .library(name: "LilAPI", targets: ["LilAPI"]),
    .library(name: "LilAuth", targets: ["LilAuth"]),
    .library(name: "LilCLI", targets: ["LilCLI"]),
    .library(name: "LilCLIInstaller", targets: ["LilCLIInstaller"]),
    .library(name: "LilSync", targets: ["LilSync"]),
    .library(name: "LilUpdates", targets: ["LilUpdates"]),
    .library(name: "MessagesContacts", targets: ["MessagesContacts"]),
    .library(name: "MessagesConversationList", targets: ["MessagesConversationList"]),
    .library(name: "MessagesDatabase", targets: ["MessagesDatabase"]),
    .library(name: "MessagesMacApp", targets: ["MessagesMacApp"]),
    .library(name: "MessagesOnboarding", targets: ["MessagesOnboarding"]),
    .library(name: "MessagesSending", targets: ["MessagesSending"]),
    .library(name: "MessagesThread", targets: ["MessagesThread"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0"),
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
    // Whether command-line tools and agents may read lil health's data on the Mac, and their access
    // log: shared by the app and the `lil-health` command.
    .target(
      name: "HealthAgentAccess",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift")
      ]
    ),
    .testTarget(
      name: "HealthAgentAccessTests",
      dependencies: [
        "HealthAgentAccess"
      ]
    ),
    .target(
      name: "HealthCatalog"
    ),
    .target(
      name: "HealthUI",
      dependencies: ["HealthCatalog"]
    ),
    // `lil-health`, lil health for Mac's command-line tool: the Health toolkit's queries on the
    // Mac's database, read-only, while command-line and agent access is on (851-2843).
    .target(
      name: "HealthCLI",
      dependencies: [
        "HealthAgentAccess",
        "HealthCatalog",
        "HealthDatabase",
        "HealthTools",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    // `lil-health` for `swift run lil-health-dev` and HealthCLITests. The app bundles the same
    // main.swift, built by an Xcode tool target of its own (`lil-health` in LilHealth.xcodeproj),
    // as `lil` is.
    .executableTarget(
      name: "lil-health-dev",
      dependencies: ["HealthCLI"],
      path: "Sources/lil-health"
    ),
    .testTarget(
      name: "HealthCLITests",
      dependencies: [
        "HealthAgentAccess",
        "HealthCLI",
        "HealthDatabase",
        "HealthTools",
        "lil-health-dev",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ]
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
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ]
    ),
    .testTarget(
      name: "HealthDatabaseTests",
      dependencies: [
        "HealthDatabase",
        "LilAPI",
        "LilSync",
        "LilTestSupport",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        // `SyncBootstrapBenchmark` sends requests the way the app's client does.
        .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
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
        "HealthAgentAccess",
        "HealthCatalog",
        "HealthDatabase",
        "HealthPages",
        "HealthUI",
        "LilAuth",
        "LilSync",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ]
    ),
    .testTarget(
      name: "HealthMacAppTests",
      dependencies: [
        "HealthAgentAccess",
        "HealthCatalog",
        "LilTestSupport",
        "HealthDatabase",
        "HealthMacApp",
        "LilAuth",
        "LilSync",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
    // lil health for Mac's data pages (Sleep, Workouts, Medications…), which HealthMacApp's browse
    // and sidebar open, and what the Mac's pages and shell share (page colors, MetricFormat,
    // previewFrame).
    .target(
      name: "HealthPages",
      dependencies: [
        "HealthCatalog",
        "HealthDatabase",
        "HealthUI",
        "LilSync",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ]
    ),
    .testTarget(
      name: "HealthPagesTests",
      dependencies: [
        "HealthCatalog",
        "HealthDatabase",
        "HealthPages",
      ]
    ),
    .target(
      name: "HealthPhoneApp",
      dependencies: [
        "HealthCatalog",
        "HealthKitAccess",
        "HealthUI",
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
    // The Health toolkit (`Services/api/src/health/tools/HealthToolkit.ts`, 851-2841) on the Mac's
    // database: each tool's answer, as the toolkit's output schemas have it. `lil-health`'s
    // commands, and its MCP server, use them.
    .target(
      name: "HealthTools",
      dependencies: [
        "HealthCatalog",
        "HealthDatabase",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .testTarget(
      name: "HealthToolsTests",
      dependencies: [
        "HealthCatalog",
        "HealthDatabase",
        "HealthTools",
        .product(name: "SQLiteData", package: "sqlite-data"),
      ]
    ),
    .target(
      name: "HealthUpload",
      dependencies: [
        "HealthCatalog",
        "HealthKitAccess",
        "LilAPI",
        "LilGzip",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "IssueReporting", package: "swift-issue-reporting"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
      ]
    ),
    .testTarget(
      name: "HealthUploadTests",
      dependencies: [
        "HealthUpload",
        "LilAPI",
        "LilGzip",
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
      ],
      // Google's G and font, for its sign-in button.
      resources: [.process("Resources")]
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
    // `lil`, the command that runs each app's own (`lil health …` runs `lil-health …`), like git.
    .target(
      name: "LilCLI"
    ),
    // `lil` for `swift run lil-dev` and LilCLITests. The apps bundle the same main.swift, built
    // by an Xcode tool target of their own (`lil` in LilHealth.xcodeproj). Named apart from it,
    // so the two don't build the same file in a workspace's shared products folder.
    .executableTarget(
      name: "lil-dev",
      dependencies: ["LilCLI"],
      path: "Sources/lil"
    ),
    .testTarget(
      name: "LilCLITests",
      dependencies: [
        "LilCLI",
        "lil-dev",
      ]
    ),
    // An app's Install Command Line Tool… menu item, which installs the `lil` it bundles.
    .target(
      name: "LilCLIInstaller",
      dependencies: ["LilCLI"]
    ),
    .testTarget(
      name: "LilCLIInstallerTests",
      dependencies: [
        "LilCLI",
        "LilCLIInstaller",
      ]
    ),
    .target(
      name: "LilGzip"
    ),
    .target(
      name: "LilSync",
      dependencies: [
        "LilAPI",
        "LilGzip",
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
        "LilGzip",
        "LilSync",
        "LilTestSupport",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
      ]
    ),
    .target(
      name: "LilUpdates",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle")
      ]
    ),
    .target(
      name: "MessagesContacts",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies")
      ]
    ),
    .testTarget(
      name: "MessagesContactsTests",
      dependencies: [
        "MessagesContacts"
      ]
    ),
    .target(
      name: "MessagesConversationList",
      dependencies: [
        "MessagesContacts",
        "MessagesDatabase",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Tagged", package: "swift-tagged"),
      ]
    ),
    .testTarget(
      name: "MessagesConversationListTests",
      dependencies: [
        "MessagesConversationList"
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
      name: "MessagesMacApp",
      dependencies: [
        "MessagesContacts",
        "MessagesConversationList",
        "MessagesDatabase",
        "MessagesOnboarding",
        "MessagesThread",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ]
    ),
    .testTarget(
      name: "MessagesMacAppTests",
      dependencies: [
        "MessagesMacApp"
      ]
    ),
    .target(
      name: "MessagesOnboarding",
      dependencies: [
        "MessagesDatabase",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(
      name: "MessagesOnboardingTests",
      dependencies: [
        "MessagesOnboarding"
      ]
    ),
    .target(
      name: "MessagesSending",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies")
      ]
    ),
    .testTarget(
      name: "MessagesSendingTests",
      dependencies: [
        "MessagesSending"
      ]
    ),
    .target(
      name: "MessagesThread",
      dependencies: [
        "MessagesDatabase",
        "MessagesSending",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Tagged", package: "swift-tagged"),
      ]
    ),
    .testTarget(
      name: "MessagesThreadTests",
      dependencies: [
        "MessagesThread"
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
