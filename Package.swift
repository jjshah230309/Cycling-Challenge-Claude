// swift-tools-version:5.9
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
products.append(.executable(name: "Breakaway", targets: ["Breakaway"]))
targets.append(
    .executableTarget(
        name: "Breakaway",
        dependencies: ["BreakawayCore"],
        path: "Sources/Breakaway",
        exclude: ["Info.plist"]
    )
)
#endif

let package = Package(
    name: "Breakaway",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
