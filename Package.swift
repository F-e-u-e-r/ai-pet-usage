// swift-tools-version: 6.0
import PackageDescription

// 本機 CommandLineTools 的 5.10 manifest 相容層損壞,故以 tools-version 6.0 搭配
// per-target -swift-version 5 維持 Swift 5 語言模式。
let swift5: [SwiftSetting] = [.unsafeFlags(["-swift-version", "5"])]

let package = Package(
    name: "AIPetUsage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .executable(name: "AIPetUsage", targets: ["AIPetUsage"]),
        .executable(name: "aipet", targets: ["aipet"]),
    ],
    targets: [
        .target(
            name: "UsageCore",
            resources: [
                .copy("Resources/model-prices.json"),
                .copy("Resources/model-prices-generated.json"),
            ],
            swiftSettings: swift5
        ),
        .target(name: "PetCore", dependencies: ["UsageCore"], swiftSettings: swift5),
        .executableTarget(name: "AIPetUsage", dependencies: ["UsageCore", "PetCore"], swiftSettings: swift5),
        .executableTarget(name: "aipet", dependencies: ["UsageCore"], swiftSettings: swift5),
        // 註:此機器的 CLT 不含 XCTest,測試以獨立執行檔跑:`Scripts/swiftpm.sh run usagecore-tests`
        .executableTarget(
            name: "usagecore-tests",
            dependencies: ["UsageCore", "PetCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: swift5
        ),
    ]
)
