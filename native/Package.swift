// swift-tools-version:5.10
// Portable core + headless bridge build on Linux and macOS. The Dock app target exists only on macOS.
import PackageDescription

var targets: [Target] = [
    .target(name: "BridgeCore", path: "Sources/BridgeCore", swiftSettings: [.unsafeFlags(["-enable-testing"], .when(configuration: .debug))]),
    .executableTarget(name: "t3wow-bridge", dependencies: ["BridgeCore"], path: "Sources/HeadlessBridge"),
    .executableTarget(name: "bridgecore-tests", dependencies: ["BridgeCore"], path: "Tests/BridgeCoreTests"),
]
var products: [Product] = [
    .executable(name: "t3wow-bridge", targets: ["t3wow-bridge"]),
    .executable(name: "bridgecore-tests", targets: ["bridgecore-tests"]),
]
#if os(macOS)
targets.append(.executableTarget(name: "T3ForWoWApp", dependencies: ["BridgeCore"], path: "Sources/App",
                                 linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit"),
                                                  .linkedFramework("Security"), .linkedFramework("ServiceManagement"), .linkedFramework("Vision")]))
products.append(.executable(name: "T3ForWoWApp", targets: ["T3ForWoWApp"]))
#endif

let package = Package(
    name: "T3ForWoW",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
