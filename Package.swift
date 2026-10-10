// swift-tools-version:5.9
import Foundation
import PackageDescription

// Breakaway is a macOS app. The simulation engine (BreakawayCore) is plain Swift
// + Foundation so it also builds and tests on Linux CI; the app target needs
// SwiftUI, SceneKit and CoreBluetooth and is only declared on Apple platforms.

var products: [Product] = [
    .library(name: "BreakawayCore", targets: ["BreakawayCore"]),
]

var targets: [Target] = [
    .target(
        name: "BreakawayCore",
        path: "Sources/BreakawayCore"
    ),
    .testTarget(
        name: "BreakawayCoreTests",
        dependencies: ["BreakawayCore"],
        path: "Tests/BreakawayCoreTests"
    ),
]

#if os(macOS)
// Embed Info.plist in the executable so macOS shows the Bluetooth permission
// prompt even when the app is launched straight from `swift run` or Xcode.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/Breakaway/Info.plist").path

products.append(.executable(name: "Breakaway", targets: ["Breakaway"]))
targets.append(
    .executableTarget(
        name: "Breakaway",
        dependencies: ["BreakawayCore"],
        path: "Sources/Breakaway",
        exclude: ["Info.plist"],
        linkerSettings: [
            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
        ]
    )
)
#endif

let package = Package(
    name: "Breakaway",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
