// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacHelperKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .library(name: "Metrics", targets: ["Metrics"]),
        .library(name: "FanControl", targets: ["FanControl"]),
        .library(name: "HelperProtocol", targets: ["HelperProtocol"]),
        .library(name: "PrivilegedOps", targets: ["PrivilegedOps"]),
        .library(name: "DiskScan", targets: ["DiskScan"]),
        .library(name: "CleanEngine", targets: ["CleanEngine"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "SettingsPortability", targets: ["SettingsPortability"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
        .executable(name: "machelper", targets: ["machelper"]),
        .executable(name: "mhprobe", targets: ["mhprobe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Thin C layer: struct layouts and private API declarations only. No logic.
        .target(
            name: "CSystemBridge",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("IOReport"),
            ]
        ),
        .target(name: "SMCKit", dependencies: ["CSystemBridge"]),
        .target(name: "Metrics", dependencies: ["CSystemBridge", "SMCKit"]),
        .target(name: "FanControl"),
        .target(name: "DiskScan", dependencies: ["CSystemBridge"]),
        .target(name: "CleanEngine", dependencies: ["DiskScan", "PrivilegedOps"], resources: [.copy("Rules"), .copy("Artifacts"), .copy("UninstallRules"),
                                                                  .process("Localizable.xcstrings"), .process("Rules.xcstrings")]),
        .target(name: "Storage", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "SettingsPortability", dependencies: ["CleanEngine", "FanControl"]),
        .target(name: "Diagnostics", dependencies: ["CleanEngine", "Storage"], resources: [.process("Localizable.xcstrings")]),
        .executableTarget(
            name: "machelper",
            dependencies: ["CleanEngine", "Diagnostics", "DiskScan", "Metrics", "SMCKit", "Storage",
                           .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        // Fixed allowlists for what the root Helper may delete or switch; no dependencies.
        .target(name: "PrivilegedOps"),
        .target(name: "HelperProtocol", dependencies: ["SMCKit", "FanControl"], linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "mhprobe", dependencies: ["SMCKit", "Metrics"]),
        .testTarget(name: "SMCKitTests", dependencies: ["SMCKit"]),
        .testTarget(name: "FanControlTests", dependencies: ["FanControl"]),
        .testTarget(name: "DiskScanTests", dependencies: ["DiskScan"]),
        .testTarget(name: "CleanEngineTests", dependencies: ["CleanEngine"]),
        .testTarget(name: "PrivilegedOpsTests", dependencies: ["PrivilegedOps"]),
        .testTarget(name: "StorageTests", dependencies: ["Storage"]),
        .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics", "Storage"]),
        .testTarget(name: "SettingsPortabilityTests", dependencies: ["SettingsPortability", "CleanEngine", "FanControl"]),
    ]
)
