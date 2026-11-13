// swift-tools-version: 6.0
import PackageDescription

// 獨立的驗證套件：不依賴專案根目錄的 Package.swift，也不寫入根目錄的 .build。
// ProductCode 只透過符號連結編譯真正的產品原始碼，沒有複製的副本。
let package = Package(
    name: "SwiftToolchainVerification",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ProductCode"),
        .testTarget(name: "ProductCodeTests", dependencies: ["ProductCode"]),
    ]
)
