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
    // Renders state catalogs to images in `swift test` (HealthSnapshotTests, 851-2931).
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.7"),
    .package(url: "https://github.com/pointfreeco/swift-tagged", from: "0.10.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.0"),
    .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.3.2"),
    .package(url: "https://github.com/pointfreeco/swift-issue-reporting", from: "2.0.0"),
    .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
    // The official MCP SDK, for `lil-health mcp` (851-2844). Exact: it's before 1.0, so a minor
    // release may break its API.
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
    // Already a dependency of sqlite-data; direct for its prepared statements (HealthDatabase).
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
  ],
  targets: [
    // Whether command-line tools and agents may read lil health's data on the Mac, and their access
    // log: shared by the app and the `lil-health` command.
    .target(
      name: "HealthAgentAccess",
      dependencies: [
        // Names the pages the command line asks the app to open, for the log (851-2895).
        "HealthCatalog",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      path: "Sources/Health/HealthAgentAccess"
    ),
    .testTarget(
      name: "HealthAgentAccessTests",
      dependencies: [
        "HealthAgentAccess"
      ],
      path: "Tests/Health/HealthAgentAccessTests"
    ),
    .target(
      name: "HealthCatalog",
      path: "Sources/Health/HealthCatalog"
    ),
    .target(
      name: "HealthUI",
      dependencies: ["HealthCatalog"],
      path: "Sources/Health/HealthUI"
    ),
    // `lil-health`, lil health for Mac's command-line tool: the Health toolkit's queries on the
    // Mac's database, read-only, while command-line and agent access is on (851-2843), as
    // commands and as a local MCP server (`lil-health mcp`, 851-2844).
    .target(
      name: "HealthCLI",
      dependencies: [
        "HealthAgentAccess",
        "HealthCatalog",
        "HealthDatabase",
        "HealthTools",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "MCP", package: "swift-sdk"),
      ],
      path: "Sources/Health/HealthCLI"
    ),
    // `lil-health` for `swift run lil-health-dev` and HealthCLITests. The app bundles the same
    // main.swift, built by an Xcode tool target of its own (`lil-health` in LilHealth.xcodeproj),
    // as `lil` is.
    .executableTarget(
      name: "lil-health-dev",
      dependencies: ["HealthCLI"],
      path: "Sources/Health/lil-health"
    ),
    .testTarget(
      name: "HealthCLITests",
      dependencies: [
        "HealthAgentAccess",
        "HealthCatalog",
        "HealthCLI",
        "HealthDatabase",
        "HealthTools",
        "LilAPI",
        "LilSync",
        "LilTestSupport",
        "lil-health-dev",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ],
      path: "Tests/Health/HealthCLITests"
    ),
    .testTarget(
      name: "HealthCatalogTests",
      dependencies: [
        "HealthCatalog",
        "HealthKitAccess",
      ],
      path: "Tests/Health/HealthCatalogTests"
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
      ],
      path: "Sources/Health/HealthDatabase"
    ),
    .testTarget(
      name: "HealthDatabaseTests",
      dependencies: [
        "HealthDatabase",
        "LilAPI",
        // Snapshot parts for `TestSnapshot`.
        "LilGzip",
        "LilSync",
        "LilTestSupport",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        // `SyncBootstrapBenchmark` sends requests the way the app's client does.
        .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
      ],
      path: "Tests/Health/HealthDatabaseTests"
    ),
    .target(
      name: "HealthKitAccess",
      dependencies: [
        "HealthCatalog",
        .product(name: "Dependencies", package: "swift-dependencies"),
      ],
      path: "Sources/Health/HealthKitAccess"
    ),
    .testTarget(
      name: "HealthKitAccessTests",
      dependencies: [
        "HealthKitAccess"
      ],
      path: "Tests/Health/HealthKitAccessTests"
    ),
    .target(
      name: "HealthMacApp",
      dependencies: [
        "HealthAgentAccess",
        "LilCLIInstaller",
        "HealthCatalog",
        "HealthDatabase",
        "HealthPages",
        "HealthUI",
        "LilAPI",
        "LilAuth",
        "LilSync",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ],
      path: "Sources/Health/HealthMacApp"
    ),
    .testTarget(
      name: "HealthMacAppTests",
      dependencies: [
        "HealthAgentAccess",
        "HealthCatalog",
        "LilTestSupport",
        "HealthDatabase",
        "HealthMacApp",
        "LilAPI",
        "LilAuth",
        "LilSync",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ],
      path: "Tests/Health/HealthMacAppTests"
    ),
    // lil health for Mac's data pages (Sleep, Workouts, Medications…), which HealthMacApp's browse
    // and sidebar open, and what the Mac's pages and shell share (page colors, MetricFormat).
    .target(
      name: "HealthPages",
      dependencies: [
        "HealthCatalog",
        "HealthDatabase",
        "HealthUI",
        "LilSync",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ],
      path: "Sources/Health/HealthPages"
    ),
    // State catalogs of lil health for Mac, rendered to images in `swift test` by
    // swift-snapshot-testing and compared with the references in `__Snapshots__` (851-2931).
    .testTarget(
      name: "HealthSnapshotTests",
      dependencies: [
        "HealthAgentAccess",
        "HealthCatalog",
        "HealthDatabase",
        "HealthMacApp",
        "HealthPages",
        "LilAuth",
        "LilSync",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ],
      path: "Tests/Health/HealthSnapshotTests",
      // References, beside the tests that take them. A new folder of state catalogs adds its own.
      exclude: [
        "Catalogs/HealthMacApp/__Snapshots__",
        "Catalogs/HealthPages/__Snapshots__",
        "Catalogs/LilAuth/__Snapshots__",
      ]
    ),
    .testTarget(
      name: "HealthPagesTests",
      dependencies: [
        "HealthCatalog",
        "HealthDatabase",
        "HealthPages",
      ],
      path: "Tests/Health/HealthPagesTests"
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
      ],
      path: "Sources/Health/HealthPhoneApp"
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
      ],
      path: "Tests/Health/HealthPhoneAppTests"
    ),
    // The Health toolkit (`Services/api/src/health/tools/HealthToolkit.ts`, 851-2841) on the Mac's
    // database: each tool's answer, as the toolkit's output schemas have it. `lil-health`'s
    // commands, and its MCP server, use them.
    .target(
      name: "HealthTools",
      dependencies: [
        "HealthCatalog",
        "HealthDatabase",
        .product(name: "SQLiteData", package: "sqlite-data"),
      ],
      path: "Sources/Health/HealthTools"
    ),
    .testTarget(
      name: "HealthToolsTests",
      dependencies: [
        "HealthCatalog",
        "HealthDatabase",
        "HealthTools",
        .product(name: "SQLiteData", package: "sqlite-data"),
      ],
      path: "Tests/Health/HealthToolsTests"
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
      ],
      path: "Sources/Health/HealthUpload"
    ),
    .testTarget(
      name: "HealthUploadTests",
      dependencies: [
        "HealthUpload",
        "LilAPI",
        "LilGzip",
        "LilTestSupport",
      ],
      path: "Tests/Health/HealthUploadTests"
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
      ],
      path: "Sources/Lil/LilAPI"
    ),
    // Code generated by swift-openapi-generator (scripts/generate-api-client). Its warnings aren't
    // ours to fix, so they're suppressed and CI doesn't treat them as errors.
    .target(
      name: "LilAPIGenerated",
      dependencies: [
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
      ],
      path: "Sources/Lil/LilAPIGenerated",
      exclude: ["openapi.sha256"],
      swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
    ),
    .testTarget(
      name: "LilAPITests",
      dependencies: [
        "LilAPI",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ],
      path: "Tests/Lil/LilAPITests"
    ),
    .target(
      name: "LilAuth",
      dependencies: [
        "LilAPI",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "IssueReporting", package: "swift-issue-reporting"),
      ],
      path: "Sources/Lil/LilAuth",
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
      ],
      path: "Tests/Lil/LilAuthTests"
    ),
    // `lil`, the command that runs each app's own (`lil health …` runs `lil-health …`), like git,
    // and `lil mcp`, one MCP server combining each app's (851-2897).
    .target(
      name: "LilCLI",
      dependencies: [
        .product(name: "MCP", package: "swift-sdk")
      ],
      path: "Sources/Lil/LilCLI"
    ),
    // `lil` for `swift run lil-dev` and LilCLITests. The apps bundle the same main.swift, built
    // by an Xcode tool target of their own (`lil` in LilHealth.xcodeproj). Named apart from it,
    // so the two don't build the same file in a workspace's shared products folder.
    .executableTarget(
      name: "lil-dev",
      dependencies: ["LilCLI"],
      path: "Sources/Lil/lil"
    ),
    .testTarget(
      name: "LilCLITests",
      dependencies: [
        "HealthAgentAccess",
        "HealthDatabase",
        "LilAPI",
        "LilCLI",
        "lil-dev",
        "lil-example",
        "lil-health-dev",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "MCP", package: "swift-sdk"),
      ],
      path: "Tests/Lil/LilCLITests"
    ),
    // A stand-in for a second app's command line tool, for LilCLITests: `lil-example mcp` serves
    // one tool and one resource, so `lil mcp` is tested with two apps while lil health is the only
    // one with a server.
    .executableTarget(
      name: "lil-example",
      dependencies: [
        .product(name: "MCP", package: "swift-sdk")
      ],
      path: "Tests/Lil/lil-example"
    ),
    // An app's Install Command Line Tool… menu item, which installs the `lil` it bundles.
    .target(
      name: "LilCLIInstaller",
      dependencies: ["LilCLI"],
      path: "Sources/Lil/LilCLIInstaller"
    ),
    .testTarget(
      name: "LilCLIInstallerTests",
      dependencies: [
        "LilCLI",
        "LilCLIInstaller",
      ],
      path: "Tests/Lil/LilCLIInstallerTests"
    ),
    .target(
      name: "LilGzip",
      path: "Sources/Lil/LilGzip"
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
      ],
      path: "Sources/Lil/LilSync"
    ),
    // Clocks and waiting for test targets (`ManualClock`, `RecordingClock`, `eventually`).
    .target(
      name: "LilTestSupport",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies")
      ],
      path: "Tests/Lil/LilTestSupport"
    ),
    .testTarget(
      name: "LilSyncTests",
      dependencies: [
        "LilAPI",
        "LilGzip",
        "LilSync",
        "LilTestSupport",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
      ],
      path: "Tests/Lil/LilSyncTests"
    ),
    .target(
      name: "LilUpdates",
      dependencies: [
        .product(name: "Sparkle", package: "Sparkle")
      ],
      path: "Sources/Lil/LilUpdates"
    ),
    .target(
      name: "MessagesContacts",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies")
      ],
      path: "Sources/Messages/MessagesContacts"
    ),
    .testTarget(
      name: "MessagesContactsTests",
      dependencies: [
        "MessagesContacts"
      ],
      path: "Tests/Messages/MessagesContactsTests"
    ),
    .target(
      name: "MessagesConversationList",
      dependencies: [
        "MessagesContacts",
        "MessagesDatabase",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Tagged", package: "swift-tagged"),
      ],
      path: "Sources/Messages/MessagesConversationList"
    ),
    .testTarget(
      name: "MessagesConversationListTests",
      dependencies: [
        "MessagesConversationList"
      ],
      path: "Tests/Messages/MessagesConversationListTests"
    ),
    .target(
      name: "MessagesDatabase",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Tagged", package: "swift-tagged"),
      ],
      path: "Sources/Messages/MessagesDatabase"
    ),
    .testTarget(
      name: "MessagesDatabaseTests",
      dependencies: [
        "MessagesDatabase",
        "LilTestSupport",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ],
      path: "Tests/Messages/MessagesDatabaseTests"
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
      ],
      path: "Sources/Messages/MessagesMacApp"
    ),
    .testTarget(
      name: "MessagesMacAppTests",
      dependencies: [
        "MessagesMacApp"
      ],
      path: "Tests/Messages/MessagesMacAppTests"
    ),
    .target(
      name: "MessagesOnboarding",
      dependencies: [
        "MessagesDatabase",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ],
      path: "Sources/Messages/MessagesOnboarding"
    ),
    .testTarget(
      name: "MessagesOnboardingTests",
      dependencies: [
        "MessagesOnboarding"
      ],
      path: "Tests/Messages/MessagesOnboardingTests"
    ),
    .target(
      name: "MessagesSending",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies")
      ],
      path: "Sources/Messages/MessagesSending"
    ),
    .testTarget(
      name: "MessagesSendingTests",
      dependencies: [
        "MessagesSending"
      ],
      path: "Tests/Messages/MessagesSendingTests"
    ),
    // lil messages for Mac's state catalogs (851-2968), rendered as HealthSnapshotTests' are. Its
    // snapshot support is HealthSnapshotTests' own files, linked (symlinks), as the iPhone's
    // target builds them. Synthetic conversations only, never a real `chat.db`.
    .testTarget(
      name: "MessagesSnapshotTests",
      dependencies: [
        "MessagesConversationList",
        "MessagesDatabase",
        "MessagesMacApp",
        "MessagesOnboarding",
        "MessagesThread",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
        .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "Tagged", package: "swift-tagged"),
      ],
      path: "Tests/Messages/MessagesSnapshotTests",
      // References, beside the tests that take them. A new folder of state catalogs adds its own.
      exclude: [
        "Catalogs/MessagesConversationList/__Snapshots__",
        "Catalogs/MessagesMacApp/__Snapshots__",
        "Catalogs/MessagesOnboarding/__Snapshots__",
        "Catalogs/MessagesThread/__Snapshots__",
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
      ],
      path: "Sources/Messages/MessagesThread"
    ),
    .testTarget(
      name: "MessagesThreadTests",
      dependencies: [
        "MessagesThread"
      ],
      path: "Tests/Messages/MessagesThreadTests"
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
